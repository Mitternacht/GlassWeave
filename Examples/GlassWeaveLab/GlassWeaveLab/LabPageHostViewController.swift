import UIKit

/// Shows one of the laboratory's launch-argument screens (the presentation
/// screen of GW-27 and the frost pyramid screen of GW-24a, which open as the
/// window's root with `-lab.presentation YES` and `-lab.frost YES`) over the
/// main screen, with a Close button, so every page is reachable from the
/// main screen's menu. The page itself is the same view controller the launch
/// argument uses.
final class LabPageHostViewController: UIViewController {
    private let page: UIViewController
    private let closeButton = UIButton(configuration: .glass())

    /// - Parameters:
    ///   - page: The screen to show.
    ///   - closeIdentifier: The Close button's accessibility identifier.
    init(page: UIViewController, closeIdentifier: String) {
        self.page = page
        super.init(nibName: nil, bundle: nil)
        closeButton.accessibilityIdentifier = closeIdentifier
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        addChild(page)
        page.view.frame = view.bounds
        page.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(page.view)
        page.didMove(toParent: self)

        closeButton.configuration?.image = UIImage(systemName: "xmark")
        closeButton.accessibilityLabel = String(localized: "Close")
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    /// Opens the presentation screen (GW-27) over `presenter`.
    static func presentPresentation(from presenter: UIViewController, animated: Bool) {
        guard presenter.presentedViewController == nil else { return }
        presenter.present(
            LabPageHostViewController(page: PresentationLabViewController(), closeIdentifier: "presentation.close"),
            animated: animated
        )
    }

    /// Opens the frost pyramid screen (GW-24a) over `presenter`.
    static func presentFrost(from presenter: UIViewController, animated: Bool) {
        guard presenter.presentedViewController == nil else { return }
        presenter.present(
            LabPageHostViewController(page: FrostLabViewController(), closeIdentifier: "frost.close"),
            animated: animated
        )
    }
}
