import UIKit

/// Hold and settle for one pane host: while the divider moves or the window
/// resizes, the screens on both sides that adopt `PaneLiveResizing` hold
/// their heavy views at the width they had, and settle in one reflow when
/// the motion pauses, when it comes to rest, or when a window resize has
/// rested. It also feeds the host's resize meter, finger down to settle.
///
/// The host says when motion begins, moves and ends; this owns which screens
/// are held, the pause timer, and the reflow.
@MainActor
final class PaneResizeHold {
    /// A finger that stays within `pauseDistance` for `pauseDelay` has
    /// paused (under 30 pt/s for 100 ms); a window width that has not
    /// changed for `pauseDelay` has rested.
    static let pauseDistance: CGFloat = 3
    static let pauseDelay: TimeInterval = 0.1

    /// The host's leaves, whose screens hold.
    private let leaves: () -> [UIViewController?]
    /// Lays the host out at the sizes the held screens settle to.
    private let layout: () -> Void
    private let meter = PaneResizeMeter()
    /// The screens held now; empty when nothing is.
    private var held: [any PaneLiveResizing] = []
    /// The drawn width and time of the divider's last move of more than
    /// `pauseDistance`.
    private var lastMove: (width: CGFloat, time: CFTimeInterval)?
    private var pauseTimer: Timer?

    init(leaves: @escaping () -> [UIViewController?], layout: @escaping () -> Void) {
        self.leaves = leaves
        self.layout = layout
    }

    /// A grab of the divider at the drawn `width`.
    func dragBegan(at width: CGFloat) {
        lastMove = (width, CACurrentMediaTime())
        meter.beginDrag()
        hold()
    }

    /// The divider moved to `width`. A real move holds the screens (again,
    /// after a pause settled them) and restarts the pause; creeping or
    /// standing still lets the pause run on from the last real move, and it
    /// settles the screens unless `isDragging` says the drag has ended.
    func dividerMoved(to width: CGFloat, isDragging: @escaping () -> Bool) {
        if let lastMove, abs(width - lastMove.width) <= Self.pauseDistance { return }
        lastMove = (width, CACurrentMediaTime())
        hold()
        schedulePause { [weak self] in
            guard isDragging() else { return }
            self?.settle(final: false)
        }
    }

    /// A drag released: the pause is over; the screens stay held until
    /// `finish`, through the spring that lands the divider.
    func dragEnded() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        lastMove = nil
    }

    /// A window resize (rotation, Split View, Stage Manager, a Mac window
    /// edge): the screens hold from the first change and settle when the
    /// width has rested, unless `canSettle` says a drag or a spring has taken
    /// over the hold. A resize that is not live (a rotation, tiling, full
    /// screen) settles once, as at rest. During a live resize (`live`) a rest
    /// is a pause, as a divider's is, and `liveResizeEnded` settles at rest.
    func windowWidthChanged(live: Bool, canSettle: @escaping () -> Bool) {
        hold()
        schedulePause { [weak self] in
            guard canSettle() else { return }
            self?.settle(final: !live)
        }
    }

    /// The person started resizing the window: the screens hold before the
    /// first width arrives.
    func liveResizeBegan() {
        hold()
    }

    /// The live resize ended: the held screens settle at rest.
    func liveResizeEnded() {
        settle(final: true)
    }

    /// One divider frame, measured as the main thread's whole cost of it.
    func measureFrame(_ body: () -> Void) {
        meter.measureFrame(body)
    }

    /// The divider is at rest: the held screens settle and the drag's
    /// measurement ends. Safe to call when nothing moved.
    func finish() {
        lastMove = nil
        settle(final: true)
        meter.endDrag()
    }

    /// The visit's drags so far, as one event, once.
    func takeVisit() -> AppPaneResizeVisit? {
        meter.takeVisit()
    }

    /// Holds the screens on both sides, unless they are held already.
    private func hold() {
        guard held.isEmpty else { return }
        held = leaves().flatMap { PaneLeafScreens.adopters(in: $0, as: (any PaneLiveResizing).self) }
        for screen in held { screen.paneWillBeginLiveResize() }
    }

    private func schedulePause(_ fire: @escaping @MainActor () -> Void) {
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: Self.pauseDelay, repeats: false) { _ in
            MainActor.assumeIsolated { fire() }
        }
    }

    /// Lays the held screens out at their sizes now, as one reflow.
    private func settle(final: Bool) {
        pauseTimer?.invalidate()
        pauseTimer = nil
        let screens = held
        held = []
        guard !screens.isEmpty else { return }
        layout()
        meter.measureReflow {
            for screen in screens where screen.viewIfLoaded?.window != nil {
                screen.paneSettleLiveResize(to: screen.view.bounds.size, final: final)
            }
        }
    }
}
