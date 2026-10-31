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
@MainActor
final class SSHTerminalPaneTransition {
    static let settleDuration: TimeInterval = 0.3
    static let revealDuration: TimeInterval = 0.15
    static let defaultRevealTimeout: Duration = .seconds(2)

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
    /// The incoming pane's name on the placeholder, while one is shown.
    var placeholderTitle: String? { placeholder?.title }
    var isPlaceholderShown: Bool { placeholder != nil }
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
    /// `neighbour` names the pane that way, nil past the first or last pane,
    /// where the screen gives way like a scroll view's edge.
    func drag(translationX: CGFloat, neighbour: String?) {
        guard phase == .dragging, let grid, let cover, let placeholder else { return }
        let width = grid.bounds.width
        let offset = SSHTerminalPaneSwipe.offset(translation: translationX, width: width, canStep: neighbour != nil)
        cover.transform = CGAffineTransform(translationX: offset, y: 0)
        placeholder.title = neighbour
        placeholder.transform = CGAffineTransform(translationX: offset + (translationX < 0 ? width : -width), y: 0)
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

    // MARK: - What the grid reports

    /// Rex's snapshot of the pane `block` replaced the grid's terminal. Only
    /// the pane last asked for (`shown`) lifts the cover: a switch that was
    /// overtaken (A to B, then C asked for) can still land B's snapshot, and
    /// that is not the screen the cover stands in for.
    func snapshotRestored(of block: String?, expecting shown: String?) {
        guard phase == .settling || phase == .covering else { return }
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
        phase = .idle
        onSwitching?(false)
    }

    // MARK: - Slides

    private func present() -> Bool {
        guard let grid, let container = grid.superview, grid.bounds.width > 0 else { return false }
        generation += 1
        returning = false
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
        timeout = Task { [weak self, revealTimeout] in
            try? await Task.sleep(for: revealTimeout)
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
        phase = .idle
        generation += 1
        UIView.animate(withDuration: Self.revealDuration, delay: 0, options: .curveEaseOut) {
            placeholder.alpha = 0
        } completion: { _ in placeholder.removeFromSuperview() }
    }
}

/// What stands in for the incoming pane: the terminal's own background, and
/// the pane's name dimmed in the middle.
final class SSHTerminalPanePlaceholderView: UIView {
    private let label = UILabel()

    var title: String? {
        get { label.text }
        set { label.text = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .callout)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.numberOfLines = 2
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(background: UIColor, foreground: UIColor) {
        backgroundColor = background
        label.textColor = foreground.withAlphaComponent(0.45)
    }
}
