import CoreGraphics
import Metal
import Testing
@testable import GlassWeave

/// Offscreen GPU rendering of one rounded glass panel over an explicit
/// source, read back and compared with the CPU model of the shader.
///
/// Tolerance: the output is `bgra8Unorm` holding sRGB-encoded values, and
/// every comparison with a predicted image allows one 8-bit step per
/// channel (float rounding with Metal fast math). Fixtures whose predicted
/// value depends on a filter weight across a hard, high-contrast edge are
/// checked by properties (ranges, equality where no displacement applies)
/// rather than by exact prediction, because the GPU quantizes filter
/// weights. Runs with Metal API Validation when the scheme sets
/// MTL_DEBUG_LAYER=1.
@Suite(.timeLimit(.minutes(1)))
struct GlassRendererTests {
    /// Renders the fixture 1:1 with an optional panel and reads it back.
    private func render(
        _ gpu: GPUContext, _ fixture: Fixture,
        panel: GlassPanel?, displayScale: Double = 1
    ) async throws -> RenderedImage {
        let renderer = try GlassRenderer(commandQueue: gpu.queue)
        try renderer.setSource(gpu.makeLease(bgra: fixture.bgra, width: fixture.width, height: fixture.height))
        try renderer.setPanel(panel)
        let target = try gpu.makeTarget(width: fixture.width, height: fixture.height)
        let outcome = renderer.draw(targetPixelSize: (fixture.width, fixture.height), displayScale: displayScale) { target }
        #expect(outcome == .submitted(frameID: renderer.currentFrame?.frameID ?? 0))
        return try await gpu.readBack(try #require(target.renderPassDescriptor.colorAttachments[0].texture))
    }

    /// Pixel geometry of a panel at scale 1, for the CPU model.
    private func geometry(_ panel: GlassPanel) throws -> GlassPanelGeometry {
        GlassPanelGeometry(panel: try panel.normalized(), displayScale: 1)
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

    private static let strongPanel = GlassPanel(
        frame: CGRect(x: 40, y: 56, width: 176, height: 144),
        parameters: GlassParameters(cornerRadius: 20, bezelWidth: 28, refraction: 1, edgeHighlight: 0)
    )

    // MARK: Zero refraction

    @Test func `Zero refraction reproduces the source within one step`() async throws {
        let gpu = try GPUContext()
        let checker = Fixture.checkerboard(width: 96, height: 64, cell: 8, (230, 40, 20), (20, 60, 200))
        var panel = GlassPanel(
            frame: CGRect(x: 12, y: 8, width: 72, height: 48),
            parameters: GlassParameters(cornerRadius: 12, bezelWidth: 16, refraction: 0, edgeHighlight: 0)
        )
        let image = try await render(gpu, checker, panel: panel)
        let backgroundOnly = try await render(gpu, checker, panel: nil)
        #expect(image.isFullyOpaque)
        #expect(image.maximumDifference(from: backgroundOnly) <= 1)
        var worst = 0.0
        for y in 0..<checker.height {
            for x in 0..<checker.width {
                worst = max(worst, image.channels(x: x, y: y).largestDifference(from: checker.texel(x, y) * 255))
            }
        }
        #expect(worst <= 1)

        // Control: the same panel with refraction changes the rim, so the
        // comparison above did exercise the glass pass.
        panel.parameters.refraction = 1
        let refracted = try await render(gpu, checker, panel: panel)
        #expect(refracted.maximumDifference(from: backgroundOnly) > 100)
    }

    // MARK: Displacement against the CPU model

    @Test func `Refraction moves each sample where the CPU model predicts`() async throws {
        let gpu = try GPUContext()
        let gradient = Fixture.coordinateGradient()
        let image = try await render(gpu, gradient, panel: Self.strongPanel)
        #expect(image.isFullyOpaque)
        let g = try geometry(Self.strongPanel)
        #expect(maximumError(image, GlassReference(source: gradient, geometry: g)) <= 1)

        // The prediction is not trivial: many pixels show a texel at least
        // four columns or rows from their own.
        var displaced = 0
        for y in 0..<gradient.height {
            for x in 0..<gradient.width {
                let c = image.channels(x: x, y: y)
                if abs(c.z - Double(x)) >= 4 || abs(c.y - Double(y)) >= 4 { displaced += 1 }
            }
        }
        #expect(displaced > 1000)
    }

    @Test func `Panels in points render the same at every display scale`() async throws {
        let gpu = try GPUContext()
        let gradient = Fixture.coordinateGradient()
        let atScale1 = try await render(gpu, gradient, panel: Self.strongPanel, displayScale: 1)
        var halfPoints = Self.strongPanel
        halfPoints.frame = CGRect(x: 20, y: 28, width: 88, height: 72)
        halfPoints.parameters.cornerRadius = 10
        halfPoints.parameters.bezelWidth = 14
        let atScale2 = try await render(gpu, gradient, panel: halfPoints, displayScale: 2)
        #expect(atScale2.maximumDifference(from: atScale1) <= 1)
    }

    // MARK: Edges, halos, and alpha

    @Test func `A uniform source shows no halo at the outline`() async throws {
        let gpu = try GPUContext()
        let gray = Fixture.uniform(width: 128, height: 96, (128, 128, 128))
        let panel = GlassPanel(
            frame: CGRect(x: 10.25, y: 12.5, width: 100.5, height: 70),
            parameters: GlassParameters(cornerRadius: 30, bezelWidth: 24, refraction: 1, edgeHighlight: 0)
        )
        let image = try await render(gpu, gray, panel: panel)
        #expect(image.isFullyOpaque)
        var worst = 0.0
        for y in 0..<gray.height {
            for x in 0..<gray.width {
                worst = max(worst, image.channels(x: x, y: y).largestDifference(from: SIMD3(repeating: 128)))
            }
        }
        #expect(worst <= 1)
    }

    @Test func `Bright and dark edges refract without overshoot or color fringes`() async throws {
        let gpu = try GPUContext()
        let edges = Fixture.brightDarkQuadrants(width: 160, height: 120, dark: 32, bright: 224)
        // The quadrant edges (x 80, y 60) run through the panel's left and
        // top rims, parallel to the outline, so the rim pulls them sideways.
        let panel = GlassPanel(
            frame: CGRect(x: 70, y: 50, width: 80, height: 60),
            parameters: GlassParameters(cornerRadius: 16, bezelWidth: 20, refraction: 1, edgeHighlight: 0)
        )
        let image = try await render(gpu, edges, panel: panel)
        #expect(image.isFullyOpaque)
        let g = try geometry(panel)
        var outOfRange = 0, fringes = 0, unchangedMismatches = 0, refractedPixels = 0
        for y in 0..<edges.height {
            for x in 0..<edges.width {
                let c = image.channels(x: x, y: y)
                if c.min() < 31 || c.max() > 225 { outOfRange += 1 }
                if c.x != c.y || c.y != c.z { fringes += 1 }
                let pixel = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                if g.coverage(at: pixel) == 0 || g.displacement(at: pixel) == 0 {
                    // Outside the panel and in its flat interior the source
                    // shows in place.
                    if c.largestDifference(from: edges.texel(x, y) * 255) > 1 { unchangedMismatches += 1 }
                } else if c.largestDifference(from: edges.texel(x, y) * 255) > 1 {
                    refractedPixels += 1
                }
            }
        }
        #expect(outOfRange == 0)
        #expect(fringes == 0)
        #expect(unchangedMismatches == 0)
        // The rim moved the edges: some rim pixels now show the other side.
        #expect(refractedPixels > 50)
    }

    @Test func `Edge illumination only brightens the rim, as the CPU model predicts`() async throws {
        let gpu = try GPUContext()
        let gray = Fixture.uniform(width: 128, height: 96, (90, 90, 90))
        let panel = GlassPanel(
            frame: CGRect(x: 14, y: 10, width: 100, height: 76),
            parameters: GlassParameters(cornerRadius: 18, bezelWidth: 16, refraction: 0.5, edgeHighlight: 1)
        )
        let image = try await render(gpu, gray, panel: panel)
        #expect(image.isFullyOpaque)
        let g = try geometry(panel)
        #expect(maximumError(image, GlassReference(source: gray, geometry: g)) <= 1)
        var darkened = 0, brightenedOutsideRim = 0, brightest = 0.0
        for y in 0..<gray.height {
            for x in 0..<gray.width {
                let c = image.channels(x: x, y: y)
                if c.min() < 89 { darkened += 1 }
                if g.rim(at: SIMD2(Double(x) + 0.5, Double(y) + 0.5)) == 0, c.max() > 91 { brightenedOutsideRim += 1 }
                brightest = max(brightest, c.max())
            }
        }
        #expect(darkened == 0)
        #expect(brightenedOutsideRim == 0)
        // Restrained: at most a quarter of the way to white in linear light.
        let gray90 = GlassPanelGeometry.decodeSRGB(90 / 255)
        let ceiling = GlassPanelGeometry.encodeSRGB(gray90 + (1 - gray90) * GlassParameters.maximumEdgeHighlight) * 255
        #expect(brightest <= ceiling + 1)
        #expect(brightest > 100)
    }

    @Test(arguments: [0.5, 1.0])
    func `Tint mixes in linear light`(strength: Double) async throws {
        let gpu = try GPUContext()
        let source = Fixture.checkerboard(width: 96, height: 96, cell: 16, (200, 200, 200), (60, 60, 60))
        let panel = GlassPanel(
            frame: CGRect(x: 8, y: 8, width: 80, height: 80),
            parameters: GlassParameters(
                cornerRadius: 24, bezelWidth: 0, refraction: 1, edgeHighlight: 1,
                tint: GlassTint(red: 0.1, green: 0.4, blue: 0.9, strength: strength)
            )
        )
        let image = try await render(gpu, source, panel: panel)
        #expect(image.isFullyOpaque)
        // A zero-width rim makes the panel flat, so no sample moves and no
        // edge is lit; the model is exact even across the hard cell edges.
        #expect(maximumError(image, GlassReference(source: source, geometry: try geometry(panel))) <= 1)
        if strength == 1 {
            let center = image.channels(x: 48, y: 48)
            #expect(center.largestDifference(from: SIMD3(0.9, 0.4, 0.1) * 255) <= 1)
        }
    }

    @Test(arguments: [
        CGRect(x: -6, y: -6, width: 60, height: 60),
        CGRect(x: 0, y: 0, width: 48, height: 48),
        CGRect(x: 20, y: -10, width: 40, height: 30),
    ])
    func `Refracted samples never leave the valid rectangle`(frame: CGRect) async throws {
        let gpu = try GPUContext()
        // Valid content (sRGB 70, 140, 210) inside a magenta border that
        // must never appear.
        let valid = PixelRect(x: 8, y: 8, width: 48, height: 48)
        let source = Fixture.framed(width: 64, height: 64, rect: valid, inside: (70, 140, 210), outside: (255, 0, 255))
        let renderer = try GlassRenderer(commandQueue: gpu.queue)
        try renderer.setSource(gpu.makeLease(bgra: source.bgra, width: 64, height: 64, validRect: valid))
        try renderer.setPanel(GlassPanel(
            frame: frame,
            parameters: GlassParameters(cornerRadius: 10, bezelWidth: 20, refraction: 1, edgeHighlight: 0)
        ))
        let target = try gpu.makeTarget(width: 48, height: 48)
        #expect(renderer.draw(targetPixelSize: (48, 48), displayScale: 1) { target } == .submitted(frameID: 1))
        let image = try await gpu.readBack(try #require(target.renderPassDescriptor.colorAttachments[0].texture))
        #expect(image.isFullyOpaque)
        var foreign = 0
        for y in 0..<48 {
            for x in 0..<48 where image.channels(x: x, y: y).largestDifference(from: SIMD3(210, 140, 70)) > 1 {
                foreign += 1
            }
        }
        #expect(foreign == 0)
    }

    // MARK: Repeatability and lifecycle

    @Test func `Fixed inputs render identical bytes`() async throws {
        let gpu = try GPUContext()
        let checker = Fixture.checkerboard(width: 128, height: 96, cell: 6, (250, 220, 30), (10, 30, 90))
        let panel = GlassPanel(
            frame: CGRect(x: 16.5, y: 12.25, width: 95, height: 70),
            parameters: GlassParameters(
                cornerRadius: 22, bezelWidth: 18, refraction: 0.8, edgeHighlight: 0.6,
                tint: GlassTint(red: 0.3, green: 0.6, blue: 1, strength: 0.15)
            )
        )
        let first = try await render(gpu, checker, panel: panel)
        let second = try await render(gpu, checker, panel: panel)
        #expect(first.bgra == second.bgra)
        #expect(first.isFullyOpaque)
    }

    @Test func `An empty panel draws exactly the background`() async throws {
        let gpu = try GPUContext()
        let gradient = Fixture.coordinateGradient(width: 64, height: 48)
        let backgroundOnly = try await render(gpu, gradient, panel: nil)
        let empty = try await render(gpu, gradient, panel: GlassPanel(
            frame: CGRect(x: 10, y: 10, width: -20, height: 30),
            parameters: GlassParameters(refraction: 1, edgeHighlight: 1)
        ))
        #expect(empty.bgra == backgroundOnly.bgra)
    }

    @Test func `A rejected panel leaves the current panel in place`() throws {
        let gpu = try GPUContext()
        let renderer = try GlassRenderer(commandQueue: gpu.queue)
        let panel = GlassPanel(frame: CGRect(x: 0, y: 0, width: 50, height: 40), parameters: GlassParameters(cornerRadius: 80))
        try renderer.setPanel(panel)
        #expect(renderer.panel?.parameters.cornerRadius == 20)
        var invalid = panel
        invalid.parameters.refraction = .nan
        #expect(throws: GlassParameterError.nonFinite(.refraction)) {
            try renderer.setPanel(invalid)
        }
        #expect(renderer.panel?.parameters.cornerRadius == 20)
        try renderer.setPanel(nil)
        #expect(renderer.panel == nil)
    }

    @Test func `Skips run before the panel is converted`() throws {
        let gpu = try GPUContext()
        let renderer = try GlassRenderer(commandQueue: gpu.queue)
        try renderer.setPanel(Self.strongPanel)
        var acquired = false
        #expect(renderer.draw(targetPixelSize: (16, 16), displayScale: 1) { acquired = true; return nil } == .skipped(.missingSource))
        try renderer.setSource(gpu.makeLease(bgra: Fixture.uniform(width: 8, height: 8, (1, 2, 3)).bgra, width: 8, height: 8))
        // A host with no display scale has no pixels: a defined skip, not a
        // conversion with a zero scale.
        #expect(renderer.draw(targetPixelSize: (0, 0), displayScale: 0) { acquired = true; return nil } == .skipped(.zeroSizeTarget))
        #expect(!acquired)
    }

    @Test func `Release waits for every glass draw to complete`() async throws {
        let gpu = try GPUContext()
        let renderer = try GlassRenderer(commandQueue: gpu.queue)
        try renderer.setPanel(Self.strongPanel)
        let recorder = ReleaseRecorder()
        let source = Fixture.coordinateGradient(width: 32, height: 32)
        let lease = try gpu.makeLease(bgra: source.bgra, width: 32, height: 32, onRelease: recorder.handler)
        try renderer.setSource(lease)
        lease.retire()
        for _ in 0..<2 {
            let target = try gpu.makeTarget(width: 32, height: 32)
            #expect(renderer.draw(targetPixelSize: (32, 32), displayScale: 1) { target } == .submitted(frameID: 1))
        }
        renderer.clearSource()
        #expect(await recorder.firstRelease() == BackgroundFrameRelease(
            frameID: 1, completedSubmissions: 2, failedSubmissions: 0,
            skippedSubmissions: 0, cancelledSubmissions: 0
        ))
    }

    @Test func `A glass renderer is one counted renderer`() throws {
        let gpu = try GPUContext()
        let (renderer, created) = try RendererCensus.counting {
            try GlassRenderer(commandQueue: gpu.queue)
        }
        #expect(created == 1)
        #expect(renderer.commandQueue === gpu.queue)
        #expect(renderer.device === gpu.device)
    }
}
