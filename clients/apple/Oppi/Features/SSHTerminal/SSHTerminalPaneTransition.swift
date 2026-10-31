import UIKit

/// The picture a Rex terminal's grid slides between panes with: a snapshot of
/// the grid that follows the finger (or, for a menu choice or VoiceOver, slides
/// by itself), and a placeholder for the incoming pane that it uncovers.
///
/// The grid is never moved. It sits under both the whole time and keeps taking
/// the old pane's output, so it is the placeholder, not the grid, that stands
/// in for the new pane until Rex's snapshot of it has been applied and drawn.
/// Only then does the placeholder fade away; otherwise the old pane's screen
/// would slide in as if it were the new one. A pane that never answers cannot
/// leave the screen blank: after `revealTimeout` the placeholder goes whatever
/// the grid shows.
///
/// Past the last pane the incoming side is the New Pane card. A release there
/// slides it in like any switch, but there is no pane to wait for yet: the
/// card stays ("New Pane…") until the owner says the pane was opened
/// (`paneCreated`, which names the card and waits for the pane's snapshot like
/// a switch) or could not be (`creationFailed`, which slides the card away to
/// the grid's old pane). `creationTimeout` bounds the wait.
@MainActor
final class SSHTerminalPaneTransition {
    static let settleDuration: TimeInterval = 0.3
    static let revealDuration: TimeInterval = 0.15
    static let defaultRevealTimeout: Duration = .seconds(2)
    /// Rex answers a request within 15 s (`RexControl.requestTimeout`), and
    /// opening a pane makes up to three in a row.
    static let defaultCreationTimeout: Duration = .seconds(30)

    enum Phase: Equatable {
        case idle
        /// A finger is moving the snapshot.
        case dragging
        /// Letting go: the snapshot is sliding off, or back.
        case settling
        /// The slide is done and the placeholder covers the grid until the new
        /// pane's screen is on it.
        case covering
    }

    private(set) var phase = Phase.idle
    /// How long a committed switch may wait for the new pane's screen.
    var revealTimeout = SSHTerminalPaneTransition.defaultRevealTimeout
    /// How long a new pane may take to open before the cover goes anyway.
    var creationTimeout = SSHTerminalPaneTransition.defaultCreationTimeout
    /// The incoming pane's name on the placeholder, while one is shown.
    var placeholderTitle: String? { placeholder?.title }
    var isPlaceholderShown: Bool { placeholder != nil }
    /// The placeholder is the New Pane card, and a release now would open one.
    var isNewPaneArmed: Bool { placeholder?.showsNewPaneCard == true && placeholder?.isArmed == true }
    /// The placeholder is the New Pane card.
    var isShowingNewPaneCard: Bool { placeholder?.showsNewPaneCard == true }
    /// A pane is being opened: the card waits for the owner's answer.
    private(set) var isAwaitingCreation = false
    /// `true` when a switch begins (a finger down on the swipe, or a switch
    /// with no finger) and `false` when it has settled: the slide ended, the
    /// spring back ended, or the transition was dropped. The layout minimap
    /// shows between the two.
    var onSwitching: ((Bool) -> Void)?

    private weak var grid: SSHTerminalGridView?
    private var cover: UIView?
    private var placeholder: SSHTerminalPanePlaceholderView?
    /// The settle in progress is the spring back, not a switch.
    private var returning = false
    /// Bumped by every presentation and teardown, so a late animation
    /// completion or timeout cannot act on a newer one.
    private var generation = 0
    private var slideFinished = false
    private var snapshotApplied = false
    private var framePainted = false
    private var timedOut = false
    private var timeout: Task<Void, Never>?
    /// The finger is past the new-pane threshold: the tick was made.
    private var tickedForNewPane = false
    /// Opening the pane failed while the slide was still running.
    private var creationFailedMidSlide = false

    init(grid: SSHTerminalGridView) {
        self.grid = grid
    }

    // MARK: - Finger

    /// A swipe began. False when the grid cannot be slid (not in a view, no
    /// width) or a transition is still running; the swipe then does nothing.
    @discardableResult
    func beginDrag() -> Bool {
        guard phase == .idle, present() else { return false }
        phase = .dragging
        onSwitching?(true)
        return true
    }

    /// The finger is `translationX` points from where the swipe began.
    /// `neighbour` names the pane that way. Past the first pane the screen
    /// gives way like a scroll view's edge; past the last one, with
    /// `offersNewPane`, the incoming side is the New Pane card, dimmed until the
    /// finger is far enough that letting go opens a pane, and a selection tick
    /// marks the moment it is.
    func drag(translationX: CGFloat, neighbour: String?, offersNewPane: Bool) {
        guard phase == .dragging, let grid, let cover, let placeholder else { return }
        let width = grid.bounds.width
        let newPane = neighbour == nil && offersNewPane && translationX < 0
        let offset = SSHTerminalPaneSwipe.offset(translation: translationX, width: width, canStep: neighbour != nil || newPane)
        cover.transform = CGAffineTransform(translationX: offset, y: 0)
        placeholder.transform = CGAffineTransform(translationX: offset + (translationX < 0 ? width : -width), y: 0)
        guard newPane else {
            tickedForNewPane = false
            placeholder.title = neighbour
            return
        }
        let armed = SSHTerminalPaneSwipe.crossesThreshold(translationX)
        placeholder.showNewPane(armed: armed)
        if armed, !tickedForNewPane {
            // Oppi's own switch for haptics: off in Settings, no tick.
            AppHaptics.selectionChanged()
        }
        tickedForNewPane = armed
    }

    /// The finger lifted. `step` is the switch that was just asked of the
    /// session (the slide completes it, with a selection tick), nil to put the
    /// screen back (no tick).
    func endDrag(committing step: Int?, velocityX: CGFloat) {
        guard phase == .dragging else { return }
        if let step {
            // Oppi's own switch for haptics: off in Settings, no tick.
            AppHaptics.selectionChanged()
            commit(step: step, velocityX: velocityX)
        } else {
            springBack(velocityX: velocityX)
        }
    }

    /// The finger lifted past the last pane and the owner took the request to
    /// open one: the card slides in and waits for `paneCreated` or
    /// `creationFailed`. A flick that never crossed the threshold ticks now,
    /// so the tick is made once either way.
    func endDragCreatingPane(velocityX: CGFloat) {
        guard phase == .dragging, let placeholder else { return }
        if !tickedForNewPane { AppHaptics.selectionChanged() }
        placeholder.showCreating()
        isAwaitingCreation = true
        commit(step: 1, velocityX: velocityX)
    }

    // MARK: - Without a finger

    /// A switch with no drag behind it (a menu choice, a minimap cell,
    /// VoiceOver's Next and Previous Pane): the old screen slides off in the
    /// direction of travel. `step` is +1 toward a pane further along, -1 for one
    /// before. Call it after the session took the request.
    func slide(toward step: Int, neighbour: String?) {
        switch phase {
        case .dragging:
            // A finger owns the screen; its release decides.
            return
        case .settling where returning:
            // The screen was springing back and a switch came: drop that
            // cover and slide as from rest, so the new pane is still covered.
            cancel()
        case .settling:
            // Another switch while one runs: the screen waits for the newest
            // pane's snapshot instead, and the running slide's end settles it.
            onSwitching?(true)
            armReveal()
            placeholder?.title = neighbour
            return
        case .covering:
            // The slide is over and the screen waits for a snapshot: the new
            // switch is a flash of its own, and the screen waits for the newest.
            onSwitching?(true)
            armReveal()
            placeholder?.title = neighbour
            onSwitching?(false)
            return
        case .idle:
            break
        }
        onSwitching?(true)
        guard present(), let grid else {
            // Nothing to slide, but the switch still happened.
            onSwitching?(false)
            return
        }
        placeholder?.title = neighbour
        placeholder?.transform = CGAffineTransform(translationX: step > 0 ? grid.bounds.width : -grid.bounds.width, y: 0)
        commit(step: step, velocityX: 0)
    }

    /// Opening a pane with no drag behind it (VoiceOver's New Pane, the
    /// switcher's menu item): the old screen slides off and the card waits, as
    /// after a drag. Call it after the owner took the request, and only from
    /// rest.
    func slideToNewPane() {
        guard phase == .idle else { return }
        onSwitching?(true)
        guard present(), let grid, let placeholder else {
            // Nothing to slide; the pane is still opened and `paneCreated` slides to it.
            onSwitching?(false)
            return
        }
        placeholder.showCreating()
        placeholder.transform = CGAffineTransform(translationX: grid.bounds.width, y: 0)
        isAwaitingCreation = true
        commit(step: 1, velocityX: 0)
    }

    /// The pane was opened and asked for (it is the one the session shows
    /// now), and `name` is what it is called. The card takes the name and
    /// waits for the pane's snapshot like any switch. When the card already
    /// left (the creation timeout), the pane is a switch of its own.
    func paneCreated(named name: String) {
        guard isAwaitingCreation else {
            slide(toward: 1, neighbour: name)
            return
        }
        isAwaitingCreation = false
        placeholder?.title = name
        armReveal()
    }

    /// No pane was opened: the card slides away and the grid's own pane, which
    /// never stopped taking its output, is back under it.
    func creationFailed() {
        guard isAwaitingCreation else { return }
        isAwaitingCreation = false
        switch phase {
        case .covering: retreat()
        case .settling: creationFailedMidSlide = true
        case .idle, .dragging: break
        }
    }

    // MARK: - What the grid reports

    /// Rex's snapshot of the pane `block` replaced the grid's terminal. Only
    /// the pane last asked for (`shown`) lifts the cover: a switch that was
    /// overtaken (A to B, then C asked for) can still land B's snapshot, and
    /// that is not the screen the cover stands in for.
    func snapshotRestored(of block: String?, expecting shown: String?) {
        guard phase == .settling || phase == .covering, !isAwaitingCreation else { return }
        if let block, let shown, block != shown { return }
        snapshotApplied = true
    }

    /// The grid drew a frame. The first one after the new pane's snapshot is
    /// the pane's own screen.
    func frameDrawn() {
        guard snapshotApplied, !framePainted else { return }
        framePainted = true
        revealIfReady()
    }

    /// The grid was resized under the placeholder.
    func gridLaidOut() {
        guard let grid, let placeholder, phase == .covering else { return }
        placeholder.frame = grid.frame
    }

    /// Drops everything at once: the grid left its view, or the swipe is gone.
    func cancel() {
        generation += 1
        timeout?.cancel()
        timeout = nil
        cover?.removeFromSuperview()
        placeholder?.removeFromSuperview()
        cover = nil
        placeholder = nil
        returning = false
        isAwaitingCreation = false
        creationFailedMidSlide = false
        tickedForNewPane = false
        phase = .idle
        onSwitching?(false)
    }

    // MARK: - Slides

    private func present() -> Bool {
        guard let grid, let container = grid.superview, grid.bounds.width > 0 else { return false }
        generation += 1
        returning = false
        creationFailedMidSlide = false
        tickedForNewPane = false
        let placeholder = SSHTerminalPanePlaceholderView()
        placeholder.frame = grid.frame
        placeholder.apply(background: grid.backgroundColor ?? .black, foreground: grid.foreground)
        // A snapshot the render server could not make is a plain stand-in.
        let cover = grid.snapshotView(afterScreenUpdates: false) ?? {
            let blank = UIView()
            blank.backgroundColor = grid.backgroundColor
            return blank
        }()
        cover.frame = grid.frame
        cover.isUserInteractionEnabled = false
        // On top of anything an earlier placeholder is still fading out of.
        container.addSubview(placeholder)
        container.addSubview(cover)
        self.placeholder = placeholder
        self.cover = cover
        return true
    }

    /// The old screen leaves toward `-step`, the placeholder arrives from the
    /// other side, and the grid waits behind it for the new pane's screen.
    private func commit(step: Int, velocityX: CGFloat) {
        guard let grid, let cover, let placeholder else { return cancel() }
        phase = .settling
        returning = false
        slideFinished = false
        armReveal()
        let token = generation
        let width = grid.bounds.width
        let exit = CGFloat(-step) * width
        let finish: (Bool) -> Void = { [weak self] _ in
            guard let self, self.generation == token else { return }
            self.cover?.removeFromSuperview()
            self.cover = nil
            self.slideFinished = true
            self.phase = .covering
            self.onSwitching?(false)
            if self.creationFailedMidSlide {
                self.retreat()
                return
            }
            self.revealIfReady()
        }
        if UIAccessibility.isReduceMotionEnabled {
            placeholder.transform = .identity
            UIView.animate(withDuration: Self.settleDuration * 0.6, delay: 0, options: .curveEaseOut) {
                cover.alpha = 0
            } completion: { finished in finish(finished) }
            return
        }
        let remaining = exit - cover.transform.tx
        let velocity = remaining == 0 ? 0 : min(max(velocityX / remaining, 0), 8)
        UIView.animate(
            springDuration: Self.settleDuration, bounce: 0, initialSpringVelocity: velocity, delay: 0,
            options: [.beginFromCurrentState]
        ) {
            cover.transform = CGAffineTransform(translationX: exit, y: 0)
            placeholder.transform = .identity
        } completion: { finished in finish(finished) }
    }

    private func springBack(velocityX: CGFloat) {
        guard let grid, let cover, let placeholder else { return cancel() }
        phase = .settling
        returning = true
        let token = generation
        let side: CGFloat = placeholder.transform.tx < 0 ? -grid.bounds.width : grid.bounds.width
        let remaining = -cover.transform.tx
        let velocity = remaining == 0 ? 0 : min(max(velocityX / remaining, 0), 8)
        let finish: (Bool) -> Void = { [weak self] _ in
            guard let self, self.generation == token else { return }
            self.cancel()
        }
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: Self.settleDuration * 0.6, delay: 0, options: .curveEaseOut) {
                cover.transform = .identity
            } completion: { finished in finish(finished) }
            return
        }
        UIView.animate(
            springDuration: Self.settleDuration, bounce: 0, initialSpringVelocity: velocity, delay: 0,
            options: [.beginFromCurrentState]
        ) {
            cover.transform = .identity
            placeholder.transform = CGAffineTransform(translationX: side, y: 0)
        } completion: { finished in finish(finished) }
    }

    // MARK: - Revealing the grid

    /// Waits for a pane's snapshot, and gives up waiting after `revealTimeout`.
    private func armReveal() {
        snapshotApplied = false
        framePainted = false
        timedOut = false
        timeout?.cancel()
        let token = generation
        let wait = isAwaitingCreation ? creationTimeout : revealTimeout
        timeout = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.timedOut = true
            self.revealIfReady()
        }
    }

    private func revealIfReady() {
        guard phase == .covering, slideFinished, (snapshotApplied && framePainted) || timedOut,
              let placeholder else { return }
        timeout?.cancel()
        timeout = nil
        self.placeholder = nil
        // A timeout during a creation ends the wait: the pane, if it opens, is a switch of its own.
        isAwaitingCreation = false
        phase = .idle
        generation += 1
        UIView.animate(withDuration: Self.revealDuration, delay: 0, options: .curveEaseOut) {
            placeholder.alpha = 0
        } completion: { _ in placeholder.removeFromSuperview() }
    }

    /// The pane did not open: the card leaves the way it came, to the right,
    /// off the grid's old pane (a fade with Reduce Motion).
    private func retreat() {
        guard let grid, let placeholder else { return cancel() }
        timeout?.cancel()
        timeout = nil
        self.placeholder = nil
        creationFailedMidSlide = false
        phase = .idle
        generation += 1
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: Self.settleDuration * 0.6, delay: 0, options: .curveEaseOut) {
                placeholder.alpha = 0
            } completion: { _ in placeholder.removeFromSuperview() }
            return
        }
        UIView.animate(springDuration: Self.settleDuration, bounce: 0, delay: 0, options: [.beginFromCurrentState]) {
            placeholder.transform = CGAffineTransform(translationX: grid.bounds.width, y: 0)
        } completion: { _ in placeholder.removeFromSuperview() }
    }
}

/// What stands in for the incoming pane: the terminal's own background, and
/// the pane's name dimmed in the middle. Past the last pane it is the New Pane
/// card instead: a plus and "New Pane", dimmed until the drag has gone far
/// enough to open one, then lit.
final class SSHTerminalPanePlaceholderView: UIView {
    static let dimmedAlpha: CGFloat = 0.45

    private let glyph = UIImageView()
    private let label = UILabel()
    private let stack = UIStackView()
    private(set) var isArmed = false

    /// The text on the card: a pane's name, "New Pane", or "New Pane…".
    var title: String? {
        get { label.text }
        set {
            label.text = newValue
            glyph.isHidden = true
            isArmed = false
            stack.alpha = Self.dimmedAlpha
        }
    }

    /// Whether the card shows the plus: the placeholder is the New Pane card.
    var showsNewPaneCard: Bool { !glyph.isHidden }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        glyph.image = UIImage(systemName: "plus.circle", withConfiguration: UIImage.SymbolConfiguration(textStyle: .largeTitle))
        glyph.contentMode = .scaleAspectFit
        glyph.isHidden = true
        label.font = .preferredFont(forTextStyle: .callout)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.numberOfLines = 2
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.alpha = Self.dimmedAlpha
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(glyph)
        stack.addArrangedSubview(label)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(background: UIColor, foreground: UIColor) {
        backgroundColor = background
        label.textColor = foreground
        glyph.tintColor = foreground
    }

    /// The New Pane card of a drag. `armed` says a release now opens a pane.
    func showNewPane(armed: Bool) {
        label.text = "New Pane"
        // The first display of the card plays its dimmed state in too.
        let wasCard = !glyph.isHidden
        glyph.isHidden = false
        guard !wasCard || armed != isArmed else { return }
        isArmed = armed
        let change = {
            self.stack.alpha = armed ? 1 : Self.dimmedAlpha
            self.glyph.transform = armed || UIAccessibility.isReduceMotionEnabled ? .identity : CGAffineTransform(scaleX: 0.88, y: 0.88)
        }
        if window != nil {
            UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .curveEaseOut], animations: change)
        } else {
            change()
        }
    }

    /// The pane is being opened: the card stays, lit, while the host answers.
    func showCreating() {
        label.text = "New Pane\u{2026}"
        glyph.isHidden = false
        glyph.transform = .identity
        isArmed = true
        stack.alpha = 1
    }
}
