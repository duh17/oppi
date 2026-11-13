import UIKit

/// One sheet per window across its panes (build plan V2). While a sheet that
/// one pane presented shows, a sheet another pane asks for waits its turn,
/// and that pane's grip carries a dot; when the sheet goes, the next one
/// presents. A waiting sheet whose pane left the window is dropped, and one
/// dismissed before its turn is taken out of the line with its own dismissal
/// callback.
///
/// `Router.present` asks here for a presenter inside a pane of a window with
/// more than one pane; a sheet presented from a sheet, and the window's other
/// modals, present as before.
@MainActor @Observable
final class PaneSheetArbiter {
    private struct Waiting {
        let owner: PaneID
        let container: ObjectIdentifier
        /// Presents the sheet; false when its pane has left the window.
        let present: () -> Bool
        /// The caller's dismissal callback, for a sheet taken out of the line.
        let onCancel: (() -> Void)?
    }

    @ObservationIgnored private var line: [Waiting] = []
    @ObservationIgnored private var isShowing = false
    /// The panes with a sheet waiting, oldest first; their grips show a dot.
    private(set) var waitingOwners: [PaneID] = []

    /// Every arbiter with a sheet in its line, by sheet, for `cancel`.
    private static let lines = NSMapTable<UIViewController, PaneSheetArbiter>.weakToWeakObjects()

    /// Presents now when no pane's sheet shows, else queues it behind the
    /// one that does. The sheet's own dismissal must call `sheetDidDismiss()`.
    func request(
        owner: PaneID,
        container: UIViewController,
        onCancel: (() -> Void)?,
        present: @escaping () -> Bool
    ) {
        guard isShowing else {
            isShowing = present()
            return
        }
        line.append(Waiting(owner: owner, container: ObjectIdentifier(container), present: present, onCancel: onCancel))
        Self.lines.setObject(self, forKey: container)
        waitingOwners = line.map(\.owner)
    }

    /// The pane's sheet went: the next waiting one presents.
    func sheetDidDismiss() {
        isShowing = false
        while !isShowing, !line.isEmpty {
            let next = line.removeFirst()
            isShowing = next.present()
        }
        waitingOwners = line.map(\.owner)
    }

    /// Takes `container` out of the line it waits in, running its caller's
    /// dismissal callback. False when it is not waiting anywhere.
    static func cancel(_ container: UIViewController) -> Bool {
        guard let arbiter = lines.object(forKey: container) else { return false }
        lines.removeObject(forKey: container)
        guard let index = arbiter.line.firstIndex(where: { $0.container == ObjectIdentifier(container) }) else { return false }
        let waiting = arbiter.line.remove(at: index)
        arbiter.waitingOwners = arbiter.line.map(\.owner)
        waiting.onCancel?()
        return true
    }
}
