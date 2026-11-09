import CoreGraphics
import Metal
import Testing
@testable import GlassWeave

/// Runs the core example of the DocC catalog (DocumentationExamples.swift).
@Suite(.timeLimit(.minutes(1)))
struct DocumentationExampleTests {
    @Test func `The measuring example reports the GPU p95 of drawn frames`() async throws {
        let gpu = try GPUContext()
        let renderer = try GlassRenderer(commandQueue: gpu.queue)
        try renderer.setPanel(GlassPanel(frame: CGRect(x: 4, y: 4, width: 24, height: 16)))
        let report = measure(renderer)
        #expect(report() == nil, "Nothing drawn yet")

        try renderer.setSource(gpu.makePatternLease(width: 32, height: 24))
        let target = try gpu.makeTarget(width: 32, height: 24)
        #expect(renderer.draw(targetPixelSize: (32, 24), displayScale: 1, acquireTarget: { target }) == .submitted(frameID: 1))
        let metrics = try #require(renderer.metrics)
        let deadline = ContinuousClock.now + .seconds(5)
        while metrics.counts.commandBuffersCompleted < 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let milliseconds = report()
        // The example reports the recorder's own GPU p95, in milliseconds.
        let p95 = metrics.summary().gpu?.p95.components
        #expect(milliseconds == p95.map { Double($0.seconds) * 1_000 + Double($0.attoseconds) / 1e15 })
        if let milliseconds {
            #expect(milliseconds > 0 && milliseconds < 1_000)
        }
        #if !targetEnvironment(simulator)
        #expect(milliseconds != nil, "A Mac or device GPU reports command buffer times")
        #endif
        renderer.clearSource()
    }

    @Test func `The glow example glows amber at the top and violet below, with a clear middle`() async throws {
        let gpu = try GPUContext()
        // Odd sizes put the capsule's center on a pixel center, so the top
        // probe lies exactly at the first stop's angle.
        let frame = CGRect(x: 20, y: 20, width: 201, height: 81)
        let panel = glowingCapsule(frame: frame)
        #expect(panel.parameters.glow.colors.count == 2)
        let source = Fixture.uniform(width: 240, height: 120, (40, 42, 48))
        func render(_ panel: GlassPanel) async throws -> RenderedImage {
            let renderer = try GlassRenderer(commandQueue: gpu.queue)
            try renderer.setSource(gpu.makeLease(bgra: source.bgra, width: source.width, height: source.height))
            try renderer.setPanel(panel)
            #expect(renderer.panel?.parameters.glow == panel.parameters.glow, "In range: drawn as given")
            let target = try gpu.makeTarget(width: source.width, height: source.height)
            #expect(renderer.draw(targetPixelSize: (source.width, source.height), displayScale: 1) { target } == .submitted(frameID: 1))
            return try await gpu.readBack(try #require(target.renderPassDescriptor.colorAttachments[0].texture))
        }
        let image = try await render(panel)
        var plain = panel
        plain.parameters.glow = .none
        let withoutGlow = try await render(plain)
        // The top of the rim, facing the light, is the first stop's color.
        #expect(image.channels(x: 120, y: 21).largestDifference(from: SIMD3(0.2, 0.62, 1) * 255) <= 1)
        // The bottom leans violet: blue well above green.
        let bottom = image.channels(x: 120, y: 99)
        #expect(bottom.x > bottom.y + 40, "\(bottom)")
        // The middle is the glass without a glow.
        #expect(image.channels(x: 120, y: 60) == withoutGlow.channels(x: 120, y: 60))
        // And everything matches the CPU model.
        let g = GlassPanelGeometry(panel: try panel.normalized(), displayScale: 1)
        var worst = 0.0
        let reference = GlassReference(source: source, geometry: g)
        for y in 0..<source.height {
            for x in 0..<source.width {
                worst = max(worst, image.channels(x: x, y: y).largestDifference(from: reference.encodedColor(x: x, y: y)))
            }
        }
        #expect(worst <= 1)
    }

    @Test func `The capsule row draws each capsule's color in one pass, with quads apart and clear middles`() async throws {
        let gpu = try GPUContext()
        let colors: [GlassGlow.ColorStop] = [
            .init(red: 1, green: 0.4, blue: 0.1), .init(red: 1, green: 0.85, blue: 0.2), .init(red: 0.2, green: 0.9, blue: 0.8),
        ]
        // Odd widths put each capsule's center on a pixel center.
        let panels = capsuleRow(origin: CGPoint(x: 20, y: 20), capsuleSize: CGSize(width: 41, height: 81), colors: colors)
        #expect(panels.count == 3)
        // The documented spacing keeps every quad apart.
        let quads = panels.map { $0.frame.insetBy(dx: -($0.parameters.glow.haloRadius + 1), dy: -($0.parameters.glow.haloRadius + 1)) }
        #expect(!quads[0].intersects(quads[1]) && !quads[1].intersects(quads[2]))

        let source = Fixture.uniform(width: 240, height: 120, (30, 32, 40))
        func render(_ panels: [GlassPanel]) async throws -> RenderedImage {
            let renderer = try GlassRenderer(commandQueue: gpu.queue)
            try renderer.setSource(gpu.makeLease(bgra: source.bgra, width: source.width, height: source.height))
            try renderer.setPanels(panels)
            #expect(renderer.panels.count == panels.count)
            let target = try gpu.makeTarget(width: source.width, height: source.height)
            #expect(renderer.draw(targetPixelSize: (source.width, source.height), displayScale: 1) { target } == .submitted(frameID: 1))
            return try await gpu.readBack(try #require(target.renderPassDescriptor.colorAttachments[0].texture))
        }
        let image = try await render(panels)
        let background = try await render([])
        let withoutGlow = try await render(panels.map { panel in
            var plain = panel
            plain.parameters.glow = .none
            return plain
        })
        for (panel, color) in zip(panels, colors) {
            let midX = Int(panel.frame.midX)
            // The top of each rim is its own color.
            let expected = SIMD3(color.blue, color.green, color.red) * 255
            #expect(image.channels(x: midX, y: Int(panel.frame.minY) + 1).largestDifference(from: expected) <= 1, "\(color)")
            // The middle is see-through: exactly the glass without a glow.
            #expect(image.channels(x: midX, y: Int(panel.frame.midY)) == withoutGlow.channels(x: midX, y: Int(panel.frame.midY)))
            // The halo lightens the background beside it.
            let beside = image.channels(x: Int(panel.frame.maxX) + 3, y: Int(panel.frame.midY))
            #expect(beside.max() > background.channels(x: Int(panel.frame.maxX) + 3, y: Int(panel.frame.midY)).max() + 10)
        }
    }

    @Test func `The orb example spills a halo outside its circle and pulses`() async throws {
        let gpu = try GPUContext()
        // A 61-point circle with 30 points of surface around it.
        let frame = CGRect(x: 30, y: 30, width: 61, height: 61)
        let panel = pulsingOrb(frame: frame)
        #expect(panel.parameters.glow.isAnimated && panel.parameters.glow.hasHalo)
        let source = Fixture.uniform(width: 121, height: 121, (20, 22, 28))
        func render(at time: Double) async throws -> RenderedImage {
            let renderer = try GlassRenderer(commandQueue: gpu.queue)
            try renderer.setSource(gpu.makeLease(bgra: source.bgra, width: source.width, height: source.height))
            try renderer.setPanel(panel)
            try renderer.setEffectTime(time)
            let target = try gpu.makeTarget(width: source.width, height: source.height)
            #expect(renderer.draw(targetPixelSize: (source.width, source.height), displayScale: 1) { target } == .submitted(frameID: 1))
            return try await gpu.readBack(try #require(target.renderPassDescriptor.colorAttachments[0].texture))
        }
        let peak = try await render(at: 0)
        let trough = try await render(at: 1)
        #expect(panel.parameters.glow.pulseLevel(at: 1) == 0.5)
        // Eight points above the circle: the halo, brighter at the peak.
        let background = SIMD3<Double>(28, 22, 20)
        #expect(peak.channels(x: 60, y: 22).sum() > background.sum() + 60)
        #expect(peak.channels(x: 60, y: 22).sum() > trough.channels(x: 60, y: 22).sum() + 20)
        // Beyond the 24-point halo (25 points above the circle, still inside
        // the panel's quad) the background is unchanged.
        #expect(peak.channels(x: 60, y: 5) == background)
        // Each instant matches the CPU model.
        for (image, time) in [(peak, 0.0), (trough, 1.0)] {
            let g = GlassPanelGeometry(panel: try panel.normalized(), displayScale: 1, effectTime: time)
            let reference = GlassReference(source: source, geometry: g)
            var worst = 0.0
            for y in 0..<source.height {
                for x in 0..<source.width {
                    worst = max(worst, image.channels(x: x, y: y).largestDifference(from: reference.encodedColor(x: x, y: y)))
                }
            }
            #expect(worst <= 1, "time \(time)")
        }
    }

    @Test func `The energy orb example lights its inside, keeps its middle clear, and moves`() async throws {
        let gpu = try GPUContext()
        // A 61-point circle with 30 points of surface around it, so the
        // 24-point halo fits.
        let frame = CGRect(x: 30, y: 30, width: 61, height: 61)
        let panel = energyOrb(frame: frame)
        #expect(panel.parameters.interior.isAnimated)
        let source = Fixture.uniform(width: 121, height: 121, (20, 22, 28))
        func render(_ panel: GlassPanel, at time: Double) async throws -> RenderedImage {
            let renderer = try GlassRenderer(commandQueue: gpu.queue)
            try renderer.setSource(gpu.makeLease(bgra: source.bgra, width: source.width, height: source.height))
            try renderer.setPanel(panel)
            #expect(renderer.panel?.parameters.interior == panel.parameters.interior, "In range: drawn as given")
            try renderer.setEffectTime(time)
            let target = try gpu.makeTarget(width: source.width, height: source.height)
            #expect(renderer.draw(targetPixelSize: (source.width, source.height), displayScale: 1) { target } == .submitted(frameID: 1))
            return try await gpu.readBack(try #require(target.renderPassDescriptor.colorAttachments[0].texture))
        }
        var withoutInterior = panel
        withoutInterior.parameters.interior = .none
        let early = try await render(panel, at: 0.5)
        let later = try await render(panel, at: 1.5)
        let plain = try await render(withoutInterior, at: 0.5)
        let g = GlassPanelGeometry(panel: try panel.normalized(), displayScale: 1, effectTime: 0.5)
        var lit = 0, outsideChanged = 0, middleChanged = 0, moved = 0
        for y in 0..<source.height {
            for x in 0..<source.width {
                let pixel = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                let changed = early.channels(x: x, y: y) != plain.channels(x: x, y: y)
                if g.coverage(at: pixel) == 0 {
                    if changed { outsideChanged += 1 }
                } else if g.interiorDepthFraction(at: pixel) >= 0.85 {
                    if changed { middleChanged += 1 }
                } else if early.channels(x: x, y: y).sum() > plain.channels(x: x, y: y).sum() + 12 {
                    lit += 1
                }
                if early.channels(x: x, y: y) != later.channels(x: x, y: y) { moved += 1 }
            }
        }
        #expect(lit > 100, "Filaments light the inside")
        #expect(outsideChanged == 0, "Energy draws only inside the circle")
        #expect(middleChanged == 0, "The middle stays the glass without an interior")
        #expect(moved > 100, "A second later the filaments moved")
        // And the image matches the CPU model.
        let reference = GlassReference(source: source, geometry: g)
        var worst = 0.0
        for y in 0..<source.height {
            for x in 0..<source.width {
                worst = max(worst, early.channels(x: x, y: y).largestDifference(from: reference.encodedColor(x: x, y: y)))
            }
        }
        #expect(worst <= 1)
    }
}
