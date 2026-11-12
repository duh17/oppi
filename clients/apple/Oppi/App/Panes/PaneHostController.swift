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
/// across companions, hosts and launches by the window's `ScenePanes`, which
/// also hears which companion is shown and which leaf is focused. Past the
/// side-by-side maximum it slides over the primary, which keeps its width and
/// is covered, up to the full window but a grab edge. A companion whose
/// minimum does not fit beside the primary's opens full.
final class PaneHostController: UIViewController {
    enum Leaf: Equatable { case primary, companion }

    let primary: UIViewController
    /// The window's pane state; nil in a harness or test host.
    private let panes: ScenePanes?
    /// How long a parked companion's view stays in the hierarchy, hidden, so
    /// a quick return (a push and pop over its owner) does not rebuild it.
    let parkedViewLifetime: TimeInterval
    private(set) var focusedLeaf: Leaf = .primary

    private struct Companion {
        let controller: UIViewController
        weak var owner: AttachedLeafController?
        var widths: PaneCompanionWidths
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
    private let cover = UIView()

    /// The companion's drawn width, the one source of truth for layout: set
    /// directly during a drag, and through an animator for every open,
    /// close, and snap.
    private var width: CGFloat = 0
    /// The last settled ordinary width as a fraction of the host's width, so
    /// it scales with rotation and window resizing. Nil until known.
    private var restingFraction: CGFloat? {
        didSet { panes?.companionFraction = restingFraction }
    }
    private var isFull = false
    private var isClosing = false
    private var lastBoundsWidth: CGFloat?

    /// The finger's raw target at the drag's start; nil outside a drag.
    private var dragStartWidth: CGFloat?
    private var dragZone: PaneSnapZone?
    private var settleAnimator: UIViewPropertyAnimator?

    /// The screens on either side that hold their heavy views while the
    /// divider moves or the window resizes, and settle once.
    private lazy var resizeHold = PaneResizeHold(
        leaves: { [weak self] in [self?.primary, self?.companion?.controller] },
        layout: { [weak self] in self?.view.layoutIfNeeded() }
    )

    /// What each leaf's screens were last told, by leaf controller: the
    /// visibility and the screens that heard it, so a screen pushed inside
    /// a leaf later hears the current visibility once. The screens are held
    /// weakly by identity, so a new screen at a freed screen's address has
    /// not heard anything. A leaf's entry goes when the leaf leaves the host.
    private var reported: [ObjectIdentifier: (visibility: PaneVisibility, screens: NSHashTable<UIViewController>)] = [:]

    init(primary: UIViewController, panes: ScenePanes? = nil, parkedViewLifetime: TimeInterval = 10) {
        self.primary = primary
        self.panes = panes
        self.parkedViewLifetime = parkedViewLifetime
        super.init(nibName: nil, bundle: nil)
        restingFraction = panes?.companionFraction
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

    /// A leaf's navigation controller showed another screen: it hears the
    /// leaf's current visibility, as its siblings did at the transition.
    func leafDidShowScreen() {
        updateVisibility()
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

    /// The front screen of the focused leaf: Find and Close act there. A
    /// companion that covers the primary is the only leaf showing.
    var focusedScreen: UIViewController? {
        let companionInFront = focusedLeaf == .companion || showsFull
        let leaf = companionInFront ? companion?.controller ?? primary : primary
        return (leaf as? UINavigationController)?.topViewController ?? leaf
    }

    override var childForStatusBarStyle: UIViewController? { primary }

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
        cover.alpha = 0
        cover.isHidden = true
        hairline.isHidden = true
        divider.isHidden = true
        view.addSubview(cover)
        view.addSubview(hairline)
        view.addSubview(divider)
        divider.onBegan = { [weak self] in self?.dragBegan() }
        divider.onChanged = { [weak self] translationX in self?.dragChanged(translationX: translationX) }
        divider.onEnded = { [weak self] translationX, velocityX in
            self?.dragEnded(translationX: translationX, velocityX: velocityX)
        }
        divider.onStep = { [weak self] delta in self?.step(by: delta) }
        divider.onExpandRequested = { [weak self] in self?.settle(.full, initialVelocityPointsPerSecond: 0) }
        divider.onRestoreRequested = { [weak self] in self?.restoreFromFull() }
        divider.onCloseRequested = { [weak self] in self?.companion?.owner?.dividerRequestedClose() }
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(inputBeganEditing(_:)), name: name, object: nil
            )
        }
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the theme store changes.
        cover.backgroundColor = AppRootEnvironment.near(self)?.themeStore.backgroundColor ?? .systemBackground
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if lastBoundsWidth != view.bounds.width {
            // Only a change: the first layout, as a companion opens, must
            // leave the open's spring to carry the width from zero.
            let changed = lastBoundsWidth != nil
            lastBoundsWidth = view.bounds.width
            if changed {
                boundsWidthChanged()
                windowWidthChanged()
            }
        }
        layoutLeaves()
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
        resizeHold.windowWidthChanged { [weak self] in
            guard let self else { return false }
            return self.dragStartWidth == nil && self.settleAnimator == nil
        }
    }

    // MARK: Companion

    /// Shows `controller` beside the primary. `opening` slides it in from
    /// zero width out of the remembered width, else it returns at once at
    /// the width it rests at (its owner came back, or it was rebuilt).
    func mountCompanion(
        _ controller: UIViewController,
        widths: PaneCompanionWidths,
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
        companion = Companion(controller: controller, owner: owner, widths: widths, route: route)
        panes?.companionDidChange(route, shown: true)
        if controller.parent !== self {
            addChild(controller)
            view.insertSubview(controller.view, belowSubview: divider)
            controller.didMove(toParent: self)
        }
        controller.view.isHidden = false
        if opening { isFull = false }
        let target = restingWidth
        width = opening ? 0 : target
        view.setNeedsLayout()
        view.layoutIfNeeded()
        if opening {
            animateWidth(to: target, initialVelocity: 0)
        }
        if panes?.takeRestoredCompanionFocus() == true {
            focus(.companion)
        }
        updateVisibility()
    }

    /// The owner's panel asked for other widths: the divider's range follows
    /// at once; the drawn width stays until the next drag or resize.
    func updateCompanionWidths(_ controller: UIViewController, _ widths: PaneCompanionWidths) {
        guard companion?.controller === controller, companion?.widths != widths else { return }
        companion?.widths = widths
        view.setNeedsLayout()
    }

    /// Replaces the shown companion in place: the width and full state stay,
    /// so the pane does not close and reopen for a second reflow.
    func replaceCompanion(
        _ old: UIViewController,
        with new: UIViewController,
        widths: PaneCompanionWidths,
        route: PaneStackEntry? = nil
    ) {
        guard let current = companion, current.controller === old else {
            releaseParked(old)
            return
        }
        removeChild(old)
        companion = Companion(controller: new, owner: current.owner, widths: widths, route: route)
        panes?.companionDidChange(route, shown: true)
        addChild(new)
        view.insertSubview(new.view, belowSubview: divider)
        new.didMove(toParent: self)
        view.setNeedsLayout()
        view.layoutIfNeeded()
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
        companion = nil
        controller.view.isHidden = true
        let timer = Timer.scheduledTimer(withTimeInterval: parkedViewLifetime, repeats: false) { [weak self, weak controller] _ in
            MainActor.assumeIsolated {
                guard let controller else { return }
                self?.releaseParked(controller)
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
            self.isFull = false
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

    private func removeChild(_ controller: UIViewController) {
        reported[ObjectIdentifier(controller)] = nil
        guard controller.parent === self else { return }
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    /// The primary has the host to itself again.
    private func companionLeft() {
        width = 0
        focusedLeaf = .primary
        panes?.companionDidChange(nil, shown: false)
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
            window: view.bounds.width
        )
    }

    private var restingWidth: CGFloat {
        guard let policy else { return 0 }
        if showsFull { return policy.full }
        return rememberedWidth(policy: policy)
    }

    /// The companion covers the primary: the person chose full, or the
    /// companion does not fit beside it.
    private var showsFull: Bool {
        isFull || policy?.fitsBeside == false
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
        guard settleAnimator == nil, companion != nil else { return }
        width = restingWidth
        updateVisibility()
    }

    private func layoutLeaves() {
        let bounds = view.bounds
        guard let companion, let policy else {
            primary.view.frame = bounds
            for decoration in [cover, hairline, divider] as [UIView] { decoration.isHidden = true }
            primary.view.accessibilityElementsHidden = false
            return
        }
        let drawn = max(0, min(width, bounds.width))
        // Past the side-by-side maximum the companion slides over the
        // primary, which keeps the width it had there instead of squeezing
        // (and reflowing every frame) on the way to full.
        let sideBySide = min(drawn, policy.maximum)
        primary.view.frame = CGRect(x: 0, y: 0, width: bounds.width - sideBySide, height: bounds.height)
        let companionFrame = CGRect(x: bounds.maxX - drawn, y: 0, width: drawn, height: bounds.height)
        companion.controller.view.frame = companionFrame
        let line = 1 / max(traitCollection.displayScale, 1)
        hairline.frame = CGRect(x: companionFrame.minX - line, y: 0, width: line, height: bounds.height)
        cover.frame = CGRect(x: 0, y: 0, width: max(0, hairline.frame.minX), height: bounds.height)
        cover.alpha = policy.full > policy.maximum
            ? min(1, max(0, (drawn - policy.maximum) / (policy.full - policy.maximum)))
            : 0
        // The divider straddles the hairline. Near the leading edge (full
        // window) it takes the whole grab edge, so a touch there drags the
        // companion rather than reaching the covered primary.
        let hitWidth = PaneDividerView.hitWidth
        if companionFrame.minX <= hitWidth {
            divider.frame = CGRect(x: 0, y: 0, width: companionFrame.minX + hitWidth / 2, height: bounds.height)
        } else {
            let x = min(companionFrame.minX - hitWidth / 2, bounds.width - hitWidth)
            divider.frame = CGRect(x: x, y: 0, width: hitWidth, height: bounds.height)
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
        let inCompanion = companion.map { $0.controller.view.frame.contains(point) } ?? false
        focus(inCompanion ? .companion : .primary)
    }

    /// The companion takes focus, as a touch in it does: its owner asked
    /// (a tap on the pill of the panel it shows).
    func focusCompanion() {
        focus(.companion)
    }

    private func focus(_ leaf: Leaf) {
        guard focusedLeaf != leaf, leaf == .primary || companion != nil else { return }
        focusedLeaf = leaf
        panes?.focusDidChange(onCompanion: leaf == .companion)
        updateVisibility()
    }

    /// A field began editing: its leaf takes focus, and only that leaf
    /// follows the keyboard. A field outside both (a sheet over the window)
    /// leaves every leaf following it. A field begins editing before the
    /// keyboard moves, so the leaves are settled when it does.
    @objc private func inputBeganEditing(_ notification: Notification) {
        guard let input = notification.object as? UIView, let window = view.window, input.window === window else { return }
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

    private func applyKeyboardFollowing(firstResponderIn leaf: Leaf?) {
        for screen in PaneLeafScreens.adopters(in: primary, as: (any PaneKeyboardFollowing).self) {
            screen.followsKeyboard = leaf != .companion
        }
        for screen in PaneLeafScreens.adopters(in: companion?.controller, as: (any PaneKeyboardFollowing).self) {
            screen.followsKeyboard = leaf != .primary
        }
    }

    /// Tells each leaf's screens what they can see now, once per change.
    private func updateVisibility() {
        let covered = companion != nil && showsFull
        report(covered ? .covered : .visible(focused: focusedLeaf == .primary), to: primary)
        if let companion {
            report(.visible(focused: focusedLeaf == .companion), to: companion.controller)
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

    private func dragEnded(translationX: CGFloat, velocityX: CGFloat) {
        guard let policy, let dragStartWidth else { return }
        self.dragStartWidth = nil
        dragZone = nil
        let widthVelocity = -velocityX
        let outcome = PaneSnapResolver.resolve(
            rawWidth: dragStartWidth - translationX,
            widthVelocity: widthVelocity,
            policy: policy,
            rememberedWidth: rememberedWidth(policy: policy),
            wasFull: isFull
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

    private func step(by delta: CGFloat) {
        guard !isClosing, let policy else { return }
        settle(.width(policy.clampedToOrdinaryRange(width + delta)), initialVelocityPointsPerSecond: 0)
    }

    private func restoreFromFull() {
        guard let policy else { return }
        settle(.width(rememberedWidth(policy: policy)), initialVelocityPointsPerSecond: 0)
    }

    private func settle(_ outcome: PaneSnapOutcome, initialVelocityPointsPerSecond: CGFloat) {
        guard !isClosing, let policy else { return }
        switch outcome {
        case .closed:
            isFull = false
            // The owner closes the way its panel's own Close does, so its
            // model stays the one source of truth.
            companion?.owner?.dividerRequestedClose()
        case .full:
            isFull = true
            animateWidth(to: policy.full, initialVelocity: initialVelocityPointsPerSecond)
        case .width where !policy.fitsBeside:
            // No room beside: the companion stays full.
            isFull = true
            animateWidth(to: policy.full, initialVelocity: initialVelocityPointsPerSecond)
        case .width(let target):
            isFull = false
            restingFraction = policy.window > 0 ? target / policy.window : 0
            animateWidth(to: target, initialVelocity: initialVelocityPointsPerSecond)
        }
        updateVisibility()
    }

    /// Animates to `target` with an interruptible spring: a transition still
    /// in flight (a quick toggle, or a drag that starts mid-settle) stops in
    /// place and restarts from there, so the companion never jumps.
    private func animateWidth(to target: CGFloat, initialVelocity: CGFloat, completion: (() -> Void)? = nil) {
        stopSettle()
        let distance = target - width
        let velocityVector = distance == 0 ? .zero : CGVector(dx: initialVelocity / distance, dy: 0)
        let timing = UISpringTimingParameters(dampingRatio: 0.86, initialVelocity: velocityVector)
        let animator = UIViewPropertyAnimator(duration: 0.42, timingParameters: timing)
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

    // MARK: - Testing

    /// The divider, so a test can drive a drag through the exact closures a
    /// live pan calls instead of synthesizing touches.
    var dividerForTesting: PaneDividerView { divider }
    var companionWidthForTesting: CGFloat? { companion == nil ? nil : width }
    var isFullForTesting: Bool { isFull }
    var restingFractionForTesting: CGFloat? { restingFraction }
    var coverForTesting: UIView { cover }
    var companionForTesting: UIViewController? { companion?.controller }

    /// Lands an in-flight open, snap, or close at its end now, completion
    /// included, as if the spring had run out.
    func finishSettleForTesting() {
        guard let animator = settleAnimator else { return }
        animator.stopAnimation(false)
        animator.finishAnimation(at: .end)
    }
}

extension PaneHostController: NavigationBarHiding {
    var hidesNavigationBar: Bool { true }
}

/// Reports where each touch lands, for pane focus; hit testing is unchanged.
private final class PaneHostView: UIView {
    var onTouch: ((CGPoint) -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit != nil, event?.type == .touches { onTouch?(point) }
        return hit
    }
}
