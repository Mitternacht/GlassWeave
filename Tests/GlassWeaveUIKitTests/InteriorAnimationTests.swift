#if canImport(UIKit)
import Metal
import Testing
import UIKit
@testable import GlassWeave
@testable import GlassWeaveUIKit

/// GW-19's interiors on the GW-18 effect clock: the clock runs only while a
/// visible surface presents a moving interior (or a pulsing glow), each tick
/// draws one frame at the advanced effect time, and nothing is drawn once the
/// interior is still, hidden, or under Reduce Motion, which presents its
/// still frame (interior time 0). Ticks go through the same scheduler as
/// every other request, so the in-flight bound holds.
///
/// As in `GlowAnimationTests`, the scene state comes from
/// `sceneStateOverride` and ticks are delivered by calling `effectTick` with
/// chosen model times; the laboratory's UI tests run the real link.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct InteriorAnimationTests {
    let device: any MTLDevice
    let queue: any MTLCommandQueue

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        queue = try #require(device.makeCommandQueue())
    }

    static let ramp: [GlassInterior.Color] = [
        .init(red: 0.1, green: 0.3, blue: 1), .init(red: 0.3, green: 0.85, blue: 1), .init(red: 0.95, green: 0.98, blue: 1),
    ]

    static func interior(_ effect: GlassInterior.Effect = .energy, speed: Double = 1.5) -> GlassInterior {
        GlassInterior(effect: effect, colors: ramp, intensity: 0.9, speed: speed, seed: 4)
    }

    static func panel(_ interior: GlassInterior, glow: GlassGlow = .none) -> GlassPanel {
        GlassPanel(frame: CGRect(x: 24, y: 20, width: 120, height: 80), parameters: GlassParameters(glow: glow, interior: interior))
    }

    /// A visible surface with a still source, so every permitted draw
    /// submits a frame.
    private func makeSurface(
        sceneState: SurfaceVisibility.SceneState? = .foregroundActive,
        settings: GlassAccessibilitySettings = GlassAccessibilitySettings()
    ) throws -> GlassSurfaceView {
        let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
        surface.sceneStateOverride = sceneState
        surface.accessibilitySettingsSource = .fixed(settings)
        surface.traitOverrides.displayScale = 2
        surface.frame = CGRect(x: 0, y: 0, width: 168, height: 120)
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

    private func awaitIdle(_ surface: GlassSurfaceView) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while surface.frameStatistics.framesInFlight > 0 {
            #expect(ContinuousClock.now < deadline, "GPU work did not complete")
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func settle(_ surface: GlassSurfaceView) async throws {
        surface.renderNow()
        try await awaitIdle(surface)
    }

    /// The interior time of the last draw: the presented interior at the
    /// renderer's effect time, as the renderer uploads it.
    private func drawnPhase(_ surface: GlassSurfaceView) throws -> Float {
        let panel = try #require(surface.presentedPanel)
        let geometry = GlassPanelGeometry(panel: panel, displayScale: 2, effectTime: surface.renderer.effectTime)
        return try #require(geometry.interior).phase
    }

    // MARK: When the clock runs

    @Test func `The effect clock runs only while a visible interior moves`() throws {
        let surface = try makeSurface()
        try surface.setPanel(Self.panel(Self.interior(speed: 0)))
        #expect(!surface.isAnimating, "A still interior never animates")
        for effect in [GlassInterior.Effect.energy, .rays, .embers] {
            try surface.setPanel(Self.panel(Self.interior(effect)))
            #expect(surface.isAnimating, "\(effect)")
        }
        // Nothing to draw: no effect, no colors, no intensity.
        try surface.setPanel(Self.panel(GlassInterior(effect: .none, colors: Self.ramp)))
        #expect(!surface.isAnimating)
        try surface.setPanel(Self.panel(GlassInterior(effect: .rays, colors: [])))
        #expect(!surface.isAnimating)
        try surface.setPanel(Self.panel(GlassInterior(effect: .rays, colors: Self.ramp, intensity: 0)))
        #expect(!surface.isAnimating)
        // A steady glow does not stop a moving interior, and a still
        // interior does not stop a pulsing glow.
        let steadyGlow = GlassGlow(colors: [.init(red: 1, green: 0.5, blue: 0.2)], haloRadius: 12)
        try surface.setPanel(Self.panel(Self.interior(), glow: steadyGlow))
        #expect(surface.isAnimating)
        var pulsing = steadyGlow
        pulsing.pulseDepth = 0.5
        try surface.setPanel(Self.panel(Self.interior(speed: 0), glow: pulsing))
        #expect(surface.isAnimating)
        try surface.setPanel(Self.panel(Self.interior(speed: 0), glow: steadyGlow))
        #expect(!surface.isAnimating)

        // Visibility: background, hidden, inactive (still on screen), no window.
        try surface.setPanel(Self.panel(Self.interior()))
        surface.sceneStateOverride = .background
        #expect(!surface.isAnimating)
        surface.sceneStateOverride = .foregroundInactive
        #expect(surface.isAnimating)
        surface.isHidden = true
        #expect(!surface.isAnimating)
        surface.isHidden = false
        #expect(surface.isAnimating)
        surface.sceneStateOverride = nil
        #expect(!surface.isAnimating)
    }

    @Test func `Each tick moves the interior and draws one frame, and nothing draws between ticks`() async throws {
        let surface = try makeSurface()
        try surface.setPanel(Self.panel(Self.interior(.embers, speed: 1.5)))
        try await settle(surface)
        let start = surface.frameStatistics.submitted
        #expect(start == 1)
        #expect(try drawnPhase(surface) == 0)
        for tick in 1...12 {
            surface.effectTick(modelTime: 300 + Double(tick) / 60)
            try await settle(surface)
            #expect(surface.frameStatistics.submitted == start + tick)
            let time = Double(tick - 1) / 60
            #expect(abs(surface.renderer.effectTime - time) < 1e-9, "The draw used the clock's time")
            // The interior is drawn at the effect time times its speed.
            #expect(abs(Double(try drawnPhase(surface)) - time * 1.5) < 1e-6)
        }
        let afterTicks = surface.frameStatistics
        for _ in 0..<10 { surface.renderNow() }
        #expect(surface.frameStatistics.submitted == afterTicks.submitted)
        #expect(surface.frameStatistics.requested == afterTicks.requested)
    }

    @Test(arguments: [false, true])
    func `Stilling or removing the interior draws once and then submits nothing`(removes: Bool) async throws {
        let surface = try makeSurface()
        try surface.setPanel(Self.panel(Self.interior()))
        try await settle(surface)
        for tick in 1...5 {
            surface.effectTick(modelTime: Double(tick) / 60)
            try await settle(surface)
        }
        // Speed 0 stills the interior; `.none` removes it.
        try surface.setPanel(Self.panel(removes ? .none : Self.interior(speed: 0)))
        #expect(!surface.isAnimating)
        try await settle(surface)
        let settled = surface.frameStatistics
        surface.effectTick(modelTime: 10)
        for _ in 0..<10 { surface.renderNow() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(surface.frameStatistics.requested == settled.requested)
        #expect(surface.frameStatistics.submitted == settled.submitted)
        #expect(settled.submitted == 1 + 5 + 1)
    }

    @Test func `A hidden surface submits nothing and resumes the interior where it stopped`() async throws {
        let surface = try makeSurface()
        try surface.setPanel(Self.panel(Self.interior(.rays, speed: 2)))
        try await settle(surface)
        for tick in 0...30 {
            surface.effectTick(modelTime: 20 + Double(tick) / 60)
            try await settle(surface)
        }
        let reached = surface.effectClock.time
        #expect(abs(reached - 0.5) < 1e-9)
        #expect(abs(Double(try drawnPhase(surface)) - 1) < 1e-6)

        surface.isHidden = true
        #expect(!surface.isAnimating)
        let hidden = surface.frameStatistics
        for tick in 1...30 {
            surface.effectTick(modelTime: 30 + Double(tick) / 60)
            surface.renderNow()
        }
        #expect(surface.frameStatistics.submitted == hidden.submitted)
        #expect(surface.frameStatistics.requested == hidden.requested, "No tick reached the scheduler")
        #expect(surface.effectClock.time == reached)

        surface.isHidden = false
        #expect(surface.isAnimating)
        surface.effectTick(modelTime: 900)
        try await settle(surface)
        surface.effectTick(modelTime: 900 + 1.0 / 60)
        try await settle(surface)
        #expect(abs(surface.effectClock.time - (reached + 1.0 / 60)) < 1e-9)
        #expect(abs(Double(try drawnPhase(surface)) - (reached + 1.0 / 60) * 2) < 1e-6)
    }

    @Test func `Under Reduce Motion the interior is its still frame and no clock runs`() async throws {
        let surface = try makeSurface(settings: GlassAccessibilitySettings(reduceMotion: true))
        try surface.setPanel(Self.panel(Self.interior(.energy, speed: 2)))
        #expect(!surface.isAnimating)
        let presented = try #require(surface.presentedPanel?.parameters.interior)
        #expect(presented.speed == 0)
        #expect(presented.effect == .energy && presented.colors == Self.ramp && presented.intensity == 0.9)
        #expect(surface.panel?.parameters.interior.speed == 2, "The app's panel is kept")
        try await settle(surface)
        #expect(try drawnPhase(surface) == 0)
        let still = surface.frameStatistics
        surface.effectTick(modelTime: 1)
        for _ in 0..<10 { surface.renderNow() }
        #expect(surface.frameStatistics.submitted == still.submitted)
        #expect(surface.frameStatistics.requested == still.requested)

        // Off: the interior moves; on again: one draw of the still frame at
        // interior time 0, although the clock has advanced, then nothing.
        surface.accessibilitySettingsSource = .fixed(GlassAccessibilitySettings())
        #expect(surface.isAnimating)
        try await settle(surface)
        surface.effectTick(modelTime: 2)
        try await settle(surface)
        surface.effectTick(modelTime: 2.5)
        try await settle(surface)
        #expect(surface.effectClock.time == 0.5)
        #expect(try drawnPhase(surface) == 1)
        surface.accessibilitySettingsSource = .fixed(GlassAccessibilitySettings(reduceMotion: true))
        #expect(!surface.isAnimating)
        try await settle(surface)
        #expect(try drawnPhase(surface) == 0, "The still frame is interior time 0")
        let again = surface.frameStatistics
        surface.effectTick(modelTime: 3)
        for _ in 0..<10 { surface.renderNow() }
        #expect(surface.frameStatistics.submitted == again.submitted)
        #expect(again.submitted == still.submitted + 4)
    }

    @Test func `Interior ticks at the in-flight bound are coalesced, never queued`() async throws {
        let surface = try makeSurface()
        try surface.setPanel(Self.panel(Self.interior(.embers)))
        try await settle(surface)
        let before = surface.frameStatistics
        for tick in 1...120 {
            surface.effectTick(modelTime: Double(tick) / 120)
            surface.effectTick(modelTime: Double(tick) / 120 + 1e-4)
            surface.renderNow()
            #expect(surface.frameStatistics.framesInFlight <= GlassSurfaceView.maximumFramesInFlight)
        }
        try await awaitIdle(surface)
        let after = surface.frameStatistics
        #expect(after.requested - before.requested == 240)
        #expect(after.coalesced - before.coalesced >= 120)
        #expect(after.peakFramesInFlight <= GlassSurfaceView.maximumFramesInFlight)
        #expect(after.submitted - before.submitted <= 120)
        #expect(after.submitted == after.completed)
    }

    // MARK: The accessibility mapping

    private static func traits(_ contrast: UIAccessibilityContrast) -> UITraitCollection {
        UITraitCollection { $0.accessibilityContrast = contrast }
    }

    @Test func `Reduce Transparency and Increase Contrast remove the interior; normal settings keep it`() {
        let glow = GlassGlow(colors: [.init(red: 1, green: 0.5, blue: 0.2)], haloRadius: 12, pulseDepth: 0.4)
        let panel = Self.panel(Self.interior(.rays), glow: glow)
        for reduceMotion in [false, true] {
            let transparent = GlassAccessibilityPolicy.presentedPanel(
                for: panel, settings: GlassAccessibilitySettings(reduceTransparency: true, reduceMotion: reduceMotion), traits: Self.traits(.normal)
            )
            #expect(transparent.parameters.interior == .none)
            let contrast = GlassAccessibilityPolicy.presentedPanel(
                for: panel, settings: GlassAccessibilitySettings(reduceMotion: reduceMotion), traits: Self.traits(.high)
            )
            #expect(contrast.parameters.interior == .none)
            #expect(!contrast.parameters.interior.isAnimated)
        }
        let normal = GlassAccessibilityPolicy.presentedPanel(for: panel, settings: GlassAccessibilitySettings(), traits: Self.traits(.normal))
        #expect(normal.parameters.interior == Self.interior(.rays))
        let still = GlassAccessibilityPolicy.presentedPanel(
            for: panel, settings: GlassAccessibilitySettings(reduceMotion: true), traits: Self.traits(.normal)
        )
        var expected = Self.interior(.rays)
        expected.speed = 0
        #expect(still.parameters.interior == expected)
    }

    @Test func `A UIKit color becomes an interior color resolved for the traits`() throws {
        let light = UITraitCollection(userInterfaceStyle: .light), dark = UITraitCollection(userInterfaceStyle: .dark)
        let lightColor = try #require(GlassInterior.Color(.systemOrange, traits: light))
        let darkColor = try #require(GlassInterior.Color(.systemOrange, traits: dark))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor.systemOrange.resolvedColor(with: dark).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #expect(darkColor == GlassInterior.Color(red: Double(red), green: Double(green), blue: Double(blue)))
        #expect(lightColor != darkColor, "A dynamic color follows the appearance")
        // Alpha is ignored.
        #expect(GlassInterior.Color(UIColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.1), traits: light)
            == GlassInterior.Color(red: 0.2, green: 0.4, blue: 0.6))
        // A pattern color has no RGB components.
        let pattern = UIColor(patternImage: UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in })
        #expect(GlassInterior.Color(pattern, traits: light) == nil)
    }
}
#endif
