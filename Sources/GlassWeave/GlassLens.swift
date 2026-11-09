import Foundation

/// The thick-lens optics of a glass panel: how the glass is shaped as a
/// solid (a height field with a thickness and an index of refraction) and so
/// how it magnifies and bends what is behind it.
///
/// > Important: Experimental. This API may change before a stable release.
///
/// Apple's native glass is a fixed, system-defined shape. GlassWeave's own
/// glass can be a lens: with a profile other than ``Profile/rim``, the panel
/// is a piece of glass of a chosen ``thickness`` whose height rises over the
/// ``GlassParameters/bezelWidth`` from the outline, and each pixel samples the
/// background along the ray the glass bends (Snell's law, with the
/// ``indexOfRefraction``). Content bends hard toward the outline, a dome
/// magnifies its middle, and a ring stands up at the edge.
///
/// The lens is off by default: ``GlassLens/none`` (the ``Profile/rim``
/// profile with nothing else set) renders the panel with the shader's
/// original rim refraction, byte for byte, using the pipeline variant that
/// does not contain the lens code.
///
/// | Property | Unit | Valid range | Default | Meaning |
/// | --- | --- | --- | --- | --- |
/// | ``profile`` | ``Profile`` | — | ``Profile/rim`` | The height profile. ``Profile/rim`` is the original rim: it uses ``GlassParameters/refraction`` and ``GlassParameters/bezelWidth`` and ignores the lens properties below. Every other profile uses ``GlassParameters/bezelWidth`` as the bevel width (a ``Profile/dome`` uses the panel's inscribed radius) and **ignores** ``GlassParameters/refraction``. |
/// | ``thickness`` | points | 0 to ``maximumThickness`` | 24 | The glass height at its thickest. The thicker the glass, the harder it bends. |
/// | ``indexOfRefraction`` | ratio | 1 to ``maximumIndexOfRefraction`` | 1.5 | 1 shows the background unbent. Glass is about 1.5. |
/// | ``maximumOffset`` | points | 0 to ``maximumMaximumOffset`` | 48 | The longest any sample moves. |
/// | ``dispersion`` | normalized | 0...1 | 0 | Chromatic dispersion: how far the index of refraction differs between red and blue light. Where the glass bends hard (its bevel), the background splits into colored fringes; white and gray stay neutral. 0 draws none. |
/// | ``dispersionTaps`` | ``DispersionTaps`` | — | ``DispersionTaps/threeTap`` | How the spectrum is sampled: one sample each for red, green, and blue, or six wavelengths blended into smooth rainbows. Both keep the weights of every channel summing to 1 in linear light, so white stays white. |
/// | ``allowsFold`` | `Bool` | — | `false` | When `false`, the offsets are scaled down just enough that the sampled position never turns back along the bevel, so content is magnified but never mirrored. When `true`, a thick bevel folds the content over, as a real glass edge can. |
///
/// **The math** (see `docs/glass-optics.md`). The height is
/// `h = thickness × s(t)`, with `t = lensDepth / bevel` and `s` the
/// profile (0 at the outline, 1 at the top of the bevel). The surface normal
/// is `N = normalize(−∇h, 1)`, the ray `T = refract(−z, N, 1 / ior)`, and a
/// pixel samples the background at `pixel + T.xy / (−T.z) × h`, at most
/// ``maximumOffset`` away. Domes and rings take the bevel from the shape: a
/// dome's is the inscribed radius, a ring's is its outer edge.
///
/// **Normalization rule** (the ``GlassParameters`` rule). A NaN or infinite
/// value anywhere is rejected with ``GlassParameterError/nonFiniteLens(_:)``
/// naming its ``Field``; finite values out of range are clamped to the
/// ranges above. ``GlassRenderer/panel`` reports the lens that is drawn.
public struct GlassLens: Hashable, Sendable {
    /// The height profile of the glass, from the outline inward.
    public enum Profile: Hashable, Sendable {
        /// The original rim (GW-05): a quadratic displacement toward the
        /// interior within ``GlassParameters/bezelWidth``. The default.
        case rim
        /// A quarter circle: `s = sqrt(1 − (1 − t)²)`. A round bead edge.
        case circular
        /// A superellipse, `s = (1 − (1 − t)ⁿ)^(1/n)`. `exponent` is clamped
        /// to 1...8; 2 is ``circular``, 4 the familiar squircle bevel.
        case squircle(exponent: Double)
        /// A straight face (about 40 degrees) that rounds into the flat top.
        case chamfer
        /// A circular profile whose bevel is the panel's inscribed radius:
        /// a dome on a square or circle, a pebble on a pill.
        case dome
        /// A bump of glass standing up at `center` points inside the outline
        /// and `width` points wide, flat on both sides: the rim of a ring
        /// button. A width under 2 pixels is widened to 2 so it does not
        /// alias.
        case ring(center: Double, width: Double)
    }

    /// How the spectrum is sampled for ``dispersion``.
    public enum DispersionTaps: Hashable, Sendable {
        /// Three samples: red, green, and blue each from their own
        /// wavelength. The cheapest; the fringes are three-colored.
        case threeTap
        /// Six samples across the spectrum, blended into red, green, and
        /// blue with weights that sum to 1 per channel: a smooth rainbow.
        case sixTap
    }

    /// The height profile of the glass.
    public var profile: Profile
    /// The glass height at its thickest, in points.
    public var thickness: Double
    /// The index of refraction.
    public var indexOfRefraction: Double
    /// The longest any sample moves, in points.
    public var maximumOffset: Double
    /// Whether the content may fold over where the glass bends hardest.
    public var allowsFold: Bool
    /// Chromatic dispersion, 0...1.
    public var dispersion: Double
    /// How the spectrum is sampled where the colors separate.
    public var dispersionTaps: DispersionTaps

    /// The thickest glass: 64 points.
    public static let maximumThickness = 64.0
    /// The highest index of refraction: 2.4.
    public static let maximumIndexOfRefraction = 2.4
    /// The longest sample offset that can be asked for: 512 points.
    public static let maximumMaximumOffset = 512.0

    public init(
        profile: Profile = .rim,
        thickness: Double = 24,
        indexOfRefraction: Double = 1.5,
        maximumOffset: Double = 48,
        allowsFold: Bool = false,
        dispersion: Double = 0,
        dispersionTaps: DispersionTaps = .threeTap
    ) {
        self.profile = profile
        self.thickness = thickness
        self.indexOfRefraction = indexOfRefraction
        self.maximumOffset = maximumOffset
        self.allowsFold = allowsFold
        self.dispersion = dispersion
        self.dispersionTaps = dispersionTaps
    }

    /// No lens: the panel's original rim refraction.
    public static let none = GlassLens()

    /// Whether the lens changes the picture: a profile other than
    /// ``Profile/rim``, or dispersion above 0 (on the rim profile it splits
    /// the rim's displacement by wavelength). A panel without it is drawn by
    /// the base pipeline.
    public var isActive: Bool {
        profile != .rim || dispersion > 0
    }

    /// The lens parameter that held a rejected value.
    public enum Field: String, Hashable, Sendable, CaseIterable {
        case thickness
        case indexOfRefraction
        case maximumOffset
        case dispersion
        case squircleExponent
        case ringCenter
        case ringWidth
    }

    /// Applies the normalization rule. Lengths in points are capped at
    /// `maximumLength` (half the panel's shorter side) where they live
    /// inside the panel.
    package func normalized(maximumLength: Double) throws(GlassParameterError) -> GlassLens {
        var checks: [(Field, Double)] = [
            (.thickness, thickness), (.indexOfRefraction, indexOfRefraction), (.maximumOffset, maximumOffset),
            (.dispersion, dispersion),
        ]
        switch profile {
        case let .squircle(exponent): checks.append((.squircleExponent, exponent))
        case let .ring(center, width): checks += [(.ringCenter, center), (.ringWidth, width)]
        case .rim, .circular, .chamfer, .dome: break
        }
        for (field, value) in checks where !value.isFinite {
            throw .nonFiniteLens(field)
        }
        let clamp = { (value: Double, low: Double, high: Double) in min(max(value, low), high) }
        var lens = self
        lens.thickness = clamp(thickness, 0, Self.maximumThickness)
        lens.indexOfRefraction = clamp(indexOfRefraction, 1, Self.maximumIndexOfRefraction)
        lens.maximumOffset = clamp(maximumOffset, 0, Self.maximumMaximumOffset)
        lens.dispersion = clamp(dispersion, 0, 1)
        switch profile {
        case let .squircle(exponent): lens.profile = .squircle(exponent: clamp(exponent, 1, 8))
        case let .ring(center, width):
            lens.profile = .ring(center: clamp(center, 0, maximumLength), width: clamp(width, 0, maximumLength))
        case .rim, .circular, .chamfer, .dome: break
        }
        return lens
    }
}
