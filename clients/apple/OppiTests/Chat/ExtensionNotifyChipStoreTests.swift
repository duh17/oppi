import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Extension notify chip")
struct ExtensionNotifyChipStoreTests {
    @Test func unknownMethodFeedsTheChipNotTheSheet() {
        let (conn, _) = makeTestConnection()
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
        #expect(state?.newest.extensionDisplayName == "Review Helper")
        conn.extensionNotifyChipStore.dismiss(sessionId: "s1")
    }

    @Test(arguments: ["notify", "future_method"])
    func sessionStreamNotifyDoesNotInsertChip(method: String) {
        let (conn, pipe) = makeTestConnection()
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

    @Test func focusedAppEventInsertsOneChip() {
        let (conn, _) = makeTestConnection()
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
    func sessionStreamAndAppEventInsertOneChip(method: String) {
        let (conn, pipe) = makeTestConnection()
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

    @Test func backgroundSessionAppEventInsertsOneChip() {
        let (conn, _) = makeTestConnection(sessionId: "s1")
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
        let store = ExtensionNotifyChipStore(clock: hangingClock())
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
        let store = ExtensionNotifyChipStore(clock: hangingClock())
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
            clock: ExtensionNotifyClock(
                now: { ContinuousClock().now },
                sleep: { duration in
                    #expect(duration == ExtensionNotifyChipStore.autoDismissDuration)
                }
            )
        )
        store.apply(message: "gone soon", notifyType: "info", displayName: "Ext", sessionId: "s1")
        try await waitUntil { store.state(for: "s1") == nil }
    }

    @Test func newerNotifyResetsTheTimer() async throws {
        var sleepDurations: [Duration] = []
        let store = ExtensionNotifyChipStore(
            clock: ExtensionNotifyClock(
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
            ExtensionNotifyChipStore.autoDismissDuration,
            ExtensionNotifyChipStore.autoDismissDuration,
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
            clock: ExtensionNotifyClock(
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
            clock: ExtensionNotifyClock(
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

    @Test func clearingExtensionSurfaceLeavesChip() {
        let (conn, _) = makeTestConnection()
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

    @Test func stopConfirmedLeavesChip() {
        let (conn, _) = makeTestConnection()
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

    @Test func sessionEndedRemovesChip() {
        let (conn, _) = makeTestConnection()
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
        let store = ExtensionNotifyChipStore(clock: hangingClock())
        store.apply(message: "   ", notifyType: "info", displayName: "Ext", sessionId: "s1")
        store.apply(message: nil, notifyType: "info", displayName: "Ext", sessionId: "s1")
        #expect(store.state(for: "s1") == nil)
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

@Suite("Extension notify chip chrome")
struct ExtensionNotifyChipChromeTests {
    @Test("Collapsed notify uses the glassy strip pill surface")
    func collapsedNotifyUsesGlassyStripPillSurface() throws {
        let source = try notifyChipSource()
        let pill = try notifyChipSourceSlice(
            named: "struct ExtensionNotifyChip: View {",
            until: "struct ExtensionNotifyDrawer: View {",
            in: source
        )
        #expect(pill.contains(".extensionStripPillSurface("))
        #expect(pill.contains("state.isExpanded ? \"chevron.down\" : \"chevron.right\""))
        #expect(pill.contains("chat.extensionNotify.chip"))
        #expect(!pill.contains("Spacer(minLength: 0)"))
        #expect(!pill.contains(".background(.themeFg.opacity(0.08), in: Capsule())"))
        #expect(!pill.contains(".padding(.vertical, 5)"))
    }

    @Test("Expanded notify uses the glass drawer panel")
    func expandedNotifyUsesGlassDrawerPanel() throws {
        let source = try notifyChipSource()
        let drawer = try notifyChipSourceSlice(
            named: "struct ExtensionNotifyDrawer: View {",
            until: "private enum ExtensionNotifyChipChrome",
            in: source
        )
        #expect(drawer.contains(".extensionGlassPanel(cornerRadius: 18)"))
        #expect(drawer.contains("chat.extensionNotify.expanded"))
        #expect(drawer.contains("chat.extensionNotify.dismiss"))
        #expect(drawer.contains("chat.extensionNotify.list"))
        #expect(!drawer.contains(".background(\n            .themeFg.opacity(0.06)"))
        #expect(!drawer.contains("cornerRadius: 14"))
    }
}

private func notifyChipSource() throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Oppi/Features/Chat/Support/ExtensionNotifyChip.swift")
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

private func notifyChipSourceSlice(
    named marker: String,
    until endMarker: String,
    in source: String
) throws -> String {
    guard let start = source.range(of: marker) else {
        Issue.record("Missing source marker \(marker)")
        throw NotifyChipSourceSliceError.missingMarker(marker)
    }
    guard let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else {
        Issue.record("Missing source end marker \(endMarker)")
        throw NotifyChipSourceSliceError.missingMarker(endMarker)
    }
    return String(source[start.lowerBound..<end.lowerBound])
}

private enum NotifyChipSourceSliceError: Error {
    case missingMarker(String)
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
private func hangingClock() -> ExtensionNotifyClock {
    ExtensionNotifyClock(
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
