import CoreGraphics
import Foundation

/// A luminous liquid or gel held inside a glass vessel (GW-28).
///
/// > Important: Experimental. This API may change before a stable release.
///
/// Apple's native glass cannot show anything inside it. A fill gives the
/// panel a body: a calm glowing liquid whose light is the only light inside the
/// glass, seen **through the shell**, so the wall magnifies and bends it like
/// the glass it is. The panel's own shape, lens and light model draw the vessel
/// (the clean outline, the thin rim light); the fill adds what is in it.
///
/// | Region | Meaning |
/// | --- | --- |
/// | ``Region/none`` | No fill. The panel is drawn exactly as without this type, byte for byte, by a pipeline variant that does not contain the fill code. The default. |
/// | ``Region/level(level:tilt:)`` | The shell inset by ``wallThickness``, below a waved surface line with a meniscus at the wall. `level` is the fraction of the inset shell's height (0 is empty, 1 is full), and `tilt` the surface's angle in degrees relative to the vessel (``GlassFillSlosh`` computes one that sloshes). |
/// | ``Region/gel(_:)`` | A body of its own shape (any ``GlassShape`` but the rounded rectangle, which becomes a squircle) in the panel's frame units, clipped to the inset shell. A blob's wobble is its loop-locked motion. |
///
/// **What is drawn.** The liquid has a dome-shaped thickness (a quarter-round
/// profile over the inscribed radius of its region). Light from the liquid
/// itself follows the thickness along an *emissive ramp* of up to three colors
/// (thin edge to deep middle), so a thin edge is dim and the middle glows; the
/// background seen through it is absorbed by Beer-Lambert's law, which colors
/// it. Up to four *contour sheets* (iso-offsets of the fill's own distance
/// field, bent by noise) carry thin bright edges on the side facing the light,
/// through the same soft knee the light model uses, with a soft analytic bloom.
/// A thin *wall line* runs in the glass just outside the liquid, brighter
/// where the liquid is near the wall and where the wall is steep (a Fresnel
/// term). Up to 16 tiny *bubbles*, computed on the CPU, are small soft discs
/// with a faint highlight, always inside the liquid.
///
/// **A curved body.** The liquid's surface is a dome whose slope (and a slow,
/// smooth field of luminous masses that drifts on small loops) gives it a
/// normal, so one key light (the light model's, or the upper left) shades it:
/// the side facing the light is brighter and yellower, the far side a deeper
/// amber, and a soft specular streak follows the lit wall at a fixed depth. What
/// lies inside the liquid (the sheets, the bubbles) is bent by that surface, so
/// the edges magnify it like a lens. See ``gloss``.
///
/// **Normalization rule** (the ``GlassParameters`` rule). A NaN or infinite
/// value anywhere is rejected with ``GlassParameterError/nonFiniteFill(_:)``
/// naming its ``Field``; finite values out of range are clamped as the table
/// states. A list of more than three colors keeps the first three; an empty
/// list uses the default amber ramp.
///
/// | Property | Unit | Valid range | Default | Meaning |
/// | --- | --- | --- | --- | --- |
/// | ``region`` | see ``Region`` | level 0...1, tilt −60...60° | ``Region/none`` | What the fill is. |
/// | ``wallThickness`` | points | 0 to half the shorter side | 5 | The glass between the outline and the liquid. No liquid is drawn shallower than this. |
/// | ``colors`` | sRGB | components 0...1, 1 to 3 stops | amber | The emissive ramp, thin edge to deep middle. |
/// | ``emission`` | normalized | 0...1 | 0.85 | How strongly the liquid lights itself. |
/// | ``absorption`` | normalized | 0...1 | 0.6 | How much of what is behind the liquid it absorbs and colors. |
/// | ``sheets`` | see ``Sheets`` | see ``Sheets`` | 3 sheets | The contour sheets and their bright edges. |
/// | ``wallLine`` | normalized | 0...1 | 0.5 | The thin line in the glass wall. |
/// | ``gloss`` | normalized | 0...1 | 0.6 | How glossy the liquid's curved surface is: its soft specular streak, the bright thin edge and a level's meniscus line. 0 is matte. |
/// | ``bubbles`` | see ``Bubbles`` | see ``Bubbles`` | 5 | The tiny bubbles. |
/// | ``surface`` | see ``Surface`` | see ``Surface`` | calm | The level surface's waves and meniscus (level mode only); its ``Surface/waveSpeed`` also sets how fast the body's slow flow moves. |
/// | ``opaque`` | — | — | `false` | A single flat, opaque color: what Reduce Transparency presents. |
public struct GlassFill: Hashable, Sendable {
    /// What the vessel holds.
    public enum Region: Hashable, Sendable {
        /// Nothing: the panel has no fill.
        case none
        /// The inset shell below a waved surface. `level` is 0...1 of the inset
        /// shell's height; `tilt` is the surface's angle in degrees relative
        /// to the vessel, −60...60 (0 is level, positive turns the right side
        /// down on the screen).
        case level(level: Double, tilt: Double)
        /// A body of its own shape, in the panel's frame units (see
        /// ``GlassShape``), clipped to the inset shell.
        case gel(GlassShape)
    }

    /// A color of the emissive ramp, sRGB-encoded, 0...1.
    public struct Color: Hashable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// The contour sheets: iso-offsets of the fill's distance field, each with
    /// a thin bright edge.
    ///
    /// | Property | Unit | Valid range | Default | Meaning |
    /// | --- | --- | --- | --- | --- |
    /// | ``count`` | sheets | 0...4 | 3 | How many sheets; at the balanced tier at most 2, and at the minimal tier none. |
    /// | ``spacing`` | points | 0 to half the shorter side | 12 | The distance between neighbouring sheets. |
    /// | ``edge`` | normalized | 0...1 | 0.55 | How bright the edges are, on the side facing the light. |
    /// | ``wobble`` | normalized | 0...1 | 0.5 | How far noise bends the sheets. |
    public struct Sheets: Hashable, Sendable {
        public var count: Int
        public var spacing: Double
        public var edge: Double
        public var wobble: Double

        public static let maximumCount = 4
        public static let none = Sheets(count: 0)

        public init(count: Int = 3, spacing: Double = 12, edge: Double = 0.55, wobble: Double = 0.5) {
            self.count = count
            self.spacing = spacing
            self.edge = edge
            self.wobble = wobble
        }
    }

    /// The tiny bubbles in the liquid, computed on the CPU for every draw. They
    /// drift on small loops that repeat exactly every 64 seconds of effect
    /// time divided by ``speed``, and are always inside the liquid.
    ///
    /// | Property | Unit | Valid range | Default | Meaning |
    /// | --- | --- | --- | --- | --- |
    /// | ``count`` | bubbles | 0...16 | 5 | How many; at the balanced tier at most 8, and none at the minimal tier. |
    /// | ``size`` | points | 0 to half the shorter side | 3.2 | The radius of the biggest; most are smaller. |
    /// | ``speed`` | multiple | 0...3 | 1 | How fast they drift; 0 holds them still, which is what Reduce Motion gets. |
    /// | ``seed`` | — | any | 7 | Picks where they are. |
    public struct Bubbles: Hashable, Sendable {
        public var count: Int
        public var size: Double
        public var speed: Double
        public var seed: UInt32

        public static let maximumCount = 16
        public static let none = Bubbles(count: 0)

        public init(count: Int = 5, size: Double = 3.2, speed: Double = 1, seed: UInt32 = 7) {
            self.count = count
            self.size = size
            self.speed = speed
            self.seed = seed
        }
    }

    /// The level surface: its waves and the meniscus that climbs the wall.
    ///
    /// | Property | Unit | Valid range | Default | Meaning |
    /// | --- | --- | --- | --- | --- |
    /// | ``waveAmplitude`` | points | 0...16 | 1.2 | How high the waves are. 0 is a flat surface. |
    /// | ``wavelength`` | points | 8...2,000 | 60 | The distance between crests. |
    /// | ``waveSpeed`` | multiple | 0...3 | 1 | How fast they run; 0 holds them still. |
    /// | ``meniscus`` | points | 0...16 | 3 | How far the surface climbs the wall. |
    public struct Surface: Hashable, Sendable {
        public var waveAmplitude: Double
        public var wavelength: Double
        public var waveSpeed: Double
        public var meniscus: Double

        public static let flat = Surface(waveAmplitude: 0, meniscus: 0)

        public init(waveAmplitude: Double = 1.2, wavelength: Double = 60, waveSpeed: Double = 1, meniscus: Double = 3) {
            self.waveAmplitude = waveAmplitude
            self.wavelength = wavelength
            self.waveSpeed = waveSpeed
            self.meniscus = meniscus
        }
    }

    /// A fill parameter that held a rejected value; see
    /// ``GlassParameterError/nonFiniteFill(_:)``.
    public enum Field: String, Hashable, Sendable, CaseIterable {
        case level, tilt
        case wallThickness
        case colorRed, colorGreen, colorBlue
        case emission, absorption
        case sheetSpacing, sheetEdge, sheetWobble
        case wallLine
        case gloss
        case bubbleSize, bubbleSpeed
        case waveAmplitude, wavelength, waveSpeed, meniscus
        /// The vessel tilt of a ``GlassFillSlosh``.
        case vesselTilt
        /// The velocity passed to ``GlassFillSlosh/nudge(velocity:)``.
        case sloshVelocity
        /// The interval passed to ``GlassFillSlosh/advance(by:)``.
        case sloshInterval
    }

    public var region: Region
    public var wallThickness: Double
    public var colors: [Color]
    public var emission: Double
    public var absorption: Double
    public var sheets: Sheets
    public var wallLine: Double
    public var bubbles: Bubbles
    public var surface: Surface
    public var gloss: Double
    public var opaque: Bool

    /// The most colors the emissive ramp uses; further ones are dropped.
    public static let maximumColors = 3
    /// The index of refraction of the liquid.
    public static let indexOfRefraction = 1.33
    /// The ramp of a fill that gives none: deep amber, orange, pale gold.
    public static let defaultColors = [
        Color(red: 0.74, green: 0.20, blue: 0.04),
        Color(red: 1.00, green: 0.48, blue: 0.10),
        Color(red: 1.00, green: 0.78, blue: 0.42),
    ]

    /// No fill (the default).
    public static let none = GlassFill()

    public init(
        region: Region = .none,
        wallThickness: Double = 5,
        colors: [Color] = GlassFill.defaultColors,
        emission: Double = 0.85,
        absorption: Double = 0.6,
        sheets: Sheets = Sheets(),
        wallLine: Double = 0.5,
        bubbles: Bubbles = Bubbles(),
        surface: Surface = Surface(),
        gloss: Double = 0.6,
        opaque: Bool = false
    ) {
        self.region = region
        self.wallThickness = wallThickness
        self.colors = colors
        self.emission = emission
        self.absorption = absorption
        self.sheets = sheets
        self.wallLine = wallLine
        self.bubbles = bubbles
        self.surface = surface
        self.gloss = gloss
        self.opaque = opaque
    }

    /// Whether the fill draws anything: a gel, or a level above 0.
    public var isActive: Bool {
        switch region {
        case .none: false
        case let .level(level, _): level > 0
        case .gel: true
        }
    }

    /// Whether the fill changes with time: drifting bubbles, the body's slow
    /// flow and a level's running waves (both follow ``Surface/waveSpeed``), or
    /// a gel's wobbling outline. An opaque fill never moves.
    public var isAnimated: Bool {
        guard isActive, !opaque else { return false }
        if bubbles.count > 0, bubbles.speed > 0, bubbles.size > 0 { return true }
        if surface.waveSpeed > 0 { return true }
        if case let .gel(shape) = region { return shape.isAnimated }
        return false
    }

    /// The time, in seconds of ``GlassRenderer/setEffectTime(_:)`` divided by
    /// the speed, after which the bubbles and the waves repeat exactly.
    public static let loopDuration = GlassInterior.loopDuration
}

// MARK: Normalization

extension GlassFill {
    /// Applies the normalization rule: rejects non-finite values and clamps
    /// finite ones into range. Lengths are capped at `maximumLength` (half the
    /// panel's shorter side, or a blob's inscribed radius).
    func normalized(maximumLength: Double) throws(GlassParameterError) -> GlassFill {
        func finite(_ value: Double, _ field: Field) throws(GlassParameterError) -> Double {
            guard value.isFinite else { throw .nonFiniteFill(field) }
            return value
        }
        let unit = { (value: Double) in min(max(value, 0), 1) }
        let length = { (value: Double) in min(max(value, 0), maximumLength) }
        let region: Region
        switch self.region {
        case .none:
            region = .none
        case let .level(level, tilt):
            region = .level(
                level: unit(try finite(level, .level)),
                tilt: min(max(try finite(tilt, .tilt), -60), 60)
            )
        case let .gel(shape):
            var checked = try shape.normalized()
            if case .roundedRectangle = checked { checked = .squircle }
            region = .gel(checked)
        }
        var kept: [Color] = []
        for color in colors.prefix(Self.maximumColors) {
            kept.append(Color(
                red: unit(try finite(color.red, .colorRed)),
                green: unit(try finite(color.green, .colorGreen)),
                blue: unit(try finite(color.blue, .colorBlue))
            ))
        }
        // Values beyond the kept colors are still checked.
        for color in colors.dropFirst(Self.maximumColors) {
            _ = try finite(color.red, .colorRed)
            _ = try finite(color.green, .colorGreen)
            _ = try finite(color.blue, .colorBlue)
        }
        if kept.isEmpty { kept = Self.defaultColors }
        let sheets = Sheets(
            count: min(max(sheets.count, 0), Sheets.maximumCount),
            spacing: length(try finite(sheets.spacing, .sheetSpacing)),
            edge: unit(try finite(sheets.edge, .sheetEdge)),
            wobble: unit(try finite(sheets.wobble, .sheetWobble))
        )
        let bubbles = Bubbles(
            count: min(max(bubbles.count, 0), Bubbles.maximumCount),
            size: length(try finite(bubbles.size, .bubbleSize)),
            speed: min(max(try finite(bubbles.speed, .bubbleSpeed), 0), 3),
            seed: bubbles.seed
        )
        let surface = Surface(
            waveAmplitude: min(max(try finite(surface.waveAmplitude, .waveAmplitude), 0), 16),
            wavelength: min(max(try finite(surface.wavelength, .wavelength), 8), 2000),
            waveSpeed: min(max(try finite(surface.waveSpeed, .waveSpeed), 0), 3),
            meniscus: min(max(try finite(surface.meniscus, .meniscus), 0), 16)
        )
        return GlassFill(
            region: region,
            wallThickness: length(try finite(wallThickness, .wallThickness)),
            colors: kept,
            emission: unit(try finite(emission, .emission)),
            absorption: unit(try finite(absorption, .absorption)),
            sheets: sheets,
            wallLine: unit(try finite(wallLine, .wallLine)),
            bubbles: bubbles,
            surface: surface,
            gloss: unit(try finite(gloss, .gloss)),
            opaque: opaque
        )
    }
}

// MARK: Slosh

/// The slosh of a level fill's surface (GW-28): a damped spring, computed on
/// the CPU, that the app steps and reads.
///
/// > Important: Experimental. This API may change before a stable release.
///
/// The surface rests at the angle that keeps it level in the world:
/// `−vesselTilt` relative to the vessel (fixed gravity). The app reports the
/// vessel's horizontal velocity with ``nudge(velocity:)``; the surface swings
/// the other way and settles on a decaying oscillation. The whole state is
/// plain numbers advanced in fixed 1/240 s steps, so the same sequence of
/// nudges and intervals always gives the same angles, whatever the frame
/// rate. Pass ``tilt`` as the `tilt` of ``GlassFill/Region/level(level:tilt:)``,
/// and ``agitation`` to scale the surface's waves, and call ``advance(by:)``
/// until ``isSettled``, after which there is nothing left to redraw.
///
/// | Property | Unit | Valid range | Meaning |
/// | --- | --- | --- | --- |
/// | ``vesselTilt`` | degrees | −60...60 | The vessel's own tilt; the surface settles at its negative. |
/// | ``period`` | seconds | 0.2...5 | The undamped swing's period. |
/// | ``dampingRatio`` | — | 0.02...1.5 | 0 never settles, 1 is critically damped. |
public struct GlassFillSlosh: Hashable, Sendable {
    /// The vessel's own tilt in degrees; the surface rests at its negative.
    public var vesselTilt: Double
    /// The surface's angle relative to the vessel, in degrees.
    public private(set) var tilt: Double
    /// How fast the angle changes, in degrees per second.
    public private(set) var angularVelocity: Double
    /// The undamped swing's period, in seconds.
    public let period: Double
    /// The damping ratio: 1 is critical.
    public let dampingRatio: Double
    private var remainder: Double

    /// The largest swing from rest, in degrees.
    public static let maximumSwing = 40.0
    /// The fixed step the spring is advanced by, in seconds.
    public static let step = 1.0 / 240.0

    public init(period: Double = 0.9, dampingRatio: Double = 0.2, vesselTilt: Double = 0) {
        let tilt = min(max(vesselTilt.isFinite ? vesselTilt : 0, -60), 60)
        self.period = min(max(period.isFinite ? period : 0.9, 0.2), 5)
        self.dampingRatio = min(max(dampingRatio.isFinite ? dampingRatio : 0.2, 0.02), 1.5)
        self.vesselTilt = tilt
        self.tilt = -tilt
        angularVelocity = 0
        remainder = 0
    }

    /// The angle the surface settles at: the negative of the vessel's tilt.
    public var restTilt: Double {
        -min(max(vesselTilt, -60), 60)
    }

    /// Whether the surface is at rest (within 0.1 degrees of its rest angle
    /// and no longer moving), so no redraw is needed.
    public var isSettled: Bool {
        abs(tilt - restTilt) < 0.1 && abs(angularVelocity) < 0.5
    }

    /// How far the surface is from rest, 0 to 1; scales the waves' height so
    /// a swinging surface ripples and a still one does not.
    public var agitation: Double {
        min(max(abs(tilt - restTilt) / 20 + abs(angularVelocity) / 400, 0), 1)
    }

    /// The vessel moved sideways at `velocity` points per second; the surface
    /// swings the other way.
    public mutating func nudge(velocity: Double) throws(GlassParameterError) {
        guard velocity.isFinite else { throw .nonFiniteFill(.sloshVelocity) }
        let kick = min(max(-velocity * 0.12, -400), 400)
        angularVelocity += kick
    }

    /// Advances the spring by `seconds`, in fixed 1/240 s steps (the rest is
    /// carried to the next call).
    public mutating func advance(by seconds: Double) throws(GlassParameterError) {
        guard seconds.isFinite else { throw .nonFiniteFill(.sloshInterval) }
        remainder += min(max(seconds, 0), 1)
        let omega = 2 * Double.pi / period
        let rest = restTilt
        while remainder >= Self.step {
            remainder -= Self.step
            let acceleration = -omega * omega * (tilt - rest) - 2 * dampingRatio * omega * angularVelocity
            angularVelocity += acceleration * Self.step
            tilt += angularVelocity * Self.step
            let swing = min(max(tilt - rest, -Self.maximumSwing), Self.maximumSwing)
            if swing != tilt - rest {
                tilt = rest + swing
                angularVelocity = 0
            }
        }
        if isSettled {
            tilt = rest
            angularVelocity = 0
        }
    }
}
