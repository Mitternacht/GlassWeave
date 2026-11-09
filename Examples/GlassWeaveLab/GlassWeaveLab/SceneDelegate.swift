import UIKit

/// Each window scene owns its own laboratory. Nothing here is a process-wide
/// singleton, so two scenes can have different sizes and lifecycle states.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        // `-lab.appearance dark` or `light` fixes this window's appearance,
        // for UI tests on simulators where the system setting does not
        // reach the app.
        switch UserDefaults.standard.string(forKey: "lab.appearance") {
        case "dark": window.overrideUserInterfaceStyle = .dark
        case "light": window.overrideUserInterfaceStyle = .light
        default: break
        }
        // `-lab.presentation YES` opens GW-27's presentation screen.
        window.rootViewController = UserDefaults.standard.bool(forKey: "lab.presentation")
            ? PresentationLabViewController()
            : LabViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}
