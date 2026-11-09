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
