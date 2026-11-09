import CoreGraphics
import Foundation
import Metal
import Testing
@testable import GlassWeave

/// GW-17's parameter boundary: units, ranges, defaults, and the
/// normalize-or-reject rule for `GlassGlow`, plus the CPU geometry the
/// shader mirrors.
struct GlassGlowParameterTests {
    private static let frame = CGRect(x: 0, y: 0, width: 120, height: 80)

    private func normalizedGlow(_ glow: GlassGlow, frame: CGRect = frame) throws -> GlassGlow {
        try GlassPanel(frame: frame, parameters: GlassParameters(glow: glow)).normalized().parameters.glow
    }

    @Test func `Glass parameters default to no glow`() {
        #expect(GlassParameters().glow == .none)
        #expect(GlassGlow.none.colors.isEmpty)
        #expect(!GlassGlow.none.isVisible)
        let glow = GlassGlow(colors: [.init(red: 1, green: 0, blue: 0)])
        #expect(glow.rimWidth == 1.5)
        #expect(glow.rimSoftness == 1.5)
        #expect(glow.rimIntensity == 1)
        #expect(glow.innerGlowRadius == 24)
        #expect(glow.innerGlowIntensity == 0.5)
        #expect(glow.centerOpacity == 0)
        #expect(glow.lightAngle == 0)
        #expect(glow.directionality == 0)
        #expect(glow.isVisible)
        #expect(GlassGlow.maximumColorStops == 4)
    }

    @Test func `A glow draws only with a color and a rim, an inner glow, or a center fill`() {
        let red = [GlassGlow.ColorStop(red: 1, green: 0, blue: 0)]
        #expect(!GlassGlow(colors: [], rimIntensity: 1, innerGlowIntensity: 1, centerOpacity: 1).isVisible)
        #expect(!GlassGlow(colors: red, rimIntensity: 0, innerGlowIntensity: 0, centerOpacity: 0).isVisible)
        #expect(!GlassGlow(colors: red, rimWidth: 0, rimSoftness: 0, innerGlowRadius: 0).isVisible)
        #expect(GlassGlow(colors: red, rimWidth: 0, rimSoftness: 2, innerGlowIntensity: 0).isVisible)
        #expect(GlassGlow(colors: red, rimIntensity: 0, innerGlowIntensity: 0, centerOpacity: 0.1).isVisible)
        #expect(GlassGlow(colors: red, rimIntensity: 0, innerGlowRadius: 4, innerGlowIntensity: 0.2).isVisible)
    }

    @Test func `An in-range glow passes through unchanged`() throws {
        let glow = GlassGlow(
            colors: [.init(red: 0.9, green: 0.4, blue: 0.1, angle: 10), .init(red: 0.2, green: 0.6, blue: 1, angle: 200)],
            rimWidth: 2, rimSoftness: 3, rimIntensity: 0.8, innerGlowRadius: 30, innerGlowIntensity: 0.4,
            centerOpacity: 0.1, lightAngle: 359.5, directionality: 0.6
        )
        #expect(try normalizedGlow(glow) == glow)
    }

    @Test func `Out-of-range glow values are clamped`() throws {
        let glow = GlassGlow(
            colors: [.init(red: -0.5, green: 1.5, blue: 0.25)],
            rimWidth: 500, rimSoftness: -2, rimIntensity: 3, innerGlowRadius: 41, innerGlowIntensity: -1,
            centerOpacity: 7, lightAngle: 0, directionality: 1.01
        )
        let normalized = try normalizedGlow(glow)
        #expect(normalized.colors == [.init(red: 0, green: 1, blue: 0.25)])
        // Lengths: at most half the shorter side (80 / 2), never negative.
        #expect(normalized.rimWidth == 40)
        #expect(normalized.rimSoftness == 0)
        #expect(normalized.innerGlowRadius == 40)
        #expect(normalized.rimIntensity == 1)
        #expect(normalized.innerGlowIntensity == 0)
        #expect(normalized.centerOpacity == 1)
        #expect(normalized.directionality == 1)
    }

    @Test(arguments: [
        (0.0, 0.0), (360.0, 0.0), (720.0, 0.0), (-90.0, 270.0), (450.0, 90.0),
        (-0.0, 0.0), (-720.5, 359.5), (1e-20, 1e-20), (-1e-20, 0.0), (359.999, 359.999),
    ])
    func `Angles are reduced into 0 to 360`(angle: Double, expected: Double) throws {
        let glow = GlassGlow(colors: [.init(red: 1, green: 1, blue: 1, angle: angle)], lightAngle: angle)
        let normalized = try normalizedGlow(glow)
        #expect(abs(normalized.colors[0].angle - expected) < 1e-9)
        #expect(abs(normalized.lightAngle - expected) < 1e-9)
        #expect(normalized.lightAngle >= 0 && normalized.lightAngle < 360)
        #expect(normalized.lightAngle.sign == .plus)
    }

    @Test func `Only the first four stops are kept, ordered stably by angle`() throws {
        let stops: [GlassGlow.ColorStop] = [
            .init(red: 0.1, green: 0, blue: 0, angle: 300),
            .init(red: 0.2, green: 0, blue: 0, angle: -270), // 90
            .init(red: 0.3, green: 0, blue: 0, angle: 90),   // equal angle: after the one before it
            .init(red: 0.4, green: 0, blue: 0, angle: 10),
            .init(red: 0.5, green: 0, blue: 0, angle: 0),    // fifth: dropped
        ]
        let normalized = try normalizedGlow(GlassGlow(colors: stops))
        #expect(normalized.colors.map(\.red) == [0.4, 0.2, 0.3, 0.1])
        #expect(normalized.colors.map(\.angle) == [10, 90, 90, 300])
    }

    @Test func `A glow without colors normalizes to none`() throws {
        let glow = GlassGlow(colors: [], rimWidth: 3, innerGlowIntensity: 1, centerOpacity: 1)
        #expect(try normalizedGlow(glow) == .none)
    }

    @Test func `A non-finite glow value is rejected even without colors`() {
        let panel = GlassPanel(frame: Self.frame, parameters: GlassParameters(glow: GlassGlow(colors: [], centerOpacity: .nan)))
        #expect(throws: GlassParameterError.nonFinite(.glowCenterOpacity)) {
            try panel.normalized()
        }
    }

    @Test func `The renderer reports the glow it draws`() throws {
        let gpu = try GPUContext()
        let renderer = try GlassRenderer(commandQueue: gpu.queue)
        let glow = GlassGlow(
            colors: [.init(red: 0, green: 0, blue: 1, angle: 400), .init(red: 1, green: 0, blue: 0, angle: 10)],
            rimWidth: 90, innerGlowIntensity: 2
        )
        try renderer.setPanel(GlassPanel(frame: Self.frame, parameters: GlassParameters(glow: glow)))
        let drawn = try #require(renderer.panel?.parameters.glow)
        #expect(drawn.colors.map(\.angle) == [10, 40])
        #expect(drawn.colors.map(\.blue) == [0, 1])
        #expect(drawn.rimWidth == 40)
        #expect(drawn.innerGlowIntensity == 1)
        var invalid = renderer.panel!
        invalid.parameters.glow.colors[0].green = .infinity
        #expect(throws: GlassParameterError.nonFinite(.glowColorGreen)) {
            try renderer.setPanel(invalid)
        }
        #expect(renderer.panel?.parameters.glow == drawn, "A rejected panel leaves the current one in place")
    }

    // MARK: CPU geometry

    private func geometry(_ glow: GlassGlow, frame: CGRect = CGRect(x: 0, y: 0, width: 200, height: 100), scale: Double = 1) throws -> GlassPanelGeometry {
        GlassPanelGeometry(panel: try GlassPanel(frame: frame, parameters: GlassParameters(glow: glow)).normalized(), displayScale: scale)
    }

    @Test func `Gradient angles start at the top and run clockwise, with the panel scaled to a square`() throws {
        let g = try geometry(GlassGlow(colors: [.init(red: 1, green: 1, blue: 1)]))
        // Center (100, 50), half size (100, 50).
        #expect(g.glowTurn(at: [100, 0]) == 0)
        #expect(abs(g.glowTurn(at: [200, 50]) - 0.25) < 1e-12)
        #expect(abs(g.glowTurn(at: [100, 100]) - 0.5) < 1e-12)
        #expect(abs(g.glowTurn(at: [0, 50]) - 0.75) < 1e-12)
        // The top-right corner is an eighth of a turn although the panel is
        // twice as wide as it is tall.
        #expect(abs(g.glowTurn(at: [200, 0]) - 0.125) < 1e-12)
        #expect(g.glowTurn(at: [100, 50]) == 0, "The exact center has a defined angle")
    }

    @Test func `Gradient colors interpolate between neighbouring stops and wrap around`() throws {
        let g = try geometry(GlassGlow(colors: [
            .init(red: 1, green: 0, blue: 0, angle: 0),
            .init(red: 0, green: 1, blue: 0, angle: 90),
            .init(red: 0, green: 0, blue: 1, angle: 270),
        ]))
        #expect(g.glowColor(atTurn: 0) == [1, 0, 0])
        #expect(g.glowColor(atTurn: 0.25) == [0, 1, 0])
        #expect(g.glowColor(atTurn: 0.75) == [0, 0, 1])
        // Halfway from green (90°) to blue (270°), in linear light.
        let half = g.glowColor(atTurn: 0.5)
        #expect(abs(half.y - 0.5) < 1e-12 && abs(half.z - 0.5) < 1e-12 && half.x == 0)
        // From blue (270°) back to red (360°).
        let wrap = g.glowColor(atTurn: 0.875)
        #expect(abs(wrap.x - 0.5) < 1e-12 && abs(wrap.z - 0.5) < 1e-12)
        // A single stop is a solid color whatever its angle.
        let solid = try geometry(GlassGlow(colors: [.init(red: 0.5, green: 0.5, blue: 0.5, angle: 123)]))
        let linearHalf = GlassPanelGeometry.decodeSRGB(0.5)
        #expect(solid.glowColor(atTurn: 0.9) == SIMD3(repeating: linearHalf))
    }

    @Test func `A glow converts to pixels with the display scale`() throws {
        let glow = GlassGlow(colors: [.init(red: 1, green: 1, blue: 1)], rimWidth: 2, rimSoftness: 0.25, innerGlowRadius: 10)
        let panel = GlassPanel(frame: CGRect(x: 0, y: 0, width: 200, height: 100), parameters: GlassParameters(cornerRadius: 4, glow: glow))
        let g = try #require(GlassPanelGeometry(panel: try panel.normalized(), displayScale: 3).glow)
        #expect(g.rimWidth == 6)
        #expect(g.rimFeather == 1, "The rim's soft edge is at least one pixel")
        #expect(g.innerRadius == 30)
        #expect(g.normalRadius == 30)
        #expect(try geometry(.none).glow == nil)
        let uniforms = try geometry(.none).uniforms(
            background: .init(), targetWidth: 10, targetHeight: 10
        )
        #expect(uniforms.glowStopCount == 0)
    }
}

/// GW-17 on the GPU: offscreen render and readback on the device the test
/// runs on, compared with the CPU model and with the glow-off output.
///
/// Tolerance: as in `GlassRendererTests`, one 8-bit step per channel against
/// a prediction (the prediction includes the ordered dither). Properties
/// stated as "equal to the glow-off output" are exact byte comparisons.
/// Runs with Metal API Validation when the scheme sets MTL_DEBUG_LAYER=1.
@Suite(.timeLimit(.minutes(1)))
struct GlassGlowRenderTests {
    /// Renders the fixture 1:1 with a panel and reads it back.
    private func render(
        _ gpu: GPUContext, _ fixture: Fixture, panel: GlassPanel?, displayScale: Double = 1,
        renderer: GlassRenderer? = nil
    ) async throws -> RenderedImage {
        let renderer = try renderer ?? GlassRenderer(commandQueue: gpu.queue)
        try renderer.setSource(gpu.makeLease(bgra: fixture.bgra, width: fixture.width, height: fixture.height))
        try renderer.setPanel(panel)
        let target = try gpu.makeTarget(width: fixture.width, height: fixture.height)
        let outcome = renderer.draw(targetPixelSize: (fixture.width, fixture.height), displayScale: displayScale) { target }
        #expect(outcome == .submitted(frameID: renderer.currentFrame?.frameID ?? 0))
        let image = try await gpu.readBack(try #require(target.renderPassDescriptor.colorAttachments[0].texture))
        #expect(image.isFullyOpaque)
        return image
    }

    /// A renderer whose panel pass is the frozen GW-05 shader
    /// (`Tests/GlassWeaveTests/Shaders/GlassBaselineGW05.metal`).
    private func baselineRenderer(_ gpu: GPUContext) throws -> GlassRenderer {
        try GlassRenderer(
            commandQueue: gpu.queue,
            library: BackgroundRenderer.makeLibrary(device: gpu.device),
            panelLibrary: gpu.device.makeDefaultLibrary(bundle: .module),
            panelVertex: "gw_baseline_glass_vertex", panelFragment: "gw_baseline_glass_fragment"
        )
    }

    private func geometry(_ panel: GlassPanel, scale: Double = 1) throws -> GlassPanelGeometry {
        GlassPanelGeometry(panel: try panel.normalized(), displayScale: scale)
    }

    /// Largest per-channel difference between the image and the CPU model.
    private func maximumError(_ image: RenderedImage, _ reference: GlassReference) -> Double {
        var worst = 0.0
        for y in 0..<image.height {
            for x in 0..<image.width {
                worst = max(worst, image.channels(x: x, y: y).largestDifference(from: reference.encodedColor(x: x, y: y)))
            }
        }
        return worst
    }

    /// A stop's color as sRGB bytes in blue, green, red order.
    private static func bytes(_ stop: GlassGlow.ColorStop) -> SIMD3<Double> {
        SIMD3(stop.blue, stop.green, stop.red) * 255
    }

    /// The bytes a pixel shows when the glow covers `fraction` of it over a
    /// background byte color, mixed in linear light (blue, green, red).
    private static func mixed(_ background: SIMD3<Double>, _ stop: GlassGlow.ColorStop, _ fraction: Double) -> SIMD3<Double> {
        let bg = SIMD3(GlassPanelGeometry.decodeSRGB(background.x / 255), GlassPanelGeometry.decodeSRGB(background.y / 255), GlassPanelGeometry.decodeSRGB(background.z / 255))
        let c = SIMD3(GlassPanelGeometry.decodeSRGB(stop.blue), GlassPanelGeometry.decodeSRGB(stop.green), GlassPanelGeometry.decodeSRGB(stop.red))
        let m = bg + (c - bg) * fraction
        return SIMD3(GlassPanelGeometry.encodeSRGB(m.x), GlassPanelGeometry.encodeSRGB(m.y), GlassPanelGeometry.encodeSRGB(m.z)) * 255
    }

    /// A flat panel (no refraction, tint, or edge light) so the glow alone
    /// changes it.
    private static func flatPanel(_ frame: CGRect, cornerRadius: Double, glow: GlassGlow) -> GlassPanel {
        GlassPanel(frame: frame, parameters: GlassParameters(
            cornerRadius: cornerRadius, bezelWidth: 0, refraction: 0, edgeHighlight: 0, tint: .none, glow: glow
        ))
    }

    private static let darkBackground: (UInt8, UInt8, UInt8) = (30, 32, 36)

    // MARK: Default output is unchanged

    static let gw05Panels: [GlassParameters] = [
        GlassParameters(),
        GlassParameters(cornerRadius: 20, bezelWidth: 28, refraction: 1, edgeHighlight: 1,
                        tint: GlassTint(red: 0.3, green: 0.6, blue: 1, strength: 0.35)),
        GlassParameters(cornerRadius: 60, bezelWidth: 12, refraction: 0.4, edgeHighlight: 0.8,
                        tint: GlassTint(red: 0.08, green: 0.09, blue: 0.12, strength: 0.83)),
        // Colors but nothing visible: still no glow.
        GlassParameters(glow: GlassGlow(colors: [.init(red: 1, green: 0, blue: 0)], rimIntensity: 0, innerGlowIntensity: 0)),
    ]

    @Test(arguments: gw05Panels)
    func `Without a glow the output is byte-identical to the pre-glow shader`(parameters: GlassParameters) async throws {
        let gpu = try GPUContext()
        let fixtures = [
            Fixture.coordinateGradient(width: 200, height: 160),
            Fixture.checkerboard(width: 200, height: 160, cell: 7, (250, 220, 30), (10, 30, 90)),
        ]
        for fixture in fixtures {
            let panel = GlassPanel(frame: CGRect(x: 18.5, y: 14.25, width: 151, height: 120), parameters: parameters)
            let current = try await render(gpu, fixture, panel: panel)
            let baseline = try await render(gpu, fixture, panel: panel, renderer: baselineRenderer(gpu))
            // Counted rather than compared as arrays, so a failure reports a
            // number instead of every byte.
            let differing = zip(current.bgra, baseline.bgra).count { $0 != $1 }
            #expect(differing == 0, "\(differing) bytes differ, at most by \(current.maximumDifference(from: baseline))")
            // Control: the frozen shader does draw the panel.
            let backgroundOnly = try await render(gpu, fixture, panel: nil)
            #expect(baseline.maximumDifference(from: backgroundOnly) > 2)
        }
    }

    // MARK: Color on the rim

    static let rimColors: [GlassGlow.ColorStop] = [
        .init(red: 1, green: 0, blue: 0),
        .init(red: 0, green: 1, blue: 0),
        .init(red: 0, green: 0, blue: 1),
        .init(red: 1, green: 0.55, blue: 0.1),
        .init(red: 0.6, green: 0.2, blue: 1),
        .init(red: 0.1, green: 0.9, blue: 0.8),
        .init(red: 1, green: 0.2, blue: 0.75),
        .init(red: 1, green: 1, blue: 1),
    ]

    @Test(arguments: rimColors)
    func `A solid rim shows the requested color all around the outline`(color: GlassGlow.ColorStop) async throws {
        let gpu = try GPUContext()
        let source = Fixture.uniform(width: 200, height: 130, Self.darkBackground)
        let glow = GlassGlow(colors: [color], rimWidth: 4, rimSoftness: 0, rimIntensity: 1, innerGlowIntensity: 0)
        let panel = Self.flatPanel(CGRect(x: 16, y: 12, width: 168, height: 104), cornerRadius: 30, glow: glow)
        let image = try await render(gpu, source, panel: panel)
        let off = try await render(gpu, source, panel: Self.flatPanel(panel.frame, cornerRadius: 30, glow: .none))
        let g = try geometry(panel)
        let expected = Self.bytes(color)
        var rimPixels = 0, wrongRim = 0, changedInterior = 0
        for y in 0..<source.height {
            for x in 0..<source.width {
                let pixel = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                let depth = -g.signedDistance(at: pixel)
                if depth >= 0.5, depth <= 4 {
                    rimPixels += 1
                    if image.channels(x: x, y: y).largestDifference(from: expected) > 1 { wrongRim += 1 }
                } else if depth > 5, image.channels(x: x, y: y) != off.channels(x: x, y: y) {
                    changedInterior += 1
                }
            }
        }
        #expect(rimPixels > 1500)
        #expect(wrongRim == 0)
        #expect(changedInterior == 0)
    }

    @Test func `A four-stop gradient shows each stop at its angle`() async throws {
        let gpu = try GPUContext()
        let source = Fixture.uniform(width: 240, height: 160, Self.darkBackground)
        let red = GlassGlow.ColorStop(red: 1, green: 0.1, blue: 0.1, angle: 0)
        let gold = GlassGlow.ColorStop(red: 1, green: 0.8, blue: 0.1, angle: 90)
        let teal = GlassGlow.ColorStop(red: 0.1, green: 0.8, blue: 0.7, angle: 180)
        let violet = GlassGlow.ColorStop(red: 0.6, green: 0.2, blue: 1, angle: 270)
        // Given out of order; the normalization orders them by angle.
        let glow = GlassGlow(colors: [violet, red, teal, gold], rimWidth: 4, rimSoftness: 0, innerGlowIntensity: 0)
        // Odd sizes put the panel's center (120.5, 80.5) on a pixel center,
        // so the probes below lie exactly on the axes. (Half a pixel off the
        // axis already moves a dark sRGB channel by a few steps.)
        let panel = Self.flatPanel(CGRect(x: 20, y: 20, width: 201, height: 121), cornerRadius: 30, glow: glow)
        let image = try await render(gpu, source, panel: panel)
        // Rim pixels 1.5 pixels inside the middle of each edge: top (0°),
        // right (90°), bottom (180°), left (270°).
        let probes: [(x: Int, y: Int, stop: GlassGlow.ColorStop)] = [
            (120, 21, red), (219, 80, gold), (120, 139, teal), (21, 80, violet),
        ]
        for probe in probes {
            let c = image.channels(x: probe.x, y: probe.y)
            #expect(c.largestDifference(from: Self.bytes(probe.stop)) <= 1, "\(probe)")
        }
        // Between stops the color is their mix in linear light, as modeled,
        // everywhere on the image.
        let g = try geometry(panel)
        #expect(maximumError(image, GlassReference(source: source, geometry: g)) <= 1)
        // Toward the top-right corner (45°) the rim is the even linear mix of
        // red and gold.
        // Pixel (209, 30) lies on the top-right corner's arc, about 3.1
        // pixels inside the outline, at about 0.13 turn.
        let corner = SIMD2(209.5, 30.5)
        #expect(-g.signedDistance(at: corner) > 1 && -g.signedDistance(at: corner) < 4)
        let turn = g.glowTurn(at: corner)
        #expect(turn > 0.1 && turn < 0.15)
        let fraction = turn / 0.25
        let cornerColor = image.channels(x: 209, y: 30)
        let predicted = Self.mixed(Self.bytes(red), gold, fraction)
        #expect(cornerColor.largestDifference(from: predicted) <= 2, "\(cornerColor) \(predicted) at turn \(turn)")
    }

    // MARK: See-through middle and extent

    @Test func `With center opacity zero the middle is exactly the glow-off glass`() async throws {
        let gpu = try GPUContext()
        let source = Fixture.coordinateGradient(width: 256, height: 230)
        var parameters = GlassParameters(
            cornerRadius: 36, bezelWidth: 20, refraction: 0.8, edgeHighlight: 0.6,
            tint: GlassTint(red: 0.9, green: 0.95, blue: 1, strength: 0.3)
        )
        let frame = CGRect(x: 40, y: 50, width: 176, height: 140)
        let off = try await render(gpu, source, panel: GlassPanel(frame: frame, parameters: parameters))
        parameters.glow = GlassGlow(
            colors: [.init(red: 1, green: 0.4, blue: 0.1, angle: 0), .init(red: 0.2, green: 0.5, blue: 1, angle: 180)],
            rimWidth: 3, rimSoftness: 2, rimIntensity: 1, innerGlowRadius: 18, innerGlowIntensity: 0.7,
            centerOpacity: 0, lightAngle: 30, directionality: 0.5
        )
        let panel = GlassPanel(frame: frame, parameters: parameters)
        let image = try await render(gpu, source, panel: panel)
        let g = try geometry(panel)
        let reach = max(3.0 + 2, 18)
        var middle = 0, middleChanged = 0, outsideChanged = 0, glowing = 0
        for y in 0..<source.height {
            for x in 0..<source.width {
                let pixel = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                let same = image.channels(x: x, y: y) == off.channels(x: x, y: y)
                // A hundredth of a pixel of margin on either side of each
                // boundary absorbs float rounding of the GPU's distance.
                let distance = g.signedDistance(at: pixel)
                if distance >= 0.51 {
                    if !same { outsideChanged += 1 }
                } else if -distance >= reach + 0.01 {
                    middle += 1
                    if !same { middleChanged += 1 }
                } else if !same {
                    glowing += 1
                }
            }
        }
        #expect(middle > 5000)
        #expect(middleChanged == 0)
        #expect(outsideChanged == 0)
        #expect(glowing > 3000, "The glow did draw near the outline")
        #expect(maximumError(image, GlassReference(source: source, geometry: g)) <= 1)
    }

    @Test func `No pixel outside the outline changes, even with a full center fill`() async throws {
        let gpu = try GPUContext()
        let source = Fixture.coordinateGradient(width: 180, height: 150)
        let frame = CGRect(x: 25.25, y: 30.5, width: 120.5, height: 90)
        let glow = GlassGlow(
            colors: [.init(red: 0.2, green: 1, blue: 0.3)],
            rimWidth: 6, rimSoftness: 6, innerGlowRadius: 45, innerGlowIntensity: 1, centerOpacity: 0.6
        )
        let off = try await render(gpu, source, panel: Self.flatPanel(frame, cornerRadius: 45, glow: .none))
        let panel = Self.flatPanel(frame, cornerRadius: 45, glow: glow)
        let image = try await render(gpu, source, panel: panel)
        let g = try geometry(panel)
        var outsideChanged = 0, insideUnchanged = 0
        for y in 0..<source.height {
            for x in 0..<source.width {
                let pixel = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                let same = image.channels(x: x, y: y) == off.channels(x: x, y: y)
                let distance = g.signedDistance(at: pixel)
                if distance >= 0.51, !same { outsideChanged += 1 }
                if distance <= -0.51, same { insideUnchanged += 1 }
            }
        }
        #expect(outsideChanged == 0)
        #expect(insideUnchanged == 0, "A center fill reaches every covered pixel")
        #expect(maximumError(image, GlassReference(source: source, geometry: g)) <= 1)
    }

    // MARK: Documented behavior of each parameter

    @Test func `Rim width, softness, and intensity behave as documented`() async throws {
        let gpu = try GPUContext()
        let source = Fixture.uniform(width: 160, height: 120, Self.darkBackground)
        let amber = GlassGlow.ColorStop(red: 1, green: 0.6, blue: 0.1)
        let frame = CGRect(x: 10, y: 10, width: 140, height: 100)
        // Probes down the middle of the top edge (outline at y = 10).
        func probe(_ image: RenderedImage, depth: Double) -> SIMD3<Double> {
            image.channels(x: 80, y: 10 + Int(depth - 0.5))
        }
        // The glow-off panel there: the uniform background through the
        // flat glass. Pixels without glow must equal it exactly.
        let off = try await render(gpu, source, panel: Self.flatPanel(frame, cornerRadius: 20, glow: .none))
        let background = probe(off, depth: 3.5)
        // Width 6, softness 0 (a one-pixel soft edge): solid to depth 6, gone by 7.
        let solid = try await render(gpu, source, panel: Self.flatPanel(frame, cornerRadius: 20, glow: GlassGlow(
            colors: [amber], rimWidth: 6, rimSoftness: 0, rimIntensity: 1, innerGlowIntensity: 0
        )))
        #expect(probe(solid, depth: 5.5).largestDifference(from: Self.bytes(amber)) <= 1)
        #expect(probe(solid, depth: 7.5) == probe(off, depth: 7.5))
        // Softness 4: halfway through the soft edge the rim is half strength.
        let soft = try await render(gpu, source, panel: Self.flatPanel(frame, cornerRadius: 20, glow: GlassGlow(
            colors: [amber], rimWidth: 6, rimSoftness: 4, rimIntensity: 1, innerGlowIntensity: 0
        )))
        #expect(probe(soft, depth: 8.5).largestDifference(from: Self.mixed(background, amber, 1 - GlassPanelGeometry.smoothstep(6, 10, 8.5))) <= 1)
        #expect(probe(soft, depth: 10.5) == probe(off, depth: 10.5))
        // Intensity 0.5: the rim is the half mix in linear light.
        let half = try await render(gpu, source, panel: Self.flatPanel(frame, cornerRadius: 20, glow: GlassGlow(
            colors: [amber], rimWidth: 6, rimSoftness: 0, rimIntensity: 0.5, innerGlowIntensity: 0
        )))
        #expect(probe(half, depth: 3.5).largestDifference(from: Self.mixed(background, amber, 0.5)) <= 1)
        // Inner glow alone: (1 − depth / radius)² of its intensity, zero at the radius.
        let inner = try await render(gpu, source, panel: Self.flatPanel(frame, cornerRadius: 20, glow: GlassGlow(
            colors: [amber], rimIntensity: 0, innerGlowRadius: 20, innerGlowIntensity: 0.8
        )))
        for depth in [0.5, 5.5, 10.5, 15.5] {
            let t = depth / 20
            #expect(probe(inner, depth: depth).largestDifference(from: Self.mixed(background, amber, 0.8 * (1 - t) * (1 - t))) <= 1, "depth \(depth)")
        }
        #expect(probe(inner, depth: 20.5) == probe(off, depth: 20.5))
    }

    @Test(arguments: [0.0, 90.0, 180.0, 270.0])
    func `The light lights the side it comes from`(lightAngle: Double) async throws {
        let gpu = try GPUContext()
        let source = Fixture.uniform(width: 180, height: 140, Self.darkBackground)
        let cyan = GlassGlow.ColorStop(red: 0.1, green: 0.85, blue: 1)
        let frame = CGRect(x: 20, y: 20, width: 140, height: 100)
        func rimProbes(_ image: RenderedImage) -> [Double: SIMD3<Double>] {
            // The middle of each edge, two pixels inside, keyed by its angle.
            [0: image.channels(x: 90, y: 21), 90: image.channels(x: 158, y: 70),
             180: image.channels(x: 90, y: 118), 270: image.channels(x: 21, y: 70)]
        }
        let off = rimProbes(try await render(gpu, source, panel: Self.flatPanel(frame, cornerRadius: 24, glow: .none)))
        let directional = try await render(gpu, source, panel: Self.flatPanel(frame, cornerRadius: 24, glow: GlassGlow(
            colors: [cyan], rimWidth: 4, rimSoftness: 0, innerGlowIntensity: 0, lightAngle: lightAngle, directionality: 1
        )))
        for (angle, color) in rimProbes(directional) {
            let background = try #require(off[angle])
            let difference = abs(angle - lightAngle).truncatingRemainder(dividingBy: 360)
            switch difference {
            case 0:
                // Facing the light: full color.
                #expect(color.largestDifference(from: Self.bytes(cyan)) <= 1, "lit side \(angle)")
            case 180:
                // Facing away with directionality 1: no glow at all.
                #expect(color == background, "dark side \(angle)")
            default:
                // Perpendicular: facing 1/2, light 1/4.
                #expect(color.largestDifference(from: Self.mixed(background, cyan, 0.25)) <= 1, "side \(angle)")
            }
        }
        // Directionality 0 lights every side fully.
        let even = try await render(gpu, source, panel: Self.flatPanel(frame, cornerRadius: 24, glow: GlassGlow(
            colors: [cyan], rimWidth: 4, rimSoftness: 0, innerGlowIntensity: 0, lightAngle: lightAngle, directionality: 0
        )))
        for (angle, color) in rimProbes(even) {
            #expect(color.largestDifference(from: Self.bytes(cyan)) <= 1, "even \(angle)")
        }
    }

    static let modelCases: [GlassParameters] = [
        GlassParameters(
            cornerRadius: 28, bezelWidth: 16, refraction: 0.6, edgeHighlight: 0.5,
            tint: GlassTint(red: 0.95, green: 0.97, blue: 1, strength: 0.2),
            glow: GlassGlow(colors: [.init(red: 1, green: 0.55, blue: 0.15)], rimWidth: 2, rimSoftness: 3, rimIntensity: 0.8,
                            innerGlowRadius: 20, innerGlowIntensity: 0.6, centerOpacity: 0.15, lightAngle: 0, directionality: 0.7)
        ),
        GlassParameters(
            cornerRadius: 40, bezelWidth: 22, refraction: 0.9, edgeHighlight: 0.3,
            glow: GlassGlow(colors: [
                .init(red: 1, green: 0.2, blue: 0.3, angle: 15), .init(red: 1, green: 0.85, blue: 0.2, angle: 100),
                .init(red: 0.2, green: 0.9, blue: 0.6, angle: 200), .init(red: 0.4, green: 0.3, blue: 1, angle: 290),
            ], rimWidth: 3, rimSoftness: 1, innerGlowRadius: 30, innerGlowIntensity: 0.4, lightAngle: 135, directionality: 1)
        ),
        // A circle (the corner radius clamps to half the side), with the
        // inner glow reaching the center and the light from the left.
        GlassParameters(
            cornerRadius: 999, bezelWidth: 10, refraction: 0.5, edgeHighlight: 0,
            glow: GlassGlow(colors: [.init(red: 0.3, green: 0.6, blue: 1, angle: 0), .init(red: 1, green: 0.3, blue: 0.8, angle: 180)],
                            rimWidth: 1.5, rimSoftness: 1.5, innerGlowRadius: 999, innerGlowIntensity: 0.9,
                            centerOpacity: 0.3, lightAngle: 270, directionality: 0.4)
        ),
        // No rim at all (both lengths zero), inner glow only.
        GlassParameters(
            cornerRadius: 12, bezelWidth: 0, refraction: 0, edgeHighlight: 0,
            glow: GlassGlow(colors: [.init(red: 0.9, green: 0.1, blue: 0.2)], rimWidth: 0, rimSoftness: 0, rimIntensity: 1,
                            innerGlowRadius: 14, innerGlowIntensity: 1)
        ),
    ]

    @Test(arguments: modelCases)
    func `The glow matches the CPU model`(parameters: GlassParameters) async throws {
        let gpu = try GPUContext()
        let source = Fixture.coordinateGradient(width: 200, height: 160)
        // The circle case gets a square frame of odd size, so its exact
        // center falls on a pixel center (the gradient's defined angle).
        let frame = parameters.cornerRadius > 100
            ? CGRect(x: 30, y: 10, width: 141, height: 141)
            : CGRect(x: 16.5, y: 18.25, width: 165, height: 124)
        let panel = GlassPanel(frame: frame, parameters: parameters)
        let image = try await render(gpu, source, panel: panel)
        let g = try geometry(panel)
        #expect(g.glow != nil)
        #expect(maximumError(image, GlassReference(source: source, geometry: g)) <= 1)
        // The CPU model itself stays finite everywhere.
        let reference = GlassReference(source: source, geometry: g)
        var nonFinite = 0
        for y in stride(from: 0, to: source.height, by: 3) {
            for x in stride(from: 0, to: source.width, by: 3) {
                let c = reference.linearColor(x: x, y: y)
                if !(c.x.isFinite && c.y.isFinite && c.z.isFinite) { nonFinite += 1 }
            }
        }
        #expect(nonFinite == 0)
    }

    @Test func `A glow in points renders the same at every display scale`() async throws {
        let gpu = try GPUContext()
        let source = Fixture.coordinateGradient(width: 200, height: 160)
        let glow = GlassGlow(colors: [.init(red: 1, green: 0.3, blue: 0.6)], rimWidth: 4, rimSoftness: 2,
                             innerGlowRadius: 24, innerGlowIntensity: 0.6, centerOpacity: 0.1, lightAngle: 40, directionality: 0.5)
        let atScale1 = try await render(gpu, source, panel: Self.flatPanel(CGRect(x: 20, y: 24, width: 160, height: 112), cornerRadius: 32, glow: glow))
        var halfGlow = glow
        halfGlow.rimWidth = 2
        halfGlow.rimSoftness = 1
        halfGlow.innerGlowRadius = 12
        let atScale2 = try await render(
            gpu, source, panel: Self.flatPanel(CGRect(x: 10, y: 12, width: 80, height: 56), cornerRadius: 16, glow: halfGlow),
            displayScale: 2
        )
        #expect(atScale2.maximumDifference(from: atScale1) <= 1)
    }

    // MARK: Dither and repeatability

    /// A flat glow (one opacity everywhere) whose exact value lies between
    /// two 8-bit steps must not quantize to one flat level, which is what
    /// shows as a band: the ordered dither spreads it over the two
    /// neighbouring levels in a 4 × 4 pattern whose average follows the
    /// value. Without the dither every pixel would show the same level.
    @Test func `Ordered dither spreads a flat glow over the two neighbouring steps`() async throws {
        let gpu = try GPUContext()
        let source = Fixture.uniform(width: 96, height: 96, (20, 24, 28))
        let background = SIMD3<Double>(28, 24, 20)
        let violet = GlassGlow.ColorStop(red: 0.55, green: 0.25, blue: 0.95)
        var exercised = 0
        for opacity in stride(from: 0.05, through: 0.6, by: 0.025) {
            let exact = Self.mixed(background, violet, opacity)
            let fraction = exact - exact.rounded(.down)
            // Values well between two steps; the GPU's own arithmetic (sRGB
            // decode and fast-math encode) moves values by about 0.1 step.
            guard (0..<3).allSatisfy({ abs(fraction[$0] - 0.5) < 0.3 }) else { continue }
            exercised += 1
            let glow = GlassGlow(colors: [violet], rimIntensity: 0, innerGlowIntensity: 0, centerOpacity: opacity)
            let image = try await render(gpu, source, panel: Self.flatPanel(CGRect(x: 8, y: 8, width: 80, height: 80), cornerRadius: 8, glow: glow))
            var sum = SIMD3<Double>.zero
            var low = SIMD3<Double>(repeating: 255), high = SIMD3<Double>.zero
            var periodic = true
            for y in 40..<56 {
                for x in 40..<56 {
                    let c = image.channels(x: x, y: y)
                    sum += c
                    low = pointwiseMin(low, c)
                    high = pointwiseMax(high, c)
                    if c != image.channels(x: x + 4, y: y) || c != image.channels(x: x, y: y + 4) { periodic = false }
                }
            }
            let mean = sum / 256
            #expect(high - low == SIMD3(repeating: 1), "opacity \(opacity): levels \(low)...\(high)")
            #expect(low == exact.rounded(.down), "opacity \(opacity): \(low) for \(exact)")
            #expect(periodic, "opacity \(opacity): the pattern repeats every four pixels")
            #expect(mean.largestDifference(from: exact) <= 0.2, "opacity \(opacity): mean \(mean), exact \(exact)")
        }
        #expect(exercised >= 3)
    }

    @Test func `Fixed glow inputs render identical bytes`() async throws {
        let gpu = try GPUContext()
        let checker = Fixture.checkerboard(width: 128, height: 96, cell: 6, (250, 220, 30), (10, 30, 90))
        let panel = GlassPanel(frame: CGRect(x: 16.5, y: 12.25, width: 95, height: 70), parameters: Self.modelCases[1])
        let first = try await render(gpu, checker, panel: panel)
        let second = try await render(gpu, checker, panel: panel)
        #expect(zip(first.bgra, second.bgra).count { $0 != $1 } == 0)
    }
}
