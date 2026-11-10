#if canImport(UIKit)
import Metal
import Testing
import UIKit
@testable import GlassWeave
@testable import GlassWeaveUIKit

/// The tilt light (GW-33): injected motion samples move the light's azimuth
/// within the documented bounds, the low-pass filter converges, and Reduce Motion
/// pins the light. The one safety test of the task; the real Core Motion source
/// is wired but cannot be exercised without a device.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct GlassTiltLightTests {
    @Test func `Injected motion moves the light within bounds, smoothing converges, and Reduce Motion pins it`() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        let queue = try #require(device.makeCommandQueue())
        let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
        surface.sceneStateOverride = .foregroundActive
        surface.accessibilitySettingsSource = .fixed(GlassAccessibilitySettings())
        surface.traitOverrides.displayScale = 2
        surface.frame = CGRect(x: 0, y: 0, width: 120, height: 80)
        surface.updateTraitsIfNeeded()
        surface.layoutIfNeeded()
        #expect(surface.isVisible)

        let source = GlassInjectedMotionSource()
        let light = try GlassTiltLight(surface: surface, source: source)
        let configuration = light.configuration
        #expect(source.isRunning, "A visible surface starts the sensor")
        var time = 0.0
        func send(roll: Double, lean: Double = 40) -> Bool {
            time += 1.0 / 30
            return source.send(GlassMotionSample(rollDegrees: roll, leanDegrees: lean, timestamp: time))
        }

        // The renderer keeps azimuths within one turn (-20 is held as 340), so
        // angles are compared by their distance around the circle.
        func turn(_ difference: Double) -> Double {
            abs(difference - 360 * (difference / 360).rounded())
        }

        // The mapping: right edge down turns the light to the left (negative
        // azimuth), a flatter screen raises it, both clamped to the maxima.
        func mapped(_ roll: Double, _ lean: Double) -> (azimuth: Double, elevation: Double) {
            GlassTiltLight.offset(for: GlassMotionSample(rollDegrees: roll, leanDegrees: lean, timestamp: 0), configuration: configuration)
        }
        #expect(abs(mapped(0, 40).azimuth) < 1e-9 && abs(mapped(0, 40).elevation) < 1e-9, "A normal grip leaves the authored light")
        #expect(abs(mapped(30, 40).azimuth + configuration.maximumAzimuth) < 1e-9)
        #expect(abs(mapped(-30, 40).azimuth - configuration.maximumAzimuth) < 1e-9)
        #expect(abs(mapped(85, 40).azimuth + configuration.maximumAzimuth) < 1e-9, "Clamped at the maximum")
        #expect(abs(mapped(0, 70).elevation - configuration.maximumElevation) < 1e-9)
        #expect(abs(mapped(0, -20).elevation + configuration.maximumElevation) < 1e-9)

        // Bounds: a violent sweep (and nonsense gravity) never moves the light past
        // the documented limits, and the renderer holds what the light applied.
        var widest = 0.0
        for step in 0..<240 {
            let roll = 90 * sin(Double(step) * 0.7), lean = 40 + 70 * cos(Double(step) * 0.4)
            #expect(send(roll: roll, lean: lean))
            widest = max(widest, abs(light.offset.azimuth))
            #expect(abs(light.offset.azimuth) <= configuration.maximumAzimuth + 1e-9)
            #expect(abs(light.offset.elevation) <= configuration.maximumElevation + 1e-9)
        }
        #expect(widest > 5, "The sweep moved the light")
        #expect(configuration.maximumAzimuth <= GlassTiltLight.azimuthLimit && configuration.maximumElevation <= GlassTiltLight.elevationLimit)
        time += 1.0 / 30
        #expect(source.send(GlassMotionSample(gravity: SIMD3(40, -90, 7), timestamp: time)))
        #expect(abs(light.offset.azimuth) <= configuration.maximumAzimuth + 1e-9)
        #expect(turn(surface.renderer.lightOffset.azimuth - light.offset.azimuth) < GlassTiltLight.applyThreshold)

        // Smoothing converges: a steady 20 degree roll eases toward its target, not
        // in one jump, and then the light stops asking for frames.
        let target = mapped(20, 40).azimuth
        let before = light.offset.azimuth
        #expect(send(roll: 20))
        #expect(abs(light.offset.azimuth - target) > 0.5 || abs(before - target) < 1, "One sample does not reach the target")
        for _ in 0..<90 { _ = send(roll: 20) }
        #expect(abs(light.offset.azimuth - target) < 0.05, "Three seconds of a steady tilt settle on its target")
        #expect(turn(surface.renderer.lightOffset.azimuth - target) < 0.05, "The renderer holds the settled light")
        let applied = light.appliedCount
        for _ in 0..<30 { _ = send(roll: 20) }
        #expect(light.appliedCount == applied, "A settled light applies nothing more")

        // A hidden surface stops the sensor; showing it starts it again.
        surface.isHidden = true
        #expect(!source.isRunning && !send(roll: 5), "A hidden surface receives no samples")
        surface.isHidden = false
        #expect(source.isRunning)

        // Reduce Motion pins the light at the authored direction: the sensor stops,
        // the offset goes back at once, samples change nothing.
        surface.accessibilitySettingsSource = .fixed(GlassAccessibilitySettings(reduceMotion: true))
        #expect(light.isPinned && !source.isRunning)
        #expect(light.offset.azimuth == 0 && light.offset.elevation == 0)
        #expect(surface.renderer.lightOffset.azimuth == 0 && surface.renderer.lightOffset.elevation == 0)
        #expect(!send(roll: 30))
        try light.ingest(GlassMotionSample(rollDegrees: 30, leanDegrees: 70, timestamp: time + 1))
        #expect(light.offset.azimuth == 0 && surface.renderer.lightOffset.azimuth == 0, "A pinned light ignores samples")
        surface.accessibilitySettingsSource = .fixed(GlassAccessibilitySettings())
        #expect(!light.isPinned && source.isRunning, "The sensor resumes when Reduce Motion ends")

        // A surface that starts under Reduce Motion never starts the sensor.
        surface.accessibilitySettingsSource = .fixed(GlassAccessibilitySettings(reduceMotion: true))
        let pinnedSource = GlassInjectedMotionSource()
        let pinnedLight = try GlassTiltLight(surface: surface, source: pinnedSource)
        #expect(pinnedLight.isPinned && pinnedSource.startCount == 0 && !pinnedSource.isRunning)

        // Normalization: non-finite values are rejected naming the field, finite
        // ones are clamped.
        #expect(throws: GlassTiltLightError.nonFiniteConfiguration(.timeConstant)) {
            try GlassTiltLight.Configuration(timeConstant: .nan).normalized()
        }
        #expect(throws: GlassTiltLightError.nonFiniteSample(.gravityY)) {
            try light.ingest(GlassMotionSample(gravity: SIMD3(0, .infinity, 0), timestamp: 0))
        }
        let clamped = try GlassTiltLight.Configuration(maximumAzimuth: 500, maximumElevation: -3, fullTilt: 0, neutralLean: 400, timeConstant: 0).normalized()
        #expect(clamped.maximumAzimuth == GlassTiltLight.azimuthLimit && clamped.maximumElevation == 0)
        #expect(clamped.fullTilt == 5 && clamped.neutralLean == 90 && clamped.timeConstant == 0.02)

        light.invalidate()
        pinnedLight.invalidate()
    }
}
#endif
