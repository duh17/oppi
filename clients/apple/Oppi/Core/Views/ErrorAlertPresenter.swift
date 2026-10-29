import UIKit

/// A screen's failures as an alert with one dismiss button: the only way a
/// screen tells the person that something failed. Each screen has one
/// (`UIViewController.errorAlerts`), so every error on it shares one alert.
///
/// - A newer error replaces the message of the alert on screen. The older
///   message is gone, never stacked and never queued behind it: the person
///   reads the latest failure, and one tap closes the alert.
/// - An error shows only while its screen is what the person is looking at:
///   in a window, with nothing presented over the controller that holds it
///   except a search controller, an alert, or a popover. Otherwise it is held,
///   one deep (a newer held error replaces an older one), and shown when that
///   changes: a page pushed over the screen pops, the screen mounts, an
///   unrelated sheet over it (a viewer, the expanded composer, a page sheet)
///   closes. An error that a sheet raises through its own screen shows over
///   that sheet, because the sheet is then the front. A held error does not
///   expire: it waits as long as the screen is covered, and a screen that goes
///   away takes it with it. A transition in flight delays it a moment.
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
    /// The alert this presenter is closing itself (the owner's error went away),
    /// as opposed to one the person closed with OK.
    private weak var closedByUs: UIAlertController?
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
            if shownEntry?.isStateDriven == true { closeShown() }
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
        if let shown, isActive(shown), matches(shown.message) { closeShown() }
    }

    /// Closes our alert, and only it: `dismiss` on a controller also closes what
    /// is stacked above it, so an alert with something over it stays.
    private func closeShown() {
        guard let shown, shown.presentingViewController != nil, shown.presentedViewController == nil else { return }
        closedByUs = shown
        shown.dismiss(animated: true)
    }

    // MARK: - Raising and presenting

    private func raise(_ entry: Entry) {
        retries = 0
        // The person tapped OK on this very error and the alert is on its way out: re-presenting
        // it before the owner clears it would flash it back. An alert we closed ourselves (the
        // owner's error went away) does not count: the same error raised again shows.
        if let shown, shown.isBeingDismissed, shown !== closedByUs, entry.isStateDriven,
           shownEntry?.isStateDriven == true, shown.message == entry.message {
            return
        }
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
            watch(screen.view, for: .attach)
            return
        }
        // A page that is still appearing (or going away) cannot present.
        if let coordinator = screen.transitionCoordinator ?? screen.navigationController?.transitionCoordinator {
            retry(after: coordinator)
            return
        }
        // What is presented over the controller that holds the screen. A dismissal
        // in flight still blocks presenting; an unrelated sheet means the screen
        // is under it, not in front.
        var top = screen
        while let parent = top.parent { top = parent }
        if top.isBeingPresented {
            retry(after: top.transitionCoordinator)
            return
        }
        var covering: UIViewController?
        while let presented = top.presentedViewController {
            if presented.isBeingPresented || presented.isBeingDismissed {
                retry(after: presented.transitionCoordinator)
                return
            }
            if covering == nil, !(presented is UISearchController || presented is UIAlertController
                || presented.modalPresentationStyle == .popover) {
                covering = presented
            }
            top = presented
        }
        if let covering {
            // Shown when it closes: its view leaves the window. A view that is not in a window
            // cannot report that, so the front-most presented one, then the screen, stands in.
            let watched = [covering.view, top.view, screen.view].lazy.compactMap { $0 }.first { $0.window != nil }
            watch(watched ?? screen.view, for: .detach)
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
        // `animate` returns false when the transition has nothing to wait on.
        if let coordinator, coordinator.animate(alongsideTransition: nil, completion: { [weak self] _ in self?.flush() }) {
            return
        }
        guard retries < 30 else {
            // Out of retries: the next time the screen reaches a window flushes it (a state-driven
            // screen also retries on every pass), so a held error is never stranded.
            if let screen { watch(screen.view, for: .attach) }
            return
        }
        retries += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            self?.flush()
        }
    }

    /// Calls `flush` when `view` reaches a window (`.attach`) or leaves it (`.detach`).
    private func watch(_ view: UIView, for event: WindowWatcher.Event) {
        watcher?.removeFromSuperview()
        let watcher = WindowWatcher(event: event) { [weak self] in
            // The change comes at the start of a transition; flush waits it out.
            self?.flush()
        }
        view.addSubview(watcher)
        self.watcher = watcher
    }
}

/// An invisible view that reports when the view it sits in reaches or leaves a
/// window, so a held error needs no help from its screen. It removes itself
/// when it has fired.
private final class WindowWatcher: UIView {
    enum Event { case attach, detach }

    private let event: Event
    private let onChange: @MainActor () -> Void

    init(event: Event, onChange: @escaping @MainActor () -> Void) {
        self.event = event
        self.onChange = onChange
        super.init(frame: .zero)
        isHidden = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard (window != nil) == (event == .attach) else { return }
        removeFromSuperview()
        onChange()
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
