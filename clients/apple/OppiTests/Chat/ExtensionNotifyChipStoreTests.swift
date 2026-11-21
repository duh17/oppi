import Foundation
import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Extension notify chip")
struct ExtensionNotifyChipStoreTests {
    @Test func unknownMethodFeedsTheChipNotTheSheet() async {
        let (conn, _) = await makeTestConnection()
        conn.handleAppEvent(
            .extensionUINotification(
                notification: notifyNotification(
                    method: "future_method",
                    message: "Heads up",
                    notifyType: "warning",
                    displayName: "Review Helper"
                ),
                sessionId: "s1",
                workspaceId: nil,
                emittedAt: 0
            )
        )

        #expect(conn.extensionToast == nil)
        let state = conn.extensionNotifyChipStore.state(for: "s1")
        #expect(state?.newest.message == "Heads up")
        #expect(state?.newest.title == "Review Helper")
        #expect(state?.newest.source == .extensionNotify(name: "Review Helper"))
        conn.extensionNotifyChipStore.dismiss(sessionId: "s1")
    }

    @Test(arguments: ["notify", "future_method"])
    func sessionStreamNotifyDoesNotInsertChip(method: String) async {
        let (conn, pipe) = await makeTestConnection()
        pipe.handle(
            .extensionUINotification(
                notifyNotification(
                    method: method,
                    message: "Task complete",
                    notifyType: "info",
                    displayName: "Web Search"
                )
            ),
            sessionId: "s1"
        )

        #expect(conn.extensionToast == nil)
        #expect(conn.extensionNotifyChipStore.state(for: "s1") == nil)
    }

    @Test func focusedAppEventInsertsOneChip() async {
        let (conn, _) = await makeTestConnection()
        conn.handleAppEvent(
            .extensionUINotification(
                notification: notifyNotification(
                    message: "Task complete",
                    notifyType: "info",
                    displayName: "Web Search"
                ),
                sessionId: "s1",
                workspaceId: nil,
                emittedAt: 0
            )
        )

        #expect(conn.extensionToast == nil)
        #expect(conn.extensionNotifyChipStore.state(for: "s1")?.count == 1)
        #expect(conn.extensionNotifyChipStore.state(for: "s1")?.newest.message == "Task complete")
        conn.extensionNotifyChipStore.dismiss(sessionId: "s1")
    }

    @Test(arguments: ["notify", "future_method"])
    func sessionStreamAndAppEventInsertOneChip(method: String) async {
        let (conn, pipe) = await makeTestConnection()
        let notification = notifyNotification(
            method: method,
            message: "Task complete",
            notifyType: "info",
            displayName: "Web Search"
        )
        pipe.handle(.extensionUINotification(notification), sessionId: "s1")
        conn.handleAppEvent(
            .extensionUINotification(
                notification: notification,
                sessionId: "s1",
                workspaceId: nil,
                emittedAt: 0
            )
        )

        #expect(conn.extensionToast == nil)
        #expect(conn.extensionNotifyChipStore.state(for: "s1")?.count == 1)
        #expect(conn.extensionNotifyChipStore.state(for: "s1")?.newest.message == "Task complete")
        conn.extensionNotifyChipStore.dismiss(sessionId: "s1")
    }

    /// Surfaces belong to the session stream. An older server still copies
    /// them onto the app stream; applying those would redraw every chat for
    /// any session's per-second working text.
    @Test func appEventWorkingMessageChangesNothing() async {
        let (conn, _) = await makeTestConnection(sessionId: "s1")
        conn.handleAppEvent(
            .extensionUINotification(
                notification: notifyNotification(method: "setWorkingMessage", message: "Busy \u{00B7} 3s", notifyType: nil),
                sessionId: "s1",
                workspaceId: nil,
                emittedAt: 0
            )
        )

        #expect(conn.extensionSurfaces.state(for: "s1") == nil)
        #expect(conn.extensionNotifyChipStore.state(for: "s1") == nil)
    }

    @Test func backgroundSessionAppEventInsertsOneChip() async {
        let (conn, _) = await makeTestConnection(sessionId: "s1")
        conn.handleAppEvent(
            .extensionUINotification(
                notification: notifyNotification(
                    message: "Background ping",
                    notifyType: "info",
                    displayName: "Web Search"
                ),
                sessionId: "s2",
                workspaceId: nil,
                emittedAt: 0
            )
        )

        #expect(conn.extensionNotifyChipStore.state(for: "s2")?.count == 1)
        #expect(conn.extensionNotifyChipStore.state(for: "s2")?.newest.message == "Background ping")
        #expect(conn.extensionNotifyChipStore.state(for: "s1") == nil)
        conn.extensionNotifyChipStore.dismiss(sessionId: "s2")
    }

    @Test func sessionsDoNotLeakChipState() {
        let store = ExtensionNotifyChipStore(environment: hangingClock())
        store.apply(message: "A", notifyType: "info", displayName: "One", sessionId: "s1")
        store.apply(message: "B", notifyType: "error", displayName: "Two", sessionId: "s2")

        #expect(store.state(for: "s1")?.newest.message == "A")
        #expect(store.state(for: "s2")?.newest.message == "B")
        store.dismiss(sessionId: "s1")
        #expect(store.state(for: "s1") == nil)
        #expect(store.state(for: "s2")?.newest.message == "B")
        store.dismiss(sessionId: "s2")
    }

    @Test func keepsNewestFirstAndCapsAtFive() {
        let store = ExtensionNotifyChipStore(environment: hangingClock())
        for index in 1...6 {
            store.apply(
                message: "m\(index)",
                notifyType: "info",
                displayName: "Ext",
                sessionId: "s1"
            )
        }

        let messages = store.state(for: "s1")?.entries.map(\.message)
        #expect(messages == ["m6", "m5", "m4", "m3", "m2"])
        #expect(store.state(for: "s1")?.count == 5)
        store.dismiss(sessionId: "s1")
    }

    @Test func autoDismissClearsTheSession() async throws {
        let store = ExtensionNotifyChipStore(
            environment: NoticeTimerEnvironment(
                now: { ContinuousClock().now },
                sleep: { duration in
                    #expect(duration == NoticeDismiss.duration)
                }
            )
        )
        store.apply(message: "gone soon", notifyType: "info", displayName: "Ext", sessionId: "s1")
        try await waitUntil { store.state(for: "s1") == nil }
    }

    @Test func newerNotifyResetsTheTimer() async throws {
        var sleepDurations: [Duration] = []
        let store = ExtensionNotifyChipStore(
            environment: NoticeTimerEnvironment(
                now: { ContinuousClock().now },
                sleep: { duration in
                    sleepDurations.append(duration)
                    try await Task.sleep(for: .seconds(3_600))
                }
            )
        )
        store.apply(message: "first", notifyType: "info", displayName: "Ext", sessionId: "s1")
        try await waitUntil { sleepDurations.count == 1 }
        store.apply(message: "second", notifyType: "info", displayName: "Ext", sessionId: "s1")

        try await waitUntil { sleepDurations.count == 2 }
        #expect(sleepDurations == [
            NoticeDismiss.duration,
            NoticeDismiss.duration,
        ])
        #expect(store.state(for: "s1")?.newest.message == "second")
        #expect(store.state(for: "s1")?.count == 2)
        store.dismiss(sessionId: "s1")
    }

    @Test func expandPausesTimerAndCollapseResumesRemaining() async throws {
        let origin = ContinuousClock().now
        var offset: Duration = .zero
        var sleepDurations: [Duration] = []
        let store = ExtensionNotifyChipStore(
            environment: NoticeTimerEnvironment(
                now: { origin + offset },
                sleep: { duration in
                    sleepDurations.append(duration)
                    try await Task.sleep(for: .seconds(3_600))
                }
            )
        )
        store.apply(message: "hold", notifyType: "warning", displayName: "Ext", sessionId: "s1")
        try await waitUntil { sleepDurations.count == 1 }

        offset = .seconds(2)
        store.setExpanded(true, sessionId: "s1")
        #expect(store.state(for: "s1")?.isExpanded == true)

        store.setExpanded(false, sessionId: "s1")
        try await waitUntil { sleepDurations.count == 2 }
        #expect(sleepDurations.last == .seconds(4))
        store.dismiss(sessionId: "s1")
    }

    @Test func hidingExpandedSessionRearmsAutoDismiss() async throws {
        var sleepDurations: [Duration] = []
        let store = ExtensionNotifyChipStore(
            environment: NoticeTimerEnvironment(
                now: { ContinuousClock().now },
                sleep: { duration in
                    sleepDurations.append(duration)
                    try await Task.sleep(for: .seconds(3_600))
                }
            )
        )
        store.apply(message: "hold", notifyType: "info", displayName: "Ext", sessionId: "s1")
        try await waitUntil { sleepDurations.count == 1 }
        store.setExpanded(true, sessionId: "s1")
        #expect(store.state(for: "s1")?.isExpanded == true)

        store.collapseForHiddenChat(sessionId: "s1")
        try await waitUntil { sleepDurations.count == 2 }
        #expect(store.state(for: "s1")?.isExpanded == false)
        store.dismiss(sessionId: "s1")
    }

    @Test func clearingExtensionSurfaceLeavesChip() async {
        let (conn, _) = await makeTestConnection()
        conn.handleAppEvent(
            .extensionUINotification(
                notification: notifyNotification(message: "Task complete", notifyType: "info"),
                sessionId: "s1",
                workspaceId: nil,
                emittedAt: 0
            )
        )
        conn.extensionNotifyChipStore.setExpanded(true, sessionId: "s1")
        #expect(conn.extensionNotifyChipStore.state(for: "s1")?.isExpanded == true)

        conn.clearExtensionSurface(for: "s1")
        #expect(conn.extensionNotifyChipStore.state(for: "s1")?.newest.message == "Task complete")
        conn.extensionNotifyChipStore.dismiss(sessionId: "s1")
    }

    @Test func stopConfirmedLeavesChip() async {
        let (conn, _) = await makeTestConnection()
        conn.handleAppEvent(
            .extensionUINotification(
                notification: notifyNotification(message: "Task complete", notifyType: "info"),
                sessionId: "s1",
                workspaceId: nil,
                emittedAt: 0
            )
        )

        conn.handleAppEvent(
            .stopConfirmed(
                sessionId: "s1",
                workspaceId: nil,
                emittedAt: 1,
                source: "user",
                reason: nil
            )
        )

        #expect(conn.extensionNotifyChipStore.state(for: "s1")?.newest.message == "Task complete")
        conn.extensionNotifyChipStore.dismiss(sessionId: "s1")
    }

    @Test func sessionEndedRemovesChip() async {
        let (conn, _) = await makeTestConnection()
        conn.handleAppEvent(
            .extensionUINotification(
                notification: notifyNotification(message: "Task complete", notifyType: "info"),
                sessionId: "s1",
                workspaceId: nil,
                emittedAt: 0
            )
        )

        conn.handleAppEvent(
            .sessionEnded(
                sessionId: "s1",
                workspaceId: nil,
                emittedAt: 1,
                reason: "done"
            )
        )

        #expect(conn.extensionNotifyChipStore.state(for: "s1") == nil)
    }

    @Test func emptyMessageIsIgnored() {
        let store = ExtensionNotifyChipStore(environment: hangingClock())
        store.apply(message: "   ", notifyType: "info", displayName: "Ext", sessionId: "s1")
        store.apply(message: nil, notifyType: "info", displayName: "Ext", sessionId: "s1")
        #expect(store.state(for: "s1") == nil)
    }

    // MARK: - Session launch warnings

    /// A launch's warnings are one notice from the session itself: trimmed, deduped, and titled
    /// by its source, never by the server's text.
    @Test func warningsBecomeOneSessionNotice() {
        let store = ExtensionNotifyChipStore(environment: hangingClock())
        store.applyWarnings(
            ["  Routes warning one.  ", "", "Routes warning one.", "Routes warning two."],
            sessionId: "s1"
        )

        let state = testUnwrap(store.state(for: "s1"))
        #expect(state.count == 1, "a launch's warnings are one notice, however many the server lists")
        #expect(state.newest.source == .session)
        #expect(state.newest.notifyType == "warning")
        #expect(state.newest.title == "Warning")
        #expect(state.newest.originLabel == "From this session")
        #expect(state.newest.message == "Routes warning one.\n\nRoutes warning two.")
        #expect(ExtensionNotifyChipStore.messages(from: nil).isEmpty)
        #expect(ExtensionNotifyChipStore.messages(from: ["", "  "]).isEmpty)
        #expect(ExtensionNotifyChipStore.messages(from: ["alpha", "beta"]) == ["alpha", "beta"])
        store.dismiss(sessionId: "s1")
    }

    @Test func warningsShowOncePerSession() {
        let store = ExtensionNotifyChipStore(environment: hangingClock())
        store.applyWarnings(["Routes warning."], sessionId: "s1")
        #expect(store.state(for: "s1")?.count == 1)
        store.dismiss(sessionId: "s1")

        // A repaint, a chat re-entry, or the person's own dismiss must not bring it back.
        store.applyWarnings(["Routes warning."], sessionId: "s1")
        #expect(store.state(for: "s1") == nil)

        store.applyWarnings(["Routes warning two."], sessionId: "s1")
        #expect(store.state(for: "s1")?.newest.message == "Routes warning two.", "a new launch's warning shows")
        store.dismiss(sessionId: "s1")
    }

    @Test func warningsFollowTheNoticePolicy() async throws {
        var durations: [Duration] = []
        let store = ExtensionNotifyChipStore(environment: NoticeTimerEnvironment(
            sleep: { duration in durations.append(duration) }
        ))
        let warning = "Configured Agent tools are unavailable and was dropped from this session: mcp__a, mcp__b."
        store.applyWarnings([warning], sessionId: "s1")

        try await waitUntil { store.state(for: "s1") == nil }
        #expect(
            durations == [NoticeDismiss.duration(forMessage: warning)],
            "a session warning times out on the extension notice's policy: \(durations)"
        )
    }

    /// The reported bug, in a window: the launch warning was a banner above the composer that
    /// held its whole text forever. It is the strip's notice now: a compact pill with the short
    /// title, the text in the drawer a tap opens, and the notice timer removes it on its own.
    @Test func launchWarningRidesTheNoticePillInAWindow() async throws {
        let sessionId = "launch-warning-\(UUID().uuidString)"
        let (connection, _) = await makeTestConnection(sessionId: sessionId)
        var session = makeTestSession(id: sessionId, status: .ready)
        session.warnings = [Self.longLaunchWarning]
        connection.sessionStore.upsert(session)
        let chat = ChatViewController(sessionId: sessionId, connection: connection, navigation: SceneNavigation())
        chat.sessionManager._loadHistoryForTesting = { _, _ in nil }
        let window = makeSceneWindow()
        window.traitOverrides.appRootEnvironment = makeTestAppRoot()
        window.rootViewController = chat
        window.makeKeyAndVisible()
        defer {
            window.rootViewController = UIViewController()
            window.isHidden = true
            chat.sessionManager.cleanup()
            connection.disconnectStream()
        }

        let appeared = await waitForMainActorCondition(timeout: .seconds(3)) {
            chat.view.layoutIfNeeded()
            return Self.control("chat.extensionNotify.chip", in: chat.view) != nil
        }
        #expect(appeared, "the launch warning shows on the strip")
        let pill = testUnwrap(Self.control("chat.extensionNotify.chip", in: chat.view) as? UIControl)
        let label = pill.accessibilityLabel ?? "nil"
        #expect(label.hasPrefix("Session warning: "), "the pill says what it is: \(label)")
        #expect(
            pill.bounds.height <= ExtensionStripPillMetrics.hitHeight,
            "collapsed, the warning draws as a strip pill, not a banner: \(pill.frame)"
        )
        #expect(
            !Self.subviews(of: UILabel.self, in: chat.view).contains { $0.text?.contains("mcp__gmail__account") == true },
            "the full text stays off the chat until the drawer opens"
        )
        #expect(!Self.shown("chat.extensionNotify.expanded", in: chat.view), "the drawer waits for a tap")

        pill.sendActions(for: .touchUpInside)
        let opened = await waitForMainActorCondition(timeout: .seconds(2)) {
            chat.view.layoutIfNeeded()
            return Self.shown("chat.extensionNotify.expanded", in: chat.view)
                && Self.subviews(of: UITextView.self, in: chat.view)
                    .contains { $0.text?.contains("mcp__gmail__account") == true }
        }
        #expect(opened, "a tap shows the server's full text in the drawer")

        // Collapsing resumes the notice timer, which was held while the drawer was open.
        pill.sendActions(for: .touchUpInside)
        #expect(connection.extensionNotifyChipStore.state(for: sessionId)?.isExpanded == false)
        let dismissed = await waitForMainActorCondition(timeout: .seconds(20)) {
            connection.extensionNotifyChipStore.state(for: sessionId) == nil
        }
        #expect(dismissed, "the notice policy removes the launch warning without a tap")
    }

    /// The warning a classic Agent launch writes when the server drops the MCP tools its
    /// allowlist named: the report's long text.
    private static let longLaunchWarning =
        "Configured Agent tools are unavailable and was dropped from this session: "
        + ["mcp__gmail__account", "mcp__gmail__search", "mcp__gmail__read", "mcp__gmail__thread",
           "mcp__gmail__labels", "mcp__gmail__save_attachments", "mcp__gmail__modify",
           "mcp__gmail__archive", "mcp__gmail__trash", "mcp__gmail__spam", "mcp__gmail__draft",
           "mcp__gmail__send", "mcp__coros__queryDailyHealthData", "mcp__coros__querySleepOverview",
           "mcp__coros__queryRecoveryStatus", "mcp__coros__queryTrainingLoadAssessment",
           "mcp__coros__getActivityDetail", "mcp__coros__createScheduledWorkout"].joined(separator: ", ")
        + ". The session continues with the remaining allowed tools. Edit the Agent's Allowed "
        + "Tools or selected Extensions to stop this warning."

    private static func control(_ identifier: String, in root: UIView) -> UIView? {
        ([root] + subviews(of: UIView.self, in: root)).first { $0.accessibilityIdentifier == identifier }
    }

    /// Whether the control and every view between it and `root` are shown.
    private static func shown(_ identifier: String, in root: UIView) -> Bool {
        guard let view = control(identifier, in: root) else { return false }
        var node: UIView? = view
        while let current = node, current !== root {
            if current.isHidden { return false }
            node = current.superview
        }
        return true
    }

    private static func subviews<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        root.subviews.flatMap { child -> [T] in
            ((child as? T).map { [$0] } ?? []) + subviews(of: type, in: child)
        }
    }

    @Test func expandedMessageKeepsAllHTTPLinksAndSuffix() {
        let attributed = ExtensionNotifyChip.attributedMessage(
            "See https://example.com/one and https://example.org/two please"
        )
        let links = attributed.runs.compactMap { $0.link }.map(\.absoluteString)
        #expect(links == [
            "https://example.com/one",
            "https://example.org/two",
        ])
        #expect(String(attributed.characters).hasSuffix(" please"))
        #expect(ExtensionNotifyChip.containsHTTPLinks(attributed))
    }

    @Test func expandedMessageDoesNotLinkFileOrSessionURLs() {
        let attributed = ExtensionNotifyChip.attributedMessage(
            "file:///tmp/secret oppi://session/abc https://example.com/ok"
        )
        let links = attributed.runs.compactMap { $0.link }.map(\.absoluteString)
        #expect(links == ["https://example.com/ok"])
    }
}

@MainActor
private func notifyNotification(
    method: String = "notify",
    message: String?,
    notifyType: String?,
    displayName: String? = nil
) -> ExtensionUINotification {
    ExtensionUINotification(
        method: method,
        message: message,
        notifyType: notifyType,
        statusKey: nil,
        statusText: nil,
        title: nil,
        text: nil,
        widgetKey: nil,
        widgetLines: nil,
        widgetPlacement: nil,
        extensionDisplayName: displayName
    )
}

@MainActor
private func hangingClock() -> NoticeTimerEnvironment {
    NoticeTimerEnvironment(
        now: { ContinuousClock().now },
        sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
    )
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(1)
    while ContinuousClock.now < deadline {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Condition was not met")
    throw CancellationError()
}
