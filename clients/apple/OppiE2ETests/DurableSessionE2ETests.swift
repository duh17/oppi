import XCTest

/// A durable session over the conversation stream replica, on the scripted faux model
/// (`server/src/e2e-faux-provider.ts`). A faux reply streams for over ten seconds, so the
/// live row, the queue, and the stop button are observable before it lands. The stop button
/// and the queue read `pi.live.run` and `pi.inbox` from the replica.
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

    /// A follow-up and a steer sent while the reply streams queue from `pi.inbox`, start once
    /// it ends, and each show once. Stop then ends a later reply before it lands.
    func testDurableQueueFollowsTheInboxAndStopEndsTheRun() throws {
        guard E2ELabServerContext.durableSessions else {
            throw XCTSkip("Needs e2e.sh --native --durable --faux-model")
        }

        createSession()
        waitForWebSocketConnected()
        let sessionId = waitForFocusedSessionId(timeout: 20)
        waitForAckedSubscription(sessionId: sessionId, level: "full")
        let tag = String(UUID().uuidString.prefix(8))
        let first = "E2E_DURABLE_FIRST_\(tag)"
        let followUp = "E2E_DURABLE_FOLLOW_\(tag)"
        let steer = "E2E_DURABLE_STEER_\(tag)"

        sendMessage(first)
        XCTAssertTrue(waitForElementToExist(liveRow, timeout: 30), "No live row while the first reply streamed")
        XCTAssertTrue(waitForElementToExist(app.buttons["chat.stop"], timeout: 5), "The run did not show as busy")

        selectBusyMode("followUp")
        sendMessage(followUp)
        selectBusyMode("steer")
        sendMessage(steer)
        let queue = queuePill
        XCTAssertTrue(
            waitForValue(queue, containing: "1 steering \u{2022} 1 follow-up", timeout: 15),
            "The queue did not show the steer and the follow-up while the first reply streamed"
        )
        XCTAssertFalse(rowShowsText(assistantRow(replyingTo: first), Self.replyEnd, timeout: 0.5), "The first reply landed before both inputs queued")

        // Both start once the first reply ends; the queue empties and the run ends.
        XCTAssertTrue(waitForElementToDisappear(queue, timeout: 60), "The queue did not empty after the first reply")
        waitForTurnToEnd(after: "the queued inputs ran", timeout: 120)
        XCTAssertEqual(userRows.count, 3, "Expected the prompt and both queued inputs once each")
        XCTAssertTrue(rowShowsText(assistantRow(replyingTo: first), Self.replyEnd, timeout: 10), "The first reply did not land")
        XCTAssertEqual(assistantRows(replyingTo: first).count, 1, "The first reply showed more than once")

        // Stop mid-turn: the run ends well before the reply would have.
        let stopped = "E2E_DURABLE_STOP_\(tag)"
        sendMessage(stopped)
        XCTAssertTrue(
            rowShowsText(assistantRow(replyingTo: stopped), Self.replyStart, timeout: 30),
            "The reply to stop did not start streaming"
        )
        tap(app.buttons["chat.stop"], named: "stop button", timeout: 5)
        waitForTurnToEnd(after: "Stop", timeout: 10)
        XCTAssertFalse(
            rowShowsText(assistantRow(replyingTo: stopped), Self.replyEnd, timeout: 3),
            "The stopped reply still ran to its end"
        )
    }

    /// A dropped connection mid-turn: the app reconnects and resumes the replica from its
    /// cursor while the run goes on. It still shows the run as busy and the queued
    /// follow-up, and both replies land once.
    func testDurableReconnectWhileBusyKeepsTheRunAndQueue() throws {
        guard E2ELabServerContext.durableSessions else {
            throw XCTSkip("Needs e2e.sh --native --durable --faux-model")
        }

        createSession()
        waitForWebSocketConnected()
        let sessionId = waitForFocusedSessionId(timeout: 20)
        waitForAckedSubscription(sessionId: sessionId, level: "full")
        let tag = String(UUID().uuidString.prefix(8))
        let first = "E2E_DURABLE_BUSY_\(tag)"
        let followUp = "E2E_DURABLE_AFTER_\(tag)"

        sendMessage(first)
        XCTAssertTrue(waitForElementToExist(liveRow, timeout: 30), "No live row while the reply streamed")
        selectBusyMode("followUp")
        sendMessage(followUp)
        let queue = queuePill
        XCTAssertTrue(waitForValue(queue, containing: "0 steering \u{2022} 1 follow-up", timeout: 15), "The follow-up did not queue")

        // The route answers once the dropped sockets closed and released their subscriptions,
        // so the subscriber that follows is the app's new socket.
        XCTAssertGreaterThan(try dropE2EHarnessSessionStreams(sessionId: sessionId), 0, "No focused socket to drop")
        try waitForE2EHarnessSubscriberCount(sessionId: sessionId, 1, timeout: 20)
        waitForAckedSubscription(sessionId: sessionId, level: "full")

        // The session row now says the run settled; only the resumed replica's `pi.live.run`
        // can keep the stop button up.
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_settled"])
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertTrue(
            app.buttons["chat.stop"].waitForExistence(timeout: 5),
            "The stop button did not follow the resumed replica's run after the reconnect"
        )
        XCTAssertTrue(
            waitForValue(queue, containing: "1 follow-up", timeout: 10) || rowShowsText(assistantRow(replyingTo: followUp), Self.replyStart, timeout: 1),
            "The follow-up was neither queued nor running after the reconnect"
        )
        waitForTurnToEnd(after: "the reconnect", timeout: 120)
        XCTAssertFalse(queue.exists, "The queue still showed after the run ended")
        for prompt in [first, followUp] {
            XCTAssertTrue(rowShowsText(assistantRow(replyingTo: prompt), Self.replyEnd, timeout: 10), "The reply to \(prompt) did not land")
            XCTAssertEqual(assistantRows(replyingTo: prompt).count, 1, "The reply to \(prompt) showed more than once")
        }
        XCTAssertEqual(userRows.count, 2, "Expected each prompt once after the reconnect")
    }

    private var timeline: XCUIElement { app.collectionViews["chat.timeline"] }

    private var liveRow: XCUIElement {
        timeline.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", Self.liveAssistantPrefix)
        ).firstMatch
    }

    private var userRows: XCUIElementQuery {
        timeline.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.timeline.user."))
    }

    /// Assistant rows of the faux reply to `prompt` (the reply quotes its prompt).
    private func assistantRows(replyingTo prompt: String) -> XCUIElementQuery {
        timeline.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", Self.assistantPrefix)
        ).containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", prompt, prompt))
    }

    private func assistantRow(replyingTo prompt: String) -> XCUIElement {
        assistantRows(replyingTo: prompt).firstMatch
    }

    /// The busy-mode pill shows in the action row, which shows while the input has focus.
    private func selectBusyMode(_ mode: String) {
        tap(app.textViews["chat.input"], named: "chat input", timeout: 5)
        tap(app.buttons["chat.busyMode"], named: "busy mode", timeout: 5)
        tap(app.buttons["chat.busyMode.option.\(mode)"], named: "busy mode \(mode)", timeout: 5)
    }

    /// The chat's queue: a strip pill above the composer whose value counts steers and follow-ups.
    private var queuePill: XCUIElement {
        app.descendants(matching: .any)["extension-strip-aboveEditor-pill-message-queue"]
    }

    private func waitForValue(_ element: XCUIElement, containing text: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND value CONTAINS %@", text),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForElementToDisappear(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForTurnToEnd(
        after moment: String,
        timeout: TimeInterval = 60,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let stopped = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.buttons["chat.stop"]
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [stopped], timeout: timeout), .completed,
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
