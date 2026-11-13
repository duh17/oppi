import UIKit

// The controls a window's pane tree draws over its leaves once it has more
// than one: each leaf's grip (its pane menu, or the zoom capsule) and the
// dividers between the cells. `PaneHostController` places them and runs what
// they ask for; every touch, pointer, key and accessibility action runs the
// same `ScenePanes` operation.

/// One pane-menu item. The same list builds the grip's menu and its
/// accessibility actions, so the two never differ.
struct PaneMenuItem {
    var title: String
    var symbol: String
    /// The item's name as an accessibility action ("Move Left" for Move ▸ Left).
    var actionName: String
    var identifier: String
    var isEnabled = true
    var isDestructive = false
    var children: [Self] = []
    var run: @MainActor () -> Void = {}

    /// The items that run something, submenus opened.
    var leaves: [Self] { children.isEmpty ? [self] : children.flatMap(\.leaves) }

    @MainActor
    var element: UIMenuElement {
        guard children.isEmpty else {
            let menu = UIMenu(title: title, image: UIImage(systemName: symbol), children: children.map(\.element))
            return menu
        }
        let run = run
        let action = UIAction(title: title, image: UIImage(systemName: symbol)) { _ in run() }
        action.accessibilityIdentifier = identifier
        if !isEnabled { action.attributes.insert(.disabled) }
        if isDestructive { action.attributes.insert(.destructive) }
        return action
    }
}

/// A leaf's grip: a short bar centred under its pane's navigation bar, never
/// in it, because the system moves a floating window by a drag in the bar
/// even after a hold. A tap opens the pane menu; while its leaf fills the
/// window it is the zoom capsule ("1 of 3"), and a tap restores. A drag
/// moves the pane (the host's pan). The focused leaf's grip takes the accent
/// colour.
///
/// A plain view, not a menu button: a menu button takes the touch for its
/// menu as it goes down, so no drag could start. The tap presents the menu
/// through an inner button that takes no touches (`performPrimaryAction`).
final class PaneGripView: UIView {
    struct Shown: Equatable {
        var title: String
        var position: Int
        var count: Int
        var isFocused: Bool
        var isZoomed: Bool
    }

    static let size = CGSize(width: 56, height: 22)
    static let capsuleSize = CGSize(width: 76, height: 22)

    let leafID: PaneID
    /// The pane menu as it is when it opens.
    var items: @MainActor () -> [PaneMenuItem] = { [] }
    var onRestore: @MainActor () -> Void = {}

    private let mark = UIView()
    private let capsule = UILabel()
    private let menuButton = UIButton(type: .custom)
    private(set) var shown = Shown(title: "", position: 1, count: 1, isFocused: false, isZoomed: false)

    init(leafID: PaneID) {
        self.leafID = leafID
        super.init(frame: .zero)
        accessibilityIdentifier = "pane.grip.\(leafID.raw)"
        mark.isUserInteractionEnabled = false
        mark.layer.cornerRadius = 2.5
        addSubview(mark)
        capsule.isUserInteractionEnabled = false
        capsule.font = .preferredFont(forTextStyle: .caption1)
        capsule.adjustsFontForContentSizeCategory = true
        capsule.textAlignment = .center
        capsule.backgroundColor = .secondarySystemFill
        capsule.layer.cornerRadius = Self.capsuleSize.height / 2
        capsule.clipsToBounds = true
        addSubview(capsule)
        menuButton.isUserInteractionEnabled = false
        menuButton.isAccessibilityElement = false
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            MainActor.assumeIsolated { completion(self?.items().map(\.element) ?? []) }
        }])
        addSubview(menuButton)
        isAccessibilityElement = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(activate)))
        addInteraction(UIPointerInteraction(delegate: self))
        showsLargeContentViewer = true
        addInteraction(UILargeContentViewerInteraction())
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ next: Shown) {
        guard next != shown else { return }
        shown = next
        apply()
    }

    /// A tap: the capsule restores; otherwise the pane menu opens.
    @objc private func activate() {
        if shown.isZoomed {
            onRestore()
        } else {
            menuButton.performPrimaryAction()
        }
    }

    override func accessibilityActivate() -> Bool {
        activate()
        return true
    }

    private func apply() {
        mark.isHidden = shown.isZoomed
        capsule.isHidden = !shown.isZoomed
        capsule.text = String(localized: "\(shown.position) of \(shown.count)")
        mark.backgroundColor = shown.isFocused ? tintColor : .tertiaryLabel
        let place = String(localized: "\(shown.position) of \(shown.count)")
        accessibilityLabel = String(localized: "Pane, \(shown.title), \(place)")
        accessibilityValue = shown.isZoomed
            ? String(localized: "Zoomed")
            : shown.isFocused ? String(localized: "Focused") : nil
        accessibilityHint = shown.isZoomed ? String(localized: "Restores the other panes.") : nil
        largeContentTitle = shown.isZoomed ? place : shown.title
        largeContentImage = UIImage(systemName: "rectangle.split.2x1")
        setNeedsLayout()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        mark.backgroundColor = shown.isFocused ? tintColor : .tertiaryLabel
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let markSize = CGSize(width: 36, height: 5)
        mark.frame = CGRect(
            x: (bounds.width - markSize.width) / 2, y: (bounds.height - markSize.height) / 2,
            width: markSize.width, height: markSize.height
        )
        capsule.frame = bounds
        menuButton.frame = bounds
    }

    override var accessibilityTraits: UIAccessibilityTraits {
        get { .button }
        set {}
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            guard !shown.isZoomed else { return nil }
            return items().flatMap(\.leaves).filter(\.isEnabled).map { item in
                let run = item.run
                return UIAccessibilityCustomAction(name: item.actionName) { _ in
                    MainActor.assumeIsolated { run() }
                    return true
                }
            }
        }
        set {}
    }
}

extension PaneGripView: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(effect: .highlight(UITargetedPreview(view: shown.isZoomed ? capsule : mark)))
    }
}

/// The divider between two neighbouring cells of a split: a hairline, a
/// grab band for touch and pointer, and one adjustable accessibility element.
/// A double tap gives the split equal shares.
final class PaneSplitDividerView: UIView {
    /// The split this divider sits in (child indexes from the cells' root)
    /// and the child it follows.
    struct Place: Equatable {
        var path: [Int]
        var index: Int
        var axis: PaneAxis
    }

    var place: Place {
        didSet { applyAxis() }
    }

    var onBegan: (() -> Void)?
    /// The finger's distance along the split's axis since it began.
    var onChanged: ((CGFloat) -> Void)?
    var onEnded: (() -> Void)?
    var onStep: ((CGFloat) -> Void)?
    var onEqualise: (() -> Void)?
    /// The leading (or upper) neighbour's share, for VoiceOver.
    var share: Double = 0.5

    private let line = UIView()
    private let grabber = UIView()
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))

    init(place: Place, number: Int) {
        self.place = place
        super.init(frame: .zero)
        accessibilityIdentifier = "pane.divider.\(number)"
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityLabel = String(localized: "Resize panes")
        accessibilityHint = String(localized: "Drag, or use the rotor, to resize.")
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: String(localized: "Reset Sizes")) { [weak self] _ in
            self?.onEqualise?()
            return true
        }]
        line.backgroundColor = .separator
        line.isUserInteractionEnabled = false
        grabber.backgroundColor = .tertiaryLabel
        grabber.layer.cornerRadius = 2.5
        grabber.isUserInteractionEnabled = false
        addSubview(line)
        addSubview(grabber)
        addGestureRecognizer(pan)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        addInteraction(UIPointerInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func applyAxis() { setNeedsLayout() }

    override var accessibilityValue: String? {
        get { String(localized: "\(Int((share * 100).rounded())) percent") }
        set {}
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let thickness = PanePresentation.dividerThickness
        if place.axis == .row {
            line.frame = CGRect(x: (bounds.width - thickness) / 2, y: 0, width: thickness, height: bounds.height)
            grabber.frame = CGRect(x: (bounds.width - 5) / 2, y: (bounds.height - 48) / 2, width: 5, height: 48)
        } else {
            line.frame = CGRect(x: 0, y: (bounds.height - thickness) / 2, width: bounds.width, height: thickness)
            grabber.frame = CGRect(x: (bounds.width - 48) / 2, y: (bounds.height - 5) / 2, width: 48, height: 5)
        }
    }

    override func accessibilityIncrement() { onStep?(PaneDividerView.accessibilityStep) }
    override func accessibilityDecrement() { onStep?(-PaneDividerView.accessibilityStep) }

    /// Ends a drag in flight where it was last drawn.
    func cancelDrag() {
        guard pan.state == .began || pan.state == .changed else { return }
        pan.isEnabled = false
        pan.isEnabled = true
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        switch recognizer.state {
        case .began: onBegan?()
        case .changed: onChanged?(place.axis == .row ? translation.x : translation.y)
        case .ended, .cancelled: onEnded?()
        default: break
        }
    }

    @objc private func handleDoubleTap() { onEqualise?() }
}

extension PaneSplitDividerView: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(effect: .highlight(UITargetedPreview(view: grabber)))
    }
}
