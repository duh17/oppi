import UIKit

/// Where an action sheet points when it pops over (iPad, regular width).
/// Every sheet and confirmation goes through `AlertAnchor`, so no screen
/// builds a popover source of its own.
@MainActor
enum AlertAnchor {
    /// Points the popover at `anchor` when it is in a window (the row that
    /// asked). Otherwise (the row scrolled away, a menu action with no row, a
    /// row that was never built) it is centered on `screen` without an arrow,
    /// so the sheet always has a source. An alert, or a sheet on iPhone, has
    /// no popover and is left alone.
    static func apply(to alert: UIAlertController, screen: UIViewController, anchor: UIView?) {
        guard let popover = alert.popoverPresentationController else { return }
        if let anchor, anchor.window != nil {
            popover.sourceView = anchor
            popover.sourceRect = anchor.bounds
        } else {
            let host: UIView = screen.view
            popover.sourceView = host
            popover.sourceRect = CGRect(x: host.bounds.midX, y: host.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
    }

    /// Presents `alert` from the front-most controller over `screen`.
    static func present(_ alert: UIAlertController, from screen: UIViewController, anchor: UIView?) {
        apply(to: alert, screen: screen, anchor: anchor)
        Router.topPresenter(from: screen).present(alert, animated: true)
    }
}

/// What the person is asked before something that can't be undone runs: an
/// alert, or an action sheet that anchors to the asking row as a popover on
/// iPad. The action runs only after the person confirms. This is the one
/// confirmation; screens describe it and call `present(from:anchor:)`.
struct Confirmation {
    enum Style { case alert, actionSheet }

    var title: String
    var message: String?
    /// The confirming button.
    var actionTitle: String
    var style: Style = .actionSheet
    /// The confirming button reads as destructive; false for a plain default button.
    var isDestructive = true
    var cancelTitle = String(localized: "Cancel")
    /// Makes the confirming button the alert's bold, preferred one.
    var prefersAction = false
    /// The confirming button's accessibility identifier, for a test to find it.
    var actionIdentifier: String?

    /// Presents the confirmation over `screen`. `anchor` is where an action
    /// sheet points on iPad: the row that asked, or nil when nothing does (it
    /// then centers on the screen). It is required so every call decides, and
    /// a row that is not in a window never leaves a popover without a source.
    ///
    /// - Parameters:
    ///   - onConfirm: runs after the person confirms.
    ///   - onCancel: runs when the person cancels, also when a popover is
    ///     dismissed with a tap outside it.
    /// - Returns: the controller, so a screen can refuse to stack a second one.
    @MainActor
    @discardableResult
    func present(
        from screen: UIViewController,
        anchor: UIView?,
        onConfirm: @escaping () -> Void,
        onCancel: (() -> Void)? = nil
    ) -> UIAlertController {
        let alert = UIAlertController(
            title: title,
            message: message,
            preferredStyle: style == .alert ? .alert : .actionSheet
        )
        let confirm = UIAlertAction(title: actionTitle, style: isDestructive ? .destructive : .default) { _ in
            onConfirm()
        }
        confirm.accessibilityIdentifier = actionIdentifier
        alert.addAction(confirm)
        alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { _ in onCancel?() })
        if prefersAction { alert.preferredAction = confirm }
        AlertAnchor.present(alert, from: screen, anchor: anchor)
        return alert
    }
}
