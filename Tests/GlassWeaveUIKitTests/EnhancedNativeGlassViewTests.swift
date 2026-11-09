#if canImport(UIKit)
import MetalKit
import Testing
import UIKit
@testable import GlassWeave
@testable import GlassWeaveUIKit

/// GW-14, enhanced-native mode: genuine Apple glass (`UIGlassEffect`) with a
/// colored rim and halo that Core Animation layers draw around it.
///
/// These tests check the layers the view configures: their geometry against
/// the glass's frame and resolved corners (through layout, animated layout,
/// corner and display-scale changes), their colors and light against the
/// `GlassGlow` color model, the rim's pixels rendered on the CPU with
/// `CALayer.render(in:)` (which draws masks and gradients but not shadows,
/// so the halo's pixels are checked in the laboratory's UI tests), the
/// pulse animation and when it is attached, hit testing, and that nothing
/// here creates a GlassWeave renderer or an `MTKView`.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct EnhancedNativeGlassViewTests {
    /// A pulsing two-color glow with a halo.
    static let energy = GlassGlow(
        colors: [.init(red: 0.25, green: 0.85, blue: 1, angle: 0), .init(red: 0.7, green: 0.35, blue: 1, angle: 180)],
        rimWidth: 2, rimSoftness: 2.5, rimIntensity: 1,
        innerGlowRadius: 22, innerGlowIntensity: 0.75, centerOpacity: 0.2,
        lightAngle: 0, directionality: 0.2,
        haloRadius: 28, haloIntensity: 0.9, pulsePeriod: 1.8, pulseDepth: 0.55
    )

    /// A crisp four-stop gradient rim, evenly lit, without a halo.
    static let aurora = GlassGlow(
        colors: [
            .init(red: 0, green: 1, blue: 1, angle: 0), .init(red: 0.3, green: 0.2, blue: 1, angle: 90),
            .init(red: 1, green: 0.2, blue: 0.5, angle: 180), .init(red: 1, green: 0.9, blue: 0, angle: 270),
        ],
        rimWidth: 3, rimSoftness: 0, rimIntensity: 1, innerGlowIntensity: 0
    )

    /// A glass button in an enhanced-native view, laid out at `size`.
    @MainActor
    final class Fixture {
        let view = EnhancedNativeGlassView(configuration: .init(tintColor: .systemTeal, isInteractive: true))
        let button = UIButton(configuration: .plain())
        private(set) var taps = 0

        init(size: CGSize = CGSize(width: 220, height: 64), scale: CGFloat = 3) {
            view.glass.cornerConfiguration = .capsule()
            view.traitOverrides.displayScale = scale
            view.frame = CGRect(origin: CGPoint(x: 40, y: 50), size: size)
            button.configuration?.title = "Native action"
            button.translatesAutoresizingMaskIntoConstraints = false
            button.addAction(UIAction { [unowned self] _ in taps += 1 }, for: .primaryActionTriggered)
            view.glass.contentView.addSubview(button)
            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: view.glass.contentView.centerXAnchor),
                button.centerYAnchor.constraint(equalTo: view.glass.contentView.centerYAnchor),
            ])
            view.updateTraitsIfNeeded()
            view.layoutIfNeeded()
        }
    }

    // MARK: Geometry

    @Test func `The rim and halo follow the glass's frame and capsule corners`() throws {
        let fixture = Fixture()
        let view = fixture.view
        try view.setGlow(Self.energy)
        view.layoutIfNeeded()
        try expectGeometry(of: view, size: CGSize(width: 220, height: 64), radius: 32, haloRadius: 28)

        // A new size: the capsule's radius follows the new height.
        view.frame.size = CGSize(width: 300, height: 90)
        view.layoutIfNeeded()
        try expectGeometry(of: view, size: CGSize(width: 300, height: 90), radius: 45, haloRadius: 28)
    }

    @Test func `A new corner configuration on the glass reshapes the rim and halo`() throws {
        let fixture = Fixture()
        let view = fixture.view
        try view.setGlow(Self.energy)
        view.layoutIfNeeded()
        // Only the glass changes; the view is not told. Reading the radii in
        // layoutSubviews makes UIKit lay it out again.
        view.glass.cornerConfiguration = .corners(radius: .fixed(12))
        view.layoutIfNeeded()
        try expectGeometry(of: view, size: CGSize(width: 220, height: 64), radius: 12, haloRadius: 28)

        view.glass.cornerConfiguration = .corners(
            topLeftRadius: .fixed(4), topRightRadius: .fixed(20), bottomLeftRadius: .fixed(10), bottomRightRadius: nil
        )
        view.layoutIfNeeded()
        #expect(view.layout.radii == .init(topLeft: 4, topRight: 20, bottomRight: 0, bottomLeft: 10))
        let expected = NativeGlowLayout.roundedRect(
            CGRect(x: 0, y: 0, width: 220, height: 64),
            radii: .init(topLeft: 4, topRight: 20, bottomRight: 0, bottomLeft: 10)
        )
        #expect(view.rimClipMask.path == expected)
    }

    @Test func `An animated frame change animates the glow with the glass's own timing`() throws {
        let fixture = Fixture()
        let view = fixture.view
        try view.setGlow(Self.energy)
        view.layoutIfNeeded()
        UIView.animate(withDuration: 0.4, delay: 0, options: [.curveEaseInOut]) {
            view.frame = CGRect(x: 10, y: 20, width: 320, height: 100)
            view.layoutIfNeeded()
        }
        let template = try #require(view.glass.layer.animation(forKey: "bounds.size"))
        let prefix = EnhancedNativeGlassView.layoutAnimationKeyPrefix
        let animated: [(CALayer, String)] = [
            (view.rimLayer, "bounds"), (view.rimClipMask, "path"), (view.rimBandMask, "path"),
            (view.rimBandMask, "shadowPath"), (view.haloLayer, "bounds"), (view.haloLayer, "position"),
            (view.haloHoleMask, "path"), (view.haloShadowMask, "shadowPath"), (view.haloGradient, "bounds"),
        ]
        for (layer, keyPath) in animated {
            let animation = try #require(layer.animation(forKey: prefix + keyPath), "\(keyPath) of \(layer) is not animated")
            #expect(animation.duration == template.duration)
            #expect(animation.beginTime == template.beginTime)
            #expect(animation.timingFunction == template.timingFunction)
        }
        // The model values are already the final ones.
        try expectGeometry(of: view, size: CGSize(width: 320, height: 100), radius: 50, haloRadius: 28)

        // Without an animation the glow snaps with the glass.
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 50)
        view.layoutIfNeeded()
        try expectGeometry(of: view, size: CGSize(width: 200, height: 50), radius: 25, haloRadius: 28)
    }

    @Test func `The layers render at the display scale and follow its changes`() throws {
        let fixture = Fixture(scale: 2)
        let view = fixture.view
        try view.setGlow(Self.energy)
        view.layoutIfNeeded()
        #expect(view.glowLayers.allSatisfy { $0.contentsScale == 2 })
        #expect(view.layout.displayScale == 2)
        view.traitOverrides.displayScale = 3
        view.updateTraitsIfNeeded()
        #expect(view.glowLayers.allSatisfy { $0.contentsScale == 3 })
        // The halo stops one pixel inside the outline, at the new scale.
        let hole = try #require(view.haloHoleMask.path)
        let extent = try #require(view.layout.halo).extent
        #expect(hole.contains(CGPoint(x: extent + 0.5 / 3 + 0.01, y: extent + 32), using: .winding))
        #expect(!hole.contains(CGPoint(x: extent + 1 / 3 + 0.05, y: extent + 32), using: .winding))
    }

    /// The layer tree draws the presented glow at the glass's frame.
    private func expectGeometry(
        of view: EnhancedNativeGlassView, size: CGSize, radius: CGFloat, haloRadius: Double,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let frame = view.glass.frame
        #expect(frame.size == size, sourceLocation: sourceLocation)
        #expect(view.layout.radii == .init(topLeft: radius, topRight: radius, bottomRight: radius, bottomLeft: radius), sourceLocation: sourceLocation)
        let outline = NativeGlowLayout.roundedRect(CGRect(origin: .zero, size: size), radii: view.layout.radii)
        #expect(view.rimLayer.frame == frame, sourceLocation: sourceLocation)
        #expect(view.rimGradient.frame == CGRect(origin: .zero, size: size), sourceLocation: sourceLocation)
        #expect(view.rimClipMask.path == outline, sourceLocation: sourceLocation)
        let halo = try #require(view.layout.halo, sourceLocation: sourceLocation)
        let outset = CGFloat(haloRadius * NativeGlowLayout.haloOutsetFraction)
        let sigma = CGFloat(haloRadius * NativeGlowLayout.haloSigmaFraction)
        #expect(halo.extent == (outset + 4 * sigma + 1).rounded(.up), sourceLocation: sourceLocation)
        #expect(view.haloLayer.frame == frame.insetBy(dx: -halo.extent, dy: -halo.extent), sourceLocation: sourceLocation)
        #expect(view.haloGradient.frame == CGRect(origin: .zero, size: view.haloLayer.bounds.size), sourceLocation: sourceLocation)
        let shadowBox = try #require(view.haloShadowMask.shadowPath, sourceLocation: sourceLocation).boundingBoxOfPath
        let expectedBox = CGRect(x: halo.extent, y: halo.extent, width: size.width, height: size.height).insetBy(dx: -outset, dy: -outset)
        #expect(abs(shadowBox.minX - expectedBox.minX) < 1e-9 && abs(shadowBox.maxY - expectedBox.maxY) < 1e-9, sourceLocation: sourceLocation)
        #expect(view.haloShadowMask.shadowRadius == sigma, sourceLocation: sourceLocation)
        #expect(!view.haloLayer.isHidden && !view.rimLayer.isHidden, sourceLocation: sourceLocation)
        // The halo's mask removes it from the whole interior: the middle and
        // a point just inside the outline, but not just outside it.
        let hole = try #require(view.haloHoleMask.path, sourceLocation: sourceLocation)
        let center = CGPoint(x: halo.extent + size.width / 2, y: halo.extent + size.height / 2)
        #expect(!hole.contains(center, using: .winding), sourceLocation: sourceLocation)
        #expect(!hole.contains(CGPoint(x: center.x, y: halo.extent + 1), using: .winding), sourceLocation: sourceLocation)
        #expect(hole.contains(CGPoint(x: center.x, y: halo.extent - 0.5), using: .winding), sourceLocation: sourceLocation)
    }

    // MARK: Colors and light

    @Test func `A solid color rim and halo carry the color and their intensities`() throws {
        let fixture = Fixture()
        let view = fixture.view
        let orange = GlassGlow.ColorStop(red: 1, green: 0.55, blue: 0.1)
        try view.setGlow(GlassGlow(colors: [orange], rimWidth: 2, rimIntensity: 0.8, haloRadius: 20, haloIntensity: 0.6))
        let rim = try #require(view.layout.rim).gradient
        let halo = try #require(view.layout.halo).gradient
        for color in rim.colors {
            #expect(abs(color.x - 1) < 1e-9 && abs(color.y - 0.55) < 1e-9 && abs(color.z - 0.1) < 1e-9)
            #expect(abs(color.w - 0.8) < 1e-12)
        }
        #expect(halo.colors.allSatisfy { abs($0.w - 0.6) < 1e-12 && abs($0.y - 0.55) < 1e-9 })
        #expect(view.rimGradient.colors?.count == rim.colors.count)
        #expect(view.rimGradient.type == .conic)
        #expect(view.rimGradient.startPoint == CGPoint(x: 0.5, y: 0.5) && view.rimGradient.endPoint == CGPoint(x: 0.5, y: 0))
        // The gradient's colors are sRGB.
        let first = try #require((view.rimGradient.colors as? [CGColor])?.first)
        #expect(first.colorSpace?.name == CGColorSpace.sRGB)
    }

    @Test func `Each stop of a four-stop gradient shows on the rim at its angle, and the middle stays clear`() throws {
        let fixture = Fixture(size: CGSize(width: 160, height: 100), scale: 2)
        let view = fixture.view
        view.glass.cornerConfiguration = .corners(radius: .fixed(20))
        try view.setGlow(Self.aurora)
        view.layoutIfNeeded()
        let pixels = render(view.rimLayer, size: CGSize(width: 160, height: 100), scale: 2)
        // One point inside the outline at each stop's angle.
        let probes: [(CGPoint, GlassGlow.ColorStop)] = [
            (CGPoint(x: 80, y: 1), Self.aurora.colors[0]),
            (CGPoint(x: 159, y: 50), Self.aurora.colors[1]),
            (CGPoint(x: 80, y: 99), Self.aurora.colors[2]),
            (CGPoint(x: 1, y: 50), Self.aurora.colors[3]),
        ]
        for (point, stop) in probes {
            let sample = pixels.rgba(atPoint: point)
            let expected = [stop.red, stop.green, stop.blue].map { Int(($0 * 255).rounded()) }
            // Core Animation's gradient rendering lands within a few 8-bit
            // steps of the exact color (it measured within 3).
            #expect(sample.alpha >= 251, "\(point)")
            #expect(zip([sample.red, sample.green, sample.blue], expected).allSatisfy { abs($0 - $1) <= 4 }, "\(point): \(sample) expected \(expected)")
        }
        // Between two stops the color is their mix in linear light, at the
        // pixel's angle (the panel scaled to a square).
        let arc = CGFloat.pi / 4
        let cornerPoint = CGPoint(x: 140 + 20 * cos(arc) - 1, y: 20 - 20 * sin(arc) + 1)
        let corner = pixels.rgba(atPoint: cornerPoint)
        let centerX = (Double(floor(cornerPoint.x * 2)) + 0.5) / 2
        let centerY = (Double(floor(cornerPoint.y * 2)) + 0.5) / 2
        let cornerTurn = NativeGlowLayout.turn(ofDirection: SIMD2((centerX - 80) / 80, (centerY - 50) / 50))
        let linear = GlowColorModel.color(
            atTurn: cornerTurn,
            colorsLinear: GlowColorModel.linearStops(of: try Self.aurora.normalized(maximumLength: 50)).colors,
            stopTurns: [0, 0.25, 0.5, 0.75]
        )
        let mixed = [linear.x, linear.y, linear.z].map { Int((GlowColorModel.encodeSRGB($0) * 255).rounded()) }
        #expect(abs(corner.red - mixed[0]) <= 6 && abs(corner.green - mixed[1]) <= 6 && abs(corner.blue - mixed[2]) <= 6, "\(corner) expected \(mixed)")
        // Deeper than the rim nothing is drawn: the glass's middle and the
        // band's inner edge are untouched.
        for point in [CGPoint(x: 80, y: 50), CGPoint(x: 80, y: 4.5), CGPoint(x: 30, y: 50)] {
            #expect(pixels.rgba(atPoint: point).alpha == 0, "\(point)")
        }
        // Outside the outline the rim draws nothing.
        #expect(pixels.rgba(atPoint: CGPoint(x: 1, y: 1)).alpha == 0)
    }

    @Test func `A soft rim is opaque to its width, and a shadow softens its edges`() throws {
        let fixture = Fixture(size: CGSize(width: 160, height: 100), scale: 2)
        let view = fixture.view
        view.glass.cornerConfiguration = .corners(radius: .fixed(20))
        var glow = Self.aurora
        glow.rimWidth = 3
        glow.rimSoftness = 4
        try view.setGlow(glow)
        view.layoutIfNeeded()
        let rim = try #require(view.layout.rim)
        let bounds = CGRect(x: 0, y: 0, width: 160, height: 100)
        let radii = view.layout.radii
        #expect(rim.bandPath == NativeGlowLayout.band(in: bounds, radii: radii, from: 0, to: 3))
        #expect(rim.softBandPath == NativeGlowLayout.band(in: bounds, radii: radii, from: -2, to: 5))
        #expect(rim.softnessRadius == 1)
        #expect(view.rimBandMask.path == rim.bandPath)
        #expect(view.rimBandMask.shadowPath == rim.softBandPath)
        #expect(view.rimBandMask.shadowOpacity == 1 && view.rimBandMask.shadowRadius == 1)
        #expect(view.rimBandMask.fillColor != nil)
        // The CPU renderer draws the crisp band (not the shadow): opaque to
        // the rim width, nothing beyond it; the compositor adds the soft
        // edge (checked in the laboratory's UI tests).
        let pixels = render(view.rimLayer, size: bounds.size, scale: 2)
        #expect(pixels.rgba(atPoint: CGPoint(x: 80, y: 0.5)).alpha >= 251)
        #expect(pixels.rgba(atPoint: CGPoint(x: 80, y: 2.5)).alpha >= 251)
        // 1.5 points past the band (the CPU renderer's masks bleed about a
        // pixel; the shadow, were it drawn, would be about 69 % here).
        #expect(pixels.rgba(atPoint: CGPoint(x: 80, y: 4.5)).alpha == 0)
        // The band paths contain what they should.
        #expect(rim.softBandPath.contains(CGPoint(x: 80, y: 4.5), using: .winding))
        #expect(!rim.softBandPath.contains(CGPoint(x: 80, y: 5.5), using: .winding))
        #expect(!rim.bandPath.contains(CGPoint(x: 80, y: 50), using: .winding))
    }

    @Test(arguments: [
        (CGSize(width: 300, height: 60), NativeGlowLayout.CornerRadii(topLeft: 30, topRight: 30, bottomRight: 30, bottomLeft: 30)),
        (CGSize(width: 160, height: 100), NativeGlowLayout.CornerRadii(topLeft: 20, topRight: 20, bottomRight: 20, bottomLeft: 20)),
        (CGSize(width: 120, height: 120), NativeGlowLayout.CornerRadii(topLeft: 60, topRight: 60, bottomRight: 60, bottomLeft: 60)),
        (CGSize(width: 220, height: 64), NativeGlowLayout.CornerRadii(topLeft: 4, topRight: 20, bottomRight: 0, bottomLeft: 10)),
    ])
    func `The point each ray takes its light from lies on the outline`(size: CGSize, radii: NativeGlowLayout.CornerRadii) {
        let halfSize = SIMD2(Double(size.width), Double(size.height)) / 2
        for step in 0..<720 {
            let turn = Double(step) / 720
            let point = NativeGlowLayout.outlinePoint(atTurn: turn, halfSize: halfSize, radii: radii)
            let distance = NativeGlowLayout.signedDistance(at: point, halfSize: halfSize, radii: radii)
            #expect(abs(distance) < 1e-9, "turn \(turn): \(point) is \(distance) from the outline")
            // On the ray: the same angle in the panel's square.
            let back = NativeGlowLayout.turn(ofDirection: point / halfSize)
            #expect(abs(back - turn) < 1e-9 || abs(abs(back - turn) - 1) < 1e-9, "turn \(turn) came back as \(back)")
        }
    }

    @Test func `The light uses the outline's own normal, as in custom mode`() throws {
        let fixture = Fixture(size: CGSize(width: 300, height: 60))
        let view = fixture.view
        try view.setGlow(GlassGlow(
            colors: [.init(red: 1, green: 0.5, blue: 0.2)], rimWidth: 2, rimIntensity: 1,
            lightAngle: 0, directionality: 1, haloRadius: 16, haloIntensity: 1
        ))
        let layout = view.layout
        let rim = try #require(layout.rim).gradient
        func alpha(atTurn turn: Double) -> Double {
            let index = rim.locations.firstIndex { $0 >= turn - 1e-12 }!
            return rim.colors[index].w
        }
        // The flat top edge faces the light fully, also 18° off the axis;
        // the capsule's ends face sideways (a quarter), the bottom gets none.
        #expect(abs(alpha(atTurn: 0) - 1) < 1e-9)
        #expect(abs(alpha(atTurn: 0.05) - 1) < 1e-9)
        #expect(abs(alpha(atTurn: 0.25) - 0.25) < 1e-6)
        #expect(abs(alpha(atTurn: 0.5)) < 1e-9)
        // Light from the right reverses the ends.
        try view.setGlow(GlassGlow(
            colors: [.init(red: 1, green: 0.5, blue: 0.2)], rimWidth: 2, lightAngle: 90, directionality: 1
        ))
        let right = try #require(view.layout.rim).gradient
        #expect(abs(right.colors[right.locations.firstIndex { $0 >= 0.25 - 1e-12 }!].w - 1) < 1e-9)
        #expect(abs(right.colors[right.locations.firstIndex { $0 >= 0.75 - 1e-12 }!].w) < 1e-9)
    }

    @Test func `The halo's gradient shows the rim's colors on every ray, though its layer is larger`() throws {
        let fixture = Fixture(size: CGSize(width: 240, height: 60))
        let view = fixture.view
        try view.setGlow(GlassGlow(
            colors: [.init(red: 1, green: 0, blue: 0, angle: 0), .init(red: 0, green: 0, blue: 1, angle: 90)],
            rimWidth: 2, haloRadius: 30, haloIntensity: 1
        ))
        let layout = view.layout
        let halo = try #require(layout.halo)
        // The stop at 90° stays on the axis; the panel's corner direction
        // (1/8 turn in the panel's square) lands on the same ray of the
        // larger halo layer.
        let blueIndex = try #require(halo.gradient.locations.firstIndex { abs($0 - 0.25) < 1e-9 })
        #expect(abs(halo.gradient.colors[blueIndex].z - 1) < 1e-9)
        let grown = SIMD2(120 + Double(halo.extent), 30 + Double(halo.extent))
        let cornerLocation = NativeGlowLayout.turn(ofDirection: SIMD2(120, -30) / grown)
        // The halo layer's square is relatively taller than the panel's, so
        // the corner's ray sits further round in it.
        #expect(cornerLocation > 0.15)
        // The first sample at or past the corner's ray is the same panel
        // angle in both gradients, so the same color.
        let rim = try #require(layout.rim).gradient
        let rimCorner = rim.colors[try #require(rim.locations.firstIndex { $0 >= 0.125 - 1e-9 })]
        let haloCorner = halo.gradient.colors[try #require(halo.gradient.locations.firstIndex { $0 >= cornerLocation - 1e-9 })]
        #expect(abs(haloCorner.x - rimCorner.x) < 1e-9 && abs(haloCorner.z - rimCorner.z) < 1e-9, "\(haloCorner) vs \(rimCorner)")
        #expect(halo.gradient.locations == halo.gradient.locations.sorted())
    }

    @Test func `The glass keeps its own material and tint`() throws {
        let fixture = Fixture()
        let view = fixture.view
        try view.setGlow(Self.energy)
        view.layoutIfNeeded()
        let effect = try #require(view.glass.effect as? UIGlassEffect)
        #expect(effect.tintColor == .systemTeal)
        #expect(effect.isInteractive)
        #expect(view.glass.configuration == NativeGlassView.Configuration(tintColor: .systemTeal, isInteractive: true))
        // The rim is above the glass, the halo below it; both are layers of
        // this view, not of the glass, so the glass's material is untouched.
        let sublayers = try #require(view.layer.sublayers)
        let glassIndex = try #require(sublayers.firstIndex { $0 === view.glass.layer })
        #expect(sublayers.firstIndex { $0 === view.haloLayer }! < glassIndex)
        #expect(sublayers.firstIndex { $0 === view.rimLayer }! > glassIndex)
        #expect(view.glass.layer.sublayers?.contains { $0 === view.rimLayer || $0 === view.haloLayer } != true)
        #expect(!view.clipsToBounds)
    }

    // MARK: Interaction and structure

    @Test func `Touches reach the native button and pass through the halo`() throws {
        let fixture = Fixture()
        let view = fixture.view
        try view.setGlow(Self.energy)
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let behind = UIButton(configuration: .plain())
        behind.frame = CGRect(x: 0, y: 0, width: 400, height: 48)
        parent.addSubview(behind)
        parent.addSubview(view)
        parent.layoutIfNeeded()
        fixture.button.layoutIfNeeded()

        let buttonCenter = fixture.button.convert(CGPoint(x: fixture.button.bounds.midX, y: fixture.button.bounds.midY), to: parent)
        #expect(parent.hitTest(buttonCenter, with: nil) === fixture.button)
        fixture.button.sendActions(for: .primaryActionTriggered)
        #expect(fixture.taps == 1)
        // A point in the halo above the glass (inside the halo layer's frame,
        // outside the view's bounds) reaches the button behind it.
        let inHalo = CGPoint(x: view.frame.midX, y: view.frame.minY - 10)
        #expect(view.haloLayer.frame.offsetBy(dx: view.frame.minX, dy: view.frame.minY).contains(inHalo))
        #expect(parent.hitTest(inHalo, with: nil) === behind)
        // The glow adds layers, never views or accessibility elements.
        #expect(view.subviews == [view.glass])
        #expect(!view.isAccessibilityElement)
        #expect(view.accessibilityElementsHidden == false)
    }

    @Test func `Enhanced-native mode creates no renderer, Metal view, or display loop`() throws {
        let (fixture, created) = try RendererCensus.counting {
            let fixture = Fixture()
            fixture.view.sceneStateOverride = .foregroundActive
            try fixture.view.setGlow(Self.energy)
            fixture.view.frame.size = CGSize(width: 260, height: 70)
            fixture.view.layoutIfNeeded()
            fixture.view.glass.configuration.tintColor = .systemPink
            fixture.button.sendActions(for: .primaryActionTriggered)
            return fixture
        }
        #expect(created == 0)
        #expect(fixture.taps == 1)
        #expect(fixture.view.isAnimating)
        #expect(!Self.subtree(of: fixture.view).contains { $0 is MTKView || $0 is GlassSurfaceView })
        // Only Core Animation layers and animations: no layer is a Metal layer.
        #expect(!fixture.view.glowLayers.contains { $0 is CAMetalLayer })
    }

    private static func subtree(of view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(subtree(of:))
    }

    // MARK: Pulse and accessibility

    @Test func `A visible pulsing glow runs one opacity animation with the documented level`() throws {
        let fixture = Fixture()
        let view = fixture.view
        view.sceneStateOverride = .foregroundActive
        try view.setGlow(Self.energy)
        #expect(view.isAnimating)
        for layer in [view.rimLayer, view.haloLayer] {
            let pulse = try #require(layer.animation(forKey: EnhancedNativeGlassView.pulseAnimationKey) as? CABasicAnimation)
            #expect(pulse.keyPath == "opacity")
            #expect(pulse.fromValue as? Double == 1)
            #expect(abs((pulse.toValue as? Double ?? 0) - (1 - 0.55)) < 1e-12)
            #expect(pulse.duration == 0.9)
            #expect(pulse.autoreverses)
            #expect(pulse.repeatCount == .infinity)
            #expect(Self.controlPoints(of: try #require(pulse.timingFunction)) == [0.37, 0, 0.63, 1])
        }
        // The eased half cycle follows (1 − cos πx) / 2 closely, so the level
        // is custom mode's pulseLevel(at:) within half a percent.
        let curve = CAMediaTimingFunction(controlPoints: 0.37, 0, 0.63, 1)
        for x in stride(from: 0.0, through: 1.0, by: 0.05) {
            let eased = Self.evaluate(curve, at: x)
            #expect(abs(eased - (1 - cos(.pi * x)) / 2) < 0.005, "x \(x): \(eased)")
        }
        // The model opacity stays 1; the steady parts are unchanged.
        #expect(view.rimLayer.opacity == 1 && view.haloLayer.opacity == 1)
    }

    @Test func `A settled, hidden, or backgrounded glow runs no animation`() throws {
        let fixture = Fixture()
        let view = fixture.view
        view.sceneStateOverride = .foregroundActive
        try view.setGlow(Self.energy)
        #expect(view.isAnimating)

        var steady = Self.energy
        steady.pulseDepth = 0
        try view.setGlow(steady)
        expectNoAnimations(view)

        try view.setGlow(Self.energy)
        #expect(view.isAnimating)
        view.isHidden = true
        expectNoAnimations(view)
        view.isHidden = false
        #expect(view.isAnimating)

        view.sceneStateOverride = .background
        expectNoAnimations(view)
        view.sceneStateOverride = .foregroundInactive
        #expect(view.isAnimating)
        view.sceneStateOverride = nil // no window
        expectNoAnimations(view)
        view.sceneStateOverride = .foregroundActive

        view.alpha = 0
        expectNoAnimations(view)
        view.alpha = 1
        try view.setGlow(.none)
        expectNoAnimations(view)
        #expect(view.rimLayer.isHidden && view.haloLayer.isHidden)
    }

    @Test func `The pulse resumes where it stopped`() async throws {
        let fixture = Fixture()
        let view = fixture.view
        view.sceneStateOverride = .foregroundActive
        try view.setGlow(Self.energy)
        let first = try #require(view.rimLayer.animation(forKey: EnhancedNativeGlassView.pulseAnimationKey))
        #expect(first.timeOffset == 0)
        try await Task.sleep(for: .milliseconds(300))
        view.isHidden = true
        try await Task.sleep(for: .milliseconds(300))
        view.isHidden = false
        let resumed = try #require(view.rimLayer.animation(forKey: EnhancedNativeGlassView.pulseAnimationKey))
        // About 0.3 s into the 1.8 s cycle, not the hidden time on top.
        #expect(resumed.timeOffset > 0.25 && resumed.timeOffset < 0.55, "\(resumed.timeOffset)")
        #expect(view.haloLayer.animation(forKey: EnhancedNativeGlassView.pulseAnimationKey)?.timeOffset == resumed.timeOffset)
    }

    @Test func `Reduce Motion holds the rim and halo at the pulse's mean level without animation`() throws {
        let fixture = Fixture()
        let view = fixture.view
        view.sceneStateOverride = .foregroundActive
        try view.setGlow(Self.energy)
        #expect(view.isAnimating)
        view.accessibilitySettingsSource = .fixed(GlassAccessibilitySettings(reduceMotion: true))
        expectNoAnimations(view)
        let mean = 1 - 0.55 / 2
        #expect(view.presentedGlow.pulseDepth == 0)
        #expect(abs(view.presentedGlow.haloIntensity - 0.9 * mean) < 1e-12)
        #expect(abs(view.presentedGlow.rimIntensity - mean) < 1e-12)
        let halo = try #require(view.layout.halo).gradient
        #expect(halo.colors.allSatisfy { $0.w <= 0.9 * mean + 1e-12 })
        #expect(!view.haloLayer.isHidden)
        view.accessibilitySettingsSource = .fixed(GlassAccessibilitySettings())
        #expect(view.isAnimating)
    }

    @Test func `Reduce Transparency keeps a thin crisp rim; Increase Contrast keeps the halo, evenly lit`() throws {
        let fixture = Fixture()
        let view = fixture.view
        view.sceneStateOverride = .foregroundActive
        try view.setGlow(Self.energy)
        view.accessibilitySettingsSource = .fixed(GlassAccessibilitySettings(reduceTransparency: true))
        let reduced = view.presentedGlow
        #expect(reduced.rimWidth == GlassAccessibilityPolicy.reducedTransparencyRimWidth)
        #expect(reduced.rimSoftness == 0 && reduced.directionality == 0)
        #expect(reduced.haloRadius == 0 && reduced.pulseDepth == 0)
        #expect(view.haloLayer.isHidden && !view.rimLayer.isHidden)
        #expect(try #require(view.layout.rim).softnessRadius == 0)
        #expect(view.rimBandMask.shadowOpacity == 0)
        expectNoAnimations(view)

        view.accessibilitySettingsSource = .fixed(GlassAccessibilitySettings())
        view.traitOverrides.accessibilityContrast = .high
        view.updateTraitsIfNeeded()
        let contrast = view.presentedGlow
        #expect(contrast.directionality == 0 && contrast.haloRadius == 28 && contrast.pulseDepth == 0.55)
        #expect(!view.haloLayer.isHidden)
        #expect(view.isAnimating)
        #expect(try #require(view.layout.rim).gradient.colors.allSatisfy { abs($0.w - 1) < 1e-12 })
    }

    private func expectNoAnimations(_ view: EnhancedNativeGlassView, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!view.isAnimating, sourceLocation: sourceLocation)
        for layer in view.glowLayers {
            #expect(layer.animationKeys() == nil, "\(layer) has \(layer.animationKeys() ?? [])", sourceLocation: sourceLocation)
        }
    }

    // MARK: Cost

    /// The CPU cost the glow adds to a layout pass that changes the size
    /// (paths, gradients with their light, layer updates), on the simulator
    /// in a Debug build, recorded in the evidence: the same 120 resizes with
    /// the glow and without one (the glass's own layout). It is paid once per
    /// change of size, corners, scale, settings, or glow, never per frame; a
    /// layout pass that changes none of them skips it.
    @Test func `The glow adds under a millisecond to a resizing layout pass`() throws {
        func medianResize(glow: GlassGlow) throws -> (median: Duration, p95: Duration) {
            let fixture = Fixture()
            let view = fixture.view
            view.sceneStateOverride = .foregroundActive
            try view.setGlow(glow)
            view.layoutIfNeeded()
            var samples: [Duration] = []
            let clock = ContinuousClock()
            for index in 0..<120 {
                let size = CGSize(width: 200 + Double(index % 7) * 13, height: 56 + Double(index % 5) * 6)
                samples.append(clock.measure {
                    view.frame.size = size
                    view.layoutIfNeeded()
                })
                #expect(view.layout.size == size)
            }
            samples.sort()
            return (samples[samples.count / 2], samples[samples.count * 95 / 100])
        }
        // Alternate, so neither runs on a colder process.
        let plain1 = try medianResize(glow: .none), glowing1 = try medianResize(glow: Self.energy)
        let plain2 = try medianResize(glow: .none), glowing2 = try medianResize(glow: Self.energy)
        let plain = min(plain1.median, plain2.median), glowing = min(glowing1.median, glowing2.median)
        print("Enhanced-native layout per resize (Debug, simulator): without a glow median \(plain1.median)/\(plain2.median) p95 \(plain1.p95)/\(plain2.p95); with the energy glow median \(glowing1.median)/\(glowing2.median) p95 \(glowing1.p95)/\(glowing2.p95)")
        #expect(glowing - plain < .milliseconds(1), "added \(glowing - plain)")

        // A layout pass that changes nothing rebuilds nothing.
        let fixture = Fixture()
        try fixture.view.setGlow(Self.energy)
        fixture.view.layoutIfNeeded()
        let builds = fixture.view.layoutBuilds
        fixture.view.setNeedsLayout()
        fixture.view.layoutIfNeeded()
        #expect(fixture.view.layoutBuilds == builds)
        fixture.view.frame.size.width += 10
        fixture.view.layoutIfNeeded()
        #expect(fixture.view.layoutBuilds == builds + 1)
    }

    // MARK: Normalization

    @Test func `The glow follows the normalization rule and reports what is drawn`() throws {
        let fixture = Fixture()
        let view = fixture.view
        try view.setGlow(Self.energy)
        var invalid = Self.energy
        invalid.rimWidth = .nan
        #expect(throws: GlassParameterError.nonFinite(.glowRimWidth)) { try view.setGlow(invalid) }
        invalid = Self.energy
        invalid.colors[1].blue = .infinity
        #expect(throws: GlassParameterError.nonFinite(.glowColorBlue)) { try view.setGlow(invalid) }
        #expect(view.glow == (try Self.energy.normalized(maximumLength: .infinity)))

        var wide = Self.energy
        wide.rimWidth = 100
        wide.rimIntensity = 3
        wide.haloRadius = 500
        wide.colors[0].angle = -90
        try view.setGlow(wide)
        #expect(view.glow.rimWidth == 100)
        #expect(view.glow.rimIntensity == 1)
        #expect(view.glow.haloRadius == GlassGlow.maximumHaloRadius)
        #expect(view.glow.colors.map(\.angle) == [180, 270])
        // Drawn: the rim limited by the 64-point height, no inner glow or
        // center fill (Apple's material owns the inside).
        let drawn = view.presentedGlow
        #expect(drawn.rimWidth == 32)
        #expect(drawn.innerGlowIntensity == 0 && drawn.innerGlowRadius == 0 && drawn.centerOpacity == 0)
        #expect(view.layout.glow == drawn)
    }

    // MARK: Helpers

    private static func controlPoints(of curve: CAMediaTimingFunction) -> [Float] {
        var c1: [Float] = [0, 0], c2: [Float] = [0, 0]
        curve.getControlPoint(at: 1, values: &c1)
        curve.getControlPoint(at: 2, values: &c2)
        return c1 + c2
    }

    /// `curve`'s output at input `x`, by bisection on its Bézier.
    private static func evaluate(_ curve: CAMediaTimingFunction, at x: Double) -> Double {
        var c1: [Float] = [0, 0], c2: [Float] = [0, 0]
        curve.getControlPoint(at: 1, values: &c1)
        curve.getControlPoint(at: 2, values: &c2)
        func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t
        }
        var low = 0.0, high = 1.0
        for _ in 0..<60 {
            let middle = (low + high) / 2
            if bezier(middle, Double(c1[0]), Double(c2[0])) < x { low = middle } else { high = middle }
        }
        return bezier((low + high) / 2, Double(c1[1]), Double(c2[1]))
    }

    struct Pixels {
        let width: Int
        let height: Int
        let scale: CGFloat
        let bytes: [UInt8]

        /// Premultiplied sRGB bytes of the pixel containing `point`, with the
        /// color unpremultiplied.
        func rgba(atPoint point: CGPoint) -> (red: Int, green: Int, blue: Int, alpha: Int) {
            let x = min(max(Int(point.x * scale), 0), width - 1)
            let y = min(max(Int(point.y * scale), 0), height - 1)
            let index = (y * width + x) * 4
            let alpha = Int(bytes[index + 3])
            let unpremultiply = { (value: UInt8) in alpha == 0 ? 0 : Int((Double(value) * 255 / Double(alpha)).rounded()) }
            return (unpremultiply(bytes[index]), unpremultiply(bytes[index + 1]), unpremultiply(bytes[index + 2]), alpha)
        }
    }

    /// Renders `layer` (with its masks and gradients; Core Animation's CPU
    /// renderer draws no shadows) into sRGB memory at `scale`.
    private func render(_ layer: CALayer, size: CGSize, scale: CGFloat) -> Pixels {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            layer.render(in: context)
        }
        return Pixels(width: width, height: height, scale: scale, bytes: bytes)
    }
}
#endif
