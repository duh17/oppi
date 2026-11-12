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
/// across companions and launches (`AppPreferences.TrailingColumn`). Past the
/// side-by-side maximum it slides over the primary, which keeps its width and
/// is covered, up to the full window but a grab edge. A companion whose
/// minimum does not fit beside the primary's opens full.
final class PaneHostController: UIViewController {
    enum Leaf: Equatable { case primary, companion }

    let primary: UIViewController
    /// How long a parked companion's view stays in the hierarchy, hidden, so
    /// a quick return (a push and pop over its owner) does not rebuild it.
    let parkedViewLifetime: TimeInterval
    private(set) var focusedLeaf: Leaf = .primary

    private struct Companion {
        let controller: UIViewController
        weak var owner: AttachedLeafController?
        var widths: PaneCompanionWidths
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
    private var restingFraction: CGFloat? = AppPreferences.TrailingColumn.widthFraction
    private var isFull = false
    private var isClosing = false
    private var lastBoundsWidth: CGFloat?

    /// The finger's raw target at the drag's start; nil outside a drag.
    private var dragStartWidth: CGFloat?
    private var dragZone: PaneSnapZone?
    private var settleAnimator: UIViewPropertyAnimator?

    // MARK: Live resize

    /// The screens on either side that hold their heavy views while the
    /// divider moves (`PaneLiveResizing`); empty when nothing is held.
    private var heldScreens: [any PaneLiveResizing] = []
    /// The drawn width and time of the divider's last move of more than
    /// `pauseDistance`; a finger that stays within it for `pauseDelay` has
    /// paused (under 30 pt/s for 100 ms).
    private var lastMove: (width: CGFloat, time: CFTimeInterval)?
    private var pauseTimer: Timer?
    private static let pauseDistance: CGFloat = 3
    private static let pauseDelay: TimeInterval = 0.1
    private let resizeMeter = PaneResizeMeter()

    /// The visibility each leaf's screens were last told, by leaf controller.
    private var reported: [ObjectIdentifier: PaneVisibility] = [:]

    init(primary: UIViewController, parkedViewLifetime: TimeInterval = 10) {
        self.primary = primary
        self.parkedViewLifetime = parkedViewLifetime
        super.init(nibName: nil, bundle: nil)
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
            if changed { boundsWidthChanged() }
        }
        layoutLeaves()
    }

    // MARK: Companion

    /// Shows `controller` beside the primary. `opening` slides it in from
    /// zero width out of the remembered width, else it returns at once at
    /// the width it rests at (its owner came back, or it was rebuilt).
    func mountCompanion(
        _ controller: UIViewController,
        widths: PaneCompanionWidths,
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
        companion = Companion(controller: controller, owner: owner, widths: widths)
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
    func replaceCompanion(_ old: UIViewController, with new: UIViewController, widths: PaneCompanionWidths) {
        guard let current = companion, current.controller === old else {
            releaseParked(old)
            return
        }
        removeChild(old)
        companion = Companion(controller: new, owner: current.owner, widths: widths)
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
        finishLiveResize()
        resizeMeter.takeVisit().map { Telemetry.record($0) }
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
            pauseTimer?.invalidate()
            pauseTimer = nil
            divider.cancelDrag()
            finishLiveResize()
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

    private func focus(_ leaf: Leaf) {
        guard focusedLeaf != leaf, leaf == .primary || companion != nil else { return }
        focusedLeaf = leaf
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
        guard reported[key] != visibility else { return }
        reported[key] = visibility
        for screen in PaneLeafScreens.adopters(in: leaf, as: (any PaneVisibilityObserving).self) {
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
        lastMove = (width, CACurrentMediaTime())
        resizeMeter.beginDrag()
        holdScreens()
    }

    private func dragChanged(translationX: CGFloat) {
        guard let policy, let dragStartWidth else { return }
        // Dragging toward the primary (leading, negative x) widens the
        // companion: width grows as `translationX` falls.
        let raw = dragStartWidth - translationX
        let live = PaneRubberBand.liveWidth(forRawTarget: raw, policy: policy)
        if let lastMove, abs(live - lastMove.width) <= Self.pauseDistance {
            // Creeping, or still: the pause timer runs on from the last real move.
        } else {
            lastMove = (live, CACurrentMediaTime())
            holdScreens()
            schedulePauseSettle()
        }
        // Laid out here rather than at the frame's commit, so the meter sees
        // the main thread's whole cost of the new width.
        resizeMeter.measureFrame {
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
        pauseTimer?.invalidate()
        pauseTimer = nil
        lastMove = nil
        settle(outcome, initialVelocityPointsPerSecond: widthVelocity)
        // Held through the spring and settled where it lands
        // (`animateWidth`), or where a close leaves the primary; a release
        // that moves nothing settles now.
        if settleAnimator == nil, !isClosing {
            finishLiveResize()
        }
    }

    /// Holds the screens on both sides, unless they are held already.
    private func holdScreens() {
        guard heldScreens.isEmpty else { return }
        heldScreens = PaneLeafScreens.adopters(in: primary, as: (any PaneLiveResizing).self)
            + PaneLeafScreens.adopters(in: companion?.controller, as: (any PaneLiveResizing).self)
        for held in heldScreens { held.paneWillBeginLiveResize() }
    }

    private func schedulePauseSettle() {
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: Self.pauseDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.dragStartWidth != nil else { return }
                self.settleHeldScreens(final: false)
            }
        }
    }

    /// Lays the held screens out at their sizes now, as one reflow.
    private func settleHeldScreens(final: Bool) {
        pauseTimer?.invalidate()
        pauseTimer = nil
        let held = heldScreens
        heldScreens = []
        guard !held.isEmpty else { return }
        view.layoutIfNeeded()
        resizeMeter.measureReflow {
            for screen in held where screen.viewIfLoaded?.window != nil {
                screen.paneSettleLiveResize(to: screen.view.bounds.size, final: final)
            }
        }
    }

    /// The divider is at rest: the held screens settle and the drag's
    /// measurement ends. Safe to call when no drag ran.
    private func finishLiveResize() {
        lastMove = nil
        settleHeldScreens(final: true)
        resizeMeter.endDrag()
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
            let fraction = policy.window > 0 ? target / policy.window : 0
            restingFraction = fraction
            AppPreferences.TrailingColumn.setWidthFraction(fraction)
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
                if self.dragStartWidth == nil { self.finishLiveResize() }
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
