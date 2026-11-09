#if canImport(UIKit)
import Metal
import Testing
import UIKit
@testable import GlassWeave
@testable import GlassWeaveUIKit

/// GW-18's effect clock in the UIKit host: it runs only while a visible
/// surface presents a pulsing glow, each tick asks the scheduler for one
/// frame and advances the effect time the renderer draws at, and it stops
/// when the pulse is removed, the surface is hidden, or Reduce Motion
/// steadies the glow. Ticks go through the same scheduler as every other
/// request, so the in-flight bound and the on-demand rule still hold.
///
/// A test process has no window scenes, so the scene state comes from
/// `sceneStateOverride` and ticks are delivered by calling `effectTick`
/// with chosen model times, as the view's `UIUpdateLink` would. The
/// laboratory's UI tests run the real link.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct GlowAnimationTests {
    let device: any MTLDevice
    let queue: any MTLCommandQueue

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        queue = try #require(device.makeCommandQueue())
    }

    static let pulsing = GlassGlow(
        colors: [.init(red: 0.25, green: 0.85, blue: 1, angle: 0), .init(red: 0.65, green: 0.35, blue: 1, angle: 180)],
        rimWidth: 2, rimSoftness: 1.5, innerGlowRadius: 18, innerGlowIntensity: 0.7,
        haloRadius: 20, haloIntensity: 0.8, pulsePeriod: 1.6, pulseDepth: 0.6
    )

    static func panel(_ glow: GlassGlow) -> GlassPanel {
        GlassPanel(frame: CGRect(x: 24, y: 20, width: 120, height: 80), parameters: GlassParameters(glow: glow))
    }

    static var steady: GlassGlow {
        var glow = pulsing
        glow.pulseDepth = 0
        return glow
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

    /// Waits, without blocking the main actor, until no frame is in flight.
    private func awaitIdle(_ surface: GlassSurfaceView) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while surface.frameStatistics.framesInFlight > 0 {
            #expect(ContinuousClock.now < deadline, "GPU work did not complete")
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Draws whatever is pending and waits for it.
    private func settle(_ surface: GlassSurfaceView) async throws {
        surface.renderNow()
        try await awaitIdle(surface)
    }

    // MARK: When the clock runs

    @Test func `The effect clock runs only while a visible glow pulses`() throws {
        let surface = try makeSurface()
        #expect(!surface.isAnimating)
        try surface.setPanel(Self.panel(Self.steady))
        #expect(!surface.isAnimating, "A glow without a pulse never animates")
        try surface.setPanel(Self.panel(Self.pulsing))
        #expect(surface.isAnimating)
        // Only the center fill would pulse: nothing to animate.
        try surface.setPanel(Self.panel(GlassGlow(colors: Self.pulsing.colors, rimIntensity: 0, innerGlowIntensity: 0,
                                                  centerOpacity: 0.3, pulseDepth: 1)))
        #expect(!surface.isAnimating)
        try surface.setPanel(Self.panel(Self.pulsing))
        #expect(surface.isAnimating)
        try surface.setPanel(nil)
        #expect(!surface.isAnimating)
        try surface.setPanel(Self.panel(Self.pulsing))

        // Visibility: a background scene, a hidden view, and an inactive
        // (still on screen) scene.
        surface.sceneStateOverride = .background
        #expect(!surface.isAnimating)
        surface.sceneStateOverride = .foregroundInactive
        #expect(surface.isAnimating)
        surface.isHidden = true
        #expect(!surface.isAnimating)
        surface.isHidden = false
        #expect(surface.isAnimating)
        surface.sceneStateOverride = nil // no window
        #expect(!surface.isAnimating)
    }

    @Test func `Each tick advances the effect time and draws one frame, and nothing draws between ticks`() async throws {
        let surface = try makeSurface()
        try surface.setPanel(Self.panel(Self.pulsing))
        try await settle(surface)
        let start = surface.frameStatistics.submitted
        #expect(start == 1)
        for tick in 1...12 {
            surface.effectTick(modelTime: 500 + Double(tick) / 60)
            try await settle(surface)
            #expect(surface.frameStatistics.submitted == start + tick)
            // The first tick sets the clock's base; each later one adds the
            // model time since the previous tick.
            let expected = Double(tick - 1) / 60
            #expect(abs(surface.effectClock.time - expected) < 1e-9)
            #expect(surface.renderer.effectTime == surface.effectClock.time, "The draw used the clock's time")
        }
        // Display passes without a tick draw nothing.
        let afterTicks = surface.frameStatistics
        for _ in 0..<10 { surface.renderNow() }
        #expect(surface.frameStatistics.submitted == afterTicks.submitted)
        #expect(surface.frameStatistics.requested == afterTicks.requested)
        // A model time going backward never moves the clock back.
        let time = surface.effectClock.time
        surface.effectTick(modelTime: 1)
        #expect(surface.effectClock.time == time)
        try await settle(surface)
    }

    @Test func `Removing the pulse draws the steady glow once and then submits nothing`() async throws {
        let surface = try makeSurface()
        try surface.setPanel(Self.panel(Self.pulsing))
        try await settle(surface)
        for tick in 1...5 {
            surface.effectTick(modelTime: Double(tick) / 60)
            try await settle(surface)
        }
        try surface.setPanel(Self.panel(Self.steady))
        #expect(!surface.isAnimating)
        try await settle(surface)
        let settled = surface.frameStatistics
        // A tick the link may still deliver is ignored; display passes and
        // time draw nothing.
        surface.effectTick(modelTime: 10)
        for _ in 0..<10 { surface.renderNow() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(surface.frameStatistics.requested == settled.requested)
        #expect(surface.frameStatistics.submitted == settled.submitted)
        #expect(settled.submitted == 1 + 5 + 1)
    }

    @Test func `A hidden surface stops the clock, submits nothing, and resumes the pulse where it stopped`() async throws {
        let surface = try makeSurface()
        try surface.setPanel(Self.panel(Self.pulsing))
        try await settle(surface)
        for tick in 0...30 {
            surface.effectTick(modelTime: 20 + Double(tick) / 60)
            try await settle(surface)
        }
        let reached = surface.effectClock.time
        #expect(abs(reached - 0.5) < 1e-9)

        surface.sceneStateOverride = .background
        #expect(!surface.isAnimating)
        let hidden = surface.frameStatistics
        for tick in 1...30 {
            surface.effectTick(modelTime: 30 + Double(tick) / 60)
            surface.renderNow()
        }
        #expect(surface.frameStatistics.submitted == hidden.submitted)
        #expect(surface.frameStatistics.requested == hidden.requested, "No tick reached the scheduler")
        #expect(surface.effectClock.time == reached)

        // Shown again much later: the first tick only sets the base, so the
        // pulse continues from the time it reached.
        surface.sceneStateOverride = .foregroundActive
        #expect(surface.isAnimating)
        surface.effectTick(modelTime: 900)
        #expect(surface.effectClock.time == reached)
        try await settle(surface)
        surface.effectTick(modelTime: 900 + 1.0 / 60)
        #expect(abs(surface.effectClock.time - (reached + 1.0 / 60)) < 1e-9)
        try await settle(surface)
        #expect(surface.frameStatistics.submitted == hidden.submitted + 2)
    }

    @Test func `Under Reduce Motion the glow is steady at its mean level and no clock runs`() async throws {
        let surface = try makeSurface(settings: GlassAccessibilitySettings(reduceMotion: true))
        try surface.setPanel(Self.panel(Self.pulsing))
        #expect(!surface.isAnimating)
        let glow = try #require(surface.presentedPanel?.parameters.glow)
        #expect(glow.pulseDepth == 0)
        // Depth 0.6: the mean level is 0.7.
        #expect(abs(glow.rimIntensity - 0.7) < 1e-12)
        #expect(abs(glow.innerGlowIntensity - 0.7 * 0.7) < 1e-12)
        #expect(abs(glow.haloIntensity - 0.8 * 0.7) < 1e-12)
        #expect(glow.haloRadius == 20, "The halo stays, steady")
        #expect(surface.panel?.parameters.glow == Self.pulsing, "The app's panel is kept")
        try await settle(surface)
        let steady = surface.frameStatistics
        surface.effectTick(modelTime: 1)
        for _ in 0..<10 { surface.renderNow() }
        #expect(surface.frameStatistics.submitted == steady.submitted)
        #expect(surface.frameStatistics.requested == steady.requested)

        // Turning Reduce Motion off starts the pulse; on again stops it and
        // draws the steady glow once.
        surface.accessibilitySettingsSource = .fixed(GlassAccessibilitySettings())
        #expect(surface.isAnimating)
        #expect(surface.presentedPanel?.parameters.glow == Self.pulsing)
        try await settle(surface)
        surface.effectTick(modelTime: 2)
        try await settle(surface)
        surface.accessibilitySettingsSource = .fixed(GlassAccessibilitySettings(reduceMotion: true))
        #expect(!surface.isAnimating)
        try await settle(surface)
        let again = surface.frameStatistics
        surface.effectTick(modelTime: 3)
        for _ in 0..<10 { surface.renderNow() }
        #expect(surface.frameStatistics.submitted == again.submitted)
        #expect(again.submitted == steady.submitted + 3)
    }

    /// Ticks faster than the GPU completes are coalesced into the pending
    /// frame or deferred at the bound; nothing queues, and at most two
    /// frames are ever in flight.
    @Test func `Ticks at the in-flight bound are coalesced, never queued`() async throws {
        let surface = try makeSurface()
        try surface.setPanel(Self.panel(Self.pulsing))
        try await settle(surface)
        let before = surface.frameStatistics
        for tick in 1...120 {
            surface.effectTick(modelTime: Double(tick) / 120)
            // A second tick before the display pass coalesces with the first.
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
        #expect(after.framesInFlight == 0)
    }

    /// The update link holds the view weakly: a surface dropped while its
    /// clock runs is freed.
    @Test func `A running clock does not keep the surface alive`() throws {
        weak var released: GlassSurfaceView?
        try autoreleasepool {
            let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
            surface.sceneStateOverride = .foregroundActive
            surface.frame = CGRect(x: 0, y: 0, width: 100, height: 80)
            // The clock runs only for a panel it can draw: with a size and a
            // source.
            surface.layoutIfNeeded()
            try surface.setSource(makeLease())
            try surface.setPanel(Self.panel(Self.pulsing))
            #expect(surface.isAnimating)
            released = surface
        }
        #expect(released == nil)
    }

    // MARK: The accessibility mapping

    private static func traits(_ contrast: UIAccessibilityContrast) -> UITraitCollection {
        UITraitCollection { $0.accessibilityContrast = contrast }
    }

    @Test func `Reduce Transparency removes the halo and the pulse and keeps a steady rim`() {
        for reduceMotion in [false, true] {
            let presented = GlassAccessibilityPolicy.presentedPanel(
                for: Self.panel(Self.pulsing),
                settings: GlassAccessibilitySettings(reduceTransparency: true, reduceMotion: reduceMotion),
                traits: Self.traits(.normal)
            ).parameters.glow
            #expect(!presented.hasHalo)
            #expect(presented.pulseDepth == 0 && !presented.isAnimated)
            #expect(presented.rimIntensity == Self.pulsing.rimIntensity, "The rim keeps its own intensity")
            #expect(presented.innerGlowIntensity == 0 && presented.centerOpacity == 0)
        }
    }

    @Test func `Increase Contrast keeps the halo and the pulse`() {
        let presented = GlassAccessibilityPolicy.presentedPanel(
            for: Self.panel(Self.pulsing), settings: GlassAccessibilitySettings(), traits: Self.traits(.high)
        ).parameters.glow
        #expect(presented.haloRadius == 20 && presented.haloIntensity == 0.8)
        #expect(presented.pulseDepth == 0.6 && presented.pulsePeriod == 1.6)
        #expect(presented.isAnimated)
        #expect(presented.innerGlowIntensity == 0 && presented.directionality == 0)
        // With Reduce Motion as well, it is steady at the mean level.
        let still = GlassAccessibilityPolicy.presentedPanel(
            for: Self.panel(Self.pulsing), settings: GlassAccessibilitySettings(reduceMotion: true), traits: Self.traits(.high)
        ).parameters.glow
        #expect(!still.isAnimated)
        #expect(abs(still.haloIntensity - 0.8 * 0.7) < 1e-12)
    }
}
#endif
