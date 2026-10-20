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

    /// The parent shows the busy child's live tail under the spawn row and its activity in the
    /// pill, and picks the tail up again after a reconnect while the child still works.
    func testChildLiveTailShowsUnderItsToolRowAndInThePillAcrossAReconnect() throws {
        guard E2ELabServerContext.durableSessions else {
            throw XCTSkip("Needs e2e.sh --native --durable --faux-model")
        }

        createSession()
        waitForWebSocketConnected()
        let parentId = waitForFocusedSessionId(timeout: 20)
        waitForAckedSubscription(sessionId: parentId, level: "full")
        sendMessage("faux:subagent kid \(Self.childTask)")

        let timeline = app.collectionViews["chat.timeline"]
        let tail = timeline.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", Self.childTailPrefix)
        ).firstMatch
        XCTAssertTrue(waitForElementToExist(tail, timeout: 30), "No live tail under the subagent row")
        XCTAssertTrue(
            waitForValue(of: tail, containing: "$ for i in", timeout: 20),
            "The tail did not show the child's running bash call: \(tailValue(tail))"
        )
        try saveLabScreenshot(name: "durable-subagent-tail")

        expandNativeSurface(title: "1 subagent", timeout: 15)
        let activity = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Running bash", "Running bash")
        ).firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 10), "The pill row did not show the child's running tool")
        try saveLabScreenshot(name: "durable-subagent-tail-pill")

        // The parent's own turn ends while the child still works; an idle app closes its
        // socket on background, and foreground opens a new one.
        waitForTurnToEnd(timeout: 40)
        XCTAssertTrue(tail.exists, "The child finished before the reconnect; the scenario needs it busy")
        _ = try backgroundAndActivate(after: e2eLifecycleSnapshot(), scenario: "durable_subagent_busy", cycle: 1)
        waitForWebSocketConnected()
        XCTAssertEqual(waitForFocusedSessionId(parentId), parentId)
        waitForAckedSubscription(sessionId: parentId, level: "full")

        // The child's answer streams after its bash call: the tail follows it on the new socket.
        XCTAssertTrue(waitForElementToExist(tail, timeout: 20), "The tail did not come back after the reconnect")
        XCTAssertTrue(
            waitForValue(of: tail, containing: Self.replyStart, timeout: 40),
            "The tail did not show the child's streaming answer after the reconnect: \(tailValue(tail))"
        )
        try saveLabScreenshot(name: "durable-subagent-tail-after-reconnect")

        // Idle: the tail goes away.
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: tail)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 60), .completed, "The tail stayed after the child finished")
    }

    private func tailValue(_ tail: XCUIElement) -> String {
        tail.exists ? (tail.value as? String) ?? "" : ""
    }

    private func waitForValue(of element: XCUIElement, containing text: String, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) { self.tailValue(element).contains(text) }
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
