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
    /// The pane list's mark on the pane that shows.
    var isChecked = false
    var children: [Self] = []
    var run: @MainActor () -> Void = {}

    /// The items that run something, submenus opened.
    var leaves: [Self] { children.isEmpty ? [self] : children.flatMap(\.leaves) }

    @MainActor
    var element: UIMenuElement {
        guard children.isEmpty else {
            let menu = UIMenu(title: title, image: UIImage(systemName: symbol), children: children.map(\.element))
            menu.accessibilityIdentifier = identifier
            return menu
        }
        let run = run
        let action = UIAction(title: title, image: UIImage(systemName: symbol)) { _ in run() }
        action.accessibilityIdentifier = identifier
        if !isEnabled { action.attributes.insert(.disabled) }
        if isDestructive { action.attributes.insert(.destructive) }
        if isChecked { action.state = .on }
        return action
    }
}

/// The capsule the strip controls draw on (the grip, the zoom capsule, the
/// chip): a thin material with a hairline edge, so it stays legible over
/// content scrolling under it, and an accent wash when its pane has focus.
/// Shaped unlike the divider's grabber on purpose: the two sit side by side
/// in a vertical split.
final class PaneCapsuleBackground: UIVisualEffectView {
    private let wash = UIView()

    init() {
        super.init(effect: UIBlurEffect(style: .systemThinMaterial))
        isUserInteractionEnabled = false
        clipsToBounds = true
        wash.isHidden = true
        wash.backgroundColor = tintColor.withAlphaComponent(0.22)
        contentView.addSubview(wash)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (self: Self, _) in
            self.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var isTinted = false {
        didSet { wash.isHidden = !isTinted }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        layer.borderWidth = 1 / max(1, traitCollection.displayScale)
        layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        wash.frame = contentView.bounds
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        wash.backgroundColor = tintColor.withAlphaComponent(0.22)
    }
}

/// A leaf's grip: a … capsule centred under its pane's navigation bar, never
/// in it, because the system moves a floating window by a drag in the bar
/// even after a hold. A tap opens the pane menu; while its leaf fills the
/// window it is the zoom capsule ("1 of 3"), and a tap restores. A drag
/// moves the pane (the host's pan). The focused leaf's grip shows the accent
/// glyph on an accent wash; the others a secondary glyph on the material.
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
        /// A sheet this pane asked for waits behind another pane's.
        var hasWaitingSheet = false
    }

    static let size = CGSize(width: 44, height: 20)
    static let capsuleSize = CGSize(width: 76, height: 20)
    /// The touch target's height; the capsule draws shorter, inside its strip.
    static let hitHeight: CGFloat = 44

    let leafID: PaneID
    /// The pane menu as it is when it opens.
    var items: @MainActor () -> [PaneMenuItem] = { [] }
    var onRestore: @MainActor () -> Void = {}
    /// Whether the touch target may reach above the capsule, into the pane's
    /// bar. False under a divider, whose own band takes the touches there;
    /// the target then reaches down instead.
    var reachesUp = true

    private let background = PaneCapsuleBackground()
    private let glyph = UIImageView(image: UIImage(
        systemName: "ellipsis",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
    ))
    private let waitingDot = UIView()
    private let capsule = UILabel()
    private let menuButton = UIButton(type: .custom)
    private(set) var shown = Shown(title: "", position: 1, count: 1, isFocused: false, isZoomed: false)

    init(leafID: PaneID) {
        self.leafID = leafID
        super.init(frame: .zero)
        accessibilityIdentifier = "pane.grip.\(leafID.raw)"
        addSubview(background)
        glyph.isUserInteractionEnabled = false
        glyph.contentMode = .center
        addSubview(glyph)
        capsule.isUserInteractionEnabled = false
        capsule.font = .preferredFont(forTextStyle: .caption1)
        capsule.adjustsFontForContentSizeCategory = true
        capsule.textAlignment = .center
        addSubview(capsule)
        waitingDot.isUserInteractionEnabled = false
        waitingDot.backgroundColor = .systemOrange
        waitingDot.layer.cornerRadius = 3
        addSubview(waitingDot)
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
        glyph.isHidden = shown.isZoomed
        waitingDot.isHidden = !shown.hasWaitingSheet
        capsule.isHidden = !shown.isZoomed
        capsule.text = String(localized: "\(shown.position) of \(shown.count)")
        applyFocus()
        let place = String(localized: "\(shown.position) of \(shown.count)")
        accessibilityLabel = String(localized: "Pane, \(shown.title), \(place)")
        let state = shown.isZoomed
            ? String(localized: "Zoomed")
            : shown.isFocused ? String(localized: "Focused") : nil
        accessibilityValue = shown.hasWaitingSheet
            ? [state, String(localized: "Sheet waiting")].compactMap { $0 }.joined(separator: ", ")
            : state
        accessibilityHint = shown.isZoomed ? String(localized: "Restores the other panes.") : nil
        largeContentTitle = shown.isZoomed ? place : shown.title
        largeContentImage = UIImage(systemName: "rectangle.split.2x1")
        setNeedsLayout()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyFocus()
    }

    private func applyFocus() {
        let focused = shown.isFocused && !shown.isZoomed
        background.isTinted = focused
        glyph.tintColor = focused ? tintColor : .secondaryLabel
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        background.frame = bounds
        glyph.frame = bounds
        capsule.frame = bounds
        menuButton.frame = bounds
        // A badge on the capsule's trailing shoulder.
        waitingDot.frame = CGRect(x: bounds.maxX - 5, y: -1, width: 6, height: 6)
    }

    /// At least 44 pt to touch, though the capsule draws 20 pt tall.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let width = max(bounds.width, Self.hitHeight)
        let extra = Self.hitHeight - bounds.height
        let target = CGRect(
            x: bounds.midX - width / 2, y: reachesUp ? bounds.minY - extra / 2 : bounds.minY,
            width: width, height: Self.hitHeight
        )
        return target.contains(point)
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
        UIPointerStyle(effect: .highlight(UITargetedPreview(view: background)))
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

    /// The grabber's thickness across the divider; half of it reaches into
    /// each neighbour, and a grip under it keeps clear.
    static let grabberThickness: CGFloat = 5

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
            let thin = Self.grabberThickness
            grabber.frame = CGRect(x: (bounds.width - thin) / 2, y: (bounds.height - 48) / 2, width: thin, height: 48)
        } else {
            line.frame = CGRect(x: 0, y: (bounds.height - thickness) / 2, width: bounds.width, height: thickness)
            let thin = Self.grabberThickness
            grabber.frame = CGRect(x: (bounds.width - 48) / 2, y: (bounds.height - thin) / 2, width: 48, height: thin)
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

/// A collapsed pane: a 20 pt strip in its place along its split, with a mark
/// across it and the pane's title for VoiceOver, the pointer and the Large
/// Content Viewer. A tap (or VoiceOver's activate) expands the pane to the
/// share it had.
final class PaneStripView: UIView {
    var onExpand: @MainActor () -> Void = {}
    /// The part of the strip under its bottom edge's home indicator: it
    /// paints there but neither draws its mark nor takes a touch, so the
    /// system's swipe up never lands on it.
    var bottomInset: CGFloat = 0 {
        didSet { if bottomInset != oldValue { setNeedsLayout() } }
    }

    private let mark = UIView()
    private var axis = PaneAxis.row

    init(leafID: PaneID) {
        super.init(frame: .zero)
        accessibilityIdentifier = "pane.strip.\(leafID.raw)"
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = String(localized: "Expands the pane.")
        backgroundColor = .secondarySystemBackground
        mark.backgroundColor = .tertiaryLabel
        mark.layer.cornerRadius = 2.5
        mark.isUserInteractionEnabled = false
        addSubview(mark)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(expand)))
        addInteraction(UIPointerInteraction(delegate: self))
        showsLargeContentViewer = true
        largeContentImage = UIImage(systemName: "rectangle.expand.vertical")
        addInteraction(UILargeContentViewerInteraction())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(title: String, axis: PaneAxis) {
        accessibilityLabel = String(localized: "Collapsed pane, \(title)")
        largeContentTitle = title
        guard axis != self.axis else { return }
        self.axis = axis
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The mark runs along the strip, as the divider's grabber does.
        let size = axis == .row ? CGSize(width: 5, height: 48) : CGSize(width: 48, height: 5)
        let height = bounds.height - bottomInset
        mark.frame = CGRect(
            x: (bounds.width - size.width) / 2, y: (height - size.height) / 2,
            width: size.width, height: size.height
        )
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) && point.y < bounds.height - bottomInset
    }

    @objc private func expand() { onExpand() }

    override func accessibilityActivate() -> Bool {
        onExpand()
        return true
    }
}

extension PaneStripView: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(effect: .highlight(UITargetedPreview(view: mark)))
    }
}

/// The pane chip on a compact window (iPhone, a narrow iPad window), where
/// one pane shows at a time: the shown pane's title and its place ("Files ·
/// 2 of 3") in the strip under its bar. A tap lists the panes and shows the
/// one chosen; a swipe shows the next or previous pane in tree order.
///
/// A plain view with an inner menu button that takes no touches, as the
/// grip is, so the swipes reach it.
final class PaneChipView: UIView {
    struct Shown: Equatable {
        var title: String
        var position: Int
        var count: Int
    }

    static let height = PaneGripView.size.height

    /// The pane list as it is when it opens.
    var items: @MainActor () -> [PaneMenuItem] = { [] }
    /// A swipe: +1 the next pane, -1 the previous one.
    var onStep: @MainActor (Int) -> Void = { _ in }

    private let background = PaneCapsuleBackground()
    private let label = UILabel()
    private let menuButton = UIButton(type: .custom)
    private(set) var shown = Shown(title: "", position: 1, count: 1)

    init() {
        super.init(frame: .zero)
        accessibilityIdentifier = "pane.chip"
        isAccessibilityElement = true
        addSubview(background)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.isUserInteractionEnabled = false
        addSubview(label)
        menuButton.isUserInteractionEnabled = false
        menuButton.isAccessibilityElement = false
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            MainActor.assumeIsolated { completion(self?.items().map(\.element) ?? []) }
        }])
        addSubview(menuButton)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openList)))
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            addGestureRecognizer(swipe)
        }
        addInteraction(UIPointerInteraction(delegate: self))
        showsLargeContentViewer = true
        largeContentImage = UIImage(systemName: "rectangle.stack")
        addInteraction(UILargeContentViewerInteraction())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ next: Shown) {
        guard next != shown else { return }
        shown = next
        let place = String(localized: "\(next.position) of \(next.count)")
        label.text = "\(next.title) · \(place)"
        accessibilityLabel = String(localized: "Panes, \(next.title), \(place)")
        accessibilityHint = String(localized: "Lists the panes. Swipe to show the next or previous pane.")
        largeContentTitle = label.text
        setNeedsLayout()
    }

    /// The label's width, padded and capped by the pane it sits in.
    func fittingWidth(maximum: CGFloat) -> CGFloat {
        min(maximum, label.intrinsicContentSize.width + 24)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        background.frame = bounds
        label.frame = bounds.insetBy(dx: 10, dy: 0)
        menuButton.frame = bounds
    }

    /// The whole strip takes the touch, as before the capsule drew shorter.
    /// Not taller: on a phone the strip sits right under the bar's search.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: -(PaneStripSlot.height - bounds.height) / 2).contains(point)
    }

    @objc private func openList() { menuButton.performPrimaryAction() }

    @objc private func swiped(_ recognizer: UISwipeGestureRecognizer) {
        onStep(recognizer.direction == .left ? 1 : -1)
    }

    override var accessibilityTraits: UIAccessibilityTraits {
        get { .button }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        openList()
        return true
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            [
                UIAccessibilityCustomAction(name: String(localized: "Next Pane")) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onStep(1) }
                    return true
                },
                UIAccessibilityCustomAction(name: String(localized: "Previous Pane")) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onStep(-1) }
                    return true
                },
            ]
        }
        set {}
    }
}

extension PaneChipView: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(effect: .highlight(UITargetedPreview(view: background)))
    }
}

/// The strip a pane reserves under its bar for its grip or chip, as a view in
/// the pane's screen: pinned to the top of the screen's safe area, less the
/// strip the host adds to it, so Auto Layout keeps it under the bar and
/// anything the bar carries (a search that hides as the list scrolls) with
/// no measuring. Draws nothing and takes no touches; the host places the grip
/// or chip over it, and hears when it moves.
final class PaneStripSlot: UIView {
    /// The strip's height: a grip or chip capsule with a point above and below.
    static let height: CGFloat = 22

    private var onMove: () -> Void = {}

    static func slot(in screen: UIViewController) -> PaneStripSlot? {
        screen.view.subviews.lazy.compactMap { $0 as? PaneStripSlot }.first
    }

    static func install(in screen: UIViewController, onMove: @escaping () -> Void) {
        let slot = PaneStripSlot()
        slot.onMove = onMove
        slot.isUserInteractionEnabled = false
        slot.isAccessibilityElement = false
        slot.translatesAutoresizingMaskIntoConstraints = false
        screen.view.addSubview(slot)
        let guide = screen.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            slot.bottomAnchor.constraint(equalTo: guide.topAnchor),
            slot.heightAnchor.constraint(equalToConstant: height),
            slot.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            slot.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
        ])
    }

    override var center: CGPoint {
        didSet { if center != oldValue { onMove() } }
    }
}

/// The toast after a pane change Undo can take back: "Undo Close Pane" at
/// the foot of the window for a few seconds. A tap undoes the change; the
/// grip menu and View ▸ Panes offer the same Undo after it goes.
final class PaneUndoToast: UIButton {
    static let lifetime: Duration = .seconds(6)
    private var hiding: Task<Void, Never>?

    init() {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = .secondarySystemBackground
        configuration.baseForegroundColor = .label
        configuration.image = UIImage(systemName: "arrow.uturn.backward")
        configuration.imagePadding = 6
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .subheadline)
            return attributes
        }
        super.init(frame: .zero)
        self.configuration = configuration
        accessibilityIdentifier = "pane.undo"
        isHidden = true
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Shows "Undo `action`" until the lifetime passes or `hide()`.
    func show(action: String) {
        configuration?.title = String(localized: "Undo \(action)")
        isHidden = false
        hiding?.cancel()
        hiding = Task { [weak self] in
            try? await Task.sleep(for: Self.lifetime)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hiding?.cancel()
        hiding = nil
        isHidden = true
    }
}
