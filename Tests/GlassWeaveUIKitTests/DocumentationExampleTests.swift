#if canImport(UIKit)
import Metal
import MetalKit
import Testing
import UIKit
@testable import GlassWeave
@testable import GlassWeaveUIKit

/// Runs the UIKit examples of the DocC catalog (DocumentationExamples.swift)
/// and checks that each does what the documentation says.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DocumentationExampleTests {
    let device: any MTLDevice
    let queue: any MTLCommandQueue

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
    }

    @Test func `The native example is Apple glass around an actionable button, with no renderer`() throws {
        var taps = 0
        let action = UIAction { _ in taps += 1 }
        let (glass, created) = RendererCensus.counting {
            makeNativeGlassButton(title: "Native action", action: action)
        }
        #expect(created == 0, "Native mode created a GlassWeave renderer")
        #expect(glass.effect is UIGlassEffect)
        #expect(glass.configuration == NativeGlassView.Configuration(tintColor: nil, isInteractive: true))
        let button = try #require(glass.contentView.subviews.first as? UIButton)
        #expect(button.configuration?.title == "Native action")
        button.sendActions(for: .primaryActionTriggered)
        #expect(taps == 1)
        glass.frame = CGRect(x: 0, y: 0, width: 220, height: 60)
        glass.layoutIfNeeded()
        #expect(!glass.subviews.contains { $0 is MTKView })
    }

    @Test func `The custom example produces each frame and draws it with the panel`() async throws {
        let stage = try GlassStage(commandQueue: queue)
        let surface = stage.surface
        // A test process has no window scene; stand in for a visible one.
        surface.sceneStateOverride = .foregroundActive
        surface.frame = CGRect(x: 0, y: 0, width: 160, height: 120)
        surface.layoutIfNeeded()
        try stage.placePanel(over: CGRect(x: 20, y: 20, width: 120, height: 80))
        #expect(surface.panel?.frame == CGRect(x: 20, y: 20, width: 120, height: 80))

        for expected in UInt64(1)...3 {
            surface.requestFrame()
            surface.renderNow()
            #expect(surface.lastRenderOutcome == .submitted(frameID: expected))
            #expect(surface.renderer.currentFrame?.frameID == expected)
            // Let the frame complete, so the in-flight bound never defers
            // the next draw of this synchronous loop.
            let deadline = ContinuousClock.now + .seconds(5)
            while surface.frameStatistics.framesInFlight > 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        #expect(surface.lastProducedFrameError == nil)
        #expect(surface.presentedPanel != nil)
        #expect(surface.frameStatistics.submitted == 3)
        #expect(surface.frameStatistics.peakFramesInFlight <= GlassSurfaceView.maximumFramesInFlight)

        // Hiding the surface calls the visibility handler, which trims the
        // pool; drawing then defers until the surface is shown again.
        surface.isHidden = true
        #expect(!surface.isVisible)
        surface.requestFrame()
        surface.renderNow()
        #expect(surface.frameStatistics.submitted == 3)
    }

    @Test func `The still example presents a committed upload and reports its release`() async throws {
        let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
        let texture = try uploadedTexture()
        let recorder = ReleaseRecorder()
        try presentStill(texture, on: surface, reusable: recorder.handler)
        #expect(surface.renderer.currentFrame?.frameID == 1)
        #expect(recorder.releases.isEmpty, "The surface still presents the frame")

        surface.clearSource()
        let deadline = ContinuousClock.now + .seconds(5)
        while recorder.releases.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(recorder.releases.map(\.frameID) == [1])
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark], [UIAccessibilityContrast.normal, .high])
    func `The legible tint keeps the documented contrast`(style: UIUserInterfaceStyle, contrast: UIAccessibilityContrast) {
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = style
            traits.accessibilityContrast = contrast
        }
        let tint = legibleTint(for: traits)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor.label.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let text = GlassTint.relativeLuminance(red: red, green: green, blue: blue)
        let target = contrast == .high ? 7.0 : 4.5
        #expect(tint.worstCaseContrast(againstTextLuminance: text) >= target - 1e-9)
        #expect(tint.strength >= 0.45)
    }

    /// A 4 × 4 sRGB texture whose upload is committed to `queue`.
    private func uploadedTexture() throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: 4, height: 4, mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead]
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let bytes = [UInt8](repeating: 128, count: 4 * 4 * 4)
        let staging = try #require(device.makeBuffer(bytes: bytes, length: bytes.count, options: .storageModeShared))
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: staging, sourceOffset: 0, sourceBytesPerRow: 16, sourceBytesPerImage: bytes.count,
            sourceSize: MTLSize(width: 4, height: 4, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        commandBuffer.commit()
        return texture
    }
}
#endif
