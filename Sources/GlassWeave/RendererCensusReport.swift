/// Read-only access to the renderer census for diagnostics screens (GW-15).
///
/// Every GlassWeave renderer reports its creation and destruction to the
/// census, so an app can show that a code path creates no renderer or only
/// the one it should. The counters are process-wide.
///
/// > Important: Experimental. This is SPI: import with
/// > `@_spi(Census) import GlassWeave`. It may change before a stable release.
@_spi(Census)
public enum GlassRendererCensus {
    /// Renderers created since the process started.
    public static var created: Int { RendererCensus.created }
    /// Renderers alive now.
    public static var live: Int { RendererCensus.live }
}
