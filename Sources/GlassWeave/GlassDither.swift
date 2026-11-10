/// How a panel's 8-bit encode is dithered (CLEAN, experimental).
///
/// The drawing target holds 8 bits per channel, so a smooth gradient (a glow,
/// a halo, pooled light, an inner glow, a shadow, a clear body) would show
/// steps. A dither adds a little noise before the encode so the steps average
/// out. Experimental; the shader's behavior may change before release.
public enum GlassDither: Hashable, Sendable {
    /// The 4 x 4 ordered dither the shader has always used, of at most 0.47 of
    /// an 8-bit step and only where a light term changed the pixel. A pixel no
    /// light term touches keeps the bytes it always had.
    case ordered
    /// A static triangular-PDF dither of one 8-bit step, from an integer hash
    /// of the pixel's position: isotropic (no direction, so it cannot read as
    /// a streak) and fixed in time (it does not shimmer). It goes where the
    /// shader makes a smooth gradient that would show steps (a glow, the halo
    /// and the shadows, an inner light, an interior, a fill, the touch, a
    /// frosted body, a caustic, the soft rim) and not on a flat body: a clear
    /// body is as smooth as the system glass's (CLEAN-2; before, it covered
    /// every pixel and one 8-bit step of noise on a flat body read as grain),
    /// on every pipeline variant. With the refined look's presence, the clean
    /// look also shows a flat patch of the backdrop (one as flat as a source's
    /// own dither or grain) as the average of a few taps of it, so the body
    /// does not repeat the source's noise. It also interpolates the glow's color stops and the inner
    /// light's palettes with a smooth step instead of a straight line, so a
    /// hue has no corner where one stop hands over to the next. The refined
    /// look's ``GlassLighting/clean`` selects it too.
    case triangular
}
