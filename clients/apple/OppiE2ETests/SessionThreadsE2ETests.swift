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
    /// A stopped root with stopped children: history-only from both inbox targets.
    private static let stoppedRootKey = "145f0dcd-266a-42fe-9f97-2f8e58672536"
    private static let stoppedRootChildKey = "608460ea-1677-4f17-9900-99815dff3766"
    /// Synthetic (not part of the captured snapshot): a stopped session last active
    /// ten days ago, so it falls outside the app's three-day recent-session list.
    /// The orchestrator's cross-thread message to it is a simulated edge; a real
    /// prompt would have refreshed its activity.
    nonisolated private static let archivedCounterpartKey = "synthetic-archived-counterpart"
    nonisolated private static let archivedCounterpartName = "Archived Markdown resource review"
    /// Root of a stopped two-session thread in "oppi" (Daily upstream mirror sync).
    nonisolated private static let mirrorRootKey = "8bac488b-aa9a-416c-bddd-921a9c51ad8d"
    private static let mirrorChildKey = "2549460f-9896-478b-a1b5-bff6afce5e01"
    /// Synthetic: an idle child of the mirror thread launched into another workspace,
    /// so the thread spans two workspaces. Idle keeps it out of Outline's finished fold.
    nonisolated private static let crossWorkspaceChildKey = "synthetic-cross-workspace-child"
    nonisolated private static let crossWorkspaceName = "kypu"

    override var e2eLaunchesSessionsInboxOnly: Bool { true }
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }
    override var e2eRequiresFreshLaunch: Bool { true }

    /// Session Threads is opt-in. Launch with the experiment set the way a saved
    /// preference reads at startup: on for the thread tests, so they start where a
    /// user who enabled it does, and explicitly off for the opt-in test (the
    /// simulator keeps earlier tests' saved choice, so "unset" is a unit-test fact).
    override func configureE2ELaunch(_ application: XCUIApplication) {
        let enabled = !name.contains("testSessionThreadsStayOffUntilEnabledInSettings")
        application.launchArguments += ["-\(Self.sessionThreadsDefaultsKey)", enabled ? "YES" : "NO"]
    }

    nonisolated private static let sessionThreadsDefaultsKey = "dev.chenda.Oppi.experiments.sessionThreads"

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
        // Only the cross-workspace test gets the extra workspace and session, so
        // every other test replays the captured snapshot unchanged.
        if name.contains("testWorkspaceListsShareLayoutAndMarkCrossWorkspaceThreads") { sessions.append([
            "key": Self.crossWorkspaceChildKey,
            "parentKey": Self.mirrorRootKey,
            "name": "Kypu mirror follow-up",
            "status": "ready",
            "workspaceName": Self.crossWorkspaceName,
            "createdAtOffsetMs": -9_000_000,
            "lastActivityOffsetMs": -8_600_000,
            "model": "xai/grok-4.6",
            "cost": 0.42,
            "messageCount": 12,
        ]) }
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

        let inbox = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 20), "Inbox missing")
        beat(1)

        // Flat List (Settings, Session List): children appear as their own rows.
        try setSessionThreads(false)
        XCTAssertTrue(
            reveal(app.buttons["session.nav.\(donkeyMaster)"], in: inbox),
            "Flat List should list the Donkey Master child row"
        )
        beat(2)
        for _ in 0..<3 { inbox.swipeDown(velocity: .fast) }

        // Threads: children fold under their root.
        try setSessionThreads(true)
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
        showOutline()
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

    /// The root body opens the root's chat and only the labelled Thread strip opens Thread
    /// detail. They are separate targets, and swiping either one never navigates. Stopped roots
    /// and children open as ended history and stay stopped on the server.
    func testRootBodyAndThreadStripAreDisjointTargetsAndStoppedHistoryStaysStopped() throws {
        XCUIDevice.shared.orientation = .portrait
        let orchestrator = try id(Self.orchestratorKey)
        let stoppedRoot = try id(Self.stoppedRootKey)
        let stoppedChild = try id(Self.stoppedRootChildKey)
        try assertStopped(stoppedRoot, "before opening")
        try assertStopped(stoppedChild, "before opening")

        let inbox = app.collectionViews["workspace.sessionList"]
        let rootBody = app.buttons["session.nav.\(orchestrator)"]
        let strip = app.buttons["thread.nav.\(orchestrator)"]
        XCTAssertTrue(reveal(strip, in: inbox, timeout: 20), "Thread strip missing")
        XCTAssertTrue(rootBody.exists, "Thread root body target missing")
        XCTAssertLessThanOrEqual(
            rootBody.frame.maxY, strip.frame.minY + 1,
            "Root body and Thread strip must not overlap: \(rootBody.frame) \(strip.frame)"
        )
        XCTAssertTrue(strip.label.contains("Thread with"), "Strip should be labelled as the Thread control: \(strip.label)")

        // Swiping either target reveals actions and never navigates.
        for (name, target) in [("root body", rootBody), ("Thread strip", strip)] {
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
            assertStillOnInbox("leading drag on the \(name)")
            dismissSidebarIfOpen()
            target.swipeLeft()
            XCTAssertTrue(
                app.buttons["session.stop.\(orchestrator)"].waitForExistence(timeout: 5),
                "Trailing swipe on the \(name) did not expose Stop"
            )
            assertStillOnInbox("trailing swipe on the \(name)")
            target.swipeRight()
            XCTAssertTrue(waitForNonExistence(app.buttons["session.stop.\(orchestrator)"], timeout: 5), "Swipe did not close")
        }

        // One tap on the strip opens Thread detail, not the root chat.
        strip.tap()
        XCTAssertTrue(app.staticTexts["thread.title"].waitForExistence(timeout: 15), "Strip did not open Thread detail")
        XCTAssertFalse(app.buttons["chat.toolbar.files"].exists, "Strip must not open the root chat")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(inbox.waitForExistence(timeout: 10), "Back did not return to the inbox")

        // Stopped root: body tap is history-only; the strip opens the thread, whose stopped child is too.
        expandStoppedGroups()
        let stoppedBody = app.buttons["session.nav.\(stoppedRoot)"]
        XCTAssertTrue(reveal(stoppedBody, in: inbox, timeout: 20), "Stopped root body missing")
        stoppedBody.tap()
        XCTAssertFalse(app.staticTexts["thread.title"].exists, "Root body must not open Thread detail")
        try assertOpenedAsEndedHistory(stoppedRoot, via: "stopped root body")
        app.buttons["chat.toolbar.back"].tap()
        XCTAssertTrue(inbox.waitForExistence(timeout: 10), "Back did not return to the inbox")

        let stoppedStrip = app.buttons["thread.nav.\(stoppedRoot)"]
        XCTAssertTrue(reveal(stoppedStrip, in: inbox), "Stopped root Thread strip missing")
        stoppedStrip.tap()
        XCTAssertTrue(app.staticTexts["thread.title"].waitForExistence(timeout: 15), "Stopped root strip did not open Thread detail")
        showOutline()
        let detail = app.collectionViews["thread.detail"]
        // Finished children fold under their parent until expanded.
        let fold = app.buttons["thread.fold.\(stoppedRoot)"]
        XCTAssertTrue(reveal(fold, in: detail), "Finished children fold missing")
        if fold.value as? String == "Collapsed" { fold.tap() }
        let childRow = app.buttons["thread.row.\(stoppedChild)"]
        XCTAssertTrue(reveal(childRow, in: detail), "Stopped child outline row missing")
        childRow.tap()
        try assertOpenedAsEndedHistory(stoppedChild, via: "stopped child")
        app.buttons["chat.toolbar.back"].tap()
        XCTAssertTrue(app.navigationBars["Thread"].waitForExistence(timeout: 10))
        try assertStopped(stoppedRoot, "after opening its thread and child")
    }

    // MARK: - Customize Rows

    /// Customize Rows (Settings, Session List): the draft repaints an inert preview from the
    /// production row; Cancel and dismissal discard; Done returns to Settings and applies to the
    /// mounted inbox and workspace lists; the saved choice, the remembered thread view, and the
    /// saved layout survive a relaunch.
    func testCustomizeRowsPreviewDiscardsSavesAndAppliesAcrossListsAndRelaunch() throws {
        XCUIDevice.shared.orientation = .portrait
        let orchestrator = try id(Self.orchestratorKey)
        let donkeyMaster = try id(Self.donkeyMasterKey)
        let inbox = app.collectionViews["workspace.sessionList"]
        let rootBody = app.buttons["session.nav.\(orchestrator)"]
        let strip = app.buttons["thread.nav.\(orchestrator)"]
        XCTAssertTrue(reveal(strip, in: inbox, timeout: 20), "Thread strip missing")

        try resetRowDisplayToDefaults()
        XCTAssertTrue(reveal(rootBody, in: inbox))
        let rootCost = try costText(in: rootBody.label)
        XCTAssertTrue(strip.label.contains("$"), "Default strip should total cost: \(strip.label)")

        // Preview: sample data, every fact on, and the production strip.
        try openRowEditor()
        XCTAssertEqual(app.staticTexts["sessionRows.preview.label"].label, "PREVIEW \u{00B7} SAMPLE DATA")
        let facts = previewFacts
        for (name, element) in facts { XCTAssertTrue(element.exists, "Default preview lacks \(name)") }
        XCTAssertTrue(previewFact(label: "sonnet").exists, "Default preview lacks the model")
        XCTAssertTrue(previewStrip.exists)
        XCTAssertTrue(previewStrip.label.contains("$4.68"), previewStrip.label)
        let standardHeight = previewBox.frame.height
        let standardStripHeight = previewStrip.frame.height
        let titleHeight = previewFact("Refactor checkout flow").frame.height
        // Widths of every fact Compact could squeeze; the relative time is left out because its text drifts.
        let standardWidths = fixedWidthFacts.map { $0.element.frame.width }
        XCTAssertTrue(standardWidths.allSatisfy { $0 > 0 }, "Default preview facts must have real width")

        // Each control repaints the preview immediately; nothing is saved.
        setToggle("cost", on: false)
        XCTAssertTrue(waitForNonExistence(previewFact("$3.14"), timeout: 5), "Cost off should hide the row cost")
        XCTAssertFalse(previewStrip.label.contains("$"), "Hidden cost leaked into the strip: \(previewStrip.label)")
        XCTAssertTrue(previewFact("48%").exists, "Cost toggle must not hide other facts")
        setToggle("cost", on: true)
        XCTAssertTrue(previewFact("$3.14").waitForExistence(timeout: 5))
        setToggle("laneGraph", on: false)
        XCTAssertTrue(
            waitForFrameHeight(previewStrip, below: standardStripHeight),
            "Lane graph off should shrink the strip"
        )
        setToggle("laneGraph", on: true)
        setDensity("Compact")
        XCTAssertTrue(waitForFrameHeight(previewBox, below: standardHeight), "Compact should be denser")
        XCTAssertEqual(previewFact("Refactor checkout flow").frame.height, titleHeight, accuracy: 0.5, "Compact must not shrink the title")
        for (name, element) in facts { XCTAssertTrue(element.exists, "Compact hid \(name)") }
        // Compact may re-arrange rows but must not shorten a fact Standard shows in full.
        for ((name, element), width) in zip(fixedWidthFacts, standardWidths) {
            XCTAssertEqual(element.frame.width, width, accuracy: 1, "Compact shortened \(name)")
        }
        XCTAssertLessThanOrEqual(previewFact("Done").frame.maxX, previewBox.frame.maxX + 1, "Status must stay inside the row")

        // Every optional detail off: safety facts, the Thread control, and a child's question stay.
        for control in ["model", "time", "context", "cost", "files", "compactions", "agentSummary", "laneGraph"] {
            setToggle(control, on: false)
        }
        for (name, element) in facts { XCTAssertTrue(waitForNonExistence(element, timeout: 5), "\(name) should be hidden") }
        XCTAssertTrue(previewFact("Done").exists, "Root status must stay")
        XCTAssertTrue(previewFact("shop-app").exists, "Workspace context must stay")
        XCTAssertTrue(previewStrip.label.contains("Thread with 3 child sessions"), previewStrip.label)
        XCTAssertTrue(previewStrip.label.contains("Question from Review API diff"), "Child question hidden: \(previewStrip.label)")
        XCTAssertTrue(previewStrip.label.contains("working"), previewStrip.label)
        // With so little to show, Compact joins context and status on one line; Standard keeps two.
        let workspace = previewFact("Workspace shop-app")
        let status = previewFact("Done")
        XCTAssertLessThan(abs(workspace.frame.midY - status.frame.midY), 4, "Compact should join workspace and status on one line")
        setDensity("Standard")
        XCTAssertGreaterThan(abs(workspace.frame.midY - status.frame.midY), 8, "Standard keeps context and status on separate lines")
        setDensity("Compact")

        // Preview actions are inert.
        previewFact("Refactor checkout flow").tap()
        XCTAssertTrue(rowEditor.exists, "Tapping the preview must not navigate")
        XCTAssertFalse(app.buttons["chat.toolbar.files"].exists)
        XCTAssertFalse(app.staticTexts["thread.title"].exists)

        // Restore Defaults changes only the draft.
        restoreButton.tap()
        for (name, element) in facts { XCTAssertTrue(element.waitForExistence(timeout: 5), "Restore lacks \(name)") }
        XCTAssertTrue(densityButton("Standard").isSelected)
        XCTAssertFalse(restoreButton.isEnabled, "Restore is a no-op on defaults")

        // Cancel discards.
        setToggle("cost", on: false)
        try closeRowEditor("cancel")
        XCTAssertTrue(reveal(rootBody, in: inbox))
        XCTAssertTrue(rootBody.label.contains(rootCost), "Cancel changed saved rows: \(rootBody.label)")
        XCTAssertTrue(strip.label.contains("$"), "Cancel changed the saved strip: \(strip.label)")
        try openRowEditor()
        XCTAssertEqual(toggle("cost").value as? String, "1", "Cancelled draft was kept")

        // Swiping the sheet away discards too.
        setToggle("cost", on: false)
        let grabber = app.navigationBars["Customize Rows"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grabber.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(waitForNonExistence(rowEditor, timeout: 10), "Sheet did not dismiss")
        try returnToInbox()
        XCTAssertTrue(reveal(rootBody, in: inbox))
        XCTAssertTrue(rootBody.label.contains(rootCost), "Dismissal saved the draft: \(rootBody.label)")

        // Done saves exactly what the preview showed and applies to the mounted inbox.
        try openRowEditor()
        setToggle("cost", on: false)
        setToggle("laneGraph", on: false)
        setDensity("Compact")
        try closeRowEditor("done")
        XCTAssertTrue(reveal(rootBody, in: inbox))
        XCTAssertFalse(rootBody.label.contains(rootCost), "Saved Cost off still shows on the row: \(rootBody.label)")
        XCTAssertFalse(strip.label.contains("$"), "Hidden cost leaked into the strip: \(strip.label)")
        XCTAssertTrue(strip.label.contains("working"), "Strip lost who is working: \(strip.label)")

        // Workspace lists use the same renderer and saved choice.
        app.buttons["workspace.sidebar.open"].tap()
        XCTAssertTrue(revealWorkspace(named: "oppi"), "Workspace row missing")
        app.buttons["workspace.open.oppi"].coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()
        let workspaceRow = app.buttons["session.nav.\(orchestrator)"]
        XCTAssertTrue(reveal(workspaceRow, in: app.collectionViews["workspace.sessionList"], timeout: 20), "Workspace row missing")
        XCTAssertFalse(workspaceRow.label.contains(rootCost), "Workspace list ignored the saved choice: \(workspaceRow.label)")
        try returnToInbox()

        // Thread view memory and the saved layout, then relaunch.
        strip.tap()
        XCTAssertTrue(app.staticTexts["thread.title"].waitForExistence(timeout: 15))
        app.buttons["thread.mode.timeline"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(reveal(strip, in: inbox))
        strip.tap()
        XCTAssertTrue(app.buttons["thread.mode.timeline"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["thread.mode.timeline"].isSelected, "Thread view was not remembered on reopen")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        try setSessionThreads(false)
        let childRow = app.buttons["session.nav.\(donkeyMaster)"]
        XCTAssertTrue(reveal(childRow, in: inbox), "Flat List should list the child session as its own row")

        // Relaunch on the saved choice: a launch argument would override it.
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.terminate()
        app.launch()
        XCTAssertTrue(inbox.waitForExistence(timeout: 30), "Inbox did not return after relaunch")
        XCTAssertTrue(reveal(childRow, in: inbox, timeout: 30), "Saved Flat List layout did not survive relaunch")
        try setSessionThreads(true)
        XCTAssertTrue(reveal(strip, in: inbox, timeout: 30), "Threads layout did not return")
        XCTAssertFalse(childRow.exists, "Threads should fold the child session under its root")
        XCTAssertTrue(reveal(rootBody, in: inbox, timeout: 30))
        XCTAssertFalse(rootBody.label.contains(rootCost), "Saved row appearance did not survive relaunch: \(rootBody.label)")
        XCTAssertFalse(strip.label.contains("$"), strip.label)
        strip.tap()
        XCTAssertTrue(app.buttons["thread.mode.timeline"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["thread.mode.timeline"].isSelected, "Thread view did not survive relaunch")
        app.buttons["thread.mode.outline"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Leave the simulator's saved appearance at the defaults.
        try openRowEditor()
        XCTAssertEqual(toggle("cost").value as? String, "0", "Editor did not open on the saved choice")
        restoreButton.tap()
        try closeRowEditor("done")
        XCTAssertTrue(reveal(rootBody, in: inbox))
        XCTAssertTrue(rootBody.label.contains(rootCost), "Restored defaults did not return Cost: \(rootBody.label)")
    }

    /// Workspace lists follow the same Layout as All Sessions. A thread is listed once, in its
    /// root's workspace, and says how many workspaces it spans; its member in another workspace
    /// stays a row there with an In thread link that opens the same thread, whose Outline names
    /// that workspace. Flat List lists the child in the root's workspace again.
    func testWorkspaceListsShareLayoutAndMarkCrossWorkspaceThreads() throws {
        XCUIDevice.shared.orientation = .portrait
        let root = try id(Self.mirrorRootKey)
        let localChild = try id(Self.mirrorChildKey)
        let remoteChild = try id(Self.crossWorkspaceChildKey)
        let inbox = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 20), "Inbox missing")
        try setSessionThreads(true)

        // All Sessions: one thread row that names both workspaces.
        let inboxStrip = app.buttons["thread.nav.\(root)"]
        XCTAssertTrue(reveal(inboxStrip, in: inbox, timeout: 20), "Mirror thread strip missing from All Sessions")
        XCTAssertTrue(inboxStrip.label.contains("across 2 workspaces"), inboxStrip.label)
        XCTAssertFalse(app.buttons["session.nav.\(remoteChild)"].exists, "All Sessions must fold the remote child")

        // Root's workspace: the same thread row; its local child folds under it.
        let oppiList = try openWorkspaceList("oppi")
        let workspaceStrip = app.buttons["thread.nav.\(root)"]
        XCTAssertTrue(reveal(workspaceStrip, in: oppiList, timeout: 20), "Workspace list did not draw the Thread strip")
        XCTAssertTrue(workspaceStrip.label.contains("across 2 workspaces"), workspaceStrip.label)
        XCTAssertFalse(
            reveal(app.buttons["session.nav.\(localChild)"], in: oppiList, timeout: 3),
            "Threads layout must fold the child in its root's workspace"
        )
        try returnToInbox()

        // Other workspace: the child stays a row, linked to the thread by name and workspace.
        let kypuList = try openWorkspaceList(Self.crossWorkspaceName)
        let remoteRow = app.buttons["session.nav.\(remoteChild)"]
        XCTAssertTrue(reveal(remoteRow, in: kypuList, timeout: 20), "Remote child row missing from its own workspace")
        let link = app.buttons["thread.link.\(remoteChild)"]
        XCTAssertTrue(link.exists, "Remote child has no In thread link")
        XCTAssertTrue(link.label.contains("Daily upstream mirror sync") && link.label.contains("oppi"), link.label)
        XCTAssertFalse(app.buttons["thread.nav.\(root)"].exists, "The thread must not be drawn twice")

        link.tap()
        XCTAssertTrue(app.staticTexts["thread.title"].waitForExistence(timeout: 15), "In thread link did not open Thread detail")
        showOutline()
        let detail = app.collectionViews["thread.detail"]
        let outlineRow = app.buttons["thread.row.\(remoteChild)"]
        XCTAssertTrue(reveal(outlineRow, in: detail), "Remote child missing from the Outline")
        XCTAssertTrue(outlineRow.label.contains(Self.crossWorkspaceName), "Outline should name the other workspace: \(outlineRow.label)")
        let rootRow = app.buttons["thread.row.\(root)"]
        XCTAssertTrue(reveal(rootRow, in: detail))
        XCTAssertFalse(rootRow.label.contains("oppi"), "The root's own workspace is not repeated: \(rootRow.label)")
        try returnToInbox()

        // Flat List reaches workspace lists too.
        try setSessionThreads(false)
        let flatList = try openWorkspaceList("oppi")
        XCTAssertTrue(
            reveal(app.buttons["session.nav.\(localChild)"], in: flatList, timeout: 20),
            "Flat List should list the child in the workspace list"
        )
        XCTAssertFalse(app.buttons["thread.nav.\(root)"].exists, "Flat List draws no Thread strip")
        try returnToInbox()
        try setSessionThreads(true)
    }

    /// Session Threads is opt-in: with the experiment off All Sessions and workspace lists are
    /// flat, Settings has no Layout picker, and Customize Rows has no Thread options. Turning the
    /// Experiments toggle on brings back strips, Thread detail, and the Thread options.
    func testSessionThreadsStayOffUntilEnabledInSettings() throws {
        XCUIDevice.shared.orientation = .portrait
        let orchestrator = try id(Self.orchestratorKey)
        let donkeyMaster = try id(Self.donkeyMasterKey)
        let inbox = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 20), "Inbox missing")

        // Off: the child is its own row and nothing offers a thread.
        XCTAssertTrue(
            reveal(app.buttons["session.nav.\(donkeyMaster)"], in: inbox, timeout: 20),
            "Child session should be its own row while Session Threads is off"
        )
        XCTAssertFalse(app.buttons["thread.nav.\(orchestrator)"].exists, "Thread strip drawn while Session Threads is off")
        XCTAssertFalse(app.buttons["thread.link.\(donkeyMaster)"].exists, "In thread link drawn while Session Threads is off")

        openSettings()
        XCTAssertTrue(settingsSwitch("settings.sessionThreads").isHittable, "Experiments → Session Threads missing")
        XCTAssertEqual(app.switches["settings.sessionThreads"].value as? String, "0")
        XCTAssertFalse(app.buttons["settings.inboxListMode"].exists, "Layout picker should be gone")
        // Reopen Settings from the top: the switch sits below Customize Rows.
        try returnToInbox()
        try openRowEditor()
        XCTAssertTrue(toggle("cost").exists, "Row options missing")
        XCTAssertFalse(toggle("laneGraph").exists, "Thread options shown while Session Threads is off")
        XCTAssertFalse(toggle("agentSummary").exists, "Thread options shown while Session Threads is off")
        app.buttons["sessionRows.cancel"].tap()
        XCTAssertTrue(waitForNonExistence(rowEditor, timeout: 10), "Editor did not close")
        XCTAssertFalse(app.buttons["settings.inboxListMode"].exists, "Layout picker should be gone")

        // On (still in Settings after closing the editor): the same list folds the child under a Thread strip.
        let threadsSwitch = settingsSwitch("settings.sessionThreads")
        flip(threadsSwitch)
        XCTAssertEqual(threadsSwitch.value as? String, "1")
        try returnToInbox()
        let strip = app.buttons["thread.nav.\(orchestrator)"]
        XCTAssertTrue(reveal(strip, in: inbox, timeout: 20), "Thread strip missing after enabling Session Threads")
        XCTAssertFalse(app.buttons["session.nav.\(donkeyMaster)"].exists, "Child should fold under its root when enabled")
        strip.tap()
        XCTAssertTrue(app.staticTexts["thread.title"].waitForExistence(timeout: 15), "Thread detail did not open")
        try returnToInbox()

        try openRowEditor()
        revealInForm(toggle("laneGraph"))
        XCTAssertTrue(toggle("agentSummary").exists, "Thread options missing when enabled")
        try closeRowEditor("cancel")
        try setSessionThreads(false)
    }

    /// Thread detail's compose bar starts a session that joins the thread as a child of the root.
    func testThreadComposeStartsSessionInThread() throws {
        XCUIDevice.shared.orientation = .portrait
        let root = try id(Self.orchestratorKey)
        let inbox = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 20), "Inbox missing")
        try setSessionThreads(true)

        let strip = app.buttons["thread.nav.\(root)"]
        XCTAssertTrue(reveal(strip, in: inbox, timeout: 20), "Orchestrator thread strip missing")
        strip.tap()
        XCTAssertTrue(app.staticTexts["thread.title"].waitForExistence(timeout: 15), "Thread detail did not open")
        let before = try threadMemberIds(root: root)

        tap(app.buttons["workspace.quickSession.start"], named: "thread compose bar")
        let input = app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 30), "Quick Session did not open from the thread")
        let threadPill = app.buttons["quickSession.threadParent"]
        XCTAssertTrue(threadPill.waitForExistence(timeout: 5), "Quick Session does not show the thread it joins")
        XCTAssertTrue(threadPill.label.contains("Investigate Unfinished Sonnet Worktree"), threadPill.label)
        tap(input, named: "quick session input", timeout: 5)
        input.typeText("E2E_THREAD_COMPOSE")
        tap(app.buttons["chat.send"], named: "quick session send button", timeout: 5)
        XCTAssertTrue(
            app.buttons["chat.toolbar.files"].waitForExistence(timeout: 30),
            "Chat did not open after starting a session from the thread"
        )

        let deadline = Date().addingTimeInterval(20)
        var added: [String: Any]?
        while added == nil, Date() < deadline {
            added = try threadMembers(root: root).first { member in
                guard let id = member["id"] as? String else { return false }
                return !before.contains(id)
            }
            if added == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        }
        let child = try XCTUnwrap(added, "New session never joined the thread")
        XCTAssertEqual(child["parentSessionId"] as? String, root, "New session should be a child of the root")
        XCTAssertEqual(child["workspaceName"] as? String, "oppi", "New session should run in the root's workspace")
    }

    private func threadMembers(root: String) throws -> [[String: Any]] {
        let response = try e2eLabAPIJSON(method: "GET", path: "/sessions/\(root)/thread")
        return response["sessions"] as? [[String: Any]] ?? []
    }

    private func threadMemberIds(root: String) throws -> Set<String> {
        Set(try threadMembers(root: root).compactMap { $0["id"] as? String })
    }

    /// Opens a workspace's session list from the sidebar with its stopped groups expanded.
    private func openWorkspaceList(_ name: String) throws -> XCUIElement {
        app.buttons["workspace.sidebar.open"].tap()
        XCTAssertTrue(revealWorkspace(named: name), "Workspace \(name) missing from the sidebar")
        app.buttons["workspace.open.\(name)"].coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()
        let list = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(
            app.buttons["workspace.edit.open"].waitForExistence(timeout: 20) && list.waitForExistence(timeout: 20),
            "Workspace \(name) list did not open"
        )
        expandStoppedGroups(in: list, headerPrefix: "workspace.stoppedGroup.")
        return list
    }

    /// Row appearance saved in the editor also drives the workspace list's stopped-history rows.
    func testSavedRowAppearanceAppliesToWorkspaceStoppedHistoryRows() throws {
        XCUIDevice.shared.orientation = .portrait
        let stoppedRoot = try id(Self.stoppedRootKey)
        XCTAssertTrue(app.collectionViews["workspace.sessionList"].waitForExistence(timeout: 20), "Inbox missing")
        try resetRowDisplayToDefaults()

        // Control: with defaults the stopped history row shows its cost (15.49 in the replayed data).
        let before = try workspaceStoppedRowLabel(stoppedRoot)
        XCTAssertTrue(before.contains("$15.49"), "Default history row should show its cost: \(before)")
        XCTAssertTrue(before.contains("Stopped"), "Row should be the stopped session: \(before)")
        try returnToInbox()

        try openRowEditor()
        setToggle("cost", on: false)
        try closeRowEditor("done")

        let after = try workspaceStoppedRowLabel(stoppedRoot)
        XCTAssertFalse(after.contains("$15.49"), "Saved Cost off must apply to workspace history rows: \(after)")
        XCTAssertTrue(after.contains("Stopped"), "History row lost its status: \(after)")
        try assertStopped(stoppedRoot, "after only viewing its workspace history row")
        try returnToInbox()
        try resetRowDisplayToDefaults()
    }

    /// Opening the editor and discarding or saving leaves the inbox's own state alone: the
    /// stopped-day group a user toggled and an active search with its results.
    func testSearchAndStoppedGroupStateSurviveEditorDiscardAndSave() throws {
        XCUIDevice.shared.orientation = .portrait
        let donkey = try id(Self.donkeyMasterKey)
        let inbox = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 20), "Inbox missing")
        try resetRowDisplayToDefaults()

        // A stopped-day group in a state the user chose (the opposite of its default).
        let header = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.sessionList.")).firstMatch
        XCTAssertTrue(reveal(header, in: inbox, timeout: 20), "Stopped-day header missing")
        let defaultState = try XCTUnwrap(header.value as? String)
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2)).tap()
        let chosen = defaultState == "Expanded" ? "Collapsed" : "Expanded"
        XCTAssertTrue(waitForValue(header, chosen), "Header did not toggle to \(chosen)")

        try openRowEditor()
        setToggle("cost", on: false)
        try closeRowEditor("cancel")
        XCTAssertTrue(reveal(header, in: inbox))
        XCTAssertTrue(waitForValue(header, chosen), "Cancelling the editor changed the stopped-day group")

        try openRowEditor()
        setToggle("cost", on: false)
        try closeRowEditor("done")
        XCTAssertTrue(reveal(header, in: inbox))
        XCTAssertTrue(waitForValue(header, chosen), "Saving the editor changed the stopped-day group")
        try openRowEditor()
        restoreButton.tap()
        try closeRowEditor("done")

        // Active search: the query and its result rows survive discard and save, and results take the saved look.
        // The search field lives in the navigation drawer, which hides while the list is scrolled.
        let search = app.searchFields["Search sessions"]
        for _ in 0..<4 where !search.exists { inbox.swipeDown(velocity: .fast) }
        XCTAssertTrue(search.waitForExistence(timeout: 10), "Search field missing")
        search.tap()
        search.typeText("Donkey")
        let result = app.buttons["session.nav.\(donkey)"]
        XCTAssertTrue(result.waitForExistence(timeout: 20), "Search result row missing")
        XCTAssertTrue(result.label.contains("$2.17"), "Default search row should show its cost: \(result.label)")
        if app.keyboards.buttons["Search"].exists { app.keyboards.buttons["Search"].tap() }

        // While a search is active iOS hides the inbox top bar, so Settings is reached through the
        // sidebar edge gesture.
        try openRowEditor(viaEdgeSwipe: true)
        setToggle("cost", on: false)
        try closeRowEditor("cancel", returningUntil: search)
        XCTAssertEqual(search.value as? String, "Donkey", "Cancelling the editor changed the search query")
        XCTAssertTrue(result.waitForExistence(timeout: 10), "Search results vanished after Cancel")
        XCTAssertTrue(result.label.contains("$2.17"), "Cancel changed the saved look: \(result.label)")

        try openRowEditor(viaEdgeSwipe: true)
        XCTAssertEqual(toggle("cost").value as? String, "1", "Cancelled draft was kept")
        setToggle("cost", on: false)
        try closeRowEditor("done", returningUntil: search)
        XCTAssertEqual(search.value as? String, "Donkey", "Saving the editor changed the search query")
        XCTAssertTrue(result.waitForExistence(timeout: 10), "Search results vanished after Done")
        XCTAssertFalse(result.label.contains("$2.17"), "Search results ignored the saved choice: \(result.label)")

        try openRowEditor(viaEdgeSwipe: true)
        restoreButton.tap()
        try closeRowEditor("done", returningUntil: search)
        XCTAssertEqual(search.value as? String, "Donkey")
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.label.contains("$2.17"), "Restored defaults did not return Cost: \(result.label)")
    }

    // MARK: Customize Rows helpers

    private var rowEditor: XCUIElement { app.navigationBars["Customize Rows"] }
    private var previewBox: XCUIElement { app.descendants(matching: .any)["sessionRows.preview"] }
    private var previewStrip: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Thread with 3 child sessions")).firstMatch
    }

    /// Every optional fact the sample root can show. The relative time drifts while the test runs.
    private var previewFacts: [(name: String, element: XCUIElement)] {
        [
            ("cost", previewFact("$3.14")),
            ("context usage", previewFact("48%")),
            ("files touched", previewFact("7 files touched")),
            ("compactions", previewFact("2 compactions")),
            ("time", previewFact(label: "m ago")),
        ]
    }

    /// Facts whose full text Standard always shows, for the no-truncation check.
    private var fixedWidthFacts: [(name: String, element: XCUIElement)] {
        previewFacts.filter { $0.name != "time" } + [
            ("workspace", previewFact("Workspace shop-app")),
            ("model", previewFact(label: "sonnet")),
        ]
    }

    private func previewFact(_ label: String) -> XCUIElement {
        previewBox.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func previewFact(label fragment: String) -> XCUIElement {
        previewBox.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    private func toggle(_ id: String) -> XCUIElement { app.switches["sessionRows.toggle.\(id)"] }

    /// Opens Settings from the sidebar and its Customize Rows entry under Session List.
    private func openRowEditor(viaEdgeSwipe: Bool = false) throws {
        openSettings(viaEdgeSwipe: viaEdgeSwipe)
        try openRowEditorFromSettings()
    }

    private func openRowEditorFromSettings() throws {
        let entry = settingsRow("settings.customizeRows")
        XCTAssertTrue(entry.isHittable, "Customize Rows missing from Settings")
        entry.tap()
        XCTAssertTrue(rowEditor.waitForExistence(timeout: 10), "Customize Rows did not open from Settings")
        XCTAssertTrue(previewBox.waitForExistence(timeout: 10), "Preview missing")
    }

    /// Taps the editor's Cancel or Done, which returns to Settings, then pops back to All Sessions.
    private func closeRowEditor(_ action: String, returningUntil marker: XCUIElement? = nil) throws {
        app.buttons["sessionRows.\(action)"].tap()
        XCTAssertTrue(waitForNonExistence(rowEditor, timeout: 10), "Editor did not close")
        XCTAssertTrue(app.buttons["settings.customizeRows"].exists, "Closing the editor should return to Settings")
        try returnToInbox(until: marker)
    }

    /// Turns the Session Threads experiment (Settings → Experiments) on or off, then returns to All Sessions.
    private func setSessionThreads(_ enabled: Bool) throws {
        openSettings()
        let threadsSwitch = settingsSwitch("settings.sessionThreads")
        XCTAssertTrue(threadsSwitch.isHittable, "Session Threads toggle missing from Settings")
        if (threadsSwitch.value as? String == "1") != enabled {
            flip(threadsSwitch)
        }
        XCTAssertEqual(threadsSwitch.value as? String, enabled ? "1" : "0", "Session Threads toggle did not change")
        try returnToInbox()
    }

    private func openSettings(viaEdgeSwipe: Bool = false) {
        if viaEdgeSwipe {
            let list = app.collectionViews["workspace.sessionList"]
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        } else {
            app.buttons["workspace.sidebar.open"].tap()
        }
        let settings = app.buttons["workspace.settings.open"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "App Settings missing from the sidebar")
        settings.tap()
    }

    /// Scrolls Settings until the row is on screen.
    private func settingsRow(_ identifier: String) -> XCUIElement {
        let row = app.buttons[identifier]
        _ = row.waitForExistence(timeout: 5)
        for _ in 0..<8 where !row.exists || !row.isHittable { app.swipeUp() }
        // Settings may already be scrolled past the row (the Experiments section sits below it).
        for _ in 0..<8 where !row.exists || !row.isHittable { app.swipeDown() }
        return row
    }

    /// A Settings switch spans its whole row; the control sits at the trailing edge.
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    /// Scrolls Settings until the switch is on screen.
    private func settingsSwitch(_ identifier: String) -> XCUIElement {
        let row = app.switches[identifier]
        _ = row.waitForExistence(timeout: 5)
        for _ in 0..<12 where !row.exists || !row.isHittable { app.swipeUp() }
        return row
    }

    /// Scrolls the editor form until `element` can be tapped.
    private func revealInForm(_ element: XCUIElement) {
        let form = app.collectionViews["sessionRows.form"]
        for _ in 0..<5 where !element.isHittable { form.swipeUp() }
        for _ in 0..<5 where !element.isHittable { form.swipeDown() }
        XCTAssertTrue(element.isHittable, "\(element) is not reachable in the editor")
    }

    /// Restore Defaults sits below the toggles, so the form must scroll to it.
    private var restoreButton: XCUIElement {
        let button = app.buttons["sessionRows.restore"]
        revealInForm(button)
        return button
    }

    /// A leading drag also reveals the workspace sidebar; close it so the next gesture starts on the list.
    private func dismissSidebarIfOpen() {
        let opener = app.buttons["workspace.sidebar.open"]
        guard !opener.isHittable else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.50)).tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: opener)
        XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: 5), .completed, "Sidebar did not close")
    }

    private func densityButton(_ name: String) -> XCUIElement {
        let button = app.segmentedControls["sessionRows.density"].buttons[name]
        revealInForm(button)
        return button
    }

    private func setDensity(_ name: String) {
        densityButton(name).tap()
        XCTAssertTrue(densityButton(name).isSelected, "Density \(name) did not apply")
    }

    private func setToggle(_ id: String, on: Bool) {
        let control = toggle(id)
        revealInForm(control)
        if (control.value as? String == "1") != on {
            // The switch sits at the trailing edge of its row.
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", on ? "1" : "0"),
            object: control
        )
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 5), .completed, "Toggle \(id) did not change")
    }

    private func waitForFrameHeight(_ element: XCUIElement, below height: CGFloat, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.frame.height < height - 1 { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    /// Known start: earlier runs on this simulator may have saved a customization.
    private func resetRowDisplayToDefaults() throws {
        try openRowEditor()
        if restoreButton.isEnabled {
            restoreButton.tap()
            try closeRowEditor("done")
        } else {
            try closeRowEditor("cancel")
        }
    }

    /// Opens the "oppi" workspace list, opens its stopped groups, and returns a stopped row's label.
    private func workspaceStoppedRowLabel(_ sessionId: String) throws -> String {
        app.buttons["workspace.sidebar.open"].tap()
        XCTAssertTrue(revealWorkspace(named: "oppi"), "Workspace row missing")
        app.buttons["workspace.open.oppi"].coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()
        let list = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(list.waitForExistence(timeout: 20), "Workspace list missing")
        expandStoppedGroups(in: list, headerPrefix: "workspace.stoppedGroup.")
        let row = app.buttons["session.nav.\(sessionId)"]
        XCTAssertTrue(reveal(row, in: list, timeout: 20), "Workspace history row missing")
        return row.label
    }

    private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// The row's cost as shown, so the assertion is on the row's own text.
    private func costText(in label: String) throws -> String {
        let match = try XCTUnwrap(
            label.range(of: #"\$\d+\.\d{2}"#, options: .regularExpression),
            "Row shows no cost by default: \(label)"
        )
        return String(label[match])
    }

    private func assertStillOnInbox(_ what: String) {
        XCTAssertTrue(app.collectionViews["workspace.sessionList"].exists, "\(what) left the inbox")
        XCTAssertFalse(app.buttons["chat.toolbar.files"].exists, "\(what) opened a chat")
        XCTAssertFalse(app.staticTexts["thread.title"].exists, "\(what) opened Thread detail")
    }

    /// Stopped day groups start collapsed once they are old enough, and lazy lists only mount
    /// visible headers: walk the list and open every collapsed group.
    private func expandStoppedGroups(
        in list: XCUIElement? = nil,
        headerPrefix: String = "workspace.sessionList."
    ) {
        let inbox = list ?? app.collectionViews["workspace.sessionList"]
        for _ in 0..<3 { inbox.swipeDown(velocity: .fast) }
        for _ in 0..<10 {
            let headers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", headerPrefix))
            for index in 0..<headers.count {
                let header = headers.element(boundBy: index)
                // A short list leaves its last header partly under the bottom toolbar, where
                // isHittable is false; tap the header's uncovered top edge.
                if header.value as? String == "Collapsed", header.frame.minY < inbox.frame.maxY - 100 {
                    header.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2)).tap()
                }
            }
            let start = inbox.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            let end = inbox.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    /// Pops back to All Sessions, recognised by `marker` (the top-bar workspaces button by default;
    /// workspace lists do not show it).
    private func returnToInbox(until marker: XCUIElement? = nil) throws {
        let inbox = app.collectionViews["workspace.sessionList"]
        let marker = marker ?? app.buttons["workspace.sidebar.open"]
        for _ in 0..<4 {
            if marker.exists { return }
            if app.buttons["workspace.sidebar.showWorkspaces"].exists {
                app.buttons["workspace.sidebar.showWorkspaces"].tap()
            } else if app.navigationBars.buttons.element(boundBy: 0).exists {
                app.navigationBars.buttons.element(boundBy: 0).tap()
            }
            _ = inbox.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(marker.exists, "Could not return to All Sessions")
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
        showOutline()
        let detail = app.collectionViews["thread.detail"]

        // Outline: open the archived counterpart.
        let counterpart = app.descendants(matching: .any)["thread.counterpart.\(archived)"]
        XCTAssertTrue(reveal(counterpart, in: detail), "Archived counterpart row missing from the outline")
        XCTAssertTrue(counterpart.label.contains(Self.archivedCounterpartName), counterpart.label)
        counterpart.tap()
        try assertOpenedAsEndedHistory(archived, via: "outline")
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
        try assertOpenedAsEndedHistory(archived, via: "timeline")
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
        // Opening the stopped child is history-only too.
        finishedRow.tap()
        try assertOpenedAsEndedHistory(finishedFix, via: "finished child outline row")
        app.buttons["chat.toolbar.back"].tap()
        XCTAssertTrue(app.navigationBars["Thread"].waitForExistence(timeout: 10), "Back did not return to the thread")
        XCTAssertTrue(reveal(finishedRow, in: detail), "Stopped outline row missing after returning")
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

    /// Thread detail remembers its last view on this device; start from Outline explicitly.
    private func showOutline() {
        let outline = app.buttons["thread.mode.outline"]
        XCTAssertTrue(outline.waitForExistence(timeout: 10), "Thread view pill missing")
        if !outline.isSelected { outline.tap() }
    }

    /// The chat shows ended-session history with its Resume footer, and the session stays stopped.
    private func assertOpenedAsEndedHistory(_ sessionId: String, via: String) throws {
        XCTAssertTrue(
            app.buttons["chat.toolbar.files"].waitForExistence(timeout: 15),
            "Row (\(via)) did not open the session"
        )
        // Give an implicit stream open time to start the runtime before reading server state.
        beat(3)
        try assertStopped(sessionId, "after opening from \(via)")
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
        // Inbox and thread rows can sit under the bottom toolbar (compose bar), where taps and
        // swipes land on the toolbar instead. Scroll such a row up before returning it.
        func settled() -> Bool {
            guard ["workspace.sessionList", "thread.detail"].contains(list.identifier),
                  element.frame.height < list.frame.height / 2 else { return true }
            for _ in 0..<3 where element.frame.maxY > list.frame.maxY - 150 {
                let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
            return true
        }
        if element.waitForExistence(timeout: 1), onScreen() { return settled() }
        for _ in 0..<3 { list.swipeDown(velocity: .fast) }
        for _ in 0..<14 {
            if onScreen() { return settled() }
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: end)
            _ = element.waitForExistence(timeout: 0.6)
        }
        return onScreen() && settled()
    }

    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
