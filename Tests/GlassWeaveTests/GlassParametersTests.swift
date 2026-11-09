import CoreGraphics
import Foundation
import Testing
@testable import GlassWeave

/// The parameter boundary (units, ranges, and the normalize-or-reject rule)
/// and the panel's shape field in pixels.
struct GlassParametersTests {
    // MARK: Normalization rule

    @Test func `In-range parameters pass through unchanged`() throws {
        let parameters = GlassParameters(
            cornerRadius: 20, bezelWidth: 12, refraction: 0.4, edgeHighlight: 0.7,
            tint: GlassTint(red: 0.2, green: 0.5, blue: 0.9, strength: 0.3)
        )
        let panel = GlassPanel(frame: CGRect(x: 10, y: 20, width: 200, height: 100), parameters: parameters)
        #expect(try panel.normalized() == panel)
        #expect(try GlassPanel(frame: panel.frame).normalized() == GlassPanel(frame: panel.frame))
    }

    @Test func `Out-of-range coefficients are clamped to 0...1`() throws {
        let parameters = GlassParameters(
            cornerRadius: 10, bezelWidth: 10, refraction: 1.7, edgeHighlight: -0.4,
            tint: GlassTint(red: -1, green: 2, blue: 0.5, strength: 1.5)
        )
        let normalized = try GlassPanel(frame: CGRect(x: 0, y: 0, width: 100, height: 100), parameters: parameters).normalized().parameters
        #expect(normalized.refraction == 1)
        #expect(normalized.edgeHighlight == 0)
        #expect(normalized.tint == GlassTint(red: 0, green: 1, blue: 0.5, strength: 1))
    }

    @Test func `Lengths are clamped between zero and half the shorter side`() throws {
        let frame = CGRect(x: 0, y: 0, width: 120, height: 40)
        let long = try GlassPanel(frame: frame, parameters: GlassParameters(cornerRadius: 500, bezelWidth: 21)).normalized().parameters
        #expect(long.cornerRadius == 20)
        #expect(long.bezelWidth == 20)
        let negative = try GlassPanel(frame: frame, parameters: GlassParameters(cornerRadius: -3, bezelWidth: -0.5)).normalized().parameters
        #expect(negative.cornerRadius == 0)
        #expect(negative.bezelWidth == 0)
    }

    @Test func `A negative size becomes an empty panel that draws nothing`() throws {
        let panel = try GlassPanel(frame: CGRect(x: 5, y: 5, width: -30, height: 40)).normalized()
        #expect(panel.frame == CGRect(x: 5, y: 5, width: 0, height: 40))
        #expect(panel.parameters.cornerRadius == 0)
        #expect(panel.parameters.bezelWidth == 0)
        #expect(GlassPanelGeometry(panel: panel, displayScale: 2).isEmpty)
    }

    static let nonFiniteValues: [Double] = [.nan, .infinity, -.infinity]

    /// Every field a panel holds; the effect time is the renderer's and is
    /// tested with it (`GlassHaloParameterTests`).
    static let panelFields = GlassParameterError.Field.allCases.filter { $0 != .effectTime }

    @Test(arguments: panelFields, nonFiniteValues)
    func `A non-finite value is rejected and names its field`(field: GlassParameterError.Field, value: Double) {
        var panel = GlassPanel(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        // A visible glow with two stops, so a bad value in either is found.
        panel.parameters.glow = GlassGlow(colors: [
            .init(red: 1, green: 0.5, blue: 0, angle: 0), .init(red: 0, green: 0.5, blue: 1, angle: 180),
        ])
        // A visible interior with two colors, likewise (GW-19).
        panel.parameters.interior = GlassInterior(effect: .energy, colors: [
            .init(red: 0.2, green: 0.6, blue: 1), .init(red: 1, green: 1, blue: 1),
        ])
        switch field {
        case .frame: panel.frame.size.width = value
        case .cornerRadius: panel.parameters.cornerRadius = value
        case .bezelWidth: panel.parameters.bezelWidth = value
        case .refraction: panel.parameters.refraction = value
        case .edgeHighlight: panel.parameters.edgeHighlight = value
        case .tintRed: panel.parameters.tint.red = value
        case .tintGreen: panel.parameters.tint.green = value
        case .tintBlue: panel.parameters.tint.blue = value
        case .tintStrength: panel.parameters.tint.strength = value
        case .glowColorRed: panel.parameters.glow.colors[1].red = value
        case .glowColorGreen: panel.parameters.glow.colors[0].green = value
        case .glowColorBlue: panel.parameters.glow.colors[1].blue = value
        case .glowColorAngle: panel.parameters.glow.colors[1].angle = value
        case .glowRimWidth: panel.parameters.glow.rimWidth = value
        case .glowRimSoftness: panel.parameters.glow.rimSoftness = value
        case .glowRimIntensity: panel.parameters.glow.rimIntensity = value
        case .glowInnerGlowRadius: panel.parameters.glow.innerGlowRadius = value
        case .glowInnerGlowIntensity: panel.parameters.glow.innerGlowIntensity = value
        case .glowCenterOpacity: panel.parameters.glow.centerOpacity = value
        case .glowLightAngle: panel.parameters.glow.lightAngle = value
        case .glowDirectionality: panel.parameters.glow.directionality = value
        case .glowHaloRadius: panel.parameters.glow.haloRadius = value
        case .glowHaloIntensity: panel.parameters.glow.haloIntensity = value
        case .glowPulsePeriod: panel.parameters.glow.pulsePeriod = value
        case .glowPulseDepth: panel.parameters.glow.pulseDepth = value
        case .interiorColorRed: panel.parameters.interior.colors[1].red = value
        case .interiorColorGreen: panel.parameters.interior.colors[0].green = value
        case .interiorColorBlue: panel.parameters.interior.colors[1].blue = value
        case .interiorIntensity: panel.parameters.interior.intensity = value
        case .interiorSpeed: panel.parameters.interior.speed = value
        case .interiorCenterFade: panel.parameters.interior.centerFade = value
        case .effectTime: Issue.record("Not a panel field")
        }
        #expect(throws: GlassParameterError.nonFinite(field)) {
            try panel.normalized()
        }
        #expect(GlassParameterError.nonFinite(field).description.contains(field.rawValue))
    }

    @Test func `A non-finite frame origin is rejected`() {
        let panel = GlassPanel(frame: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10))
        #expect(throws: GlassParameterError.nonFinite(.frame)) {
            try panel.normalized()
        }
    }

    // MARK: Points to pixels

    @Test func `Points convert to pixels with the display scale`() throws {
        let panel = try GlassPanel(
            frame: CGRect(x: 10, y: 20, width: 100, height: 50),
            parameters: GlassParameters(
                cornerRadius: 12, bezelWidth: 8, refraction: 0.5, edgeHighlight: 1,
                tint: GlassTint(red: 0.5, green: 0, blue: 1, strength: 0.25)
            )
        ).normalized()
        let geometry = GlassPanelGeometry(panel: panel, displayScale: 3)
        #expect(geometry.center == SIMD2(180, 135))
        #expect(geometry.halfSize == SIMD2(150, 75))
        #expect(geometry.cornerRadius == 36)
        #expect(geometry.bezelWidth == 24)
        #expect(geometry.normalRadius == 36)
        // refraction × bezel / 2, in pixels.
        #expect(geometry.maxDisplacement == 6)
        #expect(geometry.edgeHighlight == GlassParameters.maximumEdgeHighlight)
        // sRGB 0.5 is about 0.214 in linear light.
        #expect(abs(geometry.tintLinear.x - 0.21404) < 1e-4)
        #expect(geometry.tintLinear.y == 0)
        #expect(abs(geometry.tintLinear.z - 1) < 1e-12)
        #expect(geometry.tintStrength == 0.25)
    }

    // MARK: Shape field

    /// A 200 x 100 pixel panel centered at (150, 100), corner radius 10,
    /// rim 20, full refraction.
    private func geometry(cornerRadius: Double = 10, bezelWidth: Double = 20, refraction: Double = 1) throws -> GlassPanelGeometry {
        let panel = try GlassPanel(
            frame: CGRect(x: 50, y: 50, width: 200, height: 100),
            parameters: GlassParameters(cornerRadius: cornerRadius, bezelWidth: bezelWidth, refraction: refraction, edgeHighlight: 1)
        ).normalized()
        return GlassPanelGeometry(panel: panel, displayScale: 1)
    }

    @Test func `Signed distance is negative inside, zero on the outline, positive outside`() throws {
        let g = try geometry()
        #expect(g.signedDistance(at: [150, 100]) == -50)
        #expect(g.signedDistance(at: [250, 100]) == 0)
        #expect(g.signedDistance(at: [255, 100]) == 5)
        #expect(g.signedDistance(at: [150, 45]) == 5)
        // On the top-right corner arc (centered at (240, 60), radius 10), and
        // at the square corner the arc cuts off.
        let onArc = SIMD2<Double>(240 + 10 / 2.0.squareRoot(), 60 - 10 / 2.0.squareRoot())
        #expect(abs(g.signedDistance(at: onArc)) < 1e-9)
        #expect(abs(g.signedDistance(at: [250, 50]) - (10 * 2.0.squareRoot() - 10)) < 1e-9)
    }

    @Test func `Normals point outward along edges and radially at corners`() throws {
        let g = try geometry()
        #expect(g.outwardNormal(at: [245, 100]) == SIMD2(1, 0))
        #expect(g.outwardNormal(at: [55, 100]) == SIMD2(-1, 0))
        #expect(g.outwardNormal(at: [150, 52]) == SIMD2(0, -1))
        #expect(g.outwardNormal(at: [150, 148]) == SIMD2(0, 1))
        // normalRadius is max(10, 20) = 20: the corner field is centered at
        // (230, 70) for the top-right corner.
        let diagonal = g.outwardNormal(at: [240, 60])
        #expect(abs(diagonal.x - 1 / 2.0.squareRoot()) < 1e-12)
        #expect(abs(diagonal.y + 1 / 2.0.squareRoot()) < 1e-12)
    }

    @Test func `Displacement is largest at the outline and zero past the rim`() throws {
        let g = try geometry()
        #expect(g.maxDisplacement == 10)
        #expect(g.displacement(at: [250, 100]) == 10)
        // Outside the outline (the antialiased band) it stays at the maximum.
        #expect(g.displacement(at: [250.4, 100]) == 10)
        // Halfway into the rim: 10 × (1 - 0.5)².
        #expect(g.displacement(at: [240, 100]) == 2.5)
        #expect(g.displacement(at: [230, 100]) == 0)
        #expect(g.displacement(at: [150, 100]) == 0)
        #expect(try geometry(refraction: 0).displacement(at: [250, 100]) == 0)
        #expect(try geometry(bezelWidth: 0).displacement(at: [250, 100]) == 0)
    }

    @Test(arguments: [0.25, 0.5, 1.0])
    func `Every sample moves inward by at most the bound, without folding over`(refraction: Double) throws {
        let g = try geometry(refraction: refraction)
        let bound = refraction * g.bezelWidth / 2
        var previousSampledDepth = -Double.infinity
        // Along the right edge, from the outline inward.
        for step in 0...400 {
            let pixel = SIMD2(250 - Double(step) * 0.1, 100)
            let sample = g.samplePosition(at: pixel)
            let sampledDepth = -g.signedDistance(at: sample)
            #expect(sampledDepth >= previousSampledDepth - 1e-12)
            previousSampledDepth = sampledDepth
        }
        // Everywhere in and around the panel, the sample moves no farther
        // than the bound and never toward the outline.
        for y in stride(from: 40.5, to: 160, by: 1) {
            for x in stride(from: 40.5, to: 260, by: 1) {
                let pixel = SIMD2(x, y)
                let sample = g.samplePosition(at: pixel)
                let moved = sample - pixel
                #expect((moved.x * moved.x + moved.y * moved.y).squareRoot() <= bound + 1e-9)
                if g.signedDistance(at: pixel) <= 0 {
                    #expect(g.signedDistance(at: sample) <= g.signedDistance(at: pixel) + 1e-9)
                }
            }
        }
    }

    @Test func `Rim normals turn smoothly around a corner tighter than the rim`() throws {
        // Corner radius 4 with a 20-pixel rim: normals come from a radius-20
        // field, so walking around the corner at mid-rim depth never jumps.
        let g = try geometry(cornerRadius: 4, bezelWidth: 20)
        var previous: SIMD2<Double>?
        for step in 0...200 {
            let angle = Double(step) / 200 * Double.pi / 2
            // Around the top-right corner of the radius-20 field.
            let pixel = SIMD2(230, 70) + SIMD2(cos(angle), -sin(angle)) * 12
            let normal = g.outwardNormal(at: pixel)
            if let previous {
                let turn = acos(min(max(previous.x * normal.x + previous.y * normal.y, -1), 1))
                #expect(turn < 0.02)
            }
            previous = normal
        }
    }

    @Test func `Edge illumination stays in the rim, is bounded, and favors the lit side`() throws {
        let g = try geometry()
        #expect(g.highlight(at: [150, 100]) == 0)
        #expect(g.highlight(at: [215, 100]) == 0)
        var largest = 0.0
        for y in stride(from: 50.5, to: 150, by: 1) {
            for x in stride(from: 50.5, to: 250, by: 1) {
                largest = max(largest, g.highlight(at: [x, y]))
            }
        }
        #expect(largest <= GlassParameters.maximumEdgeHighlight)
        #expect(largest > 0.2)
        // Upper-left rim faces the light; lower-right faces away.
        #expect(g.highlight(at: [60, 60]) > g.highlight(at: [240, 140]))
        #expect(g.highlight(at: [150, 50.5]) > g.highlight(at: [150, 149.5]))
    }
}
