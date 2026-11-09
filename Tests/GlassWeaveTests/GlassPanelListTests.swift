import CoreGraphics
import Metal
import Testing
@testable import GlassWeave

/// Several panels in one pass (GW-20): `GlassRenderer.setPanels(_:)` draws an
/// ordered list of panels, each as one quad after the background, sampling
/// the same frame. One panel set as a list renders exactly what
/// `setPanel(_:)` renders; panels whose quads do not overlap render exactly
/// what each renders alone; where quads overlap, the later panel wins; the
/// list follows the `GlassParameters` normalization rule and keeps the first
/// `maximumPanelCount` panels.
///
/// GPU readback on the test machine with Metal API Validation when the scheme
/// sets MTL_DEBUG_LAYER=1. Comparisons are byte for byte: the same shader
/// with the same inputs on the same device.
@Suite(.timeLimit(.minutes(1)))
struct GlassPanelListTests {
    /// A checkerboard with a gradient-free structure, so refraction and the
    /// halo change visible bytes.
    private static let source = Fixture.checkerboard(width: 240, height: 160, cell: 10, (40, 70, 120), (200, 190, 150))

    /// A glowing capsule with a halo and an animated interior whose sparks
    /// rise into the halo.
    private static func emberCapsule(_ frame: CGRect) -> GlassPanel {
        GlassPanel(frame: frame, parameters: GlassParameters(
            cornerRadius: min(frame.width, frame.height) / 2, bezelWidth: 10, refraction: 0.8, edgeHighlight: 0.4,
            tint: GlassTint(red: 0.05, green: 0.05, blue: 0.1, strength: 0.5),
            glow: GlassGlow(
                colors: [.init(red: 1, green: 0.45, blue: 0.15, angle: 0), .init(red: 0.9, green: 0.1, blue: 0.1, angle: 180)],
                rimWidth: 1.5, rimSoftness: 1.5, innerGlowRadius: 10, innerGlowIntensity: 0.7,
                centerOpacity: 0.2, lightAngle: 0, directionality: 0.6,
                haloRadius: 12, haloIntensity: 0.9, pulsePeriod: 1.5, pulseDepth: 0.4
            ),
            interior: GlassInterior(
                effect: .embers,
                colors: [.init(red: 0.8, green: 0.1, blue: 0.05), .init(red: 1, green: 0.55, blue: 0.1), .init(red: 1, green: 0.9, blue: 0.4)],
                intensity: 0.9, speed: 1, seed: 11, centerFade: 0.4
            )
        ))
    }

    /// A circle with an energy interior and a cool halo.
    private static func orb(_ frame: CGRect) -> GlassPanel {
        GlassPanel(frame: frame, parameters: GlassParameters(
            cornerRadius: frame.width / 2, bezelWidth: 8, refraction: 0.7, edgeHighlight: 0.5,
            glow: GlassGlow(
                colors: [.init(red: 0.3, green: 0.85, blue: 1, angle: 0), .init(red: 0.7, green: 0.35, blue: 1, angle: 180)],
                innerGlowRadius: 8, innerGlowIntensity: 0.6, haloRadius: 10, haloIntensity: 0.8
            ),
            interior: GlassInterior(
                effect: .energy,
                colors: [.init(red: 0.25, green: 0.3, blue: 1), .init(red: 0.3, green: 0.85, blue: 1), .init(red: 0.95, green: 0.98, blue: 1)],
                intensity: 0.9, speed: 1, seed: 7, centerFade: 0.6
            )
        ))
    }

    /// A plain glass panel without a glow.
    private static func plain(_ frame: CGRect) -> GlassPanel {
        GlassPanel(frame: frame, parameters: GlassParameters(cornerRadius: 8, bezelWidth: 10, refraction: 1, edgeHighlight: 0.6))
    }

    /// Three panels whose quads (the panel grown by one pixel and its halo
    /// radius) do not overlap, at scale 1.
    private static let layout: [GlassPanel] = [
        emberCapsule(CGRect(x: 16, y: 30, width: 48, height: 100)),
        orb(CGRect(x: 100, y: 50, width: 56, height: 56)),
        plain(CGRect(x: 176, y: 24, width: 52, height: 112)),
    ]

    /// Renders the source 1:1 with `panels` at `effectTime` and reads it back.
    private func render(_ gpu: GPUContext, panels: [GlassPanel], effectTime: Double = 2.75, useSetPanel: Bool = false) async throws -> RenderedImage {
        let source = Self.source
        let renderer = try GlassRenderer(commandQueue: gpu.queue)
        try renderer.setSource(gpu.makeLease(bgra: source.bgra, width: source.width, height: source.height))
        if useSetPanel {
            try renderer.setPanel(panels.first)
        } else {
            try renderer.setPanels(panels)
        }
        try renderer.setEffectTime(effectTime)
        let target = try gpu.makeTarget(width: source.width, height: source.height)
        let outcome = renderer.draw(targetPixelSize: (source.width, source.height), displayScale: 1) { target }
        #expect(outcome == .submitted(frameID: 1))
        return try await gpu.readBack(try #require(target.renderPassDescriptor.colorAttachments[0].texture))
    }

    /// The pixels a panel's quad covers at scale 1: the panel grown by one
    /// pixel and its halo radius on every side, by pixel center.
    private static func quad(_ panel: GlassPanel) -> CGRect {
        let halo = panel.parameters.glow.hasHalo ? panel.parameters.glow.haloRadius : 0
        return panel.frame.insetBy(dx: -(1 + halo), dy: -(1 + halo))
    }

    /// The number of bytes that differ between two images of one size.
    private static func differingBytes(_ a: RenderedImage, _ b: RenderedImage) -> Int {
        zip(a.bgra, b.bgra).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
    }

    @Test func `One panel set as a list renders the same bytes as setPanel`() async throws {
        let gpu = try GPUContext()
        for panel in Self.layout {
            let list = try await render(gpu, panels: [panel])
            let single = try await render(gpu, panels: [panel], useSetPanel: true)
            #expect(list.isFullyOpaque)
            #expect(Self.differingBytes(list, single) == 0)
        }
        // An empty list draws the background alone, like setPanel(nil).
        let empty = try await render(gpu, panels: [])
        let none = try await render(gpu, panels: [], useSetPanel: true)
        #expect(Self.differingBytes(empty, none) == 0)
    }

    @Test func `Panels whose quads do not overlap render what each renders alone`() async throws {
        let gpu = try GPUContext()
        let quads = Self.layout.map(Self.quad)
        for (index, quad) in quads.enumerated() {
            for other in quads[(index + 1)...] {
                #expect(!quad.intersects(other), "The fixture's quads must not overlap")
            }
        }
        let together = try await render(gpu, panels: Self.layout)
        let background = try await render(gpu, panels: [])
        var alone: [RenderedImage] = []
        for panel in Self.layout {
            alone.append(try await render(gpu, panels: [panel]))
        }
        #expect(together.isFullyOpaque)

        // Expected: inside a panel's quad, that panel drawn alone; elsewhere,
        // the background pass.
        var mismatched = 0
        var changedPerPanel = Array(repeating: 0, count: quads.count)
        for y in 0..<together.height {
            for x in 0..<together.width {
                let center = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                let owner = quads.firstIndex { $0.contains(center) }
                let expected = owner.map { alone[$0].color(x: x, y: y) } ?? background.color(x: x, y: y)
                if together.color(x: x, y: y) != expected { mismatched += 1 }
                if let owner, alone[owner].color(x: x, y: y) != background.color(x: x, y: y) {
                    changedPerPanel[owner] += 1
                }
            }
        }
        #expect(mismatched == 0)
        // Each panel did draw something different from the background, so
        // the comparison exercised all three.
        for (index, changed) in changedPerPanel.enumerated() {
            #expect(changed > 500, "Panel \(index) changed only \(changed) pixels")
        }

        // The order of non-overlapping panels does not matter.
        let reversed = try await render(gpu, panels: Self.layout.reversed())
        #expect(Self.differingBytes(together, reversed) == 0)
    }

    @Test func `Every panel draws at the same effect time`() async throws {
        let gpu = try GPUContext()
        // Two animated panels at two times: each one's region matches that
        // panel drawn alone at the same time, so they share one clock.
        for time in [0.0, 1.3, 41.25] {
            let together = try await render(gpu, panels: Array(Self.layout.prefix(2)), effectTime: time)
            for (index, panel) in Self.layout.prefix(2).enumerated() {
                let alone = try await render(gpu, panels: [panel], effectTime: time)
                let quad = Self.quad(panel)
                var mismatched = 0
                for y in Int(quad.minY)..<Int(quad.maxY) {
                    for x in Int(quad.minX)..<Int(quad.maxX) where together.color(x: x, y: y) != alone.color(x: x, y: y) {
                        mismatched += 1
                    }
                }
                #expect(mismatched == 0, "Panel \(index) at t = \(time)")
            }
        }
        let early = try await render(gpu, panels: Self.layout, effectTime: 0.5)
        let late = try await render(gpu, panels: Self.layout, effectTime: 1.0)
        #expect(Self.differingBytes(early, late) > 100, "The animated panels did not change with the effect time")
    }

    @Test func `Where quads overlap the later panel wins`() async throws {
        let gpu = try GPUContext()
        let first = Self.plain(CGRect(x: 20, y: 20, width: 120, height: 100))
        let second = Self.orb(CGRect(x: 110, y: 40, width: 60, height: 60))
        let both = try await render(gpu, panels: [first, second])
        let secondAlone = try await render(gpu, panels: [second])
        let firstAlone = try await render(gpu, panels: [first])
        let quad = Self.quad(second)
        var mismatched = 0
        var differsFromFirst = 0
        for y in Int(quad.minY)..<Int(quad.maxY) {
            for x in Int(quad.minX)..<Int(quad.maxX) {
                if both.color(x: x, y: y) != secondAlone.color(x: x, y: y) { mismatched += 1 }
                if x < 140, both.color(x: x, y: y) != firstAlone.color(x: x, y: y) { differsFromFirst += 1 }
            }
        }
        #expect(mismatched == 0)
        // In the overlap the first panel's glass is gone: the second panel
        // samples the background, not what the first drew.
        #expect(differsFromFirst > 100)
    }

    @Test func `The list follows the normalization rule and keeps the first eight panels`() throws {
        let gpu = try GPUContext()
        let renderer = try GlassRenderer(commandQueue: gpu.queue)
        #expect(renderer.panels.isEmpty)
        #expect(renderer.panel == nil)

        // Each panel is normalized: a negative size and an oversized radius
        // are clamped.
        var odd = Self.plain(CGRect(x: 5, y: 5, width: -10, height: 40))
        odd.parameters.cornerRadius = 500
        let wide = Self.emberCapsule(CGRect(x: 0, y: 0, width: 80, height: 40))
        try renderer.setPanels([wide, odd])
        #expect(renderer.panels == [try wide.normalized(), try odd.normalized()])
        #expect(renderer.panels[1].frame.width == 0)
        #expect(renderer.panels[0].parameters.cornerRadius == 20)
        #expect(renderer.panel == renderer.panels.first)

        // Only the first maximumPanelCount are kept, in order.
        #expect(GlassRenderer.maximumPanelCount == 8)
        let many = (0..<11).map { Self.plain(CGRect(x: Double($0) * 20, y: 0, width: 16, height: 16)) }
        try renderer.setPanels(many)
        #expect(renderer.panels.count == 8)
        #expect(renderer.panels.map { Double($0.frame.minX) } == (0..<8).map { Double($0) * 20 })

        // A non-finite value anywhere, even past the maximum, throws naming
        // its field and keeps the current panels.
        var broken = many
        broken[10].parameters.glow = GlassGlow(colors: [.init(red: 1, green: 1, blue: 1)], haloRadius: .nan)
        #expect(throws: GlassParameterError.nonFinite(.glowHaloRadius)) { try renderer.setPanels(broken) }
        #expect(renderer.panels.count == 8)
        var brokenFrame = [wide, Self.plain(CGRect(x: 0, y: CGFloat.infinity, width: 10, height: 10))]
        #expect(throws: GlassParameterError.nonFinite(.frame)) { try renderer.setPanels(brokenFrame) }
        brokenFrame[1].frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        try renderer.setPanels(brokenFrame)
        #expect(renderer.panels.count == 2)

        // setPanel replaces the whole list; nil empties it.
        try renderer.setPanel(wide)
        #expect(renderer.panels == [try wide.normalized()])
        try renderer.setPanel(nil)
        #expect(renderer.panels.isEmpty)
    }

    @Test func `A panel whose quad misses the target leaves every byte unchanged`() async throws {
        // What a host's effect clock relies on (GlassSurfaceView): a panel
        // that does not reach the target cannot change a pixel, whatever its
        // pulse or interior does. The ember capsule has a 12-pixel halo, so
        // its quad reaches 13 pixels beyond its rectangle at scale 1.
        let gpu = try GPUContext()
        let source = Self.source
        let background = try await render(gpu, panels: [])
        let size = (width: source.width, height: source.height)
        let missing: [CGRect] = [
            CGRect(x: -48 - 13, y: 30, width: 48, height: 100),         // left, quad ends at 0
            CGRect(x: 240 + 13, y: 30, width: 48, height: 100),         // right, quad starts at 240
            CGRect(x: 100, y: -100 - 13.5, width: 48, height: 100),     // above
            CGRect(x: 100, y: 160 + 13.5, width: 48, height: 100),      // below
            CGRect(x: 100, y: 30, width: 0, height: 100),               // no area
        ]
        for frame in missing {
            let panel = try Self.emberCapsule(frame).normalized()
            #expect(!panel.reachesTarget(pixelWidth: size.width, pixelHeight: size.height, displayScale: 1), "\(frame)")
            for time in [0.0, 0.4, 1.9] {
                let image = try await render(gpu, panels: [panel], effectTime: time)
                #expect(Self.differingBytes(image, background) == 0, "\(frame) at \(time) s")
            }
        }
        // One pixel more and the quad covers a column or row of the target.
        let reaching: [CGRect] = [
            CGRect(x: -48 - 12, y: 30, width: 48, height: 100),
            CGRect(x: 240 + 12, y: 30, width: 48, height: 100),
            CGRect(x: 100, y: -100 - 12.5, width: 48, height: 100),
            CGRect(x: 100, y: 160 + 12.5, width: 48, height: 100),
        ]
        for frame in reaching {
            let panel = try Self.emberCapsule(frame).normalized()
            #expect(panel.reachesTarget(pixelWidth: size.width, pixelHeight: size.height, displayScale: 1), "\(frame)")
        }
        // A panel well inside changes pixels, and reaches the target.
        let inside = try Self.emberCapsule(CGRect(x: 100, y: 30, width: 48, height: 100)).normalized()
        #expect(inside.reachesTarget(pixelWidth: size.width, pixelHeight: size.height, displayScale: 1))
        #expect(Self.differingBytes(try await render(gpu, panels: [inside]), background) > 1000)

        // In points at scale 2: the one-pixel outset is half a point; no
        // target, or a scale that is not positive and finite, reaches nothing.
        let right = try Self.emberCapsule(CGRect(x: 120 + 12.25, y: 10, width: 24, height: 50)).normalized()
        #expect(right.reachesTarget(pixelWidth: 240, pixelHeight: 160, displayScale: 2))
        let beyond = try Self.emberCapsule(CGRect(x: 120 + 12.75, y: 10, width: 24, height: 50)).normalized()
        #expect(!beyond.reachesTarget(pixelWidth: 240, pixelHeight: 160, displayScale: 2))
        #expect(!inside.reachesTarget(pixelWidth: 0, pixelHeight: 160, displayScale: 1))
        for scale in [0.0, -1, .infinity, .nan] {
            #expect(!inside.reachesTarget(pixelWidth: 240, pixelHeight: 160, displayScale: scale))
        }
    }
}
