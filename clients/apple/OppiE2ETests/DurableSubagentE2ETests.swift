import XCTest

/// Durable subagents on the scripted faux model (`server/src/e2e-faux-provider.ts`): the parent
/// spawns a background child whose task runs a ticking `bash`, then answers with the streamed
/// faux reply, so the child stays busy for about twenty seconds.
///
/// Run with `e2e.sh --native --durable --faux-model`; skipped otherwise.
@MainActor
final class DurableSubagentE2ETests: E2ETestCase {
    private static let liveAssistantPrefix = "chat.timeline.assistant.pi.live-"
    private static let replyStart = "Durable faux reply to"
    private static let activityRowPrefix = "extension.native.activity.row."
    private static let childTailPrefix = "chat.timeline.childTail."
    /// Ticks once a second for fourteen seconds, inside bash's fifteen-second foreground window.
    private static let childTask = "faux:bash for i in $(seq 1 14); do echo tick $i; sleep 1; done"

    override var e2eAutoCreatesSessionOnLaunch: Bool { false }

    func testOpeningChildFromPillStreamsItLive() throws {
        guard E2ELabServerContext.durableSessions else {
            throw XCTSkip("Needs e2e.sh --native --durable --faux-model")
        }

        createSession()
        waitForWebSocketConnected()
        let parentId = waitForFocusedSessionId(timeout: 20)
        waitForAckedSubscription(sessionId: parentId, level: "full")
        sendMessage("faux:subagent kid \(Self.childTask)")

        // The pill lists the child once its Session is bound.
        expandNativeSurface(title: "1 subagent", timeout: 30)
        let childRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", Self.activityRowPrefix)
        ).firstMatch
        XCTAssertTrue(childRow.waitForExistence(timeout: 15), "The pill did not list the child")
        let childId = String(childRow.identifier.dropFirst(Self.activityRowPrefix.count))
        try saveLabScreenshot(name: "durable-subagent-pill")

        tap(childRow, named: "child row in the subagent pill")
        XCTAssertEqual(waitForFocusedSessionId(childId, timeout: 20), childId, "The child did not open")
        waitForAckedSubscription(sessionId: childId, level: "full")

        // Still busy when opened: its bash output keeps arriving, then its reply streams live.
        let timeline = app.collectionViews["chat.timeline"]
        XCTAssertTrue(
            timelineShows(timeline, "faux:bash", timeout: 15),
            "The child's task did not show"
        )
        try saveLabScreenshot(name: "durable-subagent-child-busy")
        let liveReply = timeline.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", Self.liveAssistantPrefix)
        ).firstMatch
        XCTAssertTrue(
            waitForElementToExist(liveReply, timeout: 40),
            "The child's reply never streamed as a live row"
        )
        XCTAssertTrue(app.buttons["chat.stop"].exists, "The child was not running while its reply streamed")
        try saveLabScreenshot(name: "durable-subagent-child-streaming")
    }

    /// A background child's live tail shows in the expanded pill, not under the spawn row, and
    /// the pill picks it up again after a reconnect while the child still works.
    func testBackgroundChildLiveTailShowsInThePillAcrossAReconnect() throws {
        guard E2ELabServerContext.durableSessions else {
            throw XCTSkip("Needs e2e.sh --native --durable --faux-model")
        }

        createSession()
        waitForWebSocketConnected()
        let parentId = waitForFocusedSessionId(timeout: 20)
        waitForAckedSubscription(sessionId: parentId, level: "full")
        sendMessage("faux:subagent kid \(Self.childTask)")

        expandNativeSurface(title: "1 subagent", timeout: 30)
        let childRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", Self.activityRowPrefix)
        ).firstMatch
        XCTAssertTrue(childRow.waitForExistence(timeout: 15), "The pill did not list the child")
        XCTAssertTrue(
            waitForValue(of: childRow, containing: "$ for i in", timeout: 20),
            "The pill row did not show the child's running bash call: \(elementValue(childRow))"
        )
        // The spawn call returned, so nothing hangs under its row.
        let timeline = app.collectionViews["chat.timeline"]
        let tail = timeline.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", Self.childTailPrefix)
        ).firstMatch
        XCTAssertFalse(tail.exists, "A background child's tail showed under its spawn row")
        try saveLabScreenshot(name: "durable-subagent-tail-pill")

        // The parent's own turn ends while the child still works; an idle app closes its
        // socket on background, and foreground opens a new one.
        waitForTurnToEnd(timeout: 40)
        _ = try backgroundAndActivate(after: e2eLifecycleSnapshot(), scenario: "durable_subagent_busy", cycle: 1)
        waitForWebSocketConnected()
        XCTAssertEqual(waitForFocusedSessionId(parentId), parentId)
        waitForAckedSubscription(sessionId: parentId, level: "full")

        // The child's answer streams after its bash call: the pill follows it on the new socket.
        expandNativeSurface(title: "1 subagent", timeout: 15)
        XCTAssertTrue(
            waitForValue(of: childRow, containing: Self.replyStart, timeout: 40),
            "The pill row did not show the child's streaming answer after the reconnect: \(elementValue(childRow))"
        )
        try saveLabScreenshot(name: "durable-subagent-tail-pill-after-reconnect")
    }

    /// A child the parent waits on shows its live tail under the running spawn row, and tapping
    /// the tail opens the child.
    func testForegroundChildLiveTailShowsUnderItsToolRowAndOpensTheChild() throws {
        guard E2ELabServerContext.durableSessions else {
            throw XCTSkip("Needs e2e.sh --native --durable --faux-model")
        }

        createSession()
        waitForWebSocketConnected()
        let parentId = waitForFocusedSessionId(timeout: 20)
        waitForAckedSubscription(sessionId: parentId, level: "full")
        sendMessage("faux:subagent-wait kid \(Self.childTask)")

        let timeline = app.collectionViews["chat.timeline"]
        let tail = timeline.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", Self.childTailPrefix)
        ).firstMatch
        XCTAssertTrue(waitForElementToExist(tail, timeout: 30), "No live tail under the waiting spawn row")
        XCTAssertTrue(
            waitForValue(of: tail, containing: "$ for i in", timeout: 20),
            "The tail did not show the child's running bash call: \(elementValue(tail))"
        )
        try saveLabScreenshot(name: "durable-subagent-tail-foreground")

        tap(tail, named: "foreground child live tail")
        let childId = waitForFocusedSessionId(excluding: parentId, timeout: 20)
        XCTAssertNotEqual(childId, parentId, "Tapping the tail did not open the child")
        waitForAckedSubscription(sessionId: childId, level: "full")
        XCTAssertTrue(
            timelineShows(timeline, "faux:bash", timeout: 15),
            "The opened session is not the child running the task"
        )
        try saveLabScreenshot(name: "durable-subagent-foreground-child-opened")
    }

    private func elementValue(_ element: XCUIElement) -> String {
        element.exists ? (element.value as? String) ?? "" : ""
    }

    private func waitForValue(of element: XCUIElement, containing text: String, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) { self.elementValue(element).contains(text) }
    }

    private func waitForCondition(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    private func waitForTurnToEnd(timeout: TimeInterval) {
        let stopped = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.buttons["chat.stop"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: timeout), .completed, "The parent's turn did not end")
    }

    private func timelineShows(_ timeline: XCUIElement, _ text: String, timeout: TimeInterval) -> Bool {
        let match = timeline.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        ).firstMatch
        return waitForElementToExist(match, timeout: timeout)
    }

    private func expandNativeSurface(title: String, timeout: TimeInterval) {
        let collapse = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Collapse \(title) surface")
        ).firstMatch
        if collapse.waitForExistence(timeout: 0.5) { return }
        let expand = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Expand \(title) surface")
        ).firstMatch
        XCTAssertTrue(expand.waitForExistence(timeout: timeout), "The \(title) surface did not appear")
        tap(expand, named: "\(title) surface expand toggle", timeout: timeout)
        XCTAssertTrue(collapse.waitForExistence(timeout: timeout), "The \(title) surface did not expand")
    }
}
