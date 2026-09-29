import XCTest

/// Session threads against a replay of real server data.
///
/// `Fixtures/session-threads-2026-09-29.json` is an export of the owner's
/// session state at 09:23 on 2026-09-29: names, models, costs, launch parents,
/// statuses, and the cross-session messages recorded in their transcripts.
/// Times keep their clock time when replayed on a later day.
@MainActor
final class SessionThreadsE2ETests: E2ETestCase {
    nonisolated(unsafe) private var workspaceIds: [String] = []
    nonisolated(unsafe) private var sessionIds: [String: String] = [:]

    private static let orchestratorKey = "d0dd7892-8366-4793-b923-debbc77c7ad3"
    private static let donkeyMasterKey = "0562cb98-a36a-432f-8ddd-48eed410ab73"
    private static let finishedFixKey = "7422b7a7-fe4c-4a8f-a41b-41562a6f2182"
    private static let reviewCleanupKey = "f7741ae5-2491-47a3-bb68-c0a0e57d32c0"

    override var e2eLaunchesSessionsInboxOnly: Bool { true }
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }
    override var e2eRequiresFreshLaunch: Bool { true }

    override func seedE2EFixtures() throws {
        let bundle = Bundle(for: SessionThreadsE2ETests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "session-threads-2026-09-29", withExtension: "json", subdirectory: "Fixtures")
                ?? bundle.url(forResource: "session-threads-2026-09-29", withExtension: "json"),
            "Missing session-threads fixture"
        )
        let fixture = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var sessions = try XCTUnwrap(fixture["sessions"] as? [[String: Any]])
        let snapshotAtMs = try XCTUnwrap(fixture["snapshotAtMs"] as? Double)

        var workspaceIdByName: [String: String] = [:]
        for name in Set(sessions.compactMap { $0["workspaceName"] as? String }).sorted() {
            let id = try createLabWorkspace(named: name)
            workspaceIdByName[name] = id
            workspaceIds.append(id)
        }
        sessions = sessions.map { session in
            var copy = session
            copy["workspaceId"] = workspaceIdByName[session["workspaceName"] as? String ?? ""]
            return copy
        }

        let response = try e2eLabAPIJSON(
            method: "POST",
            path: "/e2e/ui/fixtures/session-threads",
            body: [
                "workspaceId": workspaceIds[0],
                "nowMs": Self.replayNowMs(snapshotAtMs: snapshotAtMs),
                "sessions": sessions,
                "interactions": fixture["interactions"] ?? [],
            ]
        )
        sessionIds = try XCTUnwrap(response["sessionIds"] as? [String: String])
    }

    /// Shift by whole days so clock times match the capture; fall back to now
    /// when that would place the snapshot in the future.
    nonisolated private static func replayNowMs(snapshotAtMs: Double) -> Double {
        let calendar = Calendar.current
        let snapshot = Date(timeIntervalSince1970: snapshotAtMs / 1000)
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: snapshot),
            to: calendar.startOfDay(for: Date())
        ).day ?? 0
        let shifted = calendar.date(byAdding: .day, value: days, to: snapshot) ?? Date()
        return min(shifted, Date()).timeIntervalSince1970 * 1000
    }

    override func tearDownWithError() throws {
        defer {
            workspaceIds = []
            sessionIds = [:]
            try? super.tearDownWithError()
        }
        terminateSharedApp()
        _ = try? e2eLabAPIJSON(method: "DELETE", path: "/e2e/ui/fixtures/session-threads")
        for id in workspaceIds {
            _ = try? e2eLabAPIJSON(method: "DELETE", path: "/workspaces/\(id)")
        }
    }

    private func id(_ key: String) throws -> String {
        try XCTUnwrap(sessionIds[key], "Fixture session \(key) was not seeded")
    }

    /// Lets a recorded run show each state before the next interaction.
    private func beat(_ seconds: TimeInterval = 1.5) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testRealSnapshotThreadsOutlineAndTimeline() throws {
        XCUIDevice.shared.orientation = .portrait
        let orchestrator = try id(Self.orchestratorKey)
        let donkeyMaster = try id(Self.donkeyMasterKey)
        let reviewCleanup = try id(Self.reviewCleanupKey)

        // Threads is the default view.
        let modeButton = app.buttons["workspace.inbox.mode"]
        XCTAssertTrue(modeButton.waitForExistence(timeout: 20), "Inbox view button missing")
        XCTAssertEqual(modeButton.value as? String, "Threads", "All Sessions should open in Threads by default")
        beat(1)

        // Flat list: children appear as their own rows.
        modeButton.tap()
        XCTAssertEqual(modeButton.value as? String, "Sessions")
        let inbox = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(
            reveal(app.buttons["session.nav.\(donkeyMaster)"], in: inbox),
            "Flat Sessions list should list the Donkey Master child row"
        )
        beat(2)
        for _ in 0..<3 { inbox.swipeDown(velocity: .fast) }

        // Threads: children fold under their root.
        modeButton.tap()
        XCTAssertEqual(modeButton.value as? String, "Threads")
        let threadRow = app.buttons["thread.nav.\(orchestrator)"]
        XCTAssertTrue(reveal(threadRow, in: inbox), "Orchestrator thread row missing")
        XCTAssertFalse(
            app.buttons["session.nav.\(donkeyMaster)"].exists,
            "Threads mode should not list child sessions as top-level rows"
        )
        XCTAssertTrue(
            (threadRow.label).contains("working"),
            "An idle root with working children should summarize its working members: \(threadRow.label)"
        )
        beat(2.5)

        // Outline.
        threadRow.tap()
        XCTAssertTrue(app.staticTexts["thread.title"].waitForExistence(timeout: 15), "Thread detail did not open")
        let detail = app.collectionViews["thread.detail"]
        XCTAssertTrue(reveal(app.buttons["thread.row.\(donkeyMaster)"], in: detail))
        beat(1.5)
        let fold = app.buttons["thread.fold.\(orchestrator)"]
        XCTAssertTrue(reveal(fold, in: detail), "Finished children fold missing")
        XCTAssertEqual(fold.value as? String, "Collapsed")
        fold.tap()
        XCTAssertTrue(
            reveal(app.buttons["thread.row.\(try id(Self.finishedFixKey))"], in: detail),
            "Expanding the fold should list finished children"
        )
        beat(1.5)
        let counterpart = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "thread.counterpart."))
            .firstMatch
        XCTAssertTrue(
            reveal(counterpart, in: detail),
            "The real 07:44 cross-thread message should list its counterpart"
        )
        XCTAssertTrue(counterpart.label.contains("Sonnet max Markdown resource access"), counterpart.label)
        beat(2)
        for _ in 0..<3 { detail.swipeDown(velocity: .fast) }

        // Timeline with primitive filters.
        let timelinePill = app.buttons["thread.mode.timeline"]
        XCTAssertTrue(reveal(timelinePill, in: detail))
        timelinePill.tap()
        beat(2)
        let launchRow = app.buttons["thread.timeline.launch:\(donkeyMaster)"]
        XCTAssertTrue(reveal(launchRow, in: detail), "Timeline launch row missing")
        beat(1.5)
        XCTAssertTrue(reveal(app.buttons["thread.timeline.now"], in: detail), "Live working row missing")
        beat(2)

        let launches = app.buttons["thread.filter.launches"]
        XCTAssertTrue(reveal(launches, in: detail))
        launches.tap()
        XCTAssertEqual(launches.value as? String, "Off")
        XCTAssertTrue(
            waitForNonExistence(app.buttons["thread.timeline.launch:\(donkeyMaster)"], timeout: 5),
            "Hiding launches should remove launch rows"
        )
        beat(2)
        app.buttons["thread.filter.ends"].tap()
        beat(2)
        launches.tap()
        app.buttons["thread.filter.ends"].tap()
        beat(1)

        // A second real thread whose orchestrator messaged its workers.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let reviewRow = app.buttons["thread.nav.\(reviewCleanup)"]
        XCTAssertTrue(reveal(reviewRow, in: inbox), "Review cleanup thread row missing")
        reviewRow.tap()
        XCTAssertTrue(app.staticTexts["thread.title"].waitForExistence(timeout: 15))
        XCTAssertTrue(reveal(app.buttons["thread.mode.timeline"], in: detail))
        app.buttons["thread.mode.timeline"].tap()
        let messagesOnly = [
            app.buttons["thread.filter.launches"],
            app.buttons["thread.filter.ends"],
            app.buttons["thread.filter.control"],
            app.buttons["thread.filter.crossThread"],
        ]
        for chip in messagesOnly {
            XCTAssertTrue(chip.waitForExistence(timeout: 5))
            chip.tap()
        }
        let messageRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "thread.timeline.interaction:")
        )
        XCTAssertTrue(messageRows.firstMatch.waitForExistence(timeout: 5), "Recorded messages should remain visible")
        XCTAssertEqual(messageRows.count, 4, "The review orchestrator messaged four checkpoint workers")
        beat(3)
    }

    /// Lists only expose mounted rows. Scroll to the top, then drag down in
    /// short steps until `element` is on screen.
    @discardableResult
    private func reveal(_ element: XCUIElement, in list: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        _ = list.waitForExistence(timeout: timeout)
        // Horizontal scroll views report isHittable == false for visible
        // children, so check the frame against the list instead.
        func onScreen() -> Bool {
            guard element.exists else { return false }
            let frame = element.frame
            return !frame.isEmpty && list.frame.contains(CGPoint(x: frame.minX + 4, y: frame.midY))
        }
        if element.waitForExistence(timeout: 1), onScreen() { return true }
        for _ in 0..<3 { list.swipeDown(velocity: .fast) }
        for _ in 0..<14 {
            if onScreen() { return true }
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: end)
            _ = element.waitForExistence(timeout: 0.6)
        }
        return onScreen()
    }

    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
