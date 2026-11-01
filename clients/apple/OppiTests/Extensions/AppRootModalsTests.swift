import Foundation
import Testing
import UIKit
@testable import Oppi

/// The window root's app-wide modals: which extension requests get a sheet, the
/// slot rules (a server switch closes the other server's dialog without
/// answering it), and how each modal clears the state it shows.
@MainActor
@Suite("App root modals", .serialized)
struct AppRootModalsTests {
    // MARK: Pure rules

    @Test("only the editor and the fallback get a sheet; ask cards stay in the chat",
          arguments: [
              ("editor", true), ("custom", true), ("notify-me", true),
              ("ask", false), ("confirm", false), ("input", false),
          ])
    func sheetRequestFollowsPresentation(method: String, hasSheet: Bool) {
        let request = ExtensionUIRequest(id: "r", sessionId: "s", method: method)
        #expect((AppRootModals.sheetRequest(request) != nil) == hasSheet)
        #expect(AppRootModals.sheetRequest(nil) == nil)
    }

    @Test("a fallback dialog opens at medium and large; the editor opens large")
    func dialogDetents() {
        let fallback = AppRootModals.dialogPresentation(for: ExtensionUIRequest(id: "r", sessionId: "s", method: "custom"))
        let editor = AppRootModals.dialogPresentation(for: ExtensionUIRequest(id: "r", sessionId: "s", method: "editor"))
        #expect(fallback.detents.count == 2)
        #expect(editor.detents.count == 1)
        #expect(fallback.wrapsInNavigation && editor.wrapsInNavigation)
    }

    @Test("the fallback expires in whole seconds, at least one, from the deadline or the timeout")
    func fallbackTimeoutSummary() {
        let now = Date(timeIntervalSince1970: 1_000)
        func summary(timeout: Int? = nil, timeoutAt: Date? = nil) -> String? {
            let request = ExtensionUIRequest(id: "r", sessionId: "s", method: "custom", timeout: timeout, timeoutAt: timeoutAt)
            return ExtensionDialogFallbackViewController.timeoutSummary(of: request, now: now)
        }
        #expect(summary() == nil)
        #expect(summary(timeout: 0) == nil)
        #expect(summary(timeout: 1_500)?.contains("2") == true)
        #expect(summary(timeoutAt: now.addingTimeInterval(41.2))?.contains("42") == true)
        #expect(summary(timeoutAt: now.addingTimeInterval(-5))?.contains("1 ") == true)
        // The deadline wins over the timeout it came with.
        #expect(summary(timeout: 60_000, timeoutAt: now.addingTimeInterval(10))?.contains("10") == true)
    }

    @Test("a notice line with a web link is a label and a link; anything else is text")
    func noticeLines() {
        let lines = ExtensionNoticeViewController.lines(of: """
        Extension finished.

          Docs https://example.com/docs
        https://example.com/bare
        Mail me at someone@example.com
        ftp://example.com/file
        """)
        #expect(lines.map(\.text) == [
            "Extension finished.",
            "Docs https://example.com/docs",
            "https://example.com/bare",
            "Mail me at someone@example.com",
            "ftp://example.com/file",
        ])
        #expect(lines.map(\.url?.absoluteString) == [nil, "https://example.com/docs", "https://example.com/bare", nil, nil])
        #expect(lines[1].label == "Docs")
        #expect(lines[2].label == "Link")
        #expect(lines[0].label == "Extension finished.")
    }

    // MARK: The slots, on screen

    @Test("a fallback dialog cannot be swiped away; Cancel answers it, closes it, and clears it")
    func fallbackDialogCancel() async throws {
        let root = try makeRoot(servers: ["alpha"])
        let connection = root.coordinator.activeConnection
        let answers = AnswerRecorder()
        connection._sendMessageForTesting = { message in answers.record(message) }
        // The active dialog is the focused session's.
        _ = connection.focusedSessionStore.focus(sessionId: "s")
        let (host, window) = try show(root)
        defer { hide(window) }

        connection.activeExtensionDialog = ExtensionUIRequest(
            id: "dialog-1", sessionId: "s", method: "custom", title: "Pick a Plan", message: "Waiting."
        )
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { isSettled(host.presentedViewController) })

        let navigation = try #require(host.presentedViewController as? UINavigationController)
        let dialog = try #require(navigation.topViewController as? ExtensionDialogFallbackViewController)
        #expect(dialog.title == "Pick a Plan")
        #expect(navigation.isModalInPresentation, "an unanswered dialog must not be swipe-dismissible")
        #expect(dialog.isModalInPresentation)
        let cancel = try #require(dialog.navigationItem.leftBarButtonItem)
        #expect(cancel.accessibilityIdentifier == "extension.dialog.cancel")

        cancel.primaryAction?.performWithSender(nil, target: nil)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { host.presentedViewController == nil })
        #expect(answers.cancelledIds == ["dialog-1"])
        #expect(connection.activeExtensionDialog == nil)
    }

    @Test("a fallback dialog redraws when its request is replaced under the same id")
    func fallbackDialogRedrawsOnReplacement() async throws {
        let root = try makeRoot(servers: ["alpha"])
        let connection = root.coordinator.activeConnection
        _ = connection.focusedSessionStore.focus(sessionId: "s")
        let (host, window) = try show(root)
        defer { hide(window) }

        connection.activeExtensionDialog = ExtensionUIRequest(
            id: "replaced", sessionId: "s", method: "custom", title: "Old title", message: "Old message"
        )
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { isSettled(host.presentedViewController) })
        let navigation = try #require(host.presentedViewController as? UINavigationController)
        let dialog = try #require(navigation.topViewController as? ExtensionDialogFallbackViewController)
        dialog.view.layoutIfNeeded()
        #expect(await waitForMainActorCondition { labelTexts(in: dialog.view).contains("Old message") })

        connection.activeExtensionDialog = ExtensionUIRequest(
            id: "replaced", sessionId: "s", method: "custom", title: "New title",
            message: "New message", timeout: 30_000
        )
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            let texts = labelTexts(in: dialog.view)
            return texts.contains("New message") && texts.contains("Expires in about 30 seconds")
        }, "the dialog kept its old content: \(labelTexts(in: dialog.view))")
        #expect(dialog.title == "New title")
        #expect(!labelTexts(in: dialog.view).contains("Old message"))
        #expect(host.presentedViewController === navigation, "a replacement must not present again")
    }

    @Test("a dialog left up on a server that stops being active closes unanswered; the new active server's dialog opens")
    func serverSwitchClosesTheOtherServersDialog() async throws {
        let root = try makeRoot(servers: ["alpha", "beta"])
        let coordinator = root.coordinator
        let alphaConnection = coordinator.activeConnection
        let betaId = try #require(coordinator.serverStore.servers.first { $0.name == "beta" }?.id)
        let answers = AnswerRecorder()
        alphaConnection._sendMessageForTesting = { message in answers.record(message) }
        _ = alphaConnection.focusedSessionStore.focus(sessionId: "s")
        let (host, window) = try show(root)
        defer { hide(window) }

        alphaConnection.activeExtensionDialog = ExtensionUIRequest(id: "same-id", sessionId: "s", method: "custom", title: "Alpha")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { isSettled(host.presentedViewController) })
        let alphaDialog = host.presentedViewController

        // The other server already has a dialog under the same request id.
        let beta = try #require(coordinator.serverStore.server(for: betaId))
        let betaConnection = coordinator.ensureConnection(for: beta)
        _ = betaConnection.focusedSessionStore.focus(sessionId: "s")
        betaConnection.activeExtensionDialog = ExtensionUIRequest(id: "same-id", sessionId: "s", method: "custom", title: "Beta")

        #expect(coordinator.restoreActiveServer(betaId))
        #expect(coordinator.activeConnection === betaConnection)
        // A different slot for the same request id: alpha's dialog closes and beta's opens.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            isSettled(host.presentedViewController) && host.presentedViewController !== alphaDialog
        })
        let navigation = try #require(host.presentedViewController as? UINavigationController)
        #expect(navigation.topViewController?.title == "Beta")
        // Closed, not answered: alpha's dialog is still alpha's to answer.
        #expect(answers.cancelledIds.isEmpty)
        #expect(alphaConnection.activeExtensionDialog?.id == "same-id")
    }

    @Test("Done closes the notice and clears it; swiping it down clears it too; a newer message shows in place")
    func noticeLifecycle() async throws {
        let root = try makeRoot(servers: ["alpha"])
        let connection = root.coordinator.activeConnection
        let (host, window) = try show(root)
        defer { hide(window) }

        connection.extensionToast = "First https://example.com/one"
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { isSettled(host.presentedViewController) })
        let navigation = try #require(host.presentedViewController as? UINavigationController)
        let notice = try #require(navigation.topViewController as? ExtensionNoticeViewController)
        #expect(notice.title == "Notice")
        #expect(!navigation.isModalInPresentation)
        #expect(labelTexts(in: notice.view).contains("First"))
        #expect(buttonIdentifiers(in: notice.view).contains("extension.notice.link"))

        connection.extensionToast = "Second line"
        #expect(await waitForMainActorCondition { labelTexts(in: notice.view).contains("Second line") })
        #expect(host.presentedViewController === navigation, "a newer message must not present again")

        let done = try #require(notice.navigationItem.rightBarButtonItem)
        done.target?.perform(done.action, with: done)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { host.presentedViewController == nil })
        #expect(connection.extensionToast == nil)

        connection.extensionToast = "Again"
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { isSettled(host.presentedViewController) })
        // A swipe-down is the system's dismissal, not the notice's own.
        host.dismiss(animated: false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { connection.extensionToast == nil })
    }

    @Test("What's New covers the root and closes itself, which clears the flag")
    func whatsNewClosesItself() async throws {
        let root = try makeRoot(servers: ["alpha"])
        let (host, window) = try show(root)
        defer { hide(window) }

        root.navigation.showWhatsNew = true
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { isSettled(host.presentedViewController) })
        let whatsNew = try #require(host.presentedViewController as? WhatsNewViewController)

        // The root is covered and may not update; the screen's own close must clear the flag.
        Router.finish(whatsNew)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { host.presentedViewController == nil })
        #expect(await waitForMainActorCondition { !root.navigation.showWhatsNew })
    }

    // MARK: Fixtures

    private func makeRoot(servers names: [String]) throws -> AppRootEnvironment {
        let servers = try names.map { name in
            try #require(PairedServer(from: ServerCredentials(
                host: "\(name).modals.test",
                port: 7749,
                token: "sk_test",
                name: name,
                scheme: .https,
                serverFingerprint: "sha256:modals-\(name)",
                tlsCertFingerprint: "sha256:modals-\(name)-leaf"
            )))
        }
        let serverStore = ServerStore()
        serverStore.replaceServersForPreview(servers)
        let coordinator = ConnectionCoordinator(serverStore: serverStore)
        #expect(coordinator.restoreActiveServer(servers[0].id))
        return makeTestAppRoot(coordinator: coordinator)
    }

    /// The owner a real root is: `AppRootModals` driven from `updateProperties()`.
    private final class Host: UIViewController {
        private let root: AppRootEnvironment
        private lazy var modals = AppRootModals(root: root, anchor: self)

        init(root: AppRootEnvironment) {
            self.root = root
            super.init(nibName: nil, bundle: nil)
            traitOverrides.appRootEnvironment = root
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            modals.anchorDidAppear()
        }

        override func updateProperties() {
            super.updateProperties()
            modals.update()
        }
    }

    private final class AnswerRecorder {
        private(set) var cancelledIds: [String] = []
        /// Submitted values by request id, in the order they were sent.
        private(set) var values: [(id: String, value: String)] = []

        func record(_ message: ClientMessage) {
            guard case .extensionUIResponse(let id, let value, _, let cancelled, _) = message else { return }
            if cancelled == true { cancelledIds.append(id) }
            if let value { values.append((id, value)) }
        }
    }

    private func show(_ root: AppRootEnvironment) throws -> (Host, UIWindow) {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the modal tests need the test host's window scene"
        )
        let host = Host(root: root)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        return (host, window)
    }

    private func hide(_ window: UIWindow) {
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }

    private func isSettled(_ presented: UIViewController?) -> Bool {
        guard let presented else { return false }
        return !presented.isBeingPresented && presented.viewIfLoaded?.window != nil
    }

    /// The text of every label under `view`, after the pending layout.
    private func labelTexts(in view: UIView) -> [String] {
        view.layoutIfNeeded()
        return collectLabelTexts(in: view)
    }

    private func collectLabelTexts(in view: UIView) -> [String] {
        let own = (view as? UILabel).flatMap(\.text).map { [$0] } ?? []
        return own + view.subviews.flatMap { collectLabelTexts(in: $0) }
    }

    @Test("an editor request opens the expanded composer with the request's prefill")
    func editorDialogPresentsThePrefill() async throws {
        let root = try makeRoot(servers: ["alpha"])
        let connection = root.coordinator.activeConnection
        _ = connection.focusedSessionStore.focus(sessionId: "s")
        let (host, window) = try show(root)
        defer { hide(window) }

        connection.activeExtensionDialog = ExtensionUIRequest(
            id: "editor-1", sessionId: "s", method: "editor",
            title: "Edit some text", prefill: "Line 1\nLine 2\nLine 3"
        )
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { isSettled(host.presentedViewController) })
        let navigation = try #require(host.presentedViewController as? UINavigationController)
        let composer = try #require(navigation.topViewController as? ExpandedComposerViewController)
        composer.view.layoutIfNeeded()

        let editor = try #require(
            firstView(in: composer.view, where: { $0.accessibilityIdentifier == "extension.dialog.editor" }),
            "the editor sheet has no text view: \(viewIdentifiers(in: composer.view))"
        )
        #expect((editor as? UITextView)?.text == "Line 1\nLine 2\nLine 3")
        #expect(composer.navigationItem.leftBarButtonItem?.accessibilityIdentifier == "extension.dialog.cancel")
    }

    @Test("an editor's Submit sends the typed text as the request's answer and closes the editor")
    func editorSubmitAnswersWithTheTypedText() async throws {
        let root = try makeRoot(servers: ["alpha"])
        let connection = root.coordinator.activeConnection
        let answers = AnswerRecorder()
        connection._sendMessageForTesting = { message in answers.record(message) }
        _ = connection.focusedSessionStore.focus(sessionId: "s")
        let (host, window) = try show(root)
        // The editor takes focus as it opens: resign it before the window goes.
        defer { window.endEditing(true); hide(window) }

        connection.activeExtensionDialog = ExtensionUIRequest(id: "editor-2", sessionId: "s", method: "editor", title: "Ship?")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { isSettled(host.presentedViewController) })
        let navigation = try #require(host.presentedViewController as? UINavigationController)
        let composer = try #require(navigation.topViewController as? ExpandedComposerViewController)
        composer.view.layoutIfNeeded()
        let editor = try #require(
            firstView(in: composer.view, where: { $0.accessibilityIdentifier == "extension.dialog.editor" }) as? UITextView
        )
        // What the keyboard does: text into the view, which tells its delegate.
        editor.insertText("ship it")

        let submit = try #require(composer.navigationItem.rightBarButtonItem)
        #expect(submit.accessibilityIdentifier == "extension.dialog.submit")
        submit.primaryAction?.performWithSender(nil, target: nil)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { host.presentedViewController == nil })
        #expect(answers.values.map(\.id) == ["editor-2"])
        #expect(answers.values.map(\.value) == ["ship it"])
        #expect(answers.cancelledIds.isEmpty)
        #expect(connection.activeExtensionDialog == nil)
    }

    @Test("a dialog queued after the chat takes focus still presents its sheet")
    func editorDialogPresentsWhenTheQueueArrivesAfterFocus() async throws {
        // The app's order: the root's `updateProperties()` runs before any chat is
        // focused, and the dialog arrives later. Reading the queue only behind the
        // focus guard registered no dependency, so the first dialog never
        // invalidated the root and its sheet never appeared.
        let root = try makeRoot(servers: ["alpha"])
        let connection = root.coordinator.activeConnection
        let (host, window) = try show(root)
        defer { hide(window) }

        _ = connection.focusedSessionStore.focus(sessionId: "later")
        connection.activeExtensionDialog = ExtensionUIRequest(
            id: "editor-later", sessionId: "later", method: "editor", prefill: "after focus"
        )
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { isSettled(host.presentedViewController) })
        let navigation = try #require(host.presentedViewController as? UINavigationController)
        #expect(navigation.topViewController is ExpandedComposerViewController)
    }

    @Test("a dialog queued before its chat takes focus presents once it does")
    func editorDialogPresentsWhenFocusArrivesAfterTheQueue() async throws {
        // The other order: the request is already queued for a session nobody is
        // looking at (the queue changes, focus does not), and the sheet must
        // appear when that session takes focus.
        let root = try makeRoot(servers: ["alpha"])
        let connection = root.coordinator.activeConnection
        let (host, window) = try show(root)
        defer { hide(window) }

        connection.pendingExtensionDialogQueues["waiting"] = [
            ExtensionUIRequest(id: "editor-waiting", sessionId: "waiting", method: "editor", prefill: "queued first"),
        ]
        // Run the update pass this expectation is about: a root that never looked
        // after the queue changed would pass by not having looked yet.
        host.setNeedsUpdateProperties()
        try await Task.sleep(for: .milliseconds(250))
        #expect(host.presentedViewController == nil, "an unfocused session's dialog must stay queued")

        _ = connection.focusedSessionStore.focus(sessionId: "waiting")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { isSettled(host.presentedViewController) })
        let navigation = try #require(host.presentedViewController as? UINavigationController)
        #expect(navigation.topViewController is ExpandedComposerViewController)
    }

    private func firstView(in view: UIView, where matches: (UIView) -> Bool) -> UIView? {
        if matches(view) { return view }
        for subview in view.subviews {
            if let match = firstView(in: subview, where: matches) { return match }
        }
        return nil
    }

    private func viewIdentifiers(in view: UIView) -> [String] {
        let own = view.accessibilityIdentifier.map { [$0] } ?? []
        return own + view.subviews.flatMap { viewIdentifiers(in: $0) }
    }

    private func buttonIdentifiers(in view: UIView) -> [String] {
        let own = (view as? UIButton)?.accessibilityIdentifier.map { [$0] } ?? []
        return own + view.subviews.flatMap { buttonIdentifiers(in: $0) }
    }
}
