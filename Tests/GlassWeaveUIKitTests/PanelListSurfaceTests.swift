#if canImport(UIKit)
import Metal
import Testing
import UIKit
@testable import GlassWeave
@testable import GlassWeaveUIKit

/// Several panels on one `GlassSurfaceView` (GW-20): `setPanels(_:)` draws an
/// ordered list in one pass, applies the accessibility policy to each panel,
/// redraws once per change, and runs the effect clock while any presented
/// panel animates, so a surface whose panels have all settled submits
/// nothing.
///
/// A test process has no window scenes, so the scene state comes from
/// `sceneStateOverride` and ticks are delivered by calling `effectTick`, as
/// the view's `UIUpdateLink` would. The laboratory's gallery UI tests run the
/// real link.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct PanelListSurfaceTests {
    let device: any MTLDevice
    let queue: any MTLCommandQueue

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        queue = try #require(device.makeCommandQueue())
    }

    static let colors: [GlassGlow.ColorStop] = [.init(red: 1, green: 0.5, blue: 0.2)]

    /// A glow with a halo; `pulse` adds a pulse.
    static func glow(pulse: Bool) -> GlassGlow {
        GlassGlow(colors: colors, innerGlowRadius: 10, innerGlowIntensity: 0.6, haloRadius: 8, haloIntensity: 0.8,
                  pulsePeriod: 1.5, pulseDepth: pulse ? 0.5 : 0)
    }

    static func interior(speed: Double) -> GlassInterior {
        GlassInterior(effect: .rays, colors: [.init(red: 1, green: 0.8, blue: 0.3)], speed: speed, seed: 3)
    }

    /// Three panels side by side whose quads do not overlap.
    static func panels(pulse: Bool = false, interiorSpeed: Double? = nil) -> [GlassPanel] {
        [
            GlassPanel(frame: CGRect(x: 10, y: 20, width: 40, height: 60), parameters: GlassParameters(cornerRadius: 20, glow: glow(pulse: false))),
            GlassPanel(frame: CGRect(x: 72, y: 20, width: 40, height: 60), parameters: GlassParameters(
                cornerRadius: 20, glow: glow(pulse: pulse), interior: interiorSpeed.map(interior(speed:)) ?? .none
            )),
            GlassPanel(frame: CGRect(x: 134, y: 20, width: 40, height: 60), parameters: GlassParameters(cornerRadius: 20)),
        ]
    }

    private func makeSurface(settings: GlassAccessibilitySettings = GlassAccessibilitySettings()) throws -> GlassSurfaceView {
        let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
        surface.sceneStateOverride = .foregroundActive
        surface.accessibilitySettingsSource = .fixed(settings)
        surface.traitOverrides.displayScale = 2
        surface.frame = CGRect(x: 0, y: 0, width: 190, height: 100)
        surface.updateTraitsIfNeeded()
        surface.layoutIfNeeded()
        try surface.setSource(makeLease())
        return surface
    }

    /// A small still source uploaded on `queue`.
    private func makeLease() throws -> BackgroundFrameLease {
        let pattern = OrientationPattern(width: 8, height: 6)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: pattern.width, height: pattern.height, mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead]
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let bytes = pattern.bgraBytes()
        let staging = try #require(device.makeBuffer(bytes: bytes, length: bytes.count, options: .storageModeShared))
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: staging, sourceOffset: 0,
            sourceBytesPerRow: pattern.width * 4, sourceBytesPerImage: bytes.count,
            sourceSize: MTLSize(width: pattern.width, height: pattern.height, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        commandBuffer.commit()
        let frame = BackgroundFrame(
            texture: texture, frameID: 1, timestamp: .zero,
            colorConvention: .sRGBOpaque, readiness: .committed(on: queue)
        )
        return BackgroundFrameLease(frame: frame, onRelease: { _ in })
    }

    private func settle(_ surface: GlassSurfaceView) async throws {
        surface.renderNow()
        let deadline = ContinuousClock.now + .seconds(10)
        while surface.frameStatistics.framesInFlight > 0 {
            #expect(ContinuousClock.now < deadline, "GPU work did not complete")
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func `The panels are normalized, presented in order, and drawn once per change`() async throws {
        let surface = try makeSurface()
        try await settle(surface)
        let empty = surface.frameStatistics.submitted
        let panels = Self.panels()
        try surface.setPanels(panels)
        let normalized = try panels.map { try $0.normalized() }
        #expect(surface.panels == normalized)
        #expect(surface.presentedPanels == surface.panels, "No setting changes these panels")
        #expect(surface.panel == surface.panels.first)
        #expect(surface.presentedPanel == surface.presentedPanels.first)
        #expect(!surface.isAnimating, "Nothing on these panels animates")
        try await settle(surface)
        #expect(surface.frameStatistics.submitted == empty + 1)

        // Setting the same list again draws nothing.
        try surface.setPanels(panels)
        try await settle(surface)
        #expect(surface.frameStatistics.submitted == empty + 1)

        // A non-finite value in any panel throws and keeps the panels.
        var broken = panels
        broken[2].parameters.refraction = .infinity
        #expect(throws: GlassParameterError.nonFinite(.refraction)) { try surface.setPanels(broken) }
        #expect(surface.panels.count == 3)

        // setPanel replaces the list with one panel.
        try surface.setPanel(panels[2])
        #expect(surface.panels.count == 1)
        try surface.setPanel(nil)
        #expect(surface.panels.isEmpty)
        #expect(surface.presentedPanels.isEmpty)
    }

    @Test func `The policy applies to every panel`() throws {
        let transparency = try makeSurface(settings: GlassAccessibilitySettings(reduceTransparency: true))
        try transparency.setPanels(Self.panels(pulse: true, interiorSpeed: 1))
        #expect(transparency.presentedPanels.count == 3)
        for presented in transparency.presentedPanels {
            #expect(presented.parameters.tint.strength == 1, "Opaque body")
            #expect(presented.parameters.refraction == 0)
            #expect(!presented.parameters.glow.hasHalo)
            #expect(!presented.parameters.interior.isVisible)
        }
        #expect(!transparency.isAnimating)

        let motion = try makeSurface(settings: GlassAccessibilitySettings(reduceMotion: true))
        try motion.setPanels(Self.panels(pulse: true, interiorSpeed: 1))
        #expect(motion.presentedPanels[1].parameters.glow.pulseDepth == 0)
        #expect(motion.presentedPanels[1].parameters.interior.speed == 0)
        #expect(motion.presentedPanels[0].parameters.glow == motion.panels[0].parameters.glow, "A steady glow is kept")
        #expect(!motion.isAnimating)
    }

    @Test func `The clock runs while any panel animates and stops when all have settled`() async throws {
        let surface = try makeSurface()
        try surface.setPanels(Self.panels())
        #expect(!surface.isAnimating)
        // One pulsing panel among three.
        try surface.setPanels(Self.panels(pulse: true))
        #expect(surface.isAnimating)
        // One moving interior, no pulse.
        try surface.setPanels(Self.panels(interiorSpeed: 1))
        #expect(surface.isAnimating)
        // A still interior: nothing animates.
        try surface.setPanels(Self.panels(interiorSpeed: 0))
        #expect(!surface.isAnimating)

        // Animated: one frame per tick.
        try surface.setPanels(Self.panels(pulse: true, interiorSpeed: 1))
        try await settle(surface)
        let start = surface.frameStatistics.submitted
        for tick in 1...6 {
            surface.effectTick(modelTime: 100 + Double(tick) / 60)
            try await settle(surface)
        }
        #expect(surface.frameStatistics.submitted == start + 6)
        // Settled: drawn once, then nothing, whatever ticks or passes come.
        try surface.setPanels(Self.panels())
        #expect(!surface.isAnimating)
        try await settle(surface)
        let settled = surface.frameStatistics
        #expect(settled.submitted == start + 7)
        surface.effectTick(modelTime: 200)
        for _ in 0..<10 { surface.renderNow() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(surface.frameStatistics.submitted == settled.submitted)
        #expect(surface.frameStatistics.requested == settled.requested)

        // Hidden: no clock even with an animated panel.
        try surface.setPanels(Self.panels(pulse: true))
        #expect(surface.isAnimating)
        surface.isHidden = true
        #expect(!surface.isAnimating)
    }
}
#endif
