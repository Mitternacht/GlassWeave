#if canImport(UIKit)
import GlassWeaveUIKit
import UIKit

/// Native mode as a consumer uses it: Apple glass around a native button.
@MainActor
public func makeNativeControl(title: String, action: UIAction) -> NativeGlassView {
    let glass = NativeGlassView(configuration: .init(tintColor: .systemBlue, isInteractive: true))
    glass.cornerConfiguration = .capsule()
    let button = UIButton(configuration: .plain(), primaryAction: action)
    button.configuration?.title = title
    button.frame = CGRect(x: 0, y: 0, width: 200, height: 44)
    glass.contentView.addSubview(button)
    return glass
}
#endif
