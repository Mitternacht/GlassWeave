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
