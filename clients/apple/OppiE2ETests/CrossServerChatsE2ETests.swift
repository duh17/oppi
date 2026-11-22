import XCTest

/// Two real isolated HTTPS servers, both paired: a chat on each, side by side,
/// each streaming its own turn at the same time — the one thing Stage 4a is for
/// (a chat beside a chat across servers needs no transport change, because each
/// server has its own connection, focused-session claim and stream). Run with
/// `TWO_SERVER_TEST=CrossServerChatsE2ETests bun server/scripts/e2e-two-server.ts`
/// (`OPPI_SIM_DEVICE_PROFILE=ipad` for the iPad mini) or name it to the batch
/// gate, not plain `clients/apple/scripts/e2e.sh`.
@MainActor
final class CrossServerChatsE2ETests: E2ETestCase {
    override var e2eLaunchesSessionsInboxOnly: Bool { true }
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }
    override var e2eRequiresFreshLaunch: Bool { true }
    /// Mini landscape: two chat panes side by side, the window 4a is for.
    override var e2eOrientation: UIDeviceOrientation { .landscapeLeft }

    override func configureE2ELaunch(_ application: XCUIApplication) {
        do {
            application.launchEnvironment["OPPI_E2E_LAUNCH_INVITE"] = try TwoServerFixture.firstServerLaunchInvite()
        } catch {
            XCTFail("\(error)")
        }
    }

    private var grips: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.'"))
    }

    private var list: XCUIElement { app.collectionViews["workspace.sessionList"] }

    /// Polls `condition` until it holds or `timeout` passes, for a claim XCTest
    /// cannot ask as one element's existence: a count, a value, a frame.
    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    /// The session list's row for `sessionId`, once a refresh has brought it:
    /// a session another process made reaches the list on the next pull.
    private func row(_ sessionId: String, timeout: TimeInterval = 60) -> XCUIElement {
        let row = app.descendants(matching: .any)["session.nav.\(sessionId)"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if row.exists { return row }
            list.swipeDown()
            _ = row.waitForExistence(timeout: 3)
        }
        return row
    }

    func testAChatOnEachServerStreamsItsOwnTurnAtOnce() async throws {
        let fixture = try TwoServerFixture.load()
        let first = app.serverSwitcher(named: "e2e-server")
        XCTAssertTrue(first.waitForExistence(timeout: 15), "The first server did not pair")

        // Pair the second server, which becomes the window's: its list is the
        // one on screen.
        app.launchEnvironment.removeValue(forKey: "PI_E2E_INVITE_URL")
        app.launchEnvironment["OPPI_E2E_LAUNCH_INVITE"] = "skip"
        app.terminate()
        app.open(try await fixture.mintInvite())
        let second = app.serverSwitcher(named: "Offline E2E")
        assertExists(second, within: 25, "The second server did not pair and become selected")
        XCTAssertTrue(list.waitUntilExists(timeout: 30), "The second server's session list did not appear")
        hold()

        // A chat on the second server, made over its own API, opens beside the
        // list from the row's pane menu: the list stays where it is.
        let secondChat = try await fixture.createSession(named: "Second server chat")
        let secondRow = row(secondChat)
        XCTAssertTrue(secondRow.waitUntilExists(timeout: 5), "The second server's session did not reach its list")
        secondRow.press(forDuration: 1.2)
        // A pool simulator can lose the long press's first touch: press again
        // before giving up on its menu.
        if !app.buttons["pane.open.newPane.right"].waitForExistence(timeout: 5) {
            secondRow.press(forDuration: 1.2)
        }
        let right = app.buttons["pane.open.newPane.right"]
        XCTAssertTrue(right.waitForExistence(timeout: 5), "The row's menu offers Open in New Pane to the Right")
        right.tap()
        XCTAssertTrue(waitFor(grips.count == 2), "Open in New Pane made a second pane")
        let secondPane = grips.matching(NSPredicate(format: "label CONTAINS 'Second server chat'")).firstMatch
        XCTAssertTrue(secondPane.waitUntilExists(timeout: 20), "The second server's chat opened beside the list: \(grips.allElementsBoundByIndex.map(\.label))")
        XCTAssertEqual(secondPane.value as? String, "Focused", "The new pane has focus")
        hold()
        try saveScreenShot("cross-server-second-chat-beside-list")

        // The window's server moves to the first: the list in the main pane
        // now shows the first server's sessions, and the chat beside it stays
        // the second server's. The switcher names the server it is on, so the
        // pill is whichever one is current.
        let pill = app.buttons.matching(identifier: "server.switcher").firstMatch
        XCTAssertTrue(pill.waitUntilExists(timeout: 10), "The server switcher is not on screen")
        tap(pill, named: "server switcher")
        let firstServerRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "e2e-server")).firstMatch
        XCTAssertTrue(firstServerRow.waitUntilExists(timeout: 5), "The picker does not list the first server")
        tap(firstServerRow, named: "first server in the picker")
        XCTAssertTrue(first.waitForExistence(timeout: 15), "The window did not move to the first server")
        let workspaceId = try e2eWorkspaceId()
        let firstIds = try createLabSessions(count: 1, workspaceId: workspaceId, stopAfterCreate: false)
        let firstChat = try XCTUnwrap(firstIds.first, "The first server made no session")
        let firstRow = row(firstChat)
        XCTAssertTrue(firstRow.waitUntilExists(timeout: 5), "The first server's session did not reach the list")

        // Its row opens in the list's own pane, which is the main one: the list
        // gives way to the chat, and the two chats sit side by side.
        tap(firstRow, named: "first server session row")
        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(chatInput.waitForExistence(timeout: 30), "The first server's chat did not open")
        XCTAssertTrue(waitFor(grips.count == 2), "The row opened in the main pane, adding no pane")
        XCTAssertTrue(secondPane.exists, "The second server's chat kept its pane")
        XCTAssertTrue(waitFor(app.buttons["pane.grip.leaf-1"].label.contains("Screenshot Lab Session")),
                      "The main pane shows the first server's chat: \(app.buttons["pane.grip.leaf-1"].label)")
        XCTAssertTrue(secondPane.label.contains("Second server chat"),
                      "The pane beside it still shows the second server's chat: \(secondPane.label)")
        hold()
        try saveScreenShot("cross-server-two-chats")

        // The same prompt to each chat, one after the other, with the other's
        // reply still streaming: each pane's own composer sends its own
        // server's turn. The main pane is the window's own stack and carries no
        // pane.leaf view, so the chats are told apart by where they sit.
        XCTAssertTrue(waitFor(composers.count == 2), "Two chats are on screen")
        // The first turn runs a shell command, so it is still live however fast
        // the model answers; the second prompt then lands inside it, and the
        // two-stop-button check does not depend on the provider's speed.
        let stops = app.buttons.matching(identifier: "chat.stop")
        send("Use the bash tool to run `sleep 25`, then answer with one short sentence.", fromLeftChat: true)
        XCTAssertTrue(waitFor(stops.count >= 1, timeout: 30), "The first chat's turn started")
        send("Say one line about rivers.", fromLeftChat: false)
        XCTAssertTrue(waitFor(stops.count == 2, timeout: 30),
                      "Both chats stream at once (\(stops.count) of 2 stop buttons)")
        hold()
        try saveScreenShot("cross-server-both-streaming")

        // And both finish on their own, in the panes they started in.
        XCTAssertTrue(waitFor(stops.count == 0, timeout: 300), "Both turns end")
        XCTAssertTrue(waitFor(composers.count == 2), "Both chats are still there")
        XCTAssertTrue(waitFor(grips.count == 2), "One chat on each server, side by side")
        try saveScreenShot("cross-server-both-answered")
    }

    /// The window as the screen shows it, to `/tmp/oppi-screenshots` and the
    /// result: in landscape `app.screenshot()` draws the interface rotated into
    /// a portrait canvas and clips its width, which cuts the second chat.
    private func saveScreenShot(_ name: String) throws {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(uprightScreenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = URL(fileURLWithPath: "/tmp/oppi-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try screenshot.uprightPNG.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
    }

    /// Every composer on screen: one per chat, whichever panes hold them.
    private var composers: XCUIElementQuery {
        app.textViews.matching(identifier: "chat.input")
    }

    /// Sends `prompt` from the leftmost or rightmost chat on screen (the main
    /// pane is the left one), with the Send button closest to that composer:
    /// two chats share every chat identifier.
    private func send(_ prompt: String, fromLeftChat left: Bool) {
        let frames = composers.allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }
        guard let composer = left ? frames.first : frames.last else {
            XCTFail("No chat composer to send from")
            return
        }
        tap(composer, named: "chat composer", timeout: 10)
        let focus = NSPredicate(format: "hasKeyboardFocus == true")
        if !focus.evaluate(with: composer) {
            composer.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        }
        composer.typeText(prompt)
        let middle = composer.frame.midX
        let send = app.buttons.matching(identifier: "chat.send").allElementsBoundByIndex
            .min { abs($0.frame.midX - middle) < abs($1.frame.midX - middle) }
        XCTAssertNotNil(send, "The chat has a Send button")
        send?.tap()
        allowAISharingIfAsked()
    }

}
