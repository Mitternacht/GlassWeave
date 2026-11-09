#if canImport(UIKit)
import Metal
import Testing
import UIKit
@testable import GlassWeave
@testable import GlassWeaveUIKit

/// What the surface does for assistive technologies and accessibility
/// settings: no accessibility elements of its own, an opaque legible panel
/// under Reduce Transparency, and settings that tests can fix.
@MainActor
struct AccessibilityPolicyTests {
    let device: any MTLDevice
    let queue: any MTLCommandQueue

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        queue = try #require(device.makeCommandQueue())
    }

    private static let glass = GlassPanel(
        frame: CGRect(x: 10, y: 20, width: 200, height: 120),
        parameters: GlassParameters(
            cornerRadius: 30, bezelWidth: 22, refraction: 0.85, edgeHighlight: 0.6,
            tint: GlassTint(red: 0.97, green: 0.98, blue: 1, strength: 0.45)
        )
    )

    private static func traits(_ style: UIUserInterfaceStyle, _ contrast: UIAccessibilityContrast) -> UITraitCollection {
        UITraitCollection { traits in
            traits.userInterfaceStyle = style
            traits.accessibilityContrast = contrast
        }
    }

    /// The accessibility elements VoiceOver would find in `view`'s subtree,
    /// in order: a view that is an element ends the walk; hidden views and
    /// views whose elements are hidden contribute nothing.
    private func accessibilityElements(in view: UIView) -> [UIView] {
        guard !view.isHidden, view.alpha > 0.01, !view.accessibilityElementsHidden else { return [] }
        if view.isAccessibilityElement { return [view] }
        return view.subviews.flatMap { accessibilityElements(in: $0) }
    }

    @Test func `Reduce Transparency draws an opaque surface with the same shape`() {
        let traits = Self.traits(.light, .normal)
        let presented = GlassAccessibilityPolicy.presentedPanel(
            for: Self.glass, settings: GlassAccessibilitySettings(reduceTransparency: true), traits: traits
        )
        #expect(presented.frame == Self.glass.frame)
        #expect(presented.parameters.cornerRadius == Self.glass.parameters.cornerRadius)
        #expect(presented.parameters.bezelWidth == Self.glass.parameters.bezelWidth)
        #expect(presented.parameters.refraction == 0)
        #expect(presented.parameters.edgeHighlight == 0)
        #expect(presented.parameters.tint == GlassAccessibilityPolicy.opaqueSurfaceTint(for: traits))
        #expect(presented.parameters.tint.strength == 1)
        // Reduce Motion alone changes nothing in the panel.
        let unchanged = GlassAccessibilityPolicy.presentedPanel(
            for: Self.glass, settings: GlassAccessibilitySettings(reduceMotion: true), traits: traits
        )
        #expect(unchanged == Self.glass)
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark], [UIAccessibilityContrast.normal, .high])
    func `Label text on the opaque surface exceeds 7 to 1`(style: UIUserInterfaceStyle, contrast: UIAccessibilityContrast) {
        let traits = Self.traits(style, contrast)
        let tint = GlassAccessibilityPolicy.opaqueSurfaceTint(for: traits)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor.label.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let label = GlassTint.relativeLuminance(red: Double(red), green: Double(green), blue: Double(blue))
        // Opaque: the interior luminance is the tint's, whatever the background.
        #expect(tint.interiorLuminanceRange.lowerBound == tint.interiorLuminanceRange.upperBound)
        #expect(tint.worstCaseContrast(againstTextLuminance: label) >= 7)
        // The color follows the appearance.
        #expect((tint.relativeLuminance > 0.5) == (style == .light))
    }

    @Test func `The surface applies fixed settings, follows traits, and reports changes`() throws {
        let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
        surface.sceneStateOverride = .foregroundActive
        surface.frame = CGRect(x: 0, y: 0, width: 240, height: 160)
        surface.layoutIfNeeded()
        var reported: [GlassAccessibilitySettings] = []
        surface.accessibilitySettingsHandler = { reported.append($0) }
        try surface.setPanel(Self.glass)
        #expect(surface.presentedPanel == Self.glass)

        let requestsBefore = surface.frameStatistics.requested
        surface.accessibilitySettingsSource = .fixed(GlassAccessibilitySettings(reduceTransparency: true))
        #expect(reported == [GlassAccessibilitySettings(reduceTransparency: true)])
        #expect(surface.panel == Self.glass, "The app's panel is kept")
        #expect(surface.presentedPanel?.parameters.refraction == 0)
        #expect(surface.presentedPanel?.parameters.tint.strength == 1)
        #expect(surface.frameStatistics.requested == requestsBefore + 1, "The change is drawn")

        // The opaque color resolves again for a new appearance.
        surface.traitOverrides.userInterfaceStyle = .light
        surface.updateTraitsIfNeeded()
        let light = surface.presentedPanel?.parameters.tint
        surface.traitOverrides.userInterfaceStyle = .dark
        surface.updateTraitsIfNeeded()
        let dark = surface.presentedPanel?.parameters.tint
        #expect(light != dark)
        #expect(dark == GlassAccessibilityPolicy.opaqueSurfaceTint(for: surface.traitCollection))

        // Setting a new panel keeps applying the policy.
        var moved = Self.glass
        moved.frame.origin.x = 30
        try surface.setPanel(moved)
        #expect(surface.panel == moved)
        #expect(surface.presentedPanel?.frame == moved.frame)
        #expect(surface.presentedPanel?.parameters.tint.strength == 1)

        surface.accessibilitySettingsSource = .fixed(GlassAccessibilitySettings(reduceMotion: true))
        #expect(surface.presentedPanel == moved)
        #expect(reported.last == GlassAccessibilitySettings(reduceMotion: true))
        #expect(surface.accessibilitySettings.reduceMotion)
    }

    /// The accessibility runtime is not loaded in this test process, so
    /// UIKit controls do not report themselves as elements here; the
    /// laboratory's UI tests check the controls with the real runtime. This
    /// test checks what the surface itself contributes and that activation
    /// reaches the control above it.
    @Test func `A decorative surface adds no accessibility elements`() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
        surface.frame = container.bounds
        container.addSubview(surface)
        try surface.setPanel(Self.glass)
        let button = UIButton(configuration: .borderedProminent())
        button.configuration?.title = "Custom action"
        button.frame = CGRect(x: 60, y: 80, width: 160, height: 44)
        var activations = 0
        button.addAction(UIAction { _ in activations += 1 }, for: .primaryActionTriggered)
        container.addSubview(button)

        #expect(!surface.isAccessibilityElement)
        #expect(surface.accessibilityElementsHidden, "Nothing inside the surface is offered to VoiceOver")
        #expect(!surface.hostedMetalView.isAccessibilityElement)
        #expect(accessibilityElements(in: surface).isEmpty)
        // Even a subview that claims to be an element stays hidden.
        surface.hostedMetalView.isAccessibilityElement = true
        #expect(accessibilityElements(in: surface).isEmpty)
        // Activation lands on the control, not the surface below it.
        let center = CGPoint(x: button.frame.midX, y: button.frame.midY)
        #expect(container.hitTest(center, with: nil) === button)
        button.sendActions(for: .primaryActionTriggered)
        #expect(activations == 1)
    }
}
#endif
