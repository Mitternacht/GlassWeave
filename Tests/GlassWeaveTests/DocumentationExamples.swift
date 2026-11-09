// The Swift examples of Sources/GlassWeave/GlassWeave.docc/GlassWeave.md that
// need only the core, copied verbatim so the package build compiles them and
// DocumentationExampleTests runs them. scripts/check_doc_examples.py (run in
// CI) fails if the catalog and this file drift apart.
import GlassWeave

/// Starts measuring a renderer and later reports its GPU p95 in milliseconds,
/// or `nil` when the device reports no GPU times.
func measure(_ renderer: GlassRenderer) -> () -> Double? {
    let metrics = RenderMetrics()
    renderer.metrics = metrics
    return {
        guard let gpu = metrics.summary().gpu else { return nil }
        let components = gpu.p95.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}

import CoreGraphics
import GlassWeave

/// A capsule whose edge glows amber at the top and violet at the bottom and
/// fades to clear glass in the middle.
func glowingCapsule(frame: CGRect) -> GlassPanel {
    GlassPanel(frame: frame, parameters: GlassParameters(
        cornerRadius: frame.height / 2,
        glow: GlassGlow(
            colors: [
                .init(red: 1, green: 0.62, blue: 0.2, angle: 0),
                .init(red: 0.55, green: 0.3, blue: 1, angle: 180),
            ],
            rimWidth: 2, rimSoftness: 2,
            innerGlowRadius: 20, innerGlowIntensity: 0.7,
            centerOpacity: 0,
            lightAngle: 0, directionality: 0.5
        )
    ))
}

import CoreGraphics
import GlassWeave

/// A round glass button whose cyan-to-violet edge spills a soft halo and
/// pulses every two seconds, with a clear middle.
func pulsingOrb(frame: CGRect) -> GlassPanel {
    GlassPanel(frame: frame, parameters: GlassParameters(
        cornerRadius: min(frame.width, frame.height) / 2,
        glow: GlassGlow(
            colors: [
                .init(red: 0.3, green: 0.85, blue: 1, angle: 0),
                .init(red: 0.7, green: 0.35, blue: 1, angle: 180),
            ],
            innerGlowRadius: 16, innerGlowIntensity: 0.6,
            haloRadius: 24, haloIntensity: 0.8,
            pulsePeriod: 2, pulseDepth: 0.5
        )
    ))
}

import CoreGraphics
import GlassWeave

/// A round glass orb with energy filaments inside, a cyan-to-violet rim and
/// halo that pulse, and a clear middle.
func energyOrb(frame: CGRect) -> GlassPanel {
    GlassPanel(frame: frame, parameters: GlassParameters(
        cornerRadius: min(frame.width, frame.height) / 2,
        glow: GlassGlow(
            colors: [
                .init(red: 0.3, green: 0.85, blue: 1, angle: 0),
                .init(red: 0.7, green: 0.35, blue: 1, angle: 180),
            ],
            innerGlowRadius: 14, innerGlowIntensity: 0.5,
            haloRadius: 24, haloIntensity: 0.8,
            pulsePeriod: 2, pulseDepth: 0.4
        ),
        interior: GlassInterior(
            effect: .energy,
            colors: [
                .init(red: 0.25, green: 0.3, blue: 1),
                .init(red: 0.3, green: 0.85, blue: 1),
                .init(red: 0.95, green: 0.98, blue: 1),
            ],
            intensity: 0.9, speed: 1, seed: 7
        )
    ))
}

import CoreGraphics
import GlassWeave

/// Glowing capsules in a row for one `setPanels(_:)` call, one per color,
/// spaced so that no two quads (capsule, halo, and one pixel on every side)
/// overlap.
func capsuleRow(origin: CGPoint, capsuleSize: CGSize, colors: [GlassGlow.ColorStop]) -> [GlassPanel] {
    let halo = 16.0
    let gap = 2 * halo + 4
    return colors.enumerated().map { index, color in
        let x = origin.x + Double(index) * (capsuleSize.width + gap)
        return GlassPanel(
            frame: CGRect(origin: CGPoint(x: x, y: origin.y), size: capsuleSize),
            parameters: GlassParameters(
                cornerRadius: min(capsuleSize.width, capsuleSize.height) / 2,
                glow: GlassGlow(
                    colors: [color],
                    innerGlowRadius: 10, innerGlowIntensity: 0.6,
                    haloRadius: halo, haloIntensity: 0.8
                )
            )
        )
    }
}
