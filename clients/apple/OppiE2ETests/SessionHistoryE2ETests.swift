import XCTest

/// Focused power-user session-history coverage kept outside the release gate.
final class SessionHistoryE2ETests: E2ETestCase {
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }

    private let searchMarker = "HISTORY_SEARCH_SENTINEL_7A91"
    private let forkMarker = "HISTORY_FORK_SENTINEL_53F2"
    private let localImportTitle = "E2E Local Import 8C2D"
    private let localImportFirstMessage = "Local import first message 8C2D"

    private var seededSearchSessionId: String?
    private var seededForkSessionId: String?
    private var localImportFixture: (path: String, piSessionId: String)?

    override func seedE2EFixtures() throws {
        if name.contains("testStoppedSessionSearchFindsTranscriptText") {
            seededSearchSessionId = try importLocalFixtureAsStoppedSession(
                directoryName: "history-search",
                name: "E2E Search Fixture 7A91",
                firstMessage: searchMarker,
                userEntryId: "history-search-user"
            )
        } else if name.contains("testTraceOutlineForkCreatesOpenableSession") {
            seededForkSessionId = try importLocalFixtureAsStoppedSession(
                directoryName: "history-fork",
                name: "E2E Fork Source 53F2",
                firstMessage: forkMarker,
                userEntryId: "a53f2c01"
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
        let sourceSessionId = try XCTUnwrap(seededForkSessionId, "Fork fixture session was not seeded")
        let workspaceId = try e2eWorkspaceId()

        let outlineResponse = try e2eLabAPIJSON(
            method: "GET",
            path: "/workspaces/\(workspaceId)/sessions/\(sourceSessionId)/trace-outline"
        )
        let outline = try XCTUnwrap(outlineResponse["outline"] as? [String: Any], "Trace outline response missing outline")
        let entries = try XCTUnwrap(outline["entries"] as? [[String: Any]], "Trace outline response missing entries")
        let forkEntry = try XCTUnwrap(
            entries.first { entry in
                (entry["isForkable"] as? Bool) == true
                    && ((entry["kind"] as? String) == "user" || (entry["summary"] as? String)?.contains(forkMarker) == true)
            },
            "No forkable outline entry found"
        )
        let entryId = try XCTUnwrap(forkEntry["id"] as? String, "Forkable outline entry missing id")
        let forkName = "E2E Forked Session 53F2"
        let forkResponse = try e2eLabAPIJSON(
            method: "POST",
            path: "/workspaces/\(workspaceId)/sessions/\(sourceSessionId)/fork",
            body: [
                "entryId": entryId,
                "name": forkName,
            ]
        )
        let forkedSession = try XCTUnwrap(forkResponse["session"] as? [String: Any], "Fork response missing session")
        let forkedSessionId = try XCTUnwrap(forkedSession["id"] as? String, "Fork response missing session id")

        app.launchEnvironment["OPPI_E2E_AUTO_OPEN_SESSION_ID"] = forkedSessionId
        app.terminate()
        app.launch()
        XCTAssertEqual(waitForFocusedSessionId(forkedSessionId, timeout: 20), forkedSessionId)
        XCTAssertTrue(waitForElementToExist(app.textViews["chat.input"], timeout: 20), "Forked session did not open")
        XCTAssertTrue(waitForTimelineTextContaining(forkMarker, timeout: 20), "Forked session did not preserve source context")
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
        let sessionList = app.collectionViews["workspace.sessionList"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if searchField.exists { return true }
            if sessionList.exists {
                sessionList.swipeDown()
                return waitForElementToExist(searchField, timeout: 3)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return searchField.exists
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
