import UIKit

/// Where an action sheet points when it pops over (iPad, regular width).
/// Every sheet and confirmation goes through `AlertAnchor`, so no screen
/// builds a popover source of its own.
@MainActor
enum AlertAnchor {
    /// Points the popover at `anchor` when it is in a window (the row that
    /// asked). Otherwise (the row scrolled away, a menu action with no row, a
    /// row that was never built) it is centered on the front-most view without an arrow,
    /// so the sheet always has a source. An alert, or a sheet on iPhone, has
    /// no popover and is left alone.
    static func apply(to alert: UIAlertController, screen: UIViewController, anchor: UIView?) {
        guard let popover = alert.popoverPresentationController else { return }
        if let anchor, anchor.window != nil {
            popover.sourceView = anchor
            popover.sourceRect = anchor.bounds
        } else {
            let host: UIView = Router.topPresenter(from: screen).view
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

    /// A further way out, after the confirming action and before Cancel: the
    /// answer that is neither "do it" nor "never mind" (Discard Changes).
    struct AdditionalAction {
        var title: String
        var identifier: String?
        var style: UIAlertAction.Style = .default
        var handler: () -> Void
    }

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
    /// Extra answers between the confirming button and Cancel, in order.
    var additionalActions: [AdditionalAction] = []

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
        for additional in additionalActions {
            let action = UIAlertAction(title: additional.title, style: additional.style) { _ in
                additional.handler()
            }
            action.accessibilityIdentifier = additional.identifier
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { _ in onCancel?() })
        if prefersAction { alert.preferredAction = confirm }
        AlertAnchor.present(alert, from: screen, anchor: anchor)
        return alert
    }
}

/// An alert that asks for one line of text (a name), with a default button
/// that hands it back and Cancel. The one text prompt: screens describe it and
/// call `present(from:onSubmit:)`, so none builds a `UIAlertController` for it.
struct TextPrompt {
    var title: String
    var message: String?
    var placeholder = ""
    /// What the field starts with.
    var text = ""
    /// The default button.
    var actionTitle: String
    var cancelTitle = String(localized: "Cancel")
    var fieldIdentifier: String?
    var actionIdentifier: String?
    /// `.URL` also turns off autocorrection and capitals, for a name like `rex.tail1234.ts.net`.
    var keyboardType: UIKeyboardType = .default

    /// Presents the prompt over `screen`. `onSubmit` gets the field's text, as typed.
    /// - Returns: the controller, so a screen can refuse to stack a second one.
    @MainActor
    @discardableResult
    func present(from screen: UIViewController, onSubmit: @escaping (String) -> Void) -> UIAlertController {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = placeholder
            field.text = text
            field.accessibilityIdentifier = fieldIdentifier
            field.keyboardType = keyboardType
            if keyboardType == .URL {
                field.autocorrectionType = .no
                field.autocapitalizationType = .none
            }
        }
        let submit = UIAlertAction(title: actionTitle, style: .default) { [weak alert] _ in
            onSubmit(alert?.textFields?.first?.text ?? "")
        }
        submit.accessibilityIdentifier = actionIdentifier
        alert.addAction(submit)
        alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel))
        alert.preferredAction = submit
        Router.topPresenter(from: screen).present(alert, animated: true)
        return alert
    }
}
