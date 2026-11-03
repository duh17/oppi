import XCTest

/// Focused power-user session-history coverage kept outside the release gate.
final class SessionHistoryE2ETests: E2ETestCase {
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }

    private let searchMarker = "HISTORY_SEARCH_SENTINEL_7A91"
    private let localImportTitle = "E2E Local Import 8C2D"
    private let localImportFirstMessage = "Local import first message 8C2D"

    private var seededSearchSessionId: String?
    private var localImportFixture: (path: String, piSessionId: String)?

    override func seedE2EFixtures() throws {
        if name.contains("testStoppedSessionSearchFindsTranscriptText") {
            seededSearchSessionId = try importLocalFixtureAsStoppedSession(
                directoryName: "history-search",
                name: "E2E Search Fixture 7A91",
                firstMessage: searchMarker,
                userEntryId: "history-search-user"
            )
        } else if name.contains("testLocalPiSessionImportOpensImportedChat") {
            localImportFixture = try createLocalPiSessionFixture(
                directoryName: "history-local-import",
                cwd: "/private/tmp",
                name: localImportTitle,
                firstMessage: localImportFirstMessage
            )
        }
    }

    @MainActor
    func testStoppedSessionSearchFindsTranscriptText() throws {
        let sessionId = try XCTUnwrap(seededSearchSessionId, "Search fixture session was not seeded")

        let searchField = revealSessionSearchField(context: "search fixture")
        tap(searchField, named: "session search field", timeout: 1)
        searchField.typeText(searchMarker)

        XCTAssertTrue(
            waitForElementToExist(app.descendants(matching: .any)["session.nav.\(sessionId)"], timeout: 15),
            "Stopped session did not remain visible after searching for transcript text"
        )
        XCTAssertTrue(
            waitForListTextContaining(searchMarker, timeout: 10),
            "Search result did not show the matching transcript snippet"
        )
    }

    @MainActor
    func testLocalPiSessionImportOpensImportedChat() throws {
        let workspaceId = try e2eWorkspaceId()
        let fixture = try XCTUnwrap(localImportFixture, "Local import fixture was not seeded")
        let localSessions = try e2eLabAPIJSON(method: "GET", path: "/local-sessions")
        let discovered = localSessions["sessions"] as? [[String: Any]] ?? []
        XCTAssertTrue(discovered.contains { $0["path"] as? String == fixture.path }, "Local Pi fixture was not discovered")

        let searchField = revealSessionSearchField(context: "local import")
        tap(searchField, named: "session search field", timeout: 1)
        searchField.typeText(localImportTitle)

        let localRow = app.descendants(matching: .any)["localSession.nav.\(fixture.piSessionId)"]
        XCTAssertTrue(waitForElementToExist(localRow, timeout: 10), "Importable local Pi session row did not appear")
        tap(localRow, named: "local Pi session row", timeout: 1)

        XCTAssertTrue(waitForImportedChatSurface(timeout: 20), "Imported local session chat did not open")
        XCTAssertTrue(waitForTimelineTextContaining(localImportFirstMessage, timeout: 20), "Imported local trace message did not render")

        let imported = try waitForImportedSession(id: fixture.piSessionId, timeout: 10)
        XCTAssertEqual(imported["workspaceId"] as? String, workspaceId)
        XCTAssertEqual(imported["id"] as? String, fixture.piSessionId)
    }

    @MainActor
    func testTraceOutlineForkCreatesOpenableSession() throws {
        let workspaceId = try e2eWorkspaceId()

        // Oppi forks in front of the chosen user message, so this needs a live
        // session with two turns: a fork at the second keeps the first exchange
        // and drops the fork-point turn, and a fork at the first opens empty.
        // The stopped import fixture cannot show either half: its chat offers
        // Resume instead of a composer.
        let sourceIds = try createLabSessions(count: 1, workspaceId: workspaceId, stopAfterCreate: false)
        let sourceSessionId = try XCTUnwrap(sourceIds.first, "Lab session create returned no id")
        enterSession(id: sourceSessionId)
        XCTAssertEqual(waitForFocusedSessionId(sourceSessionId, timeout: 20), sourceSessionId)

        let firstTurn = "HISTORY_FORK_FIRST_TURN_53F2"
        let forkPointTurn = "HISTORY_FORK_SECOND_TURN_53F2"
        sendMessageAndWaitForResponse(localEchoPrompt(firstTurn), timeout: 180)
        XCTAssertTrue(
            waitForTimelineTextContaining(firstTurn, timeout: 20),
            "First turn did not render in the source session"
        )
        sendMessageAndWaitForResponse(localEchoPrompt(forkPointTurn), timeout: 180)
        XCTAssertTrue(
            waitForTimelineTextContaining(forkPointTurn, timeout: 20),
            "Fork-point turn did not render in the source session"
        )

        let outline = try traceOutline(workspaceId: workspaceId, sessionId: sourceSessionId)
        let firstEntryId = try forkableEntryId(in: outline, containing: firstTurn)
        let forkPointEntryId = try forkableEntryId(in: outline, containing: forkPointTurn)

        let forkAfterFirstTurnId = try forkSession(
            workspaceId: workspaceId,
            sourceSessionId: sourceSessionId,
            entryId: forkPointEntryId,
            name: "E2E Fork At Second Turn 53F2"
        )
        openForkedSession(forkAfterFirstTurnId)
        XCTAssertTrue(
            waitForTimelineTextContaining(firstTurn, timeout: 20),
            "Fork did not keep the turn before its fork point"
        )
        XCTAssertFalse(
            timelineRowAppears(forkPointTurn, within: 3),
            "Fork showed the turn it forked at instead of rewinding in front of it"
        )

        let emptyForkId = try forkSession(
            workspaceId: workspaceId,
            sourceSessionId: sourceSessionId,
            entryId: firstEntryId,
            name: "E2E Fork At First Turn 53F2"
        )
        openForkedSession(emptyForkId)
        XCTAssertTrue(
            waitForElementToExist(app.textViews["chat.input"], timeout: 20),
            "Fork of the first turn did not open a chat"
        )
        XCTAssertFalse(timelineRowAppears(firstTurn, within: 2), "Fork of the first turn kept the message it forked at")
        XCTAssertFalse(timelineRowAppears(forkPointTurn, within: 1), "Fork of the first turn showed a later turn")
        // The composer is the empty chat's working part: it takes focus for a
        // prompt, which is what the fork has to offer when it carries no turns.
        XCTAssertTrue(
            waitForSettledHittable(app.textViews["chat.input"], timeout: 10),
            "Empty fork's composer never became usable"
        )
        focusChatInput()

        // The app instance is shared across E2E classes, and a launch hint left
        // here would suppress the next class's auto-created chat.
        app.launchEnvironment.removeValue(forKey: "OPPI_E2E_AUTO_OPEN_SESSION_ID")
    }

    @MainActor
    private func traceOutline(workspaceId: String, sessionId: String) throws -> [String: Any] {
        let response = try e2eLabAPIJSON(
            method: "GET",
            path: "/workspaces/\(workspaceId)/sessions/\(sessionId)/trace-outline"
        )
        return try XCTUnwrap(response["outline"] as? [String: Any], "Trace outline response missing outline")
    }

    /// The outline id a fork at `text` accepts: the user entry that carries it,
    /// which is the part of the tree `navigate_tree` rewinds in front of.
    private func forkableEntryId(in outline: [String: Any], containing text: String) throws -> String {
        let entries = try XCTUnwrap(outline["entries"] as? [[String: Any]], "Trace outline response missing entries")
        let entry = try XCTUnwrap(
            entries.first { entry in
                (entry["kind"] as? String) == "user"
                    && (entry["isForkable"] as? Bool) == true
                    && ((entry["summary"] as? String)?.contains(text) ?? false)
            },
            "Trace outline had no forkable user entry showing \(text)"
        )
        return try XCTUnwrap(entry["id"] as? String, "Forkable outline entry missing id")
    }

    private func forkSession(
        workspaceId: String,
        sourceSessionId: String,
        entryId: String,
        name: String
    ) throws -> String {
        let response = try e2eLabAPIJSON(
            method: "POST",
            path: "/workspaces/\(workspaceId)/sessions/\(sourceSessionId)/fork",
            body: [
                "entryId": entryId,
                "name": name,
            ]
        )
        let session = try XCTUnwrap(response["session"] as? [String: Any], "Fork response missing session")
        return try XCTUnwrap(session["id"] as? String, "Fork response missing session id")
    }

    /// Relaunches the app into a fork, the way its row opens it: a fork is a
    /// normal chat, not a stopped source waiting on Resume.
    @MainActor
    private func openForkedSession(_ sessionId: String) {
        app.launchEnvironment["OPPI_E2E_AUTO_OPEN_SESSION_ID"] = sessionId
        app.terminate()
        app.launch()
        XCTAssertEqual(
            waitForFocusedSessionId(sessionId, timeout: 20),
            sessionId,
            "Forked session \(sessionId) was not the open chat after relaunch"
        )
    }

    /// Whether the chat timeline grows a row showing `text` within `timeout`.
    /// Scoped to the timeline so a marker in the composer, a bar, or a sheet
    /// cannot answer for a row, and polled so a late row still counts before an
    /// absence assertion trusts it.
    @MainActor
    private func timelineRowAppears(_ text: String, within timeout: TimeInterval) -> Bool {
        let timeline = app.collectionViews["chat.timeline"]
        let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if timeline.exists,
               timeline.descendants(matching: .any).matching(predicate).firstMatch.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    private func importLocalFixtureAsStoppedSession(
        directoryName: String,
        name: String,
        firstMessage: String,
        userEntryId: String
    ) throws -> String {
        let workspaceId = try e2eWorkspaceId()
        let fixture = try createLocalPiSessionFixture(
            directoryName: directoryName,
            cwd: "/private/tmp",
            name: name,
            firstMessage: firstMessage,
            userEntryId: userEntryId
        )
        let response = try e2eLabAPIJSON(
            method: "POST",
            path: "/workspaces/\(workspaceId)/sessions",
            body: [
                "piSessionFile": fixture.path,
                "name": name,
            ]
        )
        let session = try XCTUnwrap(response["session"] as? [String: Any], "Import response missing session")
        return try XCTUnwrap(session["id"] as? String, "Import response missing session id")
    }

    private func waitForImportedSession(
        id: String,
        timeout: TimeInterval
    ) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let response = try e2eLabAPIJSON(method: "GET", path: "/sessions?workspaceId=\(e2eWorkspaceId())&status=stopped")
            let sessions = response["sessions"] as? [[String: Any]] ?? []
            if let session = sessions.first(where: { $0["id"] as? String == id }) {
                return session
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("Imported session with id \(id) did not appear")
        return [:]
    }

    @MainActor
    private func revealSessionSearchField(context: String) -> XCUIElement {
        let searchField = app.searchFields["Search sessions"]
        if searchField.exists { return searchField }

        if revealSessionSearchFieldFromCurrentSurface(searchField: searchField, timeout: 2) {
            return searchField
        }

        let chatBackButton = app.buttons["chat.toolbar.back"]
        if chatBackButton.exists {
            tap(chatBackButton, named: "chat back button", timeout: 1)
            if revealSessionSearchFieldFromCurrentSurface(searchField: searchField, timeout: 8) {
                return searchField
            }
        }

        XCTAssertTrue(
            waitForElementToExist(searchField, timeout: 3),
            "Session search field did not appear for \(context)"
        )
        return searchField
    }

    @MainActor
    private func revealSessionSearchFieldFromCurrentSurface(
        searchField: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        if searchField.exists { return true }

        let toolbarSearch = app.toolbars.buttons["Search"]
        if toolbarSearch.exists {
            tap(toolbarSearch, named: "session search", timeout: 1)
            if waitForElementToExist(searchField, timeout: 3) {
                return true
            }
        }

        let navBar = app.navigationBars.firstMatch
        if navBar.exists {
            navBar.swipeDown()
        } else {
            let sessionList = app.descendants(matching: .any)["workspace.sessionList"]
            if sessionList.exists {
                sessionList.swipeDown()
            } else {
                app.swipeDown()
            }
        }
        return waitForElementToExist(searchField, timeout: timeout)
    }

    @MainActor
    private func waitForImportedChatSurface(timeout: TimeInterval) -> Bool {
        let filesButton = app.buttons["chat.toolbar.files"]
        let chatInput = app.textViews["chat.input"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if filesButton.exists || chatInput.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return filesButton.exists || chatInput.exists
    }

    @MainActor
    private func waitForListTextContaining(_ text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(
            format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
            text,
            text
        )
        let match = app.descendants(matching: .any).matching(predicate).firstMatch
        return waitForElementToExist(match, timeout: timeout)
    }
}
