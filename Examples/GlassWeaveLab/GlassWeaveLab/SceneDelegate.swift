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
        window.rootViewController = LabViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}
