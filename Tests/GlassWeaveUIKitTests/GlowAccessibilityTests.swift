#if canImport(UIKit)
import Metal
import Testing
import UIKit
@testable import GlassWeave
@testable import GlassWeaveUIKit

/// GW-17's accessibility mapping: under Reduce Transparency a glowing panel
/// keeps an opaque, legible body with at most a thin uniform rim; under
/// Increase Contrast its interior is the glass without a glow, so the tint's
/// legibility rule still holds for text. Includes an offscreen render of the
/// presented panels on the device the tests run on.
@MainActor
struct GlowAccessibilityTests {
    let device: any MTLDevice
    let queue: any MTLCommandQueue

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        queue = try #require(device.makeCommandQueue())
    }

    private static let amber = GlassGlow.ColorStop(red: 1, green: 0.6, blue: 0.1)

    private static let glowing = GlassPanel(
        frame: CGRect(x: 10, y: 8, width: 140, height: 84),
        parameters: GlassParameters(
            cornerRadius: 30, bezelWidth: 22, refraction: 0.85, edgeHighlight: 0.6,
            tint: GlassTint(red: 0.97, green: 0.98, blue: 1, strength: 0.45),
            glow: GlassGlow(
                colors: [amber, .init(red: 0.3, green: 0.5, blue: 1, angle: 180)],
                rimWidth: 1.5, rimSoftness: 1.5, rimIntensity: 1, innerGlowRadius: 24, innerGlowIntensity: 0.5,
                centerOpacity: 0.2, lightAngle: 0, directionality: 0.8
            )
        )
    )

    private static func traits(_ style: UIUserInterfaceStyle, _ contrast: UIAccessibilityContrast) -> UITraitCollection {
        UITraitCollection { traits in
            traits.userInterfaceStyle = style
            traits.accessibilityContrast = contrast
        }
    }

    // MARK: The mapping

    @Test(arguments: [UIAccessibilityContrast.normal, .high])
    func `Reduce Transparency keeps only a thin, crisp, evenly lit rim`(contrast: UIAccessibilityContrast) {
        let traits = Self.traits(.light, contrast)
        let presented = GlassAccessibilityPolicy.presentedPanel(
            for: Self.glowing, settings: GlassAccessibilitySettings(reduceTransparency: true), traits: traits
        )
        let glow = presented.parameters.glow
        #expect(presented.parameters.tint == GlassAccessibilityPolicy.opaqueSurfaceTint(for: traits))
        #expect(glow.colors == Self.glowing.parameters.glow.colors, "The rim keeps the shape's colors")
        // Width 1.5 plus softness 1.5, capped at 2 points, with no soft edge.
        #expect(glow.rimWidth == GlassAccessibilityPolicy.reducedTransparencyRimWidth)
        #expect(glow.rimSoftness == 0)
        #expect(glow.rimIntensity == 1)
        #expect(glow.innerGlowIntensity == 0)
        #expect(glow.centerOpacity == 0)
        #expect(glow.directionality == 0)
        // A thinner rim keeps its whole extent.
        var thin = Self.glowing
        thin.parameters.glow.rimWidth = 0.5
        thin.parameters.glow.rimSoftness = 0.75
        let thinRim = GlassAccessibilityPolicy.presentedPanel(
            for: thin, settings: GlassAccessibilitySettings(reduceTransparency: true), traits: traits
        ).parameters.glow
        #expect(thinRim.rimWidth == 1.25)
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func `Increase Contrast removes the inner glow and center fill`(style: UIUserInterfaceStyle) {
        let presented = GlassAccessibilityPolicy.presentedPanel(
            for: Self.glowing, settings: GlassAccessibilitySettings(), traits: Self.traits(style, .high)
        )
        var expected = Self.glowing
        expected.parameters.glow.innerGlowIntensity = 0
        expected.parameters.glow.centerOpacity = 0
        expected.parameters.glow.directionality = 0
        #expect(presented == expected, "Only the glow changes; the rim keeps its width and softness")
        // Normal contrast leaves the glow as the app set it.
        let normal = GlassAccessibilityPolicy.presentedPanel(
            for: Self.glowing, settings: GlassAccessibilitySettings(), traits: Self.traits(style, .normal)
        )
        #expect(normal == Self.glowing)
        // A panel without a glow is unchanged under Increase Contrast.
        var plain = Self.glowing
        plain.parameters.glow = .none
        #expect(GlassAccessibilityPolicy.presentedPanel(
            for: plain, settings: GlassAccessibilitySettings(), traits: Self.traits(style, .high)
        ) == plain)
    }

    @Test func `The surface presents the glow again when the contrast setting changes`() throws {
        let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
        surface.sceneStateOverride = .foregroundActive
        surface.frame = CGRect(x: 0, y: 0, width: 200, height: 120)
        surface.traitOverrides.accessibilityContrast = .normal
        surface.layoutIfNeeded()
        surface.updateTraitsIfNeeded()
        try surface.setPanel(Self.glowing)
        #expect(surface.presentedPanel == Self.glowing)
        let requests = surface.frameStatistics.requested
        surface.traitOverrides.accessibilityContrast = .high
        surface.updateTraitsIfNeeded()
        #expect(surface.panel == Self.glowing, "The app's panel is kept")
        #expect(surface.presentedPanel?.parameters.glow.innerGlowIntensity == 0)
        #expect(surface.presentedPanel?.parameters.glow.centerOpacity == 0)
        #expect(surface.frameStatistics.requested == requests + 1, "The change is drawn")
        surface.traitOverrides.accessibilityContrast = .normal
        surface.updateTraitsIfNeeded()
        #expect(surface.presentedPanel == Self.glowing)
    }

    @Test func `A UIKit color becomes a glow stop resolved for the traits`() throws {
        let light = Self.traits(.light, .normal), dark = Self.traits(.dark, .normal)
        let lightStop = try #require(GlassGlow.ColorStop(.systemOrange, angle: 45, traits: light))
        let darkStop = try #require(GlassGlow.ColorStop(.systemOrange, angle: 45, traits: dark))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor.systemOrange.resolvedColor(with: dark).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #expect(darkStop == GlassGlow.ColorStop(red: Double(red), green: Double(green), blue: Double(blue), angle: 45))
        #expect(lightStop != darkStop, "A dynamic color follows the appearance")
        // Alpha is not part of a stop.
        let translucent = try #require(GlassGlow.ColorStop(UIColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.3), traits: light))
        #expect(abs(translucent.red - 0.2) < 1e-6 && abs(translucent.green - 0.4) < 1e-6 && abs(translucent.blue - 0.6) < 1e-6)
        let pattern = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        #expect(GlassGlow.ColorStop(UIColor(patternImage: pattern), traits: light) == nil)
    }

    // MARK: What is drawn

    /// Renders `panel` at display scale 1 over a source whose left half is
    /// black and right half white, and returns the bytes (BGRA, rows top to
    /// bottom).
    private func render(_ panel: GlassPanel, width: Int = 160, height: Int = 100, effectTime: Double = 0) async throws -> [UInt8] {
        var bytes = [UInt8]()
        for _ in 0..<height {
            for x in 0..<width {
                let value: UInt8 = x < width / 2 ? 0 : 255
                bytes += [value, value, value, 255]
            }
        }
        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        sourceDescriptor.storageMode = .private
        sourceDescriptor.usage = [.shaderRead]
        let source = try #require(device.makeTexture(descriptor: sourceDescriptor))
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: GlassRenderer.outputPixelFormat, width: width, height: height, mipmapped: false)
        targetDescriptor.storageMode = .private
        targetDescriptor.usage = [.renderTarget]
        let target = try #require(device.makeTexture(descriptor: targetDescriptor))
        let rowBytes = width * 4
        let staging = try #require(device.makeBuffer(bytes: bytes, length: bytes.count, options: .storageModeShared))
        let readback = try #require(device.makeBuffer(length: bytes.count, options: .storageModeShared))
        let size = MTLSize(width: width, height: height, depth: 1)

        let upload = try #require(queue.makeCommandBuffer())
        let uploadBlit = try #require(upload.makeBlitCommandEncoder())
        uploadBlit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: rowBytes, sourceBytesPerImage: bytes.count,
                        sourceSize: size, to: source, destinationSlice: 0, destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        uploadBlit.endEncoding()
        upload.commit()

        let renderer = try GlassRenderer(commandQueue: queue)
        let frame = BackgroundFrame(texture: source, frameID: 1, timestamp: .zero, colorConvention: .sRGBOpaque, readiness: .committed(on: queue))
        let lease = BackgroundFrameLease(frame: frame, onRelease: { _ in })
        try renderer.setSource(lease)
        lease.retire()
        try renderer.setPanel(panel)
        try renderer.setEffectTime(effectTime)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        #expect(renderer.draw(targetPixelSize: (width, height), displayScale: 1) {
            BackgroundDrawTarget(renderPassDescriptor: pass)
        } == .submitted(frameID: 1))

        let copy = try #require(queue.makeCommandBuffer())
        let copyBlit = try #require(copy.makeBlitCommandEncoder())
        copyBlit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: size, to: readback, destinationOffset: 0,
                      destinationBytesPerRow: rowBytes, destinationBytesPerImage: bytes.count)
        copyBlit.endEncoding()
        let status = await withCheckedContinuation { continuation in
            copy.addCompletedHandler { continuation.resume(returning: $0.status) }
            copy.commit()
        }
        #expect(status == .completed)
        return Array(UnsafeRawBufferPointer(start: readback.contents(), count: bytes.count))
    }

    /// Depth of a pixel center below the panel's outline, in points at
    /// scale 1 (negative outside).
    private static func depth(_ panel: GlassPanel, x: Int, y: Int) -> Double {
        let frame = panel.frame
        let radius = min(panel.parameters.cornerRadius, min(frame.width, frame.height) / 2)
        let q = SIMD2(abs(Double(x) + 0.5 - frame.midX), abs(Double(y) + 0.5 - frame.midY))
        let d = q - (SIMD2(frame.width / 2, frame.height / 2) - radius)
        let outside = SIMD2(max(d.x, 0), max(d.y, 0))
        return -((outside.x * outside.x + outside.y * outside.y).squareRoot() + min(max(d.x, d.y), 0) - radius)
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func `Under Reduce Transparency the body is opaque over black and white, inside a thin rim`(style: UIUserInterfaceStyle) async throws {
        let traits = Self.traits(style, .normal)
        // One color, so every rim pixel has the same expected color.
        var amberGlow = Self.glowing
        amberGlow.parameters.glow.colors = [Self.amber]
        let presented = GlassAccessibilityPolicy.presentedPanel(
            for: amberGlow, settings: GlassAccessibilitySettings(reduceTransparency: true), traits: traits
        )
        let bytes = try await render(presented)
        let tint = presented.parameters.tint
        let opaque = SIMD3(tint.blue, tint.green, tint.red) * 255
        let amber = SIMD3(Self.amber.blue, Self.amber.green, Self.amber.red) * 255
        var body = 0, notOpaque = 0, rim = 0, wrongRim = 0
        for y in 0..<100 {
            for x in 0..<160 {
                let i = (y * 160 + x) * 4
                let c = SIMD3(Double(bytes[i]), Double(bytes[i + 1]), Double(bytes[i + 2]))
                let depth = Self.depth(presented, x: x, y: y)
                if depth > GlassAccessibilityPolicy.reducedTransparencyRimWidth + 1 {
                    body += 1
                    if max(abs(c.x - opaque.x), abs(c.y - opaque.y), abs(c.z - opaque.z)) > 1 { notOpaque += 1 }
                } else if depth >= 0.5, depth <= GlassAccessibilityPolicy.reducedTransparencyRimWidth {
                    // The rim, all around: its color, whatever lies behind
                    // the panel (black on the left, white on the right).
                    rim += 1
                    if max(abs(c.x - amber.x), abs(c.y - amber.y), abs(c.z - amber.z)) > 1 { wrongRim += 1 }
                }
            }
        }
        #expect(body > 8000)
        #expect(notOpaque == 0)
        #expect(rim > 300)
        #expect(wrongRim == 0)
    }

    @Test func `Under Increase Contrast the interior is exactly the glass without a glow`() async throws {
        let traits = Self.traits(.dark, .high)
        let presented = GlassAccessibilityPolicy.presentedPanel(for: Self.glowing, settings: GlassAccessibilitySettings(), traits: traits)
        var withoutGlow = presented
        withoutGlow.parameters.glow = .none
        let drawn = try await render(presented)
        let reference = try await render(withoutGlow)
        let rimExtent = presented.parameters.glow.rimWidth + max(presented.parameters.glow.rimSoftness, 1)
        var interior = 0, differing = 0, rimDiffering = 0
        for y in 0..<100 {
            for x in 0..<160 {
                let i = (y * 160 + x) * 4
                let same = drawn[i] == reference[i] && drawn[i + 1] == reference[i + 1] && drawn[i + 2] == reference[i + 2]
                let depth = Self.depth(presented, x: x, y: y)
                if depth > rimExtent + 0.5 {
                    interior += 1
                    if !same { differing += 1 }
                } else if depth > 0.5, !same {
                    rimDiffering += 1
                }
            }
        }
        #expect(interior > 8000)
        #expect(differing == 0)
        #expect(rimDiffering > 200, "The rim is still drawn")
        // So the tint's legibility rule, which describes the glass without a
        // glow, still describes the interior text sits on.
    }

    // MARK: Halo and pulse (GW-18)

    /// A smaller panel with room for its halo inside the 160 × 100 target.
    private static let haloing = GlassPanel(
        frame: CGRect(x: 30, y: 25, width: 100, height: 50),
        parameters: GlassParameters(
            cornerRadius: 20, bezelWidth: 14, refraction: 0.7, edgeHighlight: 0.5,
            tint: GlassTint(red: 0.08, green: 0.09, blue: 0.12, strength: 0.45),
            glow: GlassGlow(
                colors: [amber, .init(red: 0.3, green: 0.5, blue: 1, angle: 180)],
                rimWidth: 1.5, rimSoftness: 1.5, innerGlowRadius: 14, innerGlowIntensity: 0.6,
                centerOpacity: 0.2, lightAngle: 0, directionality: 0.6,
                haloRadius: 16, haloIntensity: 0.9, pulsePeriod: 1.6, pulseDepth: 0.6
            )
        )
    )

    /// Under Increase Contrast the halo and pulse stay, outside the shape;
    /// at every instant of the pulse the interior is still exactly the glass
    /// without a glow, so text there keeps the legibility rule.
    @Test(arguments: [0.0, 0.4, 0.8])
    func `Under Increase Contrast a pulsing halo leaves the interior exactly the glass without a glow`(effectTime: Double) async throws {
        let presented = GlassAccessibilityPolicy.presentedPanel(
            for: Self.haloing, settings: GlassAccessibilitySettings(), traits: Self.traits(.dark, .high)
        )
        #expect(presented.parameters.glow.hasHalo && presented.parameters.glow.isAnimated)
        var withoutGlow = presented
        withoutGlow.parameters.glow = .none
        let drawn = try await render(presented, effectTime: effectTime)
        let reference = try await render(withoutGlow, effectTime: effectTime)
        let rimExtent = presented.parameters.glow.rimWidth + max(presented.parameters.glow.rimSoftness, 1)
        var interior = 0, differing = 0, haloChanged = 0
        for y in 0..<100 {
            for x in 0..<160 {
                let i = (y * 160 + x) * 4
                let same = drawn[i] == reference[i] && drawn[i + 1] == reference[i + 1] && drawn[i + 2] == reference[i + 2]
                let depth = Self.depth(presented, x: x, y: y)
                if depth > rimExtent + 0.5 {
                    interior += 1
                    if !same { differing += 1 }
                } else if depth < -1, depth > -14, !same {
                    haloChanged += 1
                }
            }
        }
        #expect(interior > 2500)
        #expect(differing == 0)
        #expect(haloChanged > 1000, "The halo is drawn outside the shape")
    }

    /// Under Reduce Transparency nothing is drawn outside the shape: every
    /// pixel beyond the outline is the background, as without a glow.
    @Test func `Under Reduce Transparency no halo is drawn`() async throws {
        let settings = GlassAccessibilitySettings(reduceTransparency: true)
        let presented = GlassAccessibilityPolicy.presentedPanel(for: Self.haloing, settings: settings, traits: Self.traits(.light, .normal))
        var withoutGlow = presented
        withoutGlow.parameters.glow = .none
        let drawn = try await render(presented, effectTime: 0.8)
        let reference = try await render(withoutGlow, effectTime: 0.8)
        var outside = 0, differing = 0
        for y in 0..<100 {
            for x in 0..<160 where Self.depth(presented, x: x, y: y) < -0.5 {
                let i = (y * 160 + x) * 4
                outside += 1
                if drawn[i] != reference[i] || drawn[i + 1] != reference[i + 1] || drawn[i + 2] != reference[i + 2] {
                    differing += 1
                }
            }
        }
        #expect(outside > 10_000)
        #expect(differing == 0)
    }

    // MARK: Interiors (GW-19)

    /// Under Reduce Transparency and Increase Contrast an interior, which
    /// would move behind text, draws nothing: the presented panel renders
    /// the same bytes as without it, at any effect time, so the opaque body
    /// and the legibility rule above still describe what is drawn. Under
    /// normal settings the same interior does change the panel.
    @Test(arguments: [GlassInterior.Effect.energy, .rays, .embers])
    func `Under Reduce Transparency and Increase Contrast an interior draws nothing`(effect: GlassInterior.Effect) async throws {
        var panel = Self.haloing
        panel.parameters.interior = GlassInterior(
            effect: effect,
            colors: [.init(red: 1, green: 0.4, blue: 0.1), .init(red: 1, green: 0.9, blue: 0.5)],
            intensity: 1, seed: 3, centerFade: 0
        )
        var withoutInterior = panel
        withoutInterior.parameters.interior = .none
        let cases: [(GlassAccessibilitySettings, UITraitCollection)] = [
            (GlassAccessibilitySettings(reduceTransparency: true), Self.traits(.light, .normal)),
            (GlassAccessibilitySettings(reduceTransparency: true), Self.traits(.dark, .high)),
            (GlassAccessibilitySettings(), Self.traits(.dark, .high)),
            (GlassAccessibilitySettings(reduceMotion: true), Self.traits(.light, .high)),
        ]
        for (settings, traits) in cases {
            let presented = GlassAccessibilityPolicy.presentedPanel(for: panel, settings: settings, traits: traits)
            let reference = GlassAccessibilityPolicy.presentedPanel(for: withoutInterior, settings: settings, traits: traits)
            let drawn = try await render(presented, effectTime: 2.75)
            let expected = try await render(reference, effectTime: 2.75)
            let differing = zip(drawn, expected).count { $0 != $1 }
            #expect(differing == 0, "\(effect) under \(settings), contrast \(traits.accessibilityContrast.rawValue): \(differing) bytes differ")
        }
        // Control: with normal settings the interior lights the panel.
        let normal = Self.traits(.dark, .normal)
        let lit = try await render(GlassAccessibilityPolicy.presentedPanel(for: panel, settings: GlassAccessibilitySettings(), traits: normal), effectTime: 2.75)
        let unlit = try await render(GlassAccessibilityPolicy.presentedPanel(for: withoutInterior, settings: GlassAccessibilitySettings(), traits: normal), effectTime: 2.75)
        #expect(zip(lit, unlit).count { $0 != $1 } > 200)
    }
}
#endif
