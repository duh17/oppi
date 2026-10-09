import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Extension notify chip")
struct ExtensionNotifyChipStoreTests {
    @Test func notifyDoesNotSetExtensionToast() {
        let (conn, pipe) = makeTestConnection()
        pipe.handle(notifyMessage(message: "Task complete", notifyType: "info"), sessionId: "s1")

        #expect(conn.extensionToast == nil)
        #expect(conn.extensionNotifyChipStore.state(for: "s1")?.newest.message == "Task complete")
        #expect(conn.extensionNotifyChipStore.state(for: "s1")?.newest.extensionDisplayName == "Extension")
        #expect(conn.extensionNotifyChipStore.state(for: "s1")?.newest.notifyType == "info")
        conn.extensionNotifyChipStore.dismiss(sessionId: "s1")
    }

    @Test func unknownMethodFeedsTheChipNotTheSheet() {
        let (conn, pipe) = makeTestConnection()
        pipe.handle(
            notifyMessage(
                method: "future_method",
                message: "Heads up",
                notifyType: "warning",
                displayName: "Review Helper"
            ),
            sessionId: "s1"
        )

        #expect(conn.extensionToast == nil)
        let state = conn.extensionNotifyChipStore.state(for: "s1")
        #expect(state?.newest.message == "Heads up")
        #expect(state?.newest.extensionDisplayName == "Review Helper")
        conn.extensionNotifyChipStore.dismiss(sessionId: "s1")
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

    @Test func emptyMessageIsIgnored() {
        let store = ExtensionNotifyChipStore(clock: hangingClock())
        store.apply(message: "   ", notifyType: "info", displayName: "Ext", sessionId: "s1")
        store.apply(message: nil, notifyType: "info", displayName: "Ext", sessionId: "s1")
        #expect(store.state(for: "s1") == nil)
    }
}

@MainActor
private func notifyMessage(
    method: String = "notify",
    message: String?,
    notifyType: String?,
    displayName: String? = nil
) -> ServerMessage {
    .extensionUINotification(
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
