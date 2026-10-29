import UIKit

/// A screen's failures as an alert with one dismiss button: the only way a
/// screen tells the person that something failed. Each screen has one
/// (`UIViewController.errorAlerts`), so every error on it shares one alert.
///
/// - A newer error replaces the message of the alert on screen. The older
///   message is gone, never stacked and never queued behind it: the person
///   reads the latest failure, and one tap closes the alert.
/// - An error that arrives while the screen is not in a window (covered by a
///   pushed page, not mounted yet, in a hidden column) is held, one deep, and
///   shown once the screen is back in a window and nothing is mid-transition
///   over it. A newer held error replaces an older one.
/// - Two ways to raise one. `show` is for an event ("Delete failed") and is
///   done once the person dismisses it. `sync` is for a screen whose error is
///   state: call it from `updateProperties()` with the screen's current error.
///   The button calls `clear` with the message the person read, so the owner
///   clears only that error and never a newer one that replaced it.
@MainActor
final class ErrorAlertPresenter {
    private struct Entry {
        var title: String
        var message: String
        var buttonTitle: String
        var tint: UIColor?
        /// Set for `sync`: runs when the button is tapped, with the message shown.
        var clear: ((String) -> Void)?
        var isStateDriven: Bool
    }

    private weak var screen: UIViewController?
    private weak var shown: UIAlertController?
    private var shownEntry: Entry?
    private var held: Entry?
    private weak var watcher: WindowWatcher?
    private var retries = 0

    init(screen: UIViewController) {
        self.screen = screen
    }

    /// Tells the person an event failed.
    func show(
        title: String = String(localized: "Error"),
        message: String,
        buttonTitle: String = String(localized: "OK"),
        tint: UIColor? = nil
    ) {
        raise(Entry(
            title: title, message: message, buttonTitle: buttonTitle, tint: tint, clear: nil, isStateDriven: false
        ))
    }

    /// "Unable to Share File", the same words wherever a file share fails.
    func showShareFailure() {
        show(
            title: String(localized: "Unable to Share File"),
            message: String(localized: "The file could not be downloaded. Please try again.")
        )
    }

    /// Shows the screen's current error. A nil `message` closes the alert this
    /// method raised, because the owner's error went away.
    func sync(title: String, message: String?, clear: @escaping (_ shown: String) -> Void) {
        guard let message else {
            if held?.isStateDriven == true { held = nil }
            if shownEntry?.isStateDriven == true { shown?.dismiss(animated: true) }
            return
        }
        raise(Entry(
            title: title,
            message: message,
            buttonTitle: String(localized: "OK"),
            tint: nil,
            clear: clear,
            isStateDriven: true
        ))
    }

    /// Takes back an error that is held or shown. With a prefix, only one whose
    /// message starts with it.
    func dismiss(onlyWithPrefix prefix: String? = nil) {
        func matches(_ message: String?) -> Bool {
            guard let prefix else { return true }
            return message?.hasPrefix(prefix) == true
        }
        if matches(held?.message) { held = nil }
        if let shown, isActive(shown), matches(shown.message) { shown.dismiss(animated: true) }
    }

    // MARK: - Raising and presenting

    private func raise(_ entry: Entry) {
        if let shown, isActive(shown) {
            if shown.message != entry.message { shown.message = entry.message }
            if shown.title != entry.title { shown.title = entry.title }
            shownEntry = entry
            held = nil
            return
        }
        held = entry
        flush()
    }

    /// An alert that is up or coming up, as opposed to one that closed or is closing.
    private func isActive(_ alert: UIAlertController) -> Bool {
        alert.isBeingPresented || (alert.presentingViewController != nil && !alert.isBeingDismissed)
    }

    private func flush() {
        guard let entry = held, let screen else { return }
        screen.loadViewIfNeeded()
        guard screen.view.window != nil else {
            watchWindow(of: screen)
            return
        }
        // A page that is still appearing (or going away) cannot present.
        if let coordinator = screen.transitionCoordinator ?? screen.navigationController?.transitionCoordinator {
            retry(after: coordinator)
            return
        }
        let top = Router.topPresenter(from: screen)
        // `topPresenter` skips a controller that is being dismissed, which still blocks presenting.
        if top.isBeingPresented || top.presentedViewController != nil {
            retry(after: top.transitionCoordinator)
            return
        }
        held = nil
        retries = 0
        watcher?.removeFromSuperview()
        let alert = UIAlertController(title: entry.title, message: entry.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: entry.buttonTitle, style: .cancel) { [weak self, weak alert] _ in
            guard let self, let alert else { return }
            // The alert may now read a newer error than the one it opened with.
            let read = alert.message ?? ""
            let clear = shownEntry?.clear
            if self.shown === alert { shown = nil; shownEntry = nil }
            clear?(read)
        })
        if let tint = entry.tint { alert.view.tintColor = tint }
        shown = alert
        shownEntry = entry
        top.present(alert, animated: true)
    }

    /// Tries again when `coordinator`'s transition ends, or shortly, bounded.
    private func retry(after coordinator: UIViewControllerTransitionCoordinator?) {
        if let coordinator {
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.flush() }
            return
        }
        guard retries < 30 else { return }
        retries += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            self?.flush()
        }
    }

    private func watchWindow(of screen: UIViewController) {
        guard watcher == nil else { return }
        let watcher = WindowWatcher { [weak self] in
            // The window arrives at the start of a transition; flush waits it out.
            self?.flush()
        }
        screen.view.addSubview(watcher)
        self.watcher = watcher
    }
}

/// An invisible view that reports when its screen reaches a window, so a held
/// error needs no help from the screen. It removes itself when it has fired.
private final class WindowWatcher: UIView {
    private let onWindow: @MainActor () -> Void

    init(onWindow: @escaping @MainActor () -> Void) {
        self.onWindow = onWindow
        super.init(frame: .zero)
        isHidden = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        removeFromSuperview()
        onWindow()
    }
}

extension UIViewController {
    /// This screen's one error alert. See `ErrorAlertPresenter`.
    var errorAlerts: ErrorAlertPresenter {
        if let existing = objc_getAssociatedObject(self, &ErrorAlertsAssociation.key) as? ErrorAlertPresenter {
            return existing
        }
        let presenter = ErrorAlertPresenter(screen: self)
        objc_setAssociatedObject(self, &ErrorAlertsAssociation.key, presenter, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return presenter
    }
}

private enum ErrorAlertsAssociation {
    nonisolated(unsafe) static var key: UInt8 = 0
}
