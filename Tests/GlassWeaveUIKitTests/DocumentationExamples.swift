// The Swift examples of Sources/GlassWeave/GlassWeave.docc/GlassWeave.md that
// need UIKit, copied verbatim so the package build compiles them and
// DocumentationExampleTests runs them. scripts/check_doc_examples.py (run in
// CI) fails if the catalog and this file drift apart.
#if canImport(UIKit)
import GlassWeaveUIKit
import UIKit

/// Genuine Apple glass around a native button. Creates no GlassWeave renderer.
@MainActor
func makeNativeGlassButton(title: String, action: UIAction) -> NativeGlassView {
    let glass = NativeGlassView(configuration: .init(tintColor: nil, isInteractive: true))
    glass.cornerConfiguration = .capsule()
    let button = UIButton(configuration: .plain(), primaryAction: action)
    button.configuration?.title = title
    button.translatesAutoresizingMaskIntoConstraints = false
    glass.contentView.addSubview(button)
    NSLayoutConstraint.activate([
        button.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 20),
        button.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -20),
        button.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 8),
        button.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -8),
    ])
    return glass
}

import GlassWeave
import GlassWeaveUIKit
import Metal
import UIKit

/// One rounded glass panel over a background the app renders itself.
@MainActor
final class GlassStage {
    let surface: GlassSurfaceView
    private let pool: FrameTexturePool
    private var nextFrameID: UInt64 = 1
    private let start = ContinuousClock.now

    init(commandQueue: any MTLCommandQueue) throws {
        surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: commandQueue))
        // The presented frame plus the two the surface may have in flight.
        pool = FrameTexturePool(
            device: commandQueue.device,
            descriptor: .init(
                pixelFormat: .bgra8Unorm,
                usage: [.renderTarget, .shaderRead, .pixelFormatView],
                sampledPixelFormat: .bgra8Unorm_srgb
            ),
            capacity: 3
        )
        surface.setFrameProducer { [weak self] commandBuffer, pixelSize in
            self?.produceFrame(into: commandBuffer, pixelSize: pixelSize)
        }
        // While the surface is not visible, give free textures back.
        surface.visibilityHandler = { [weak self] visible in
            if !visible { self?.pool.trim() }
        }
    }

    /// Places the panel over `frame`, in the surface's points: for example,
    /// the frame of the native content the panel carries.
    func placePanel(over frame: CGRect) throws {
        try surface.setPanel(GlassPanel(
            frame: frame,
            parameters: GlassParameters(cornerRadius: 30, bezelWidth: 22, refraction: 0.85)
        ))
    }

    /// Encodes the app's background into a pooled texture, inside the draw's
    /// own command buffer, and hands it over.
    private func produceFrame(
        into commandBuffer: any MTLCommandBuffer,
        pixelSize: (width: Int, height: Int)
    ) -> BackgroundFrameLease? {
        guard let pooled = pool.checkout(width: pixelSize.width, height: pixelSize.height) else {
            return nil // Every texture is in use: skip; the current frame is drawn again.
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = pooled.storage
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            pool.returnUnused(pooled)
            return nil
        }
        // Draw your background here.
        encoder.endEncoding()
        let frame = BackgroundFrame(
            texture: pooled.texture,
            frameID: nextFrameID,
            timestamp: ContinuousClock.now - start,
            colorConvention: .sRGBOpaque,
            readiness: .encoded(in: commandBuffer)
        )
        nextFrameID += 1
        return pool.lease(frame, using: pooled) { _ in }
    }
}

import GlassWeave
import GlassWeaveUIKit
import Metal

/// Shows a still image whose upload was committed to the renderer's queue.
/// `reusable` runs once the surface and the GPU are done with the texture.
@MainActor
func presentStill(
    _ texture: any MTLTexture,
    on surface: GlassSurfaceView,
    reusable: @escaping @Sendable (BackgroundFrameRelease) -> Void
) throws(BackgroundSourceError) {
    let frame = BackgroundFrame(
        texture: texture,
        frameID: 1,
        timestamp: .zero,
        colorConvention: .sRGBOpaque,
        readiness: .committed(on: surface.renderer.commandQueue)
    )
    let lease = BackgroundFrameLease(frame: frame, onRelease: reusable)
    try surface.setSource(lease)
    // This frame goes to no other consumer.
    lease.retire()
}

import GlassWeave
import UIKit

/// A panel tint that keeps label text at 4.5:1 over any background, or 7:1
/// with Increase Contrast.
func legibleTint(for traits: UITraitCollection) -> GlassTint {
    var tint = traits.userInterfaceStyle == .dark
        ? GlassTint(red: 0.08, green: 0.09, blue: 0.12, strength: 0.45)
        : GlassTint(red: 0.97, green: 0.98, blue: 1.0, strength: 0.45)
    let target = traits.accessibilityContrast == .high ? 7.0 : 4.5
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    UIColor.label.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    let text = GlassTint.relativeLuminance(red: red, green: green, blue: blue)
    if let minimum = tint.minimumStrength(forContrast: target, againstTextLuminance: text) {
        tint.strength = max(tint.strength, minimum)
    }
    return tint
}

import GlassWeave
import GlassWeaveUIKit
import UIKit

/// Genuine Apple glass around a button, with a warm rim lit from the top and
/// a soft halo. Creates no GlassWeave renderer.
@MainActor
func makeGlowingNativeButton(title: String, action: UIAction) throws -> EnhancedNativeGlassView {
    let host = EnhancedNativeGlassView(configuration: .init(isInteractive: true))
    host.glass.cornerConfiguration = .capsule()
    let button = UIButton(configuration: .plain(), primaryAction: action)
    button.configuration?.title = title
    button.translatesAutoresizingMaskIntoConstraints = false
    host.glass.contentView.addSubview(button)
    NSLayoutConstraint.activate([
        button.leadingAnchor.constraint(equalTo: host.glass.contentView.leadingAnchor, constant: 20),
        button.trailingAnchor.constraint(equalTo: host.glass.contentView.trailingAnchor, constant: -20),
        button.topAnchor.constraint(equalTo: host.glass.contentView.topAnchor, constant: 8),
        button.bottomAnchor.constraint(equalTo: host.glass.contentView.bottomAnchor, constant: -8),
    ])
    try host.setGlow(GlassGlow(
        colors: [.init(red: 1, green: 0.62, blue: 0.25)],
        rimWidth: 2, rimSoftness: 2,
        lightAngle: 0, directionality: 0.7,
        haloRadius: 24, haloIntensity: 0.8
    ))
    return host
}
#endif
