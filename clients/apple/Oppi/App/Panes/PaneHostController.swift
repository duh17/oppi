import UIKit

/// The widths a companion asks for: its own minimum, the width it opens at,
/// and an optional ceiling for ordinary dragging (nil picks one generous
/// enough for most content without being the whole window).
struct PaneCompanionWidths: Equatable {
    var minimum: CGFloat
    var ideal: CGFloat
    var maximum: CGFloat?
}

/// The window's pane area: the primary leaf (the shell's stack, or a
/// harness's) and at most one companion beside it, the attached leaf a screen
/// in the primary asked for (`AttachedLeafController`). The host owns where
/// the two sit, the divider between them, which leaf is focused, what each
/// leaf can see of itself (`PaneVisibility`), and the keyboard rule
/// (`PaneKeyboardFollowing`). The companion is a real child, so UIKit forwards
/// its appearance, presents from it, and gives it the window's safe area at
/// the trailing edge.
///
/// The companion lays out compact (`AttachedLeafController` sets the trait),
/// as an inspector does. Its width is a share of the host's width, remembered
/// per pairing (`PanePairing`: a chat and a reader, the File Browser and its
/// file) across hosts and launches by the window's `ScenePanes`, which
/// also hears which companion is shown and which leaf is focused. Past the
/// side-by-side maximum it slides over the primary, which keeps its width and
/// is covered, up to the full window but a grab edge. A companion whose
/// minimum does not fit beside the primary's opens full.
///
/// The tree's other leaves, the ones Split made, are stacks of their own laid
/// out with the primary's cell by the fit rule (`PaneHostController+Tree`):
/// the primary and its companion share that cell exactly as they share the
/// window when it has no other leaf.
final class PaneHostController: UIViewController {
    enum Leaf: Equatable { case primary, companion, split(PaneID) }

    let primary: UIViewController
    /// The window's pane tree: the companion's share, zoom and focus live
    /// there, the host only draws them. A harness host gets one of its own.
    let panes: ScenePanes
    /// How long a parked companion's view stays in the hierarchy, hidden, so
    /// a quick return (a push and pop over its owner) does not rebuild it.
    let parkedViewLifetime: TimeInterval
    var focusedLeaf: Leaf {
        let focus = panes.tree.focus
        if splitLeaves[focus] != nil { return .split(focus) }
        return companion != nil && panes.isCompanionFocused ? .companion : .primary
    }

    private struct Companion {
        let controller: UIViewController
        weak var owner: AttachedLeafController?
        var widths: PaneCompanionWidths
        /// Its pairing's key (`PanePairing`): the share it rests at is
        /// remembered per pairing.
        var pairing: String
        /// The companion's link, for restoration; nil when it has none.
        var route: PaneStackEntry?
    }

    private var companion: Companion?
    /// Companions whose owner left, still in the hierarchy until their timer.
    private var parked: [(controller: UIViewController, release: Timer)] = []

    private let divider = PaneDividerView(index: 0)
    private let hairline = UIView()
    /// Paints over the part of the primary the companion has slid across past
    /// the side-by-side maximum, fading in until full leaves only the grab
    /// edge, so the primary reads as collapsing rather than squeezed.
    let cover = UIView()

    /// The companion's drawn width, the one source of truth for layout: set
    /// directly during a drag, and through an animator for every open,
    /// close, and snap.
    private var width: CGFloat = 0
    /// The last settled ordinary width as a fraction of the host's width (the
    /// tree's weight), so it scales with rotation and window resizing. Nil
    /// until known.
    private var restingFraction: CGFloat? { panes.companionShare.map { CGFloat($0) } }
    /// The person chose full: the tree's zoom of the companion, not the fit
    /// rule's.
    private var isFull: Bool { panes.isCompanionZoomed && !panes.companionZoomIsFit }
    private var isClosing = false
    private var lastBoundsWidth: CGFloat?

    /// The finger's raw target at the drag's start; nil outside a drag.
    private var dragStartWidth: CGFloat?
    /// Whether the companion filled the window when its owner left, so it
    /// returns as it was.
    private var zoomedWhenParked = false
    private var dragZone: PaneSnapZone?
    private var settleAnimator: UIViewPropertyAnimator?

    /// The window is being resized live (a Stage Manager corner, a Mac
    /// window edge): frames follow, and what a leaf hears about itself (its
    /// visibility, a parked companion's release) waits for the resize to end.
    private(set) var isLiveResizing = false
    private var geometryObservation: NSKeyValueObservation?
    /// Parked companions whose time ran out during a live resize.
    private var releasesAfterLiveResize: [UIViewController] = []

    /// The screens on either side that hold their heavy views while the
    /// divider moves or the window resizes, and settle once.
    private lazy var resizeHold = PaneResizeHold(
        leaves: { [weak self] in
            [self?.primary, self?.companion?.controller] + (self?.splitLeaves.values.map(\.controller) ?? [])
        },
        layout: { [weak self] in self?.view.layoutIfNeeded() }
    )

    /// What each leaf's screens were last told, by leaf controller: the
    /// visibility and the screens that heard it, so a screen pushed inside
    /// a leaf later hears the current visibility once. The screens are held
    /// weakly by identity, so a new screen at a freed screen's address has
    /// not heard anything. A leaf's entry goes when the leaf leaves the host.
    private var reported: [ObjectIdentifier: (visibility: PaneVisibility, screens: NSHashTable<UIViewController>)] = [:]

    // The tree's other cells (`PaneHostController+Tree`).
    var splitLeaves: [PaneID: PaneSplitLeaf] = [:]
    var splitDividers: [PaneSplitDividerView] = []
    var grips: [PaneID: PaneGripView] = [:]
    var strips: [PaneID: PaneStripView] = [:]
    /// The pane chip a compact window shows in place of the grips.
    lazy var chip = makeChip()
    /// The toast that offers Undo after a pane change.
    lazy var undoToast = makeUndoToast()
    var splitDrag: PaneSplitDrag?
    /// Where each cell sits after the last layout pass.
    var cellPresentation: PanePresentation?
    /// The primary's cell, which it shares with its companion; zero while
    /// it is in overflow or behind another cell's zoom.
    var routedCell: CGRect = .zero
    /// The zone a drag over the panes would drop into (`+Drop`).
    let dropHighlight = UIView()
    /// The software keyboard's overlap with the host's bottom edge; the fit
    /// rule draws a field's cell over its column when that leaves it short.
    var keyboardHeight: CGFloat = 0

    init(primary: UIViewController, panes: ScenePanes = ScenePanes(), parkedViewLifetime: TimeInterval = 10) {
        self.primary = primary
        self.panes = panes
        self.parkedViewLifetime = parkedViewLifetime
        super.init(nibName: nil, bundle: nil)
    }

    /// The host either of whose leaves holds `controller`.
    static func containing(_ controller: UIViewController) -> PaneHostController? {
        var current = controller.parent
        while let candidate = current {
            if let host = candidate as? PaneHostController { return host }
            current = candidate.parent
        }
        return nil
    }

    /// A leaf's navigation controller is about to show another screen (a
    /// push, a pop, a back swipe): the panes lay out again, so the screen
    /// gets its grip strip before it shows and the grip moves to that
    /// screen's slot instead of keeping the last one's place.
    func leafWillShowScreen() {
        view.setNeedsLayout()
    }

    /// The main leaf (the shell's stack) is about to show another screen.
    /// Sidebar taps, links, notifications and Settings all open there, so a
    /// main leaf behind another pane's zoom, collapsed, or in overflow is
    /// brought back and focused; otherwise the navigation would seem to do
    /// nothing. The screens a relaunch restores are not navigation and keep
    /// a restored zoom (`ScenePanes.mainStackNavigated`).
    func mainLeafWillShowScreen() {
        leafWillShowScreen()
        guard panes.mainStackNavigated() else { return }
        let id = panes.mainLeafID
        guard cellFrame(id) == nil || panes.collapsedCells.contains(id) else { return }
        focus(cell: id)
        announceLayoutChange()
    }

    /// A leaf's navigation controller showed another screen: it hears the
    /// leaf's current visibility, as its siblings did at the transition, and
    /// the grip settles on the screen's slot now that its bar is final.
    func leafDidShowScreen() {
        updateVisibility()
        view.setNeedsLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The host whose primary leaf holds `controller`; nil inside a
    /// companion, or outside any host.
    static func hosting(_ controller: UIViewController) -> PaneHostController? {
        var child = controller
        while let parent = child.parent {
            if let host = parent as? PaneHostController {
                return host.primary === child ? host : nil
            }
            child = parent
        }
        return nil
    }

    /// The focused leaf's controller: Find, Close, a link's push and a
    /// screen-less presentation act there. A companion that covers the
    /// primary is the only leaf showing.
    var focusedLeafController: UIViewController {
        if case .split(let id) = focusedLeaf, let leaf = splitLeaves[id] { return leaf.controller }
        let companionInFront = focusedLeaf == .companion || showsFull
        return companionInFront ? companion?.controller ?? primary : primary
    }

    /// The front screen of the focused leaf.
    var focusedScreen: UIViewController? {
        Self.frontScreen(of: focusedLeafController)
    }

    /// The front screen of each leaf, the focused leaf's first.
    var leafScreens: [UIViewController] {
        let focused = focusedLeafController
        let leaves: [UIViewController] = [primary, companion?.controller].compactMap { $0 }
            + panes.splitLeaves.compactMap { splitLeaves[$0.id]?.controller }
        let others = leaves.filter { $0 !== focused }
        return ([focused] + others).map(Self.frontScreen(of:))
    }

    private static func frontScreen(of leaf: UIViewController) -> UIViewController {
        (leaf as? UINavigationController)?.topViewController ?? leaf
    }

    override var childForStatusBarStyle: UIViewController? { primary }
    override var childForStatusBarHidden: UIViewController? { primary }
    override var childForHomeIndicatorAutoHidden: UIViewController? { primary }

    /// True while the shell moves the host into another layout.
    private var isMovingBetweenLayouts = false

    /// The leaves never leave the window while the shell moves the host
    /// between its layouts, so they are not told they disappeared and
    /// appeared: a chat that heard it ended its dictation and its stream.
    override var shouldAutomaticallyForwardAppearanceMethods: Bool { !isMovingBetweenLayouts }

    /// Runs the shell's move of the host to another layout (`body`), and
    /// keeps appearance from reaching the leaves until that move has settled
    /// (a navigation controller finishes showing its new root a turn later).
    /// UIKit takes the host's view out of the window for the move, which
    /// resigns the first responder; the field that had the keyboard (the
    /// composer, mid-sentence) takes it back in the same turn.
    func movesBetweenLayouts(_ body: () -> Void) {
        let responder = Self.firstResponder(in: view)
        isMovingBetweenLayouts = true
        body()
        if let responder, responder.window != nil, !responder.isFirstResponder {
            responder.becomeFirstResponder()
        }
        DispatchQueue.main.async { [weak self] in self?.isMovingBetweenLayouts = false }
    }

    static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let found = firstResponder(in: subview) { return found }
        }
        return nil
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        // The split view wraps its secondary column in a navigation
        // controller; the leaves bring their own bars.
        navigationController?.updateNavigationBar(for: self, animated: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.updateNavigationBar(for: self, animated: false)
    }

    override func loadView() {
        let view = PaneHostView()
        view.onTouch = { [weak self] point in self?.touched(at: point) }
        view.onWindowChange = { [weak self] in self?.observeWindowGeometry() }
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(primary)
        view.addSubview(primary.view)
        primary.didMove(toParent: self)
        hairline.backgroundColor = .separator
        hairline.isUserInteractionEnabled = false
        cover.isUserInteractionEnabled = false
        cover.accessibilityIdentifier = "pane.cover"
        cover.alpha = 0
        cover.isHidden = true
        hairline.isHidden = true
        divider.isHidden = true
        view.addSubview(cover)
        view.addSubview(hairline)
        view.addSubview(divider)
        divider.onBegan = { [weak self] in self?.dragBegan() }
        divider.onChanged = { [weak self] translationX in self?.dragChanged(translationX: translationX) }
        divider.onEnded = { [weak self] translation, velocity in
            self?.dragEnded(translation: translation, velocity: velocity)
        }
        divider.onStep = { [weak self] delta in self?.step(by: delta) }
        divider.onExpandRequested = { [weak self] in self?.settle(.full, initialVelocityPointsPerSecond: 0) }
        divider.onRestoreRequested = { [weak self] in self?.restoreFromFull() }
        divider.onCloseRequested = { [weak self] in self?.companion?.owner?.dividerRequestedClose() }
        divider.onResetRequested = { [weak self] in self?.resetCompanionWidth() }
        installDropInteraction()
        // Tab and Full Keyboard Access move between panes as groups.
        primary.view.focusGroupIdentifier = "pane.\(panes.mainLeafID.raw)"
        view.accessibilityCustomRotors = [makePanesRotor()]
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(inputBeganEditing(_:)), name: name, object: nil
            )
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil
        )
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the theme store changes.
        cover.backgroundColor = AppRootEnvironment.near(self)?.themeStore.backgroundColor ?? .systemBackground
        // Reading the tree here re-runs this when a split, close, focus or
        // weight changes it, and the routes when a leaf shows something else.
        _ = panes.tree
        _ = panes.stacks
        // And a sheet waiting its turn, for its pane's grip.
        _ = panes.sheets.waitingOwners
        syncSplitLeaves()
        view.setNeedsLayout()
    }

    /// The sidebar showing or hiding changes the leading safe area, and with
    /// it the width the companion has beside the primary (`companionWindow`).
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        resolveCells()
        // The width the primary and its companion share: the window, or what
        // the split leaves and the sidebar leave of it.
        let cellWidth = routedCell.width > 0 ? companionWindow : 0
        if cellWidth > 0, lastBoundsWidth != cellWidth {
            // Only a change: the first layout, as a companion opens, must
            // leave the open's spring to carry the width from zero.
            let changed = lastBoundsWidth != nil
            lastBoundsWidth = cellWidth
            if changed {
                boundsWidthChanged()
                windowWidthChanged()
            }
        }
        layoutLeaves()
        layoutSplitLeaves()
    }

    // MARK: Hold and settle for the tree's dividers

    func holdForResize(beginningAt length: CGFloat) {
        stopSettle()
        resizeHold.dragBegan(at: length)
    }

    func resizeMoved(to length: CGFloat) {
        resizeHold.dividerMoved(to: length) { [weak self] in self?.splitDrag != nil }
        resizeHold.measureFrame {
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }
    }

    func resizeEnded() {
        resizeHold.dragEnded()
        resizeHold.finish()
        resizeHold.takeVisit().map { Telemetry.record($0) }
        updateVisibility()
    }

    /// A window resize (rotation, Split View, Stage Manager, a Mac window
    /// edge) is held and settled like a divider: the leaves hold at their
    /// widths from the first change, and reflow once, keeping their reading
    /// position, when the width has rested (`PaneResizeHold`). A rotation is one
    /// change and one settle; a live resize reflows nothing while it moves.
    /// Without it a chat on its tail kept its old offset over a new content
    /// height and landed mid-history. A settle spring in flight (an open or
    /// a close) owns the hold and settles at its end.
    private func windowWidthChanged() {
        guard settleAnimator == nil, dragStartWidth == nil else { return }
        resizeHold.windowWidthChanged(live: isLiveResizing) { [weak self] in
            guard let self else { return false }
            return self.dragStartWidth == nil && self.settleAnimator == nil
        }
    }

    /// Follows the window scene's live resize
    /// (`effectiveGeometry.isInteractivelyResizing`) for the window the host
    /// is in now.
    private func observeWindowGeometry() {
        geometryObservation = view.window?.windowScene?.observe(
            \.effectiveGeometry, options: [.initial, .new]
        ) { [weak self] scene, _ in
            MainActor.assumeIsolated {
                self?.windowLiveResizeChanged(scene.effectiveGeometry.isInteractivelyResizing)
            }
        }
    }

    /// The person began or ended resizing the window live. The leaves hold
    /// from the start, as for a divider, and settle at each pause and once at
    /// the end (`PaneResizeHold`). Back and forth across the fit rule's
    /// boundary the companion's frame follows, but its leaves hear their
    /// visibility, and a parked companion is released, only at the end. A
    /// resize that is not live (rotation, tiling, full screen) is one settle
    /// (`windowWidthChanged`).
    func windowLiveResizeChanged(_ resizing: Bool) {
        guard resizing != isLiveResizing else { return }
        isLiveResizing = resizing
        guard view.window != nil else { return }
        if resizing {
            guard settleAnimator == nil, dragStartWidth == nil else { return }
            resizeHold.liveResizeBegan()
            return
        }
        resizeHold.liveResizeEnded()
        let releases = releasesAfterLiveResize
        releasesAfterLiveResize = []
        for controller in releases { releaseParked(controller) }
        updateVisibility()
    }

    // MARK: Companion

    /// Shows `controller` beside the primary. `opening` slides it in from
    /// zero width out of the remembered width, else it returns at once at
    /// the width it rests at (its owner came back, or it was rebuilt).
    func mountCompanion(
        _ controller: UIViewController,
        widths: PaneCompanionWidths,
        pairing: String,
        route: PaneStackEntry? = nil,
        owner: AttachedLeafController,
        opening: Bool
    ) {
        loadViewIfNeeded()
        if let current = companion, current.controller !== controller {
            parkCompanion(current.controller)
        }
        if let index = parked.firstIndex(where: { $0.controller === controller }) {
            parked[index].release.invalidate()
            parked.remove(at: index)
        }
        companion = Companion(controller: controller, owner: owner, widths: widths, pairing: pairing, route: route)
        panes.companionDidOpen(route, pairing: pairing) { [weak self] in self?.drawnShare }
        let restored = panes.takeRestoredCompanionState()
        panes.setCompanionZoomed(opening ? restored.zoomed : zoomedWhenParked)
        applyFitRule()
        controller.view.focusGroupIdentifier = "pane.\(panes.mainLeafID.raw).companion"
        if controller.parent !== self {
            addChild(controller)
            view.insertSubview(controller.view, belowSubview: divider)
            controller.didMove(toParent: self)
        }
        controller.view.isHidden = false
        let target = restingWidth
        width = opening ? 0 : target
        view.setNeedsLayout()
        view.layoutIfNeeded()
        if opening {
            animateWidth(to: target, initialVelocity: 0)
        }
        if restored.focused {
            focus(.companion)
        }
        updateVisibility()
    }

    /// Whether `controller`, the shown companion, fills the window by the
    /// person's choice; nil when it is not the companion or does not fit
    /// beside its leaf (full by the fit rule, which only Close ends).
    func companionFillsWindow(_ controller: UIViewController) -> Bool? {
        guard companion?.controller === controller, let policy, policy.fitsBeside else { return nil }
        return isFull
    }

    /// Fills the window with the companion, or returns it beside its leaf at
    /// the width it rests at.
    func setCompanion(_ controller: UIViewController, fillsWindow fills: Bool) {
        guard companionFillsWindow(controller) == !fills else { return }
        if fills {
            settle(.full, initialVelocityPointsPerSecond: 0)
        } else {
            restoreFromFull()
        }
    }

    /// The owner's panel asked for other widths: the divider's range follows
    /// at once; the drawn width stays until the next drag or resize.
    func updateCompanionWidths(_ controller: UIViewController, _ widths: PaneCompanionWidths) {
        guard companion?.controller === controller, companion?.widths != widths else { return }
        companion?.widths = widths
        applyFitRule()
        view.setNeedsLayout()
    }

    /// Replaces the shown companion in place: the full state stays, and so
    /// does the width within a pairing, so the pane does not close and
    /// reopen for a second reflow. Another pairing (a list replaced by a
    /// reader) moves to the width that pairing rests at.
    func replaceCompanion(
        _ old: UIViewController,
        with new: UIViewController,
        widths: PaneCompanionWidths,
        pairing: String,
        route: PaneStackEntry? = nil
    ) {
        guard let current = companion, current.controller === old else {
            releaseParked(old)
            return
        }
        removeChild(old)
        companion = Companion(controller: new, owner: current.owner, widths: widths, pairing: pairing, route: route)
        panes.companionDidOpen(route, pairing: pairing) { [weak self] in self?.drawnShare }
        applyFitRule()
        addChild(new)
        view.insertSubview(new.view, belowSubview: divider)
        new.didMove(toParent: self)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        if current.pairing != pairing, !showsFull, settleAnimator == nil, dragStartWidth == nil {
            animateWidth(to: restingWidth, initialVelocity: 0)
        }
        updateVisibility()
    }

    /// The owner left the window (a push or a modal covered it): the
    /// companion hides now, and its view leaves the hierarchy
    /// `parkedViewLifetime` later unless the owner returns first.
    func parkCompanion(_ controller: UIViewController) {
        // A close under way ends now, its completion included: stopping it
        // in place would strand the owner waiting for it.
        if isClosing, let animator = settleAnimator {
            animator.stopAnimation(false)
            animator.finishAnimation(at: .end)
        }
        guard companion?.controller === controller else { return }
        endMotion()
        zoomedWhenParked = isFull
        companion = nil
        controller.view.isHidden = true
        let timer = Timer.scheduledTimer(withTimeInterval: parkedViewLifetime, repeats: false) { [weak self, weak controller] _ in
            MainActor.assumeIsolated {
                guard let self, let controller else { return }
                if self.isLiveResizing {
                    self.releasesAfterLiveResize.append(controller)
                } else {
                    self.releaseParked(controller)
                }
            }
        }
        parked.append((controller, timer))
        companionLeft()
        report(.parked, to: controller)
    }

    /// Takes a parked companion's view out now (its timer ran out, or a
    /// memory warning dropped it, or its owner closed it while away).
    func releaseParked(_ controller: UIViewController) {
        guard let index = parked.firstIndex(where: { $0.controller === controller }) else { return }
        parked[index].release.invalidate()
        parked.remove(at: index)
        removeChild(controller)
        controller.view.isHidden = false
    }

    /// Slides the shown companion out, then removes it.
    func closeCompanion(_ controller: UIViewController, completion: @escaping () -> Void) {
        guard companion?.controller === controller else {
            releaseParked(controller)
            completion()
            return
        }
        isClosing = true
        // A grab mid-close would stop the close animation, and its
        // completion with it, leaving the companion half removed.
        dragStartWidth = nil
        divider.isUserInteractionEnabled = false
        let finish: () -> Void = { [weak self] in
            guard let self else {
                completion()
                return
            }
            self.endMotion()
            if self.companion?.controller === controller {
                self.companion = nil
                self.removeChild(controller)
            }
            self.isClosing = false
            self.divider.isUserInteractionEnabled = true
            self.companionLeft()
            completion()
        }
        guard view.window != nil else {
            finish()
            return
        }
        animateWidth(to: 0, initialVelocity: 0, completion: finish)
    }

    /// Unmounts a leaf and forgets what its screens were told, so a later
    /// leaf at the same address starts with nothing heard.
    func removeChild(_ controller: UIViewController) {
        reported[ObjectIdentifier(controller)] = nil
        guard controller.parent === self else { return }
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    /// The primary has the host to itself again.
    private func companionLeft() {
        width = 0
        panes.companionDidClose()
        applyKeyboardFollowing(firstResponderIn: nil)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        updateVisibility()
    }

    /// Ends any drag or settle in flight and settles the held screens.
    private func endMotion() {
        stopSettle()
        dragStartWidth = nil
        dragZone = nil
        resizeHold.finish()
        resizeHold.takeVisit().map { Telemetry.record($0) }
    }

    // MARK: Layout

    private var policy: PaneWidthPolicy? {
        guard let widths = companion?.widths else { return nil }
        return PaneWidthPolicy.resolved(
            minWidth: widths.minimum,
            idealWidth: widths.ideal,
            maxWidth: widths.maximum,
            window: companionWindow
        )
    }

    /// The width the primary and its companion share on screen: the primary's
    /// cell, less what the split view's sidebar covers of it. The sidebar
    /// floats over the host's leading edge and reaches it as the leading safe
    /// area (`presentation(of:)`), so beside it the two fit, or the companion
    /// covers the primary, by the width the person can see.
    private var companionWindow: CGFloat {
        let cell = routedCell.width > 0 ? routedCell : view.bounds
        let covered = max(0, view.safeAreaInsets.left - cell.minX)
        return max(0, cell.width - covered)
    }

    private var restingWidth: CGFloat {
        guard let policy else { return 0 }
        if showsFull { return policy.full }
        return rememberedWidth(policy: policy)
    }

    /// The companion's ordinary width as a share of the host, for the tree's
    /// weight before a share was ever settled.
    private var drawnShare: Double? {
        guard let policy, policy.window > 0 else { return nil }
        return Double(rememberedWidth(policy: policy) / policy.window)
    }

    /// The companion covers the primary: the person chose full, or it does
    /// not fit beside it.
    private var showsFull: Bool {
        isFull || policy?.fitsBeside == false
    }

    /// The companion's navigation, while one is open.
    var companionController: UIViewController? { companion?.controller }

    /// The companion, while it covers the primary (`showsFull`).
    var companionCoveringPrimary: UIViewController? { showsFull ? companion?.controller : nil }

    /// The fit rule (build plan §1.3): a companion that does not fit beside
    /// its leaf at both minimums shows full, as the tree's zoom of it, and
    /// its divider offers only Close. When the window fits both again (a
    /// rotation back, a wider window) the zoom ends and the companion returns
    /// beside its leaf at the share it had; a full the person chose stays.
    private func applyFitRule() {
        guard companion != nil else { return }
        if policy?.fitsBeside == false, !isFull {
            panes.setCompanionZoomed(true, byFit: true)
        } else if panes.companionZoomIsFit {
            panes.setCompanionZoomed(false)
        }
    }

    /// The remembered width in points: the last settled fraction against the
    /// current bounds, or the companion's own ideal width before anything was
    /// ever remembered.
    private func rememberedWidth(policy: PaneWidthPolicy) -> CGFloat {
        guard let restingFraction, policy.window > 0 else { return policy.ideal }
        return policy.clampedToOrdinaryRange(restingFraction * policy.window)
    }

    /// A rotation or window resize. A drag in flight cancels at the last
    /// settled width; a settle in flight owns the width this frame; a
    /// resting companion keeps its share of the host.
    private func boundsWidthChanged() {
        if dragStartWidth != nil {
            dragStartWidth = nil
            dragZone = nil
            divider.cancelDrag()
            resizeHold.finish()
        }
        applyFitRule()
        guard settleAnimator == nil, companion != nil else { return }
        width = restingWidth
        if !isLiveResizing { updateVisibility() }
    }

    /// Lays the primary and its companion out in the primary's cell.
    private func layoutLeaves() {
        let bounds = routedCell
        let cellShown = bounds.width > 0
        primary.view.isHidden = !cellShown
        companion?.controller.view.isHidden = !cellShown
        guard cellShown, let companion, let policy else {
            if cellShown { primary.view.frame = bounds }
            for decoration in [cover, hairline, divider] as [UIView] { decoration.isHidden = true }
            primary.view.accessibilityElementsHidden = false
            return
        }
        let drawn = max(0, min(width, bounds.width))
        // Past the side-by-side maximum the companion slides over the
        // primary, which keeps the width it had there instead of squeezing
        // (and reflowing every frame) on the way to full.
        let sideBySide = min(drawn, policy.maximum)
        primary.view.frame = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width - sideBySide, height: bounds.height)
        let companionFrame = CGRect(x: bounds.maxX - drawn, y: bounds.minY, width: drawn, height: bounds.height)
        companion.controller.view.frame = companionFrame
        let line = 1 / max(traitCollection.displayScale, 1)
        hairline.frame = CGRect(x: companionFrame.minX - line, y: bounds.minY, width: line, height: bounds.height)
        cover.frame = CGRect(
            x: bounds.minX, y: bounds.minY, width: max(0, hairline.frame.minX - bounds.minX), height: bounds.height
        )
        cover.alpha = policy.full > policy.maximum
            ? min(1, max(0, (drawn - policy.maximum) / (policy.full - policy.maximum)))
            : 0
        // The divider straddles the hairline. Near the leading edge (full
        // window) it takes the whole grab edge, so a touch there drags the
        // companion rather than reaching the covered primary.
        let hitWidth = PaneDividerView.hitWidth
        if companionFrame.minX - bounds.minX <= hitWidth {
            divider.frame = CGRect(
                x: bounds.minX, y: bounds.minY, width: companionFrame.minX - bounds.minX + hitWidth / 2, height: bounds.height
            )
        } else {
            let x = min(companionFrame.minX - hitWidth / 2, bounds.maxX - hitWidth)
            divider.frame = CGRect(x: x, y: bounds.minY, width: hitWidth, height: bounds.height)
        }
        cover.isHidden = false
        hairline.isHidden = drawn <= 0
        divider.isHidden = drawn <= 0
        divider.companionWidth = drawn
        divider.mode = !policy.fitsBeside ? .noRoomBeside : isFull ? .full : .beside
        // Full window: VoiceOver stays in the companion and its divider
        // instead of reading the covered primary.
        primary.view.accessibilityElementsHidden = showsFull
        view.bringSubviewToFront(divider)
    }

    // MARK: Focus, keyboard, visibility

    private func touched(at point: CGPoint) {
        guard !divider.frame.contains(point) || divider.isHidden else { return }
        guard !splitDividers.contains(where: { $0.frame.contains(point) }) else { return }
        if let (id, _) = splitLeaves.first(where: { !$0.value.controller.view.isHidden && $0.value.controller.view.frame.contains(point) }) {
            // Hit testing must not lay the panes out (it moves the grip the
            // touch is landing on); the next pass draws the new focus.
            panes.focus(id)
            view.setNeedsLayout()
            updateVisibility()
            return
        }
        let inCompanion = companion.map { $0.controller.view.frame.contains(point) } ?? false
        focus(inCompanion ? .companion : .primary)
    }

    /// The focus system (Tab, Full Keyboard Access) moved into a leaf: pane
    /// focus follows, as it does for a touch.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let next = context.nextFocusedView, next.isDescendant(of: view) else { return }
        if let (id, _) = splitLeaves.first(where: { next.isDescendant(of: $0.value.controller.view) }) {
            focus(cell: id)
        } else if let companion, next.isDescendant(of: companion.controller.view) {
            focus(.companion)
        } else if next.isDescendant(of: primary.view) {
            focus(.primary)
        }
    }

    /// The companion takes focus, as a touch in it does: its owner asked
    /// (a tap on the pill of the panel it shows).
    func focusCompanion() {
        focus(.companion)
    }

    private func focus(_ leaf: Leaf) {
        if case .split(let id) = leaf { return focus(cell: id) }
        guard focusedLeaf != leaf, leaf == .primary || companion != nil else { return }
        if case .split = focusedLeaf { panes.focus(panes.mainLeafID) }
        panes.focusCompanion(leaf == .companion)
        updateVisibility()
    }

    /// A field began editing: its leaf takes focus, and only that leaf
    /// follows the keyboard. A field outside both (a sheet over the window)
    /// leaves every leaf following it. A field begins editing before the
    /// keyboard moves, so the leaves are settled when it does.
    @objc private func inputBeganEditing(_ notification: Notification) {
        guard let input = notification.object as? UIView, let window = view.window, input.window === window else { return }
        if let (id, _) = splitLeaves.first(where: { input.isDescendant(of: $0.value.controller.view) }) {
            applyKeyboardFollowing(firstResponderIn: nil)
            focus(cell: id)
            return
        }
        let leaf: Leaf? = if let companion, input.isDescendant(of: companion.controller.view) {
            .companion
        } else if input.isDescendant(of: primary.view) {
            .primary
        } else {
            nil
        }
        applyKeyboardFollowing(firstResponderIn: leaf)
        if let leaf { focus(leaf) }
    }

    /// The keyboard moves: the panes lay out again with its overlap, in its
    /// animation, so a field's cell that it would leave short takes its
    /// column (`presentation(of:)`) as the keyboard rises, and gives it back
    /// as it falls. One pane has nothing to give way to: its screens follow
    /// the keyboard themselves.
    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let space = view.window?.windowScene?.screen.coordinateSpace,
              let end = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let frame = space.convert(end, to: view)
        // Only a keyboard docked at the bottom takes room; a floating one
        // (or a split one) sits over the panes.
        let docked = frame.intersects(view.bounds) && frame.maxY >= view.bounds.maxY - 1
        let overlap = docked ? max(0, view.bounds.maxY - frame.minY) : 0
        guard overlap != keyboardHeight else { return }
        keyboardHeight = overlap
        guard panes.cellLayout.leaves.count > 1 else { return }
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25
        let curve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? UIView.AnimationCurve.easeInOut.rawValue
        UIView.animate(withDuration: duration, delay: 0, options: UIView.AnimationOptions(rawValue: UInt(curve) << 16)) {
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
        updateVisibility()
    }

    private func applyKeyboardFollowing(firstResponderIn leaf: Leaf?) {
        for screen in PaneLeafScreens.adopters(in: primary, as: (any PaneKeyboardFollowing).self) {
            screen.followsKeyboard = leaf != .companion
        }
        for screen in PaneLeafScreens.adopters(in: companion?.controller, as: (any PaneKeyboardFollowing).self) {
            screen.followsKeyboard = leaf != .primary
        }
    }

    /// Tells each leaf's screens what they can see now, once per change.
    func updateVisibility() {
        let routedShown = routedCell.width > 0 || cellPresentation == nil
        // A cell the keyboard's zoom hides for a moment is covered, not
        // parked: it comes back as the keyboard falls.
        let hiddenByKeyboard: (PaneID) -> Bool = { [cellPresentation] id in
            cellPresentation.map { $0.zoomedForKeyboard != nil && $0.frames[id] == nil && !$0.overflow.contains(id) } ?? false
        }
        let routedHidden: PaneVisibility = hiddenByKeyboard(panes.mainLeafID) ? .covered : .parked
        let covered = companion != nil && showsFull
        report(
            !routedShown ? routedHidden : covered ? .covered : .visible(focused: focusedLeaf == .primary),
            to: primary
        )
        if let companion {
            report(routedShown ? .visible(focused: focusedLeaf == .companion) : routedHidden, to: companion.controller)
        }
        let collapsed = panes.collapsedCells
        for (id, leaf) in splitLeaves {
            let shown = cellPresentation?.frames[id] != nil && !collapsed.contains(id)
            let hidden: PaneVisibility = !collapsed.contains(id) && hiddenByKeyboard(id) ? .covered : .parked
            report(shown ? .visible(focused: focusedLeaf == .split(id)) : hidden, to: leaf.controller)
        }
    }

    private func report(_ visibility: PaneVisibility, to leaf: UIViewController) {
        let key = ObjectIdentifier(leaf)
        let screens = PaneLeafScreens.adopters(in: leaf, as: (any PaneVisibilityObserving).self)
        let previous = reported[key]
        // A changed visibility reaches every screen; an unchanged one only a
        // screen that has not heard it (pushed since).
        let heard = previous?.visibility == visibility ? previous?.screens : nil
        let unheard = screens.filter { heard?.contains($0) != true }
        guard previous?.visibility != visibility || !unheard.isEmpty else { return }
        let current = NSHashTable<UIViewController>.weakObjects()
        for screen in screens { current.add(screen) }
        reported[key] = (visibility, current)
        for screen in unheard {
            screen.paneVisibilityDidChange(visibility)
        }
    }

    // MARK: Resize, expand, and close

    private func dragBegan() {
        guard !isClosing, let policy else { return }
        stopSettle()
        // A grab mid-settle picks the divider up where it is drawn.
        let raw = PaneRubberBand.rawTarget(forLiveWidth: width, policy: policy)
        dragStartWidth = raw
        // Ticks only on crossing into another zone, not on the first move.
        dragZone = PaneSnapResolver.zone(for: raw, policy: policy)
        resizeHold.dragBegan(at: width)
    }

    private func dragChanged(translationX: CGFloat) {
        guard let policy, let dragStartWidth else { return }
        // Dragging toward the primary (leading, negative x) widens the
        // companion: width grows as `translationX` falls.
        let raw = dragStartWidth - translationX
        let live = PaneRubberBand.liveWidth(forRawTarget: raw, policy: policy)
        resizeHold.dividerMoved(to: live) { [weak self] in self?.dragStartWidth != nil }
        // Laid out here rather than at the frame's commit, so the meter sees
        // the main thread's whole cost of the new width.
        resizeHold.measureFrame {
            width = live
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }
        let zone = PaneSnapResolver.zone(for: raw, policy: policy)
        if zone != dragZone {
            dragZone = zone
            AppHaptics.selectionChanged()
        }
    }

    private func dragEnded(translation: CGPoint, velocity: CGPoint) {
        guard let policy, let dragStartWidth else { return }
        self.dragStartWidth = nil
        dragZone = nil
        let widthVelocity = -velocity.x
        let outcome = PaneSnapResolver.resolve(
            rawWidth: dragStartWidth - translation.x,
            widthVelocity: widthVelocity,
            policy: policy,
            rememberedWidth: rememberedWidth(policy: policy),
            wasFull: isFull,
            verticalTravel: translation.y,
            verticalVelocity: velocity.y
        )
        resizeHold.dragEnded()
        settle(outcome, initialVelocityPointsPerSecond: widthVelocity)
        // Held through the spring and settled where it lands
        // (`animateWidth`), or where a close leaves the primary; a release
        // that moves nothing settles now.
        if settleAnimator == nil, !isClosing {
            resizeHold.finish()
        }
    }

    /// Whether the companion's divider can step: a companion beside its
    /// leaf, not full.
    var canStepCompanion: Bool {
        companion != nil && policy?.fitsBeside == true && !isFull && !isClosing
    }

    /// Steps the companion's width, as VoiceOver's increment does.
    func stepCompanion(by delta: CGFloat) {
        guard canStepCompanion else { return }
        step(by: delta)
    }

    private func step(by delta: CGFloat) {
        guard !isClosing, let policy else { return }
        settle(.width(policy.clampedToOrdinaryRange(width + delta)), initialVelocityPointsPerSecond: 0)
    }

    /// A double-tap on the divider: the companion goes back to its pairing's
    /// default width, beside its leaf, and the pairing forgets the share the
    /// person settled on, so the next open starts there too.
    private func resetCompanionWidth() {
        guard companion != nil, let policy, policy.fitsBeside, !isClosing else { return }
        endMotion()
        panes.setCompanionZoomed(false)
        panes.forgetCompanionShare(defaultShare: policy.window > 0 ? Double(policy.ideal / policy.window) : nil)
        animateWidth(to: policy.ideal, initialVelocity: 0)
        updateVisibility()
    }

    private func restoreFromFull() {
        guard let policy else { return }
        settle(.width(rememberedWidth(policy: policy)), initialVelocityPointsPerSecond: 0)
    }

    private func settle(_ outcome: PaneSnapOutcome, initialVelocityPointsPerSecond: CGFloat) {
        guard !isClosing, let policy else { return }
        switch outcome {
        case .closed:
            // The owner closes the way its panel's own Close does, so its
            // model stays the one source of truth.
            companion?.owner?.dividerRequestedClose()
        case .full:
            panes.setCompanionZoomed(true)
            animateWidth(to: policy.full, initialVelocity: initialVelocityPointsPerSecond)
        case .width where !policy.fitsBeside:
            // No room beside: the companion stays full, by the fit rule.
            panes.setCompanionZoomed(true, byFit: true)
            animateWidth(to: policy.full, initialVelocity: initialVelocityPointsPerSecond)
        case .width(let target):
            panes.setCompanionZoomed(false)
            if policy.window > 0 { panes.setCompanionShare(Double(target / policy.window)) }
            animateWidth(to: target, initialVelocity: initialVelocityPointsPerSecond)
        }
        updateVisibility()
    }

    /// Animates to `target` with an interruptible spring (`PaneMotion`): a
    /// transition still in flight (a quick toggle, or a drag that starts
    /// mid-settle) stops in place and restarts from there, so the companion
    /// never jumps.
    private func animateWidth(to target: CGFloat, initialVelocity: CGFloat, completion: (() -> Void)? = nil) {
        stopSettle()
        // UIKit animations off (the test launch's switch, or
        // `performWithoutAnimation`) or Reduce Motion: the width lands at
        // once. A property animator would still run its spring.
        guard !PaneMotion.settlesAtOnce else {
            width = target
            view.setNeedsLayout()
            view.layoutIfNeeded()
            if dragStartWidth == nil { resizeHold.finish() }
            completion?()
            return
        }
        let animator = PaneMotion.settleAnimator(distance: target - width, velocity: initialVelocity)
        animator.addAnimations { [weak self] in
            guard let self else { return }
            self.width = target
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
        animator.addCompletion { [weak self] _ in
            if let self, self.settleAnimator === animator {
                self.settleAnimator = nil
                // At rest, unless a grab took over (it stops this animator).
                if self.dragStartWidth == nil { self.resizeHold.finish() }
            }
            completion?()
        }
        settleAnimator = animator
        animator.startAnimation()
    }

    /// Stops a settle in flight where it is drawn. `width` and the model
    /// frames already hold the target, so the width is read back from the
    /// companion's presentation layer; otherwise the next motion starts from
    /// the target and the companion jumps.
    private func stopSettle() {
        guard let animator = settleAnimator else { return }
        settleAnimator = nil
        let drawn = companion.map { $0.controller.view.layer.presentation()?.frame.width ?? $0.controller.view.frame.width }
        animator.stopAnimation(true)
        if let drawn {
            width = drawn
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }
    }

}

extension PaneHostController: NavigationBarHiding {
    var hidesNavigationBar: Bool { true }
}

/// Reports where each touch lands, for pane focus (hit testing is
/// unchanged), and when the view moves to another window.
private final class PaneHostView: UIView {
    var onTouch: ((CGPoint) -> Void)?
    var onWindowChange: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit != nil, event?.type == .touches { onTouch?(point) }
        return hit
    }
}
