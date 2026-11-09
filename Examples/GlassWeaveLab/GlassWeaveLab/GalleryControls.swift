import UIKit

/// The gallery's light/dark switch: a native control whose capsule track and
/// round knob are drawn by the gallery's glass surface beneath it (the track
/// in the background, the knob as a glass panel). The control itself draws
/// only the knob's symbol, decorative, and reports its geometry.
///
/// For assistive technologies it is one switch button ("Dark appearance",
/// on or off) that VoiceOver activates directly; a tap anywhere on it
/// toggles it.
final class ThemeToggle: UIControl {
    static let trackSize = CGSize(width: 116, height: 56)
    /// Space between the track's outline and the knob.
    static let knobInset: CGFloat = 5

    var knobDiameter: CGFloat { Self.trackSize.height - 2 * Self.knobInset }

    /// Whether the dark appearance is on.
    private(set) var isOn = false

    /// The knob's position along the track: 0 at the leading end (light), 1
    /// at the trailing end (dark). The gallery animates it.
    var knobPosition: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }

    private let symbol = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Dark appearance")
        accessibilityIdentifier = "gallery.themeToggle"
        symbol.isUserInteractionEnabled = false
        symbol.contentMode = .center
        symbol.isAccessibilityElement = false
        addSubview(symbol)
        updateSymbol()
        // Keyboards and pointers reach it like any control.
        addInteraction(UIPointerInteraction())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize { Self.trackSize }

    /// The knob's frame in this control's coordinates.
    var knobFrame: CGRect {
        let travel = bounds.width - 2 * Self.knobInset - knobDiameter
        return CGRect(
            x: Self.knobInset + travel * knobPosition,
            y: (bounds.height - knobDiameter) / 2,
            width: knobDiameter, height: knobDiameter
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        symbol.frame = knobFrame
    }

    /// Sets the value without sending an action, for the initial state.
    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        updateSymbol()
    }

    /// The knob shows a sun by day and a moon at night; the symbol changes
    /// with a cross-dissolve.
    private func updateSymbol() {
        let name = isOn ? "moon.stars.fill" : "sun.max.fill"
        let color = isOn ? UIColor(red: 1.0, green: 0.88, blue: 0.62, alpha: 1) : UIColor(red: 0.86, green: 0.40, blue: 0.0, alpha: 1)
        let configuration = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        UIView.transition(with: symbol, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.symbol.image = UIImage(systemName: name, withConfiguration: configuration)
            self.symbol.tintColor = color
        }
    }

    private func toggle() {
        isOn.toggle()
        updateSymbol()
        sendActions(for: .valueChanged)
        sendActions(for: .primaryActionTriggered)
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        super.endTracking(touch, with: event)
        guard let touch, bounds.insetBy(dx: -16, dy: -16).contains(touch.location(in: self)) else { return }
        toggle()
    }

    // MARK: Accessibility

    override var accessibilityTraits: UIAccessibilityTraits {
        get { [.button, .toggleButton] }
        set {}
    }

    override var accessibilityValue: String? {
        get { isOn ? "1" : "0" }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        toggle()
        return true
    }
}

/// One element capsule: a native button whose glass capsule is drawn by the
/// gallery's surface at ``capsule``'s frame, with its name beneath (or beside,
/// at accessibility text sizes). Selection is the button's own selected
/// state, which UIKit reports to assistive technologies.
final class ElementCard: UIButton {
    let element: GalleryElement
    /// Where the glass capsule is drawn; it takes no touches.
    let capsule = UIView()
    private let caption = UILabel()
    private let stack = UIStackView()
    private var capsuleWidth: NSLayoutConstraint!
    private var capsuleHeight: NSLayoutConstraint!

    init(element: GalleryElement) {
        self.element = element
        super.init(frame: .zero)
        accessibilityLabel = element.name
        accessibilityIdentifier = "gallery.element.\(element.identifier)"
        capsule.isUserInteractionEnabled = false
        capsule.isAccessibilityElement = false
        caption.text = element.name
        caption.font = .preferredFont(forTextStyle: .headline)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = UIColor(white: 0.97, alpha: 1)
        caption.textAlignment = .center
        caption.numberOfLines = 0
        caption.isAccessibilityElement = false
        stack.addArrangedSubview(capsule)
        stack.addArrangedSubview(caption)
        stack.alignment = .center
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        capsuleWidth = capsule.widthAnchor.constraint(equalToConstant: 88)
        capsuleHeight = capsule.heightAnchor.constraint(equalToConstant: 140)
        NSLayoutConstraint.activate([
            capsuleWidth, capsuleHeight,
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setCompact(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Sets the capsule's size in points.
    func setCapsuleSize(_ size: CGSize) {
        if capsuleWidth.constant != size.width { capsuleWidth.constant = size.width }
        if capsuleHeight.constant != size.height { capsuleHeight.constant = size.height }
    }

    /// Normal layout: the capsule above its name, with room for the floor
    /// reflection between them. Accessibility text sizes (`beside`): the
    /// name beside the capsule.
    func setCompact(_ beside: Bool) {
        stack.axis = beside ? .horizontal : .vertical
        stack.spacing = beside ? 20 : 42
        caption.textAlignment = beside ? .natural : .center
    }

    override var isHighlighted: Bool {
        didSet { caption.alpha = isHighlighted ? 0.6 : 1 }
    }
}
