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
    /// Ticks once a second for twelve seconds, inside bash's fifteen-second foreground window.
    private static let childTask = "faux:bash for i in $(seq 1 12); do echo tick $i; sleep 1; done"

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
