import XCTest

/// A durable session's reply over the conversation stream replica, on the scripted faux
/// model (`server/src/e2e-faux-provider.ts`). The faux reply streams for several seconds,
/// so the live row is observable before the reply lands.
///
/// Run with `e2e.sh --native --durable --faux-model`; skipped otherwise.
@MainActor
final class DurableSessionE2ETests: E2ETestCase {
    /// Live rows are `pi.live-*` timeline items. A landing writes the committed answer into
    /// the live row and keeps its id, so the landed reply is the same cell.
    private static let assistantPrefix = "chat.timeline.assistant."
    private static let liveAssistantPrefix = "chat.timeline.assistant.pi.live-"
    private static let replyStart = "Durable faux reply to"
    private static let replyEnd = "End of faux reply."

    /// The auto-created launch session is classic; this test creates its own durable one.
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }

    func testDurableReplyStreamsLiveThenLandsOnceAcrossReconnect() throws {
        guard E2ELabServerContext.durableSessions else {
            throw XCTSkip("Needs e2e.sh --native --durable --faux-model")
        }

        createSession()
        waitForWebSocketConnected()
        let sessionId = waitForFocusedSessionId(timeout: 20)
        waitForAckedSubscription(sessionId: sessionId, level: "full")

        let marker = "E2E_DURABLE_\(UUID().uuidString.prefix(8))"
        sendMessage(marker)

        let timeline = app.collectionViews["chat.timeline"]
        let assistantRows = timeline.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", Self.assistantPrefix)
        )
        let liveRow = timeline.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", Self.liveAssistantPrefix)
        ).firstMatch

        // Streaming: a live row shows the start of the reply while the turn is still running.
        XCTAssertTrue(
            waitForElementToExist(liveRow, timeout: 30),
            "No live pi.live assistant row appeared while the faux reply streamed"
        )
        XCTAssertTrue(
            rowShowsText(liveRow, Self.replyStart, timeout: 10),
            "The live row did not show the streaming faux reply"
        )
        XCTAssertTrue(app.buttons["chat.stop"].exists, "The turn was not running while the reply streamed")
        let liveIdentifier = liveRow.identifier

        // Landing: the turn ends and the same row holds the whole committed reply.
        waitForTurnToEnd(after: "the reply streamed")
        assertLandedOnce(assistantRows: assistantRows, marker: marker, after: "the reply landed")
        XCTAssertEqual(
            assistantRows.firstMatch.identifier, liveIdentifier,
            "The landed reply replaced the live row instead of updating it"
        )

        // An idle app closes its focused session socket (goingAway) on background; foreground
        // opens a new one and the replica re-attaches from its cursor. A busy app keeps the
        // socket for the background keep-alive window, so this cycle runs after landing.
        _ = try backgroundAndActivate(after: e2eLifecycleSnapshot(), scenario: "durable_landed", cycle: 1)
        waitForWebSocketConnected()
        XCTAssertEqual(waitForFocusedSessionId(sessionId), sessionId)
        waitForAckedSubscription(sessionId: sessionId, level: "full")

        assertLandedOnce(assistantRows: assistantRows, marker: marker, after: "a reconnect of the idle conversation")
    }

    private func waitForTurnToEnd(after moment: String, file: StaticString = #filePath, line: UInt = #line) {
        let stopped = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.buttons["chat.stop"]
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [stopped], timeout: 60), .completed,
            "The turn did not end after \(moment)", file: file, line: line
        )
    }

    private func assertLandedOnce(
        assistantRows: XCUIElementQuery,
        marker: String,
        after moment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reply = assistantRows.firstMatch
        XCTAssertTrue(
            rowShowsText(reply, marker, timeout: 15) && rowShowsText(reply, Self.replyEnd, timeout: 10),
            "The reply row did not show the full faux reply after \(moment)", file: file, line: line
        )
        XCTAssertEqual(assistantRows.count, 1, "Expected exactly one assistant row after \(moment)", file: file, line: line)
        let userRows = app.collectionViews["chat.timeline"].descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.timeline.user."))
        XCTAssertEqual(userRows.count, 1, "Expected exactly one user prompt row after \(moment)", file: file, line: line)
    }

    private func rowShowsText(_ row: XCUIElement, _ text: String, timeout: TimeInterval) -> Bool {
        let match = row.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        ).firstMatch
        return waitForElementToExist(match, timeout: timeout)
    }
}
