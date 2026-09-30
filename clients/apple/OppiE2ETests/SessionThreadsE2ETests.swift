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
    nonisolated(unsafe) private var agentIds: [String] = []

    nonisolated private static let orchestratorKey = "d0dd7892-8366-4793-b923-debbc77c7ad3"
    private static let donkeyMasterKey = "0562cb98-a36a-432f-8ddd-48eed410ab73"
    private static let finishedFixKey = "7422b7a7-fe4c-4a8f-a41b-41562a6f2182"
    private static let reviewCleanupKey = "f7741ae5-2491-47a3-bb68-c0a0e57d32c0"
    private static let sonnetCounterpartKey = "a6e4db71-dbb6-4a9c-8076-9445e62fa5e3"
    /// Synthetic (not part of the captured snapshot): a stopped session last active
    /// ten days ago, so it falls outside the app's three-day recent-session list.
    /// The orchestrator's cross-thread message to it is a simulated edge; a real
    /// prompt would have refreshed its activity.
    nonisolated private static let archivedCounterpartKey = "synthetic-archived-counterpart"
    nonisolated private static let archivedCounterpartName = "Archived Markdown resource review"

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
        var interactions = fixture["interactions"] as? [[String: Any]] ?? []
        sessions.append([
            "key": Self.archivedCounterpartKey,
            "name": Self.archivedCounterpartName,
            "status": "stopped",
            "workspaceName": "oppi",
            "createdAtOffsetMs": -10 * 86_400_000 - 3_600_000,
            "lastActivityOffsetMs": -10 * 86_400_000,
            "model": "anthropic/claude-opus-5-5",
            "cost": 3.2,
            "messageCount": 40,
        ])
        interactions.append([
            "fromKey": Self.orchestratorKey,
            "toKey": Self.archivedCounterpartKey,
            "kind": "prompt",
            "atOffsetMs": -4_000_000,
        ])
        let snapshotAtMs = try XCTUnwrap(fixture["snapshotAtMs"] as? Double)

        var workspaceIdByName: [String: String] = [:]
        for name in Set(sessions.compactMap { $0["workspaceName"] as? String }).sorted() {
            let id = try createLabWorkspace(named: name)
            workspaceIdByName[name] = id
            workspaceIds.append(id)
        }
        // Real saved Agents (Worker, Reviewer, Donkey Master…) recreated through the Agent API.
        var agentIdByKey: [String: (id: String, icon: Any)] = [:]
        for agent in fixture["agents"] as? [[String: Any]] ?? [] {
            let key = try XCTUnwrap(agent["key"] as? String)
            let response = try e2eLabAPIJSON(method: "POST", path: "/agents", body: [
                "name": try XCTUnwrap(agent["name"] as? String),
                "icon": try XCTUnwrap(agent["icon"]),
            ])
            let created = try XCTUnwrap(response["agent"] as? [String: Any])
            let agentId = try XCTUnwrap(created["id"] as? String)
            agentIds.append(agentId)
            agentIdByKey[key] = (agentId, agent["icon"] as Any)
        }
        sessions = sessions.map { session in
            var copy = session
            copy["workspaceId"] = workspaceIdByName[session["workspaceName"] as? String ?? ""]
            if let key = session["agentKey"] as? String, let agent = agentIdByKey[key] {
                copy["agentId"] = agent.id
                copy["agentIcon"] = agent.icon
            }
            return copy
        }

        let response = try e2eLabAPIJSON(
            method: "POST",
            path: "/e2e/ui/fixtures/session-threads",
            body: [
                "workspaceId": workspaceIds[0],
                "nowMs": Self.replayNowMs(snapshotAtMs: snapshotAtMs),
                "sessions": sessions,
                "interactions": interactions,
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
            agentIds = []
            try? super.tearDownWithError()
        }
        terminateSharedApp()
        _ = try? e2eLabAPIJSON(method: "DELETE", path: "/e2e/ui/fixtures/session-threads")
        for id in workspaceIds {
            _ = try? e2eLabAPIJSON(method: "DELETE", path: "/workspaces/\(id)")
        }
        // Agent names are unique among active Agents; archive so the next test can seed them again.
        for id in agentIds {
            _ = try? e2eLabAPIJSON(method: "DELETE", path: "/agents/\(id)")
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
        let rootRow = app.buttons["thread.row.\(orchestrator)"]
        XCTAssertTrue(reveal(rootRow, in: detail), "Root outline row missing")
        XCTAssertTrue(rootRow.label.contains("96% cached"), "Root row should show its real cache rate: \(rootRow.label)")
        XCTAssertTrue(reveal(app.buttons["thread.row.\(donkeyMaster)"], in: detail))
        beat(1.5)
        let fold = app.buttons["thread.fold.\(orchestrator)"]
        XCTAssertTrue(reveal(fold, in: detail), "Finished children fold missing")
        XCTAssertEqual(fold.value as? String, "Collapsed")
        // The collapsed row names which saved Agents did the finished work.
        XCTAssertTrue(
            fold.label.contains("Reviewer") || fold.label.contains("Worker"),
            "Collapsed row should name its Agents: \(fold.label)"
        )
        fold.tap()
        XCTAssertTrue(
            reveal(app.buttons["thread.row.\(try id(Self.finishedFixKey))"], in: detail),
            "Expanding the fold should list finished children"
        )
        beat(1.5)
        let counterpart = app.descendants(matching: .any)["thread.counterpart.\(try id(Self.sonnetCounterpartKey))"]
        XCTAssertTrue(
            reveal(counterpart, in: detail),
            "The real 07:44 cross-thread message should list its counterpart"
        )
        XCTAssertTrue(counterpart.label.contains("Sonnet max Markdown resource access"), counterpart.label)
        beat(1.5)

        // Tapping the cross-thread row opens that session's chat, and Back returns here.
        counterpart.tap()
        // The counterpart is stopped, so its chat shows Resume instead of an input; the toolbar is common to both.
        XCTAssertTrue(
            app.buttons["chat.toolbar.files"].waitForExistence(timeout: 15),
            "Cross-thread row did not open the other session"
        )
        beat(1.5)
        app.buttons["chat.toolbar.back"].tap()
        // The thread stays scrolled to the cross-thread card, so check the nav bar, not the title row.
        XCTAssertTrue(app.navigationBars["Thread"].waitForExistence(timeout: 10), "Back did not return to the thread")
        for _ in 0..<3 { detail.swipeDown(velocity: .fast) }

        // Waterfall: one row per session on clock time.
        let waterfallPill = app.buttons["thread.mode.waterfall"]
        XCTAssertTrue(reveal(waterfallPill, in: detail))
        waterfallPill.tap()
        let waterfallRow = app.descendants(matching: .any)["thread.waterfall.row.\(donkeyMaster)"]
        XCTAssertTrue(reveal(waterfallRow, in: detail), "Waterfall should list the Donkey Master row")
        XCTAssertTrue(waterfallRow.label.contains("Donkey Master"), "Waterfall row should name its Agent: \(waterfallRow.label)")
        beat(2.5)
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
        beat(2)

        // An idle session can be stopped from the thread outline.
        let reviewDetail = app.collectionViews["thread.detail"]
        let outlinePill = app.buttons["thread.mode.outline"]
        XCTAssertTrue(reveal(outlinePill, in: reviewDetail))
        outlinePill.tap()
        let summary = app.descendants(matching: .any)["thread.summary"]
        XCTAssertTrue(reveal(summary, in: reviewDetail), "Thread header summary missing")
        XCTAssertTrue(summary.label.contains("root idle"), "Header should call the idle root idle: \(summary.label)")
        let reviewRoot = app.buttons["thread.row.\(reviewCleanup)"]
        XCTAssertTrue(reveal(reviewRoot, in: reviewDetail), "Idle review root row missing")
        XCTAssertFalse(reviewRoot.label.contains("stopped"), "Review root should start idle: \(reviewRoot.label)")
        reviewRoot.swipeLeft()
        let stop = app.buttons["thread.stop.\(reviewCleanup)"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "Idle session row did not offer Stop")
        stop.tap()
        let stopped = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "stopped"),
            object: app.buttons["thread.row.\(reviewCleanup)"]
        )
        XCTAssertEqual(XCTWaiter().wait(for: [stopped], timeout: 10), .completed, "Stop did not stop the idle session")
        XCTAssertEqual(
            try e2eSession(sessionId: reviewCleanup)["status"] as? String,
            "stopped",
            "The server did not record the stop"
        )
        for _ in 0..<3 { reviewDetail.swipeDown(velocity: .fast) }
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "Thread header summary missing")
        XCTAssertFalse(summary.label.contains("root idle"), "Header still calls the stopped root idle: \(summary.label)")
        XCTAssertTrue(summary.label.contains("finished"), "Header summary lost its counts: \(summary.label)")
        beat(4)
    }

    /// A stopped counterpart outside the recent-session list must open as ended
    /// history. Only an explicit Resume may start a stopped session.
    func testStoppedCounterpartOutsideRecentListOpensWithoutStartingUntilExplicitResume() throws {
        XCUIDevice.shared.orientation = .portrait
        let orchestrator = try id(Self.orchestratorKey)
        let archived = try id(Self.archivedCounterpartKey)
        let finishedFix = try id(Self.finishedFixKey)

        // Oracle: the app's global refresh asks for three days; the archived session is not in it,
        // while the in-list counterpart is. Both start stopped on the server.
        let recent = try e2eLabAPIJSON(method: "GET", path: "/sessions/recent?recentDays=3")
        let recentIds = Set((recent["sessions"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        XCTAssertFalse(recentIds.contains(archived), "Archived counterpart must be outside the recent list")
        XCTAssertTrue(recentIds.contains(try id(Self.sonnetCounterpartKey)), "Control: in-list counterpart missing")
        try assertStopped(archived, "before opening")
        try assertStopped(finishedFix, "before opening")

        let inbox = app.collectionViews["workspace.sessionList"]
        let threadRow = app.buttons["thread.nav.\(orchestrator)"]
        XCTAssertTrue(reveal(threadRow, in: inbox, timeout: 20), "Orchestrator thread row missing")
        threadRow.tap()
        XCTAssertTrue(app.staticTexts["thread.title"].waitForExistence(timeout: 15), "Thread detail did not open")
        let detail = app.collectionViews["thread.detail"]

        // Outline: open the archived counterpart.
        let counterpart = app.descendants(matching: .any)["thread.counterpart.\(archived)"]
        XCTAssertTrue(reveal(counterpart, in: detail), "Archived counterpart row missing from the outline")
        XCTAssertTrue(counterpart.label.contains(Self.archivedCounterpartName), counterpart.label)
        counterpart.tap()
        try assertOpenedAsEndedHistory("outline")
        app.buttons["chat.toolbar.back"].tap()
        XCTAssertTrue(app.navigationBars["Thread"].waitForExistence(timeout: 10), "Back did not return to the thread")

        // Timeline: the same lookup path.
        let timelinePill = app.buttons["thread.mode.timeline"]
        XCTAssertTrue(reveal(timelinePill, in: detail))
        timelinePill.tap()
        let crossThreadRow = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "thread.timeline.interaction:", Self.archivedCounterpartName
        )).firstMatch
        XCTAssertTrue(reveal(crossThreadRow, in: detail), "Timeline cross-thread row for the archived session missing")
        crossThreadRow.tap()
        try assertOpenedAsEndedHistory("timeline")
        app.buttons["chat.toolbar.back"].tap()
        XCTAssertTrue(app.navigationBars["Thread"].waitForExistence(timeout: 10), "Back did not return to the thread")

        // Explicit Resume from a stopped outline row is the only action that starts a runtime.
        let outlinePill = app.buttons["thread.mode.outline"]
        XCTAssertTrue(reveal(outlinePill, in: detail))
        outlinePill.tap()
        let fold = app.buttons["thread.fold.\(orchestrator)"]
        XCTAssertTrue(reveal(fold, in: detail), "Finished children fold missing")
        if fold.value as? String == "Collapsed" { fold.tap() }
        let finishedRow = app.buttons["thread.row.\(finishedFix)"]
        XCTAssertTrue(reveal(finishedRow, in: detail), "Stopped outline row missing")
        XCTAssertTrue(finishedRow.label.contains("stopped"), "Row should read stopped first: \(finishedRow.label)")
        try assertStopped(finishedFix, "before Resume")
        finishedRow.swipeLeft()
        let resume = app.buttons["thread.resume.\(finishedFix)"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "Stopped outline row did not offer Resume")
        resume.tap()
        let resumed = expectation(description: "server records the explicit resume")
        DispatchQueue.global().async { [self] in
            for _ in 0..<40 {
                if let status = try? e2eSession(sessionId: finishedFix)["status"] as? String,
                   status == "ready" || status == "busy" {
                    resumed.fulfill()
                    return
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        wait(for: [resumed], timeout: 15)
        try assertStopped(archived, "after the explicit Resume of another session")
        beat(2)
    }

    /// The chat shows ended-session history with its Resume footer, and the session stays stopped.
    private func assertOpenedAsEndedHistory(_ via: String) throws {
        XCTAssertTrue(
            app.buttons["chat.toolbar.files"].waitForExistence(timeout: 15),
            "Cross-thread row (\(via)) did not open the session"
        )
        // Give an implicit stream open time to start the runtime before reading server state.
        beat(3)
        try assertStopped(try id(Self.archivedCounterpartKey), "after opening from \(via)")
        XCTAssertTrue(
            app.buttons["Resume Session"].waitForExistence(timeout: 10),
            "Stopped session opened from \(via) must show its ended-session Resume footer"
        )
    }

    private func assertStopped(_ sessionId: String, _ when: String) throws {
        let status = try e2eSession(sessionId: sessionId)["status"] as? String
        XCTAssertEqual(status, "stopped", "Session \(sessionId) must stay stopped \(when)")
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
