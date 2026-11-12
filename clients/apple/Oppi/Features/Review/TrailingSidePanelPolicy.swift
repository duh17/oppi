import UIKit

/// A screen beside a trailing column that follows the keyboard itself (the
/// chat). While the column is up, the column turns `followsKeyboard` off when
/// a field in its panel has the keyboard, so the screen's own inputs stay
/// where they are.
@MainActor
protocol TrailingColumnKeyboardScreen: UIViewController {
    var followsKeyboard: Bool { get set }
}

// MARK: - Width policy, rubber banding, and snapping

/// A trailing column's width range at its current bounds: the ordinary
/// side-by-side range (`minimum`...`maximum`), and `full`, the width the pane
/// can be dragged or flung all the way open to.
struct TrailingColumnWidthPolicy: Equatable {
    /// The screen beside the column keeps at least an iPhone's width while
    /// the two share the window, so its bar and composer never wrap. Past
    /// that the pane covers the screen (`full`) rather than squeezing it.
    static let screenMinimumWidth: CGFloat = 375

    let minimum: CGFloat
    /// The width a panel opens at when nothing is remembered yet.
    let ideal: CGFloat
    /// The widest side-by-side width: the panel's own ceiling, or the room
    /// left beside the screen's minimum. Past it the pane slides over the
    /// screen, which stops reflowing, instead of squeezing it further.
    let maximum: CGFloat
    /// The full-window width: the whole window but its slim grab edge
    /// (`TrailingColumnOverlayView.fullWindowGrabEdge`), the screen beside it
    /// covered.
    let full: CGFloat
    /// The overlay's own width, which a remembered width is a fraction of.
    var window: CGFloat = 0

    /// The live policy for a panel's own range in an overlay `window` wide:
    /// zero before the overlay's first layout leaves the panel's own range.
    static func resolved(
        minWidth: CGFloat,
        idealWidth: CGFloat,
        maxWidth: CGFloat?,
        window: CGFloat
    ) -> TrailingColumnWidthPolicy {
        let softMaximum = maxWidth ?? min(idealWidth * 1.75, 640)
        guard window > 0 else {
            return TrailingColumnWidthPolicy(
                minimum: min(minWidth, softMaximum), ideal: min(idealWidth, softMaximum),
                maximum: softMaximum, full: softMaximum, window: 0
            )
        }
        let full = max(0, window - TrailingColumnOverlayView.fullWindowGrabEdge)
        let maximum = max(0, min(softMaximum, window - screenMinimumWidth, full))
        return TrailingColumnWidthPolicy(
            minimum: min(minWidth, maximum),
            ideal: min(idealWidth, maximum),
            maximum: maximum,
            full: max(full, maximum),
            window: window
        )
    }

    /// Halfway between `maximum` and `full`: cross it, by position or a fast
    /// fling, and the divider commits to full instead of springing back.
    var expandThreshold: CGFloat { maximum + (full - maximum) / 2 }
    /// Halfway between `minimum` and closed: cross it and the pane closes
    /// instead of springing back to `minimum`.
    var closeThreshold: CGFloat { minimum / 2 }

    func clampedToOrdinaryRange(_ width: CGFloat) -> CGFloat {
        min(maximum, max(minimum, width))
    }
}

/// How the divider follows the finger. Inside the side-by-side range and on
/// past it toward full it tracks 1:1: past `maximum` the screen beside has
/// stopped reflowing and the pane simply slides over it, so there is nothing
/// to resist. Below `minimum` the panel's content would squeeze, so the
/// divider resists the way `UIScrollView` bounces, saying "this closes".
enum ColumnRubberBand {
    /// `coefficient: 2` puts the resisted width at the close threshold
    /// (`minimum / 2`) exactly when the finger is there too.
    static let closingCoefficient: CGFloat = 2

    static func resisted(_ distance: CGFloat, dimension: CGFloat, coefficient: CGFloat = 0.55) -> CGFloat {
        guard dimension > 0, distance > 0 else { return 0 }
        return (1 - (1 / ((distance * coefficient / dimension) + 1))) * dimension
    }

    /// The width drawn for a raw (1:1 with the finger) target.
    static func liveWidth(forRawTarget raw: CGFloat, policy: TrailingColumnWidthPolicy) -> CGFloat {
        guard raw < policy.minimum else { return min(raw, policy.full) }
        let dimension = max(policy.minimum, 1)
        return policy.minimum - resisted(policy.minimum - raw, dimension: dimension, coefficient: closingCoefficient)
    }

    /// The raw target that draws `width`, so a drag that starts mid-motion
    /// (an open still settling) picks the divider up where it is drawn
    /// instead of jumping to where the finger math would put it.
    static func rawTarget(forLiveWidth width: CGFloat, policy: TrailingColumnWidthPolicy) -> CGFloat {
        guard width < policy.minimum else { return width }
        let dimension = max(policy.minimum, 1)
        // Inverse of `resisted`: y = (1 - 1 / (c·d/D + 1))·D  ⇒  d = y / (c·(1 - y/D)).
        let resistedAmount = min(policy.minimum - width, dimension * 0.999)
        let distance = resistedAmount / (closingCoefficient * (1 - resistedAmount / dimension))
        return policy.minimum - distance
    }
}

/// Where a drag settles once it ends.
enum ColumnSnapOutcome: Equatable {
    case closed
    case width(CGFloat)
    case full
}

/// The zone a live width sits in, for a haptic tick each time a drag crosses
/// into or out of a commit zone.
enum ColumnSnapZone: Equatable {
    case closing, ordinary, expanding
}

enum ColumnSnapResolver {
    static func zone(for width: CGFloat, policy: TrailingColumnWidthPolicy) -> ColumnSnapZone {
        if width <= policy.closeThreshold { return .closing }
        if width >= policy.expandThreshold { return .expanding }
        return .ordinary
    }

    /// The divider's resting place once a drag ends: closed, full, or an
    /// ordinary width, carrying the gesture's velocity into the projection so
    /// a fast flick settles like a slower drag further in the same direction
    /// would have. Leaving full always returns to the remembered width
    /// rather than wherever the pull-back happened to stop, so full reads as
    /// a clean toggle and not a second free-resize range. `rawWidth` is the
    /// finger's own target, the same one `zone` ticks the haptic for, so a
    /// release decides exactly what the last tick announced.
    static func resolve(
        rawWidth: CGFloat,
        widthVelocity: CGFloat,
        policy: TrailingColumnWidthPolicy,
        rememberedWidth: CGFloat,
        wasFull: Bool,
        projectionSeconds: CGFloat = 0.12
    ) -> ColumnSnapOutcome {
        let projected = rawWidth + widthVelocity * projectionSeconds
        if projected <= policy.closeThreshold { return .closed }
        if projected >= policy.expandThreshold { return .full }
        if wasFull { return .width(policy.clampedToOrdinaryRange(rememberedWidth)) }
        return .width(policy.clampedToOrdinaryRange(projected))
    }
}

// MARK: - Resize handle

/// The trailing column's one draggable divider: a hairline, a visible
/// grabber mark, and the resize/expand/close gesture's single owner, so a
/// touch drag, a trackpad hover, and VoiceOver's adjustable actions all drive
/// the same width. One accessibility element, not three competing views.
final class TrailingColumnResizeHandle: UIView {
    /// VoiceOver's increment/decrement step, in points.
    static let accessibilityStep: CGFloat = 32
    /// The touch and pointer band around the hairline; narrower than this and
    /// a resize target is too easy to miss (`ExtensionStripPillHitBand` uses
    /// the same overhang idea for pill rows).
    static let hitWidth: CGFloat = 28

    var onBegan: (() -> Void)?
    var onChanged: ((_ translationX: CGFloat) -> Void)?
    var onEnded: ((_ translationX: CGFloat, _ velocityX: CGFloat) -> Void)?
    var onStep: ((_ delta: CGFloat) -> Void)?
    var onExpandRequested: (() -> Void)?
    var onRestoreRequested: (() -> Void)?

    /// Full-window or not, for the accessibility action offered and the
    /// spoken value; the overlay sets this from the controller's state.
    var isFull = false {
        didSet {
            guard isFull != oldValue else { return }
            accessibilityHint = isFull
                ? String(localized: "Drag, or use the rotor, to resize. Double-tap and drag to show chat.")
                : String(localized: "Drag, or use the rotor, to resize. Double-tap and drag to expand.")
            accessibilityCustomActions = isFull
                ? [UIAccessibilityCustomAction(name: String(localized: "Show Chat")) { [weak self] _ in
                    self?.onRestoreRequested?()
                    return true
                }]
                : [UIAccessibilityCustomAction(name: String(localized: "Expand Pane")) { [weak self] _ in
                    self?.onExpandRequested?()
                    return true
                }]
        }
    }

    /// The column's drawn width, set on every layout; spoken only when
    /// VoiceOver asks, so a drag formats no string per frame.
    var columnWidth: CGFloat = 0

    override var accessibilityValue: String? {
        get {
            isFull
                ? String(localized: "Full window")
                : String(localized: "\(Int(columnWidth.rounded())) points")
        }
        set {}
    }

    private let grabber = UIView()
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityIdentifier = "trailingColumn.resizeHandle"
        accessibilityLabel = String(localized: "Resize panel")
        accessibilityTraits = .adjustable
        // Readable on a dark theme: `.separator` all but vanishes, and in
        // portrait on the iPad mini this mark is the only cue that the pane
        // can be dragged.
        grabber.backgroundColor = .tertiaryLabel
        grabber.layer.cornerRadius = 2.5
        grabber.isUserInteractionEnabled = false
        addSubview(grabber)
        addGestureRecognizer(pan)
        addInteraction(UIPointerInteraction(delegate: self))
        accessibilityHint = String(localized: "Drag, or use the rotor, to resize. Double-tap and drag to expand.")
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: String(localized: "Expand Pane")) { [weak self] _ in
            self?.onExpandRequested?()
            return true
        }]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let grabberSize = CGSize(width: 5, height: 48)
        grabber.frame = CGRect(
            x: (bounds.width - grabberSize.width) / 2,
            y: (bounds.height - grabberSize.height) / 2,
            width: grabberSize.width,
            height: grabberSize.height
        )
    }

    override func accessibilityIncrement() { onStep?(Self.accessibilityStep) }
    override func accessibilityDecrement() { onStep?(-Self.accessibilityStep) }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            onBegan?()
        case .changed:
            onChanged?(recognizer.translation(in: self).x)
        case .ended, .cancelled:
            onEnded?(recognizer.translation(in: self).x, recognizer.velocity(in: self).x)
        default:
            break
        }
    }
}

extension TrailingColumnResizeHandle: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(effect: .highlight(UITargetedPreview(view: grabber)))
    }
}

/// A side panel in a full-height trailing column beside a UIKit screen, like
/// an iPadOS inspector: an invisible child of the screen that asked for it,
/// which calls `show` with the panel (nil hides it) and, at compact width,
/// presents the same panel as a router sheet instead. A new panel id with the
/// column already open replaces its content without re-running the open
/// transition; nil, from nothing, and from something each animate. The panel
/// is one UIKit screen at the root of the column's own navigation controller,
/// shown in a `TrailingColumnOverlayView` on top of the navigation controller
/// that holds the screen (the screen's top ancestor outside one). The panel's
/// navigation controller has no parent: it is embedded by its view alone, and
/// the column forwards its appearance itself. UIKit accepts a controller
/// whose view sits in a navigation controller's view only as that navigation
/// controller's child (any other parent raises), and every child of a
/// navigation controller is on its stack: as one, the panel was the stack's
/// top, a popped screen got no disappearance callbacks, and Back left the
/// host's trailing inset at the panel's width. Detached, a presentation from
/// inside the panel (its search, a popover from one of its screens) is one
/// UIKit logs as unsupported. App code presents from
/// `Router.topPresenter(from:)`, and `ErrorAlertPresenter` finds the host
/// through the panel's view. It attaches while the screen is on screen, so a page
/// pushed above the screen, or a full-screen modal over it, never shows it,
/// and the panel's own pushed pages survive until the screen returns.
final class TrailingColumnController: UIViewController {
    struct Panel {
        let id: AnyHashable
        let minWidth: CGFloat
        let idealWidth: CGFloat
        /// The soft ceiling of ordinary dragging; nil picks a width generous
        /// enough for most content without being the whole window.
        var maxWidth: CGFloat? = nil
        /// Builds the panel's UIKit screen when the column installs it.
        let makeScreen: () -> UIViewController
    }

    /// The divider was dragged or flung past the close threshold, same as
    /// the panel's own Close or Done. The owner closes the same way that
    /// control does, so the model stays the single source of truth and this
    /// column never reopens itself on the next update pass.
    var onDismissRequested: (() -> Void)?

    private var panelID: AnyHashable?
    private var root: AppRootEnvironment?
    private var container: RouterNavigationController?
    /// The screen in front inside the open panel, for Find and the other
    /// commands that ask what the panel shows.
    var frontScreen: UIViewController? { container?.topViewController }
    private var overlay: TrailingColumnOverlayView?
    /// The controller whose safe area makes room for the column, and the
    /// trailing inset this column added to it.
    private weak var host: UIViewController?
    private var hostInset: CGFloat = 0
    /// The screen beside the column while it is attached.
    private weak var screen: UIViewController?
    /// The UIKit screen that owns this column.
    private weak var owningScreen: UIViewController?
    private var isOnScreen = false

    /// The installed panel's own width range, captured once per install or
    /// swap; `currentWidthPolicy` turns it into points against the overlay's
    /// live bounds on every use, so a Stage Manager resize recomputes the
    /// ordinary range and `full` together with the width itself.
    private var panelConstraints: (minWidth: CGFloat, idealWidth: CGFloat, maxWidth: CGFloat?)?
    private var isFull = false
    /// The finger's raw target at the drag's start, before translation; nil
    /// outside a drag.
    private var dragStartWidth: CGFloat?
    private var dragZone: ColumnSnapZone?
    private var settleAnimator: UIViewPropertyAnimator?

    init(screen: UIViewController) {
        owningScreen = screen
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(inputBeganEditing(_:)),
                name: name,
                object: nil
            )
        }
    }

    func show(_ panel: Panel?, root: AppRootEnvironment?) {
        guard let panel, let root else {
            requested = nil
            removePanel()
            return
        }
        self.root = root
        requested = panel
        if panel.id == panelID, let overlay, container != nil, !isRemoving {
            // Already open on this id: a content-only refresh (new min/ideal
            // width from the same screen) never replays the open transition.
            applyPanelConstraints(panel, overlay: overlay)
            return
        }
        if panelID != nil, container != nil, !isRemoving {
            // A different panel while the column is already open: swap the
            // screen in place. The column's width and full state are
            // untouched, so the pane does not close and reopen for a second
            // reflow.
            swapPanel(panel)
            return
        }
        removePanel()
    }

    /// The panel the presenter asked for last; installed once any panel
    /// being removed is gone.
    private var requested: Panel?
    /// True while a removed panel waits for its search to end.
    private var isRemoving = false
    /// Work waiting for the panel being removed to be gone (`whenClosed`).
    private var closedWaiters: [() -> Void] = []

    /// Runs `body` once no panel is mounted: now when none is, otherwise
    /// after the one being removed has slid out and left the host. Close
    /// the panel (`show(nil, root:)`) first. A push onto the host's stack
    /// waits for this: the close animates the host's layout and removes the
    /// column's view, which under a running push transition left the
    /// screen's view out of the window after Back.
    func whenClosed(_ body: @escaping () -> Void) {
        guard container != nil || isRemoving else {
            body()
            return
        }
        closedWaiters.append(body)
    }

    private func installRequestedPanel() {
        guard let panel = requested, let root, container == nil else { return }
        let screen = panel.makeScreen()
        let container = RouterNavigationController(rootViewController: screen)
        let themeStore = root.themeStore
        container.interfaceStyle = { themeStore.userInterfaceStyle }
        // A narrow column lays out compact, as an inspector or a split
        // view's side column does. In a regular-width window an inset
        // grouped list (Context) misplaced and clipped its rows.
        container.traitOverrides.horizontalSizeClass = .compact
        container.onSafeAreaInsetsChange = { [weak self] in
            self?.overlay?.setNeedsLayout()
        }
        let overlay = makeOverlay(column: container.view)
        panelID = panel.id
        self.container = container
        self.overlay = overlay
        isFull = false
        applyPanelConstraints(panel, overlay: overlay)
        setNeedsUpdateProperties()
        attach(animated: true)
    }

    /// Replaces the open column's content without closing it: the overlay,
    /// its width, and `isFull` all stay as they are.
    private func swapPanel(_ panel: Panel) {
        guard let overlay, let container else { return }
        Router.endSearch(in: container) { [weak self] in
            guard let self else { return }
            let screen = panel.makeScreen()
            let newContainer = RouterNavigationController(rootViewController: screen)
            let themeStore = self.root?.themeStore
            newContainer.interfaceStyle = { themeStore?.userInterfaceStyle ?? .unspecified }
            newContainer.traitOverrides.horizontalSizeClass = .compact
            newContainer.onSafeAreaInsetsChange = { [weak self] in
                self?.overlay?.setNeedsLayout()
            }
            if self.host != nil {
                container.beginAppearanceTransition(false, animated: false)
                container.view.removeFromSuperview()
                container.endAppearanceTransition()
                overlay.replaceColumn(newContainer.view)
                newContainer.beginAppearanceTransition(true, animated: false)
                newContainer.endAppearanceTransition()
            }
            self.panelID = panel.id
            self.container = newContainer
            self.applyPanelConstraints(panel, overlay: overlay)
            self.setNeedsUpdateProperties()
        }
    }

    private func makeOverlay(column: UIView) -> TrailingColumnOverlayView {
        let overlay = TrailingColumnOverlayView(column: column)
        overlay.onColumnWidth = { [weak self] width in
            self?.makeRoom(for: width)
        }
        overlay.widthPolicy = { [weak self] in self?.currentWidthPolicy }
        overlay.handle.onBegan = { [weak self] in self?.dragBegan() }
        overlay.handle.onChanged = { [weak self] translationX in self?.dragChanged(translationX: translationX) }
        overlay.handle.onEnded = { [weak self] translationX, velocityX in
            self?.dragEnded(translationX: translationX, velocityX: velocityX)
        }
        overlay.handle.onStep = { [weak self] delta in self?.step(by: delta) }
        overlay.handle.onExpandRequested = { [weak self] in self?.requestExpandToFull() }
        overlay.handle.onRestoreRequested = { [weak self] in self?.requestRestoreFromFull() }
        overlay.onBoundsWidthChanged = { [weak self] _ in self?.rescaleForBoundsChange() }
        return overlay
    }

    /// A live resize (Stage Manager, rotation, multitasking) while the
    /// column is simply resting: rescale immediately so proportions hold at
    /// every intermediate size, not only once the user lets go of the window
    /// edge. A drag or an in-flight snap animation already owns the width
    /// this frame and must not be fought.
    private func rescaleForBoundsChange() {
        guard dragStartWidth == nil, settleAnimator == nil, let overlay else { return }
        overlay.width = restingWidth(overlay: overlay)
    }

    /// Captures the installed panel's own width range. A fraction remembered
    /// from a previous resize, in this process or a prior launch, is already
    /// bounds-independent and applies as soon as it is known; nothing here
    /// needs the overlay's bounds, which can still be zero before its first
    /// layout (`currentWidthPolicy` reads those live wherever it is used).
    private func applyPanelConstraints(_ panel: Panel, overlay: TrailingColumnOverlayView) {
        panelConstraints = (panel.minWidth, panel.idealWidth, panel.maxWidth)
        if overlay.restingFraction == nil, let stored = AppPreferences.TrailingColumn.widthFraction {
            overlay.restingFraction = stored
        }
    }

    /// The live width range in points, from the installed panel's own range
    /// and the overlay's current bounds: the ordinary resize range
    /// (`minimum`...`maximum`), and `full`, the overlay's own width.
    private var currentWidthPolicy: TrailingColumnWidthPolicy? {
        guard let panelConstraints, let overlay else { return nil }
        return TrailingColumnWidthPolicy.resolved(
            minWidth: panelConstraints.minWidth,
            idealWidth: panelConstraints.idealWidth,
            maxWidth: panelConstraints.maxWidth,
            window: overlay.bounds.width
        )
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the theme store changes.
        guard let themeStore = root?.themeStore else { return }
        container?.view.backgroundColor = themeStore.backgroundColor
        overlay?.cover.backgroundColor = themeStore.backgroundColor
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isOnScreen = true
        attach(animated: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isOnScreen = false
        detach(animated: false)
    }

    /// The navigation controller that holds the screen this column belongs
    /// to, so the column runs beside its bar; a screen outside one hosts the
    /// column itself.
    private var hostController: UIViewController? {
        owningScreen.map { $0.navigationController ?? $0 }
    }

    /// Attaches the overlay and slides the column in from zero width, so the
    /// host narrows and the pane arrives in the same interruptible motion
    /// instead of popping in once layout catches up.
    private func attach(animated: Bool) {
        guard isOnScreen, let overlay, let container, overlay.superview == nil,
              let host = hostController else { return }
        self.host = host
        screen = owningScreen
        // The overlay needs its real frame before `restingWidth` can read
        // live bounds; a `full` reopen, or a proportional one, would
        // otherwise compute against the zero-size frame it was created with.
        overlay.frame = host.view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let target = restingWidth(overlay: overlay)
        overlay.width = animated ? 0 : target
        host.view.addSubview(overlay)
        // No parent forwards appearance to the column's navigation controller.
        container.beginAppearanceTransition(true, animated: false)
        container.endAppearanceTransition()
        host.view.layoutIfNeeded()
        if animated {
            animateWidth(to: target, initialVelocity: 0)
        }
    }

    private func detach(animated: Bool, completion: (() -> Void)? = nil) {
        guard let host else {
            completion?()
            return
        }
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            if let container = self.container, self.overlay?.superview === host.view {
                container.beginAppearanceTransition(false, animated: false)
                self.overlay?.removeFromSuperview()
                container.endAppearanceTransition()
            }
            self.makeRoom(for: 0)
            self.screenFollowsKeyboard(true)
            self.screen = nil
            self.host = nil
            completion?()
        }
        guard animated, overlay?.superview != nil else {
            finish()
            return
        }
        animateWidth(to: 0, initialVelocity: 0, completion: finish)
    }

    /// The keyboard spans the window, so a field in the panel (the Outline's
    /// search) lifted the composer and pills of the chat beside it over its
    /// timeline. While the column is up, the screen stops following the
    /// keyboard only for the panel's inputs; the panel avoids the keyboard
    /// itself. The rule is decided by the panel, not the screen's view: with
    /// no navigation controller the column sits inside the screen's view, and
    /// a field in a sheet over the screen is neither. An input begins editing
    /// before the keyboard moves, so the screen is settled when it does.
    @objc private func inputBeganEditing(_ notification: Notification) {
        guard let screen, let input = notification.object as? UIView,
              let window = screen.viewIfLoaded?.window, input.window === window else { return }
        let isPanelInput = container.map { input.isDescendant(of: $0.view) } ?? false
        screenFollowsKeyboard(!isPanelInput)
    }

    private func screenFollowsKeyboard(_ follows: Bool) {
        (screen as? TrailingColumnKeyboardScreen)?.followsKeyboard = follows
    }

    /// Insets the host's safe area so the screen's bar items and content stop
    /// at the column. The system already insets the host by the device's
    /// trailing inset (a landscape iPhone's sensor housing), which the column
    /// covers, so only the rest of the column's width is added; adding all of
    /// it left a housing-wide gap before the column. Recomputed on every
    /// layout, so a rotation, and a detach at width 0, settle on the right
    /// amount. The column sits on the host's view, so it takes the host
    /// view's own top and bottom insets (status bar, home indicator), not the
    /// bar insets a navigation controller hands its children, which put the
    /// column's bar a bar lower than the screen's; and the device's trailing
    /// inset, not the room made for it.
    private func makeRoom(for width: CGFloat) {
        guard let host else { return }
        // Past the side-by-side maximum the pane slides over the screen, so
        // the screen keeps the width it had there instead of squeezing (and
        // reflowing every frame) on the way to full.
        let sideBySide = min(width, currentWidthPolicy?.maximum ?? width)
        let room = max(0, sideBySide - deviceTrailingInset(of: host.view))
        if room != hostInset {
            host.additionalSafeAreaInsets.right += room - hostInset
            hostInset = room
        }
        guard let container else { return }
        var insets = UIEdgeInsets.zero
        if width > 0, overlay?.superview === host.view {
            let current = container.view.safeAreaInsets
            let added = container.additionalSafeAreaInsets
            insets.top = host.view.safeAreaInsets.top - (current.top - added.top)
            insets.bottom = host.view.safeAreaInsets.bottom - (current.bottom - added.bottom)
            insets.right = deviceTrailingInset(of: host.view) - (current.right - added.right)
        }
        if container.additionalSafeAreaInsets != insets {
            container.additionalSafeAreaInsets = insets
        }
    }

    /// The window's trailing safe-area inset where `view` reaches the
    /// window's trailing edge, else 0 (a centered sheet).
    private func deviceTrailingInset(of view: UIView) -> CGFloat {
        guard let window = view.window else { return 0 }
        let maxX = view.convert(view.bounds, to: window).maxX
        return maxX >= window.bounds.maxX - 0.5 ? window.safeAreaInsets.right : 0
    }

    /// Removes the current panel, then installs the requested one. A panel
    /// removed under an active search left its bar over the chat, as a
    /// dismissed modal did (`Router.dismiss`), so the panel stays until the
    /// search has ended; ending a presented search completes later.
    private func removePanel() {
        guard !isRemoving else { return }
        guard let container else {
            installRequestedPanel()
            return
        }
        isRemoving = true
        // A grab mid-close would stop the close animation, and its
        // completion with it, leaving the panel half removed.
        dragStartWidth = nil
        overlay?.handle.isUserInteractionEnabled = false
        // Holds `self` until the panel is gone: a dismantled column must
        // still take its overlay off the host.
        Router.endSearch(in: container) { [self] in
            self.detach(animated: true) {
                self.container = nil
                self.overlay = nil
                self.panelID = nil
                self.panelConstraints = nil
                self.isFull = false
                self.isRemoving = false
                let waiters = self.closedWaiters
                self.closedWaiters = []
                for waiter in waiters { waiter() }
                self.installRequestedPanel()
            }
        }
    }

    // MARK: - Resize, expand, and close

    private func restingWidth(overlay: TrailingColumnOverlayView) -> CGFloat {
        guard let policy = currentWidthPolicy else { return 0 }
        if isFull { return policy.full }
        return rememberedWidth(policy: policy)
    }

    private func dragBegan() {
        guard !isRemoving, let overlay, let policy = currentWidthPolicy else { return }
        stopSettle()
        // A grab mid-settle picks the divider up where it is drawn.
        let raw = ColumnRubberBand.rawTarget(forLiveWidth: overlay.width, policy: policy)
        dragStartWidth = raw
        // Ticks only on crossing into another zone, not on the first move.
        dragZone = ColumnSnapResolver.zone(for: raw, policy: policy)
    }

    /// The remembered width in points: the last settled fraction against the
    /// current bounds, or the panel's own ideal width before anything was
    /// ever remembered.
    private func rememberedWidth(policy: TrailingColumnWidthPolicy) -> CGFloat {
        guard let fraction = overlay?.restingFraction, policy.window > 0 else { return policy.ideal }
        return policy.clampedToOrdinaryRange(fraction * policy.window)
    }

    private func dragChanged(translationX: CGFloat) {
        guard let overlay, let policy = currentWidthPolicy, let dragStartWidth else { return }
        // Dragging the handle toward the host (leading, negative x) widens
        // the column: width grows as `translationX` falls.
        let raw = dragStartWidth - translationX
        overlay.width = ColumnRubberBand.liveWidth(forRawTarget: raw, policy: policy)
        let zone = ColumnSnapResolver.zone(for: raw, policy: policy)
        if zone != dragZone {
            dragZone = zone
            AppHaptics.selectionChanged()
        }
    }

    private func dragEnded(translationX: CGFloat, velocityX: CGFloat) {
        guard let policy = currentWidthPolicy, let dragStartWidth else { return }
        self.dragStartWidth = nil
        dragZone = nil
        let widthVelocity = -velocityX
        let outcome = ColumnSnapResolver.resolve(
            rawWidth: dragStartWidth - translationX,
            widthVelocity: widthVelocity,
            policy: policy,
            rememberedWidth: rememberedWidth(policy: policy),
            wasFull: isFull
        )
        settle(outcome, initialVelocityPointsPerSecond: widthVelocity)
    }

    private func step(by delta: CGFloat) {
        guard !isRemoving, let overlay, let policy = currentWidthPolicy else { return }
        let target = policy.clampedToOrdinaryRange(overlay.width + delta)
        settle(.width(target), initialVelocityPointsPerSecond: 0)
    }

    private func requestExpandToFull() {
        settle(.full, initialVelocityPointsPerSecond: 0)
    }

    private func requestRestoreFromFull() {
        guard let policy = currentWidthPolicy else { return }
        settle(.width(rememberedWidth(policy: policy)), initialVelocityPointsPerSecond: 0)
    }

    private func settle(_ outcome: ColumnSnapOutcome, initialVelocityPointsPerSecond: CGFloat) {
        guard !isRemoving, let overlay, let policy = currentWidthPolicy else { return }
        switch outcome {
        case .closed:
            isFull = false
            onDismissRequested?()
        case .full:
            isFull = true
            overlay.isFull = true
            animateWidth(to: policy.full, initialVelocity: initialVelocityPointsPerSecond)
        case .width(let width):
            isFull = false
            overlay.isFull = false
            let fraction = policy.window > 0 ? width / policy.window : 0
            overlay.restingFraction = fraction
            AppPreferences.TrailingColumn.setWidthFraction(fraction)
            animateWidth(to: width, initialVelocity: initialVelocityPointsPerSecond)
        }
    }

    // MARK: - Testing

    /// The installed overlay's resize handle, so a test can drive a drag by
    /// calling its `onBegan`/`onChanged`/`onEnded` closures directly instead
    /// of synthesizing real touches: the exact closures a live pan gesture
    /// calls.
    var resizeHandleForTesting: TrailingColumnResizeHandle? { overlay?.handle }
    var widthForTesting: CGFloat? { overlay?.width }
    var isFullForTesting: Bool { isFull }
    var restingFractionForTesting: CGFloat? { overlay?.restingFraction }
    /// The panel's own screen, mounted at the root of the column's
    /// navigation controller, so a test can assert which destination the
    /// container is actually showing.
    var mountedScreenForTesting: UIViewController? { container?.viewControllers.first }
    /// Every screen on the column's own navigation controller, root first:
    /// a test can assert what a push inside the panel landed on top of.
    var mountedStackForTesting: [UIViewController]? { container?.viewControllers }
    var overlayForTesting: TrailingColumnOverlayView? { overlay }

    /// Lands an in-flight open, snap, or close at its end now, completion
    /// included, as if the spring had run out.
    func finishSettleForTesting() {
        guard let animator = settleAnimator else { return }
        animator.stopAnimation(false)
        animator.finishAnimation(at: .end)
    }

    /// Animates to `target` with an interruptible spring: a transition still
    /// in flight (a quick toggle, or a drag that starts mid-settle) stops in
    /// place and restarts from there, so the pane never jumps.
    private func animateWidth(to target: CGFloat, initialVelocity: CGFloat, completion: (() -> Void)? = nil) {
        guard let overlay, let host else {
            completion?()
            return
        }
        stopSettle()
        let distance = target - overlay.width
        let velocityVector = distance == 0 ? .zero : CGVector(dx: initialVelocity / distance, dy: 0)
        let timing = UISpringTimingParameters(dampingRatio: 0.86, initialVelocity: velocityVector)
        let animator = UIViewPropertyAnimator(duration: 0.42, timingParameters: timing)
        animator.addAnimations {
            overlay.width = target
            overlay.layoutIfNeeded()
            host.view.layoutIfNeeded()
        }
        animator.addCompletion { [weak self] _ in
            if self?.settleAnimator === animator {
                self?.settleAnimator = nil
            }
            completion?()
        }
        settleAnimator = animator
        animator.startAnimation()
    }

    /// Stops a settle in flight where it is drawn. `overlay.width` and the
    /// model frames already hold the old target, so the width is read back
    /// from the column's presentation layer; otherwise the next motion
    /// starts from the target and the pane jumps.
    private func stopSettle() {
        guard let animator = settleAnimator else { return }
        settleAnimator = nil
        let drawn = overlay.map { $0.column.layer.presentation()?.frame.width ?? $0.column.frame.width }
        animator.stopAnimation(true)
        if let overlay, let drawn {
            overlay.width = drawn
            overlay.layoutIfNeeded()
        }
    }
}

/// Covers the host's view and shows the column at its trailing edge, above
/// the host's navigation bar, with a draggable divider. Touches outside the
/// column reach the views below.
final class TrailingColumnOverlayView: UIView {
    /// What stays of the screen beside a full-window pane: a slim strip that
    /// carries the divider's grabber, the way back to side by side.
    nonisolated static let fullWindowGrabEdge: CGFloat = 20

    /// The column's own width, the one source of truth for layout; the
    /// controller sets it directly during a drag (cheap, every touch event)
    /// and through an animator for every open, close, and snap transition.
    var width: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }
    /// The last settled ordinary width, as a fraction of this overlay's own
    /// width, so it scales with rotation, Stage Manager resizing, and
    /// multitasking instead of freezing at a point value from a different
    /// window shape. Nil until the first resting width is known.
    var restingFraction: CGFloat?
    var onColumnWidth: ((CGFloat) -> Void)?
    /// This overlay's own width changed (a rotation, a Stage Manager live
    /// resize, or multitasking): a chance to rescale `width` from a
    /// proportional state before this same layout pass draws it, so the pane
    /// keeps its share of the window instead of keeping yesterday's points.
    var onBoundsWidthChanged: ((CGFloat) -> Void)?
    /// The controller's live width policy, for how much of the screen beside
    /// the pane covers past the side-by-side maximum.
    var widthPolicy: (() -> TrailingColumnWidthPolicy?)?
    /// Full window: the screen beside is covered, so VoiceOver stays in the
    /// pane and its divider instead of reading the hidden screen.
    var isFull = false {
        didSet {
            handle.isFull = isFull
            accessibilityViewIsModal = isFull
        }
    }

    private(set) var column: UIView
    private let divider = UIView()
    /// Paints over the part of the screen the pane has slid across past the
    /// side-by-side maximum, fading in until full leaves only the grab edge,
    /// so the screen reads as collapsing rather than squeezed under the pane.
    let cover = UIView()
    let handle = TrailingColumnResizeHandle()
    private var lastBoundsWidth: CGFloat?

    init(column: UIView) {
        self.column = column
        super.init(frame: .zero)
        backgroundColor = .clear
        divider.backgroundColor = .separator
        divider.isUserInteractionEnabled = false
        cover.isUserInteractionEnabled = false
        cover.alpha = 0
        addSubview(cover)
        addSubview(divider)
        addSubview(column)
        addSubview(handle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    /// A panel swap keeps this overlay and its width; only the hosted screen
    /// changes.
    func replaceColumn(_ newColumn: UIView) {
        column.removeFromSuperview()
        column = newColumn
        insertSubview(column, belowSubview: handle)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if lastBoundsWidth != bounds.width {
            // Only a change: the first layout, as the column attaches, must
            // leave the open's spring to carry the width from zero, or the
            // pane pops in at its full width.
            let changed = lastBoundsWidth != nil
            lastBoundsWidth = bounds.width
            if changed { onBoundsWidthChanged?(bounds.width) }
        }
        // The host may add views (a toolbar) above this one. Only when one
        // did: reordering dirties the host's layout, which would reflow the
        // screen beside on every drag frame.
        if let superview, superview.subviews.last !== self {
            superview.bringSubviewToFront(self)
        }
        let hairline = 1 / max(traitCollection.displayScale, 1)
        let width = max(0, min(self.width, bounds.width))
        column.frame = CGRect(x: bounds.maxX - width, y: 0, width: width, height: bounds.height)
        divider.frame = CGRect(x: column.frame.minX - hairline, y: 0, width: hairline, height: bounds.height)
        cover.frame = CGRect(x: 0, y: 0, width: max(0, divider.frame.minX), height: bounds.height)
        cover.alpha = coverAlpha(forColumnWidth: width)
        // The handle straddles the divider. Near the leading edge (full
        // window) it takes the whole grab edge, so a touch there drags the
        // pane rather than reaching the covered screen underneath.
        let hitWidth = TrailingColumnResizeHandle.hitWidth
        if column.frame.minX <= hitWidth {
            handle.frame = CGRect(x: 0, y: 0, width: column.frame.minX + hitWidth / 2, height: bounds.height)
        } else {
            let handleX = min(column.frame.minX - hitWidth / 2, bounds.width - hitWidth)
            handle.frame = CGRect(x: handleX, y: 0, width: hitWidth, height: bounds.height)
        }
        handle.isHidden = width <= 0
        handle.columnWidth = width
        onColumnWidth?(width)
    }

    /// 0 up to the side-by-side maximum, 1 at full.
    private func coverAlpha(forColumnWidth width: CGFloat) -> CGFloat {
        guard let policy = widthPolicy?(), policy.full > policy.maximum else { return 0 }
        return min(1, max(0, (width - policy.maximum) / (policy.full - policy.maximum)))
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        // The host's insets moved (its bar or the status bar): re-measure.
        setNeedsLayout()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if handle.frame.contains(point), !handle.isHidden { return super.hitTest(point, with: event) }
        guard column.frame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}
