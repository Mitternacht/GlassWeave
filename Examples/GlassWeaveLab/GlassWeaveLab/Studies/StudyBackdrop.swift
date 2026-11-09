import CoreGraphics
import GlassWeave
import Metal
import UIKit

/// The four material studies (GW-29): each is a lab screen that shows one
/// reference-level look over a procedural background, with native controls
/// above the glass. `-lab.study pearl|pill|shelf|vessel` opens one at launch.
enum StudyKind: String, CaseIterable {
    case pearl
    case pill
    case shelf
    case vessel

    var title: String {
        switch self {
        case .pearl: String(localized: "Pearl")
        case .pill: String(localized: "Pill")
        case .shelf: String(localized: "Shelf")
        case .vessel: String(localized: "Vessel")
        }
    }

    /// The study named by `-lab.study`, or `nil`.
    static var launchRequested: StudyKind? {
        UserDefaults.standard.string(forKey: "lab.study").flatMap(StudyKind.init(rawValue:))
    }

    var fragmentName: String { "study_\(rawValue)_fragment" }
}

/// What a study's background shows, in points: everything
/// `StudyBackgrounds.metal` reads. The picture is a pure function of this
/// value, so the producer draws a new frame only when it changes.
struct StudyBackdrop: Equatable {
    var pixelWidth = 0
    var pixelHeight = 0
    var displayScale = 1.0
    var dark = false
    var screenSize = CGSize.zero
    /// The script time, in seconds, for the pictures that move (the shelf's
    /// pebbles); zero for the others, which are still.
    var time = 0.0
    var progress = 0.0
    /// Up to six rectangles the picture draws into (the pearl's plate and
    /// well), in points on the screen.
    var rects: [CGRect] = []

    static let maximumRects = 6

    var shaderParameters: [SIMD4<Float>] {
        var parameters: [SIMD4<Float>] = [
            SIMD4(0, 0, Float(displayScale), dark ? 1 : 0),
            SIMD4(Float(screenSize.width), Float(screenSize.height), Float(time), Float(progress)),
        ]
        for index in 0..<Self.maximumRects {
            if index < rects.count {
                let rect = rects[index]
                parameters.append(SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height)))
            } else {
                parameters.append(.zero)
            }
        }
        return parameters
    }
}

/// Draws one study's background with one pipeline into pooled frames for the
/// glass surface.
final class StudyBackdropRenderer {
    enum Failure: Error, CustomStringConvertible {
        case shaderUnavailable(String)

        var description: String {
            switch self {
            case let .shaderUnavailable(reason): "The study background shader is unavailable: \(reason)."
            }
        }
    }

    /// The presented frame plus the surface's two frames in flight.
    static let textureLimit = 3

    private let pipeline: any MTLRenderPipelineState
    private let pool: FrameTexturePool
    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant
    private var nextFrameID: UInt64 = 1

    /// Frames produced for the glass surface so far.
    private(set) var producedCount = 0

    init(device: any MTLDevice, kind: StudyKind) throws {
        guard let library = device.makeDefaultLibrary() else {
            throw Failure.shaderUnavailable("no default library in the app bundle")
        }
        guard let vertex = library.makeFunction(name: "study_vertex"),
              let fragment = library.makeFunction(name: kind.fragmentName)
        else {
            throw Failure.shaderUnavailable("missing \(kind.fragmentName)")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "GlassWeaveLab study \(kind.rawValue)"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw Failure.shaderUnavailable(String(describing: error))
        }
        pool = FrameTexturePool(
            device: device,
            descriptor: FrameTexturePool.Descriptor(
                pixelFormat: .bgra8Unorm,
                usage: [.renderTarget, .shaderRead, .pixelFormatView],
                sampledPixelFormat: BackgroundColorConvention.sRGBOpaque.requiredPixelFormat
            ),
            capacity: Self.textureLimit
        )
        start = clock.now
    }

    /// Encodes the background into `commandBuffer` and returns its lease, or
    /// `nil` when no texture is free.
    func encodeFrame(into commandBuffer: any MTLCommandBuffer, backdrop: StudyBackdrop) -> BackgroundFrameLease? {
        guard backdrop.pixelWidth > 0, backdrop.pixelHeight > 0,
              let pooled = pool.checkout(width: backdrop.pixelWidth, height: backdrop.pixelHeight)
        else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = pooled.storage
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        let frameID = nextFrameID
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            pool.returnUnused(pooled)
            return nil
        }
        var parameters = backdrop.shaderParameters
        encoder.label = "GlassWeaveLab study background \(frameID)"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&parameters, length: parameters.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        nextFrameID += 1
        producedCount += 1
        let frame = BackgroundFrame(
            texture: pooled.texture,
            frameID: frameID,
            timestamp: clock.now - start,
            colorConvention: .sRGBOpaque,
            readiness: .encoded(in: commandBuffer)
        )
        return pool.lease(frame, using: pooled) { _ in }
    }

    /// Gives free textures back to Metal while the screen is not visible.
    func trim() {
        pool.trim()
    }
}
