#if canImport(UIKit)
import MetalKit
import Testing
import UIKit
@testable import GlassWeave
@testable import GlassWeaveUIKit

/// Native mode: public `UIGlassEffect` configuration around a native control,
/// with no GlassWeave rendering objects.
@MainActor
struct NativeGlassViewTests {
    /// A glass view holding a real button whose action counts taps.
    @MainActor
    private final class Fixture {
        let glass: NativeGlassView
        let button = UIButton(configuration: .plain())
        private(set) var taps = 0

        init(configuration: NativeGlassView.Configuration) {
            glass = NativeGlassView(configuration: configuration)
            glass.frame = CGRect(x: 0, y: 0, width: 220, height: 64)
            glass.cornerConfiguration = .capsule()
            button.configuration?.title = "Native action"
            button.frame = CGRect(x: 20, y: 10, width: 180, height: 44)
            button.addAction(UIAction { [unowned self] _ in taps += 1 }, for: .primaryActionTriggered)
            glass.contentView.addSubview(button)
            glass.layoutIfNeeded()
        }
    }

    private func glassEffect(of view: NativeGlassView) throws -> UIGlassEffect {
        try #require(view.effect as? UIGlassEffect)
    }

    @Test func `The effect is a public UIGlassEffect with the configured tint and interaction`() throws {
        let glass = NativeGlassView(configuration: .init(tintColor: .systemBlue, isInteractive: true))
        let effect = try glassEffect(of: glass)
        #expect(effect.tintColor == .systemBlue)
        #expect(effect.isInteractive)
    }

    @Test func `The default matches UIGlassEffect's defaults`() throws {
        let glass = NativeGlassView()
        let effect = try glassEffect(of: glass)
        #expect(effect.tintColor == nil)
        #expect(!effect.isInteractive)
        #expect(glass.configuration == NativeGlassView.Configuration())
    }

    @Test func `Changing the configuration replaces the effect`() throws {
        let glass = NativeGlassView(configuration: .init(tintColor: .systemOrange, isInteractive: true))
        glass.configuration.tintColor = nil
        glass.configuration.isInteractive = false
        var effect = try glassEffect(of: glass)
        #expect(effect.tintColor == nil)
        #expect(!effect.isInteractive)

        glass.configuration = .init(tintColor: .systemPink, isInteractive: true)
        effect = try glassEffect(of: glass)
        #expect(effect.tintColor == .systemPink)
        #expect(effect.isInteractive)
    }

    @Test func `The native button in the content view receives touches and actions`() {
        let fixture = Fixture(configuration: .init(isInteractive: true))
        let center = fixture.button.convert(
            CGPoint(x: fixture.button.bounds.midX, y: fixture.button.bounds.midY),
            to: fixture.glass
        )
        #expect(fixture.glass.hitTest(center, with: nil) === fixture.button)
        fixture.button.sendActions(for: .primaryActionTriggered)
        fixture.button.sendActions(for: .primaryActionTriggered)
        #expect(fixture.taps == 2)
        // Touches outside the button land on the glass's content view, not
        // on a GlassWeave overlay.
        #expect(fixture.glass.hitTest(CGPoint(x: 5, y: 32), with: nil) === fixture.glass.contentView)
    }

    @Test func `Native mode creates no renderer, Metal view, or display loop`() {
        let (fixture, created) = RendererCensus.counting {
            let fixture = Fixture(configuration: .init(tintColor: .systemTeal, isInteractive: true))
            fixture.glass.configuration.tintColor = .systemIndigo
            fixture.glass.configuration.isInteractive = false
            fixture.glass.frame.size = CGSize(width: 300, height: 80)
            fixture.glass.layoutIfNeeded()
            fixture.button.sendActions(for: .primaryActionTriggered)
            return fixture
        }
        // Every GlassWeave renderer reports its creation to the census (see
        // `A surface is a counted renderer`); none was created here.
        #expect(created == 0)
        #expect(fixture.taps == 1)
        #expect(!Self.subtree(of: fixture.glass).contains { $0 is MTKView })
    }

    private static func subtree(of view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(subtree(of:))
    }
}
#endif
