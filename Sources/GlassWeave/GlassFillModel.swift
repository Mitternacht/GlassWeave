import Foundation
internal import GlassWeaveShaderTypes

/// A visible ``GlassFill`` converted to target pixels and linear light at one
/// effect time (GW-28): the uploaded record, the surface and the region on the
/// CPU, and the bubbles. The shader (`Glass.metal`, "Liquid and gel fill")
/// evaluates the same field per pixel; this type is its CPU reference.
///
/// Positions are in target pixels from the panel's center (y down) unless a
/// function says otherwise.
struct GlassFillModel: Equatable {
    var mode: UInt32
    /// The wall thickness in pixels.
    var wall: Double
    /// The dome radius over which the liquid's thickness rises, in pixels.
    var domeRadius: Double
    /// Level mode: the surface's height at the center line, its slope, the
    /// meniscus height and its reach, in pixels.
    var surfaceY: Double
    var slope: Double
    var meniscusHeight: Double
    var meniscusReach: Double
    /// Level mode: the waves' amplitude, wavelength, and phases.
    var waveAmplitude: Double
    var wavelength: Double
    var wavePhases: SIMD2<Double>
    /// The level is full: the region is the inset shell.
    var isFull: Bool
    /// Gel mode: the gel's own shape, and its bounding box center relative to
    /// the panel's center.
    var gel: GlassShapeModel?
    var gelCenter: SIMD2<Double>
    /// The bubbles as uploaded: center x and y, radius, brightness.
    var bubbles: [SIMD4<Float>]
    var record: GWFillUniforms

    /// The loop's turns of the two waves, whole numbers so the waves repeat.
    static let waveTurns = SIMD2<Double>(24, 37)
    static let wavePhaseOffsets = SIMD2<Double>(0, 1.3)
    /// How much the second wave weighs against the first, and how much
    /// shorter it is.
    static let secondWaveWeight = 0.4
    static let secondWaveRatio = 0.62
    /// The thickness profile's share of the dome radius.
    static let gelDomeShare = 0.55
    /// The level's thickness profile's share of the vessel's inset depth.
    static let levelDomeShare = 0.6

    static func == (lhs: GlassFillModel, rhs: GlassFillModel) -> Bool {
        withUnsafeBytes(of: lhs.record) { Array($0) } == withUnsafeBytes(of: rhs.record) { Array($0) }
    }

    /// Converts a normalized fill for `geometry` (the panel's own geometry,
    /// with everything but the fill resolved), or returns `nil` when the fill
    /// draws nothing.
    init?(_ fill: GlassFill, frame: CGRect, displayScale scale: Double, effectTime: Double, geometry: GlassPanelGeometry) {
        guard fill.isActive else { return nil }
        let wall = fill.wallThickness * scale
        let halfSize = geometry.halfSize
        let inscribed = geometry.shape?.inscribedRadius ?? min(halfSize.x, halfSize.y)
        guard inscribed - wall > 1 else { return nil }
        self.wall = wall
        var shellDome = max(inscribed - wall, 1)
        var record = GWFillUniforms()
        var level = 0.0, tilt = 0.0
        var gelModel: GlassShapeModel?
        switch fill.region {
        case .none:
            return nil
        case let .level(value, angle):
            mode = GWFillModeLevel.rawValue
            level = value
            tilt = angle
            shellDome = max(shellDome * Self.levelDomeShare, 1)
        case let .gel(shape):
            mode = GWFillModeGel.rawValue
            guard let model = GlassShapeModel(shape, frame: frame, displayScale: scale, effectTime: effectTime) else { return nil }
            gelModel = model
            shellDome = max(min(model.inscribedRadius * Self.gelDomeShare, shellDome), 1)
        }
        gel = gelModel
        gelCenter = gelModel.map { $0.center - geometry.center } ?? .zero
        domeRadius = shellDome

        // Level surface.
        let top = -(halfSize.y - wall), bottom = halfSize.y - wall
        isFull = mode == GWFillModeLevel.rawValue && level >= 1
        surfaceY = bottom - level * (bottom - top)
        slope = Foundation.tan(tilt * .pi / 180)
        meniscusHeight = fill.surface.meniscus * scale
        meniscusReach = max(6 * scale, 1)
        // Waves vanish as the vessel nears full or empty, so a full level is
        // exactly the inset shell and an empty one shows no ripple.
        let waveScale = min(max(min(level, 1 - level) * 8, 0), 1)
        waveAmplitude = fill.surface.waveAmplitude * scale * waveScale
        wavelength = fill.surface.wavelength * scale
        let loop = GlassFill.loopDuration
        var time = (effectTime * fill.surface.waveSpeed).truncatingRemainder(dividingBy: loop)
        if time < 0 { time += loop }
        wavePhases = Self.wavePhaseOffsets + Self.waveTurns * (2 * Double.pi * time / loop)

        // Colors.
        let ramp = fill.colors.map {
            SIMD3(GlassPanelGeometry.decodeSRGB($0.red), GlassPanelGeometry.decodeSRGB($0.green), GlassPanelGeometry.decodeSRGB($0.blue))
        }
        let mid = ramp.count > 1 ? ramp[ramp.count / 2] : ramp[0]
        let bright = ramp[ramp.count - 1]
        // The edges and the wall line are the brightest ramp color, lifted a
        // little toward white: a warm light, not a white one.
        let pale = bright + (SIMD3<Double>(repeating: 1) - bright) * 0.18
        record.ramp0 = SIMD4<Float>(SIMD3<Float>(ramp[0]), 0)
        record.ramp1 = SIMD4<Float>(SIMD3<Float>(ramp.count > 1 ? ramp[1] : ramp[0]), 0)
        record.ramp2 = SIMD4<Float>(SIMD3<Float>(ramp.count > 2 ? ramp[2] : ramp[ramp.count - 1]), 0)
        // Beer-Lambert: what the liquid does not emit it absorbs, so the
        // background seen through it takes on its color. The coefficient is per
        // pixel of thickness; at the deepest the exponent is
        // `absorption * (1 - color) * 3`.
        let absorb = (SIMD3<Double>(repeating: 1) - mid) * (3 * fill.absorption / shellDome)
        record.absorption = SIMD4<Float>(SIMD3<Float>(absorb), Float(fill.emission))
        record.line = SIMD4<Float>(SIMD3<Float>(pale), Float(fill.sheets.edge))
        // The body's slow flow: two turns per loop, so it repeats exactly.
        let flow = 2 * 2 * Double.pi * time / loop
        record.region = SIMD4<Float>(Float(mode), Float(wall), Float(shellDome), Float(flow))
        record.padding0 = Float(fill.opaque ? 0 : fill.gloss)
        record.surface = SIMD4<Float>(Float(surfaceY), Float(slope), Float(meniscusHeight), Float(meniscusReach))
        record.waves = SIMD4<Float>(Float(waveAmplitude), Float(wavelength), Float(wavePhases.x), Float(wavePhases.y))
        let sheetCount = fill.opaque ? 0 : fill.sheets.count
        let spacing = fill.sheets.spacing * scale
        let lineWidth = max(0.7 * scale, 1)
        record.sheets = SIMD4<Float>(Float(sheetCount), Float(spacing), Float(lineWidth), Float(fill.sheets.wobble * spacing * 0.45))
        record.detail = SIMD4<Float>(
            Float(1 / (36 * scale)), Float(fill.bubbles.seed & 0xFFFF), Float(fill.opaque ? 0 : fill.wallLine), Float(ramp.count)
        )
        if let gelModel {
            record.gelBounds = SIMD4<Float>(Float(gelCenter.x), Float(gelCenter.y), Float(gelModel.halfSize.x), Float(gelModel.halfSize.y))
            record.gel = gelModel.record
        }
        // `richness` rides in bits 8...15 of the flags (zero without it, so the
        // record's layout and an unset fill's bytes are unchanged).
        let richness = fill.opaque ? 0 : UInt32((fill.richness * 255).rounded())
        record.flags = (fill.opaque ? GWFillFlagOpaque.rawValue : 0) | (isFull ? GWFillFlagFull.rawValue : 0) | (richness << 8)
        record.ior = Float(GlassFill.indexOfRefraction)
        bubbles = []
        self.record = record
        if !fill.opaque, fill.bubbles.count > 0 {
            let placed = placeBubbles(fill, effectTime: effectTime, scale: scale, geometry: geometry)
            bubbles = placed
            withUnsafeMutableBytes(of: &self.record.bubbles) { raw in
                let lanes = raw.bindMemory(to: SIMD4<Float>.self)
                for (index, bubble) in placed.enumerated() { lanes[index] = bubble }
            }
            self.record.bubbleCount = UInt32(placed.count)
        }
    }

    // MARK: The region on the CPU

    /// The signed distance, in pixels, to the inset shell (negative inside
    /// it): the panel's outline moved inward by the wall.
    func insetDistance(at pixel: SIMD2<Double>, geometry: GlassPanelGeometry) -> Double {
        geometry.signedDistance(at: pixel) + wall
    }

    /// The surface's height at the panel-relative `x`, in pixels from the
    /// panel's center (y down), with the waves and, `insetDepth` pixels from
    /// the inset wall, the meniscus. `insetDepth` is how far inside the inset
    /// shell the point is.
    func surfaceHeight(atX x: Double, insetDepth: Double) -> Double {
        let k = 2 * Double.pi / max(wavelength, 1)
        let wave = waveAmplitude * ((1 - Self.secondWaveWeight) * Foundation.sin(k * x + wavePhases.x)
            + Self.secondWaveWeight * Foundation.sin(k / Self.secondWaveRatio * x + wavePhases.y))
        let climb = meniscusHeight * Foundation.exp(-max(insetDepth, 0) / meniscusReach)
        return surfaceY + slope * x + wave - climb
    }

    /// The signed distance to the fill's region at a panel-relative pixel,
    /// negative inside: the level's (below the surface, within the inset
    /// shell) or the gel's (clipped to the inset shell).
    func regionDistance(at q: SIMD2<Double>, geometry: GlassPanelGeometry, waves: Bool = true) -> Double {
        let inset = insetDistance(at: geometry.center + q, geometry: geometry)
        if mode == GWFillModeGel.rawValue, let gel {
            return max(gel.signedDistance(at: geometry.center + q), inset)
        }
        if isFull { return inset }
        let height = waves ? surfaceHeight(atX: q.x, insetDepth: -inset) : staticSurfaceHeight(atX: q.x, insetDepth: -inset)
        let line = (height - q.y) / (1 + slope * slope).squareRoot()
        return max(line, inset)
    }

    /// ``surfaceHeight(atX:insetDepth:)`` without the waves.
    func staticSurfaceHeight(atX x: Double, insetDepth: Double) -> Double {
        let climb = meniscusHeight * Foundation.exp(-max(insetDepth, 0) / meniscusReach)
        return surfaceY + slope * x - climb
    }

    // MARK: Bubbles

    /// Places the bubbles for this draw. Each candidate is a deterministic
    /// point of the region's box; it is kept when it is inside the region with
    /// room for its radius and its drift (and a gel's wobble), and drifts on a
    /// small loop of whole turns per ``GlassFill/loopDuration``, so it is
    /// inside the region at every instant.
    private func placeBubbles(_ fill: GlassFill, effectTime: Double, scale: Double, geometry: GlassPanelGeometry) -> [SIMD4<Float>] {
        let count = min(fill.bubbles.count, GlassFill.Bubbles.maximumCount)
        let maxRadius = max(fill.bubbles.size * scale, 0)
        guard count > 0, maxRadius > 0 else { return [] }
        let box: (center: SIMD2<Double>, half: SIMD2<Double>)
        if mode == GWFillModeGel.rawValue, let gel {
            box = (gelCenter, gel.halfSize)
        } else {
            box = (.zero, geometry.halfSize - wall)
        }
        // A gel's wobble and the level's waves move the region's edge; the
        // bubbles keep clear of both, so none is ever outside.
        let wobble = Double(gel?.record.wobbleAmplitude ?? 0) + 2 * waveAmplitude
        let loop = GlassFill.loopDuration
        var time = (effectTime * fill.bubbles.speed).truncatingRemainder(dividingBy: loop)
        if time < 0 { time += loop }
        let turn = 2 * Double.pi * time / loop
        var placed: [SIMD4<Float>] = []
        var candidate: UInt32 = 0
        while placed.count < count, candidate < UInt32(count * 12) {
            defer { candidate += 1 }
            let key = fill.bubbles.seed &* 0x9e37_79b9 &+ candidate &* 0x85eb_ca6b
            let u = InteriorPattern.unit(InteriorPattern.hash(key))
            let v = InteriorPattern.unit(InteriorPattern.hash(key &+ 0x68e3_1da4))
            let sizeKey = InteriorPattern.unit(InteriorPattern.hash(key &+ 0xb529_7a4d))
            let phase = InteriorPattern.unit(InteriorPattern.hash(key &+ 0x1b87_3593)) * 2 * Double.pi
            let spin = Double(3 + Int(InteriorPattern.hash(key &+ 0x2545_f491) % 6))
            // Mostly small, a few larger.
            let radius = max(maxRadius * (0.35 + 0.65 * sizeKey * sizeKey), 1.0)
            let travel = fill.bubbles.speed > 0 ? min(radius * 2.2, 5 * scale) : 0
            let home = box.center + (SIMD2(u, v) * 2 - 1) * box.half
            let margin = radius + travel + wobble + 1
            guard regionDistance(at: home, geometry: geometry, waves: false) < -margin else { continue }
            // Whole turns per loop, so the drift repeats exactly.
            let position = home + travel * SIMD2(
                Foundation.sin(turn * spin + phase), Foundation.cos(turn * (spin + 2) + phase * 1.7)
            )
            let brightness = 0.45 + 0.55 * InteriorPattern.unit(InteriorPattern.hash(key &+ 0x7f4a_7c15))
            placed.append(SIMD4<Float>(Float(position.x), Float(position.y), Float(radius), Float(brightness)))
        }
        return placed
    }
}
