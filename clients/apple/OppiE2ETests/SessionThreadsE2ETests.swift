import XCTest

/// Session threads against a replay of real server data.
///
/// `Fixtures/session-threads-2026-09-29.json` is an export of the owner's
/// session state at 09:23 on 2026-09-29: names, models, costs, launch parents,
/// and statuses. Times keep their clock time when replayed on a later day.
@MainActor
final class SessionThreadsE2ETests: E2ETestCase {
    nonisolated(unsafe) private var workspaceIds: [String] = []
    nonisolated(unsafe) private var sessionIds: [String: String] = [:]
    nonisolated(unsafe) private var agentIds: [String] = []

    nonisolated private static let orchestratorKey = "d0dd7892-8366-4793-b923-debbc77c7ad3"
    private static let donkeyMasterKey = "0562cb98-a36a-432f-8ddd-48eed410ab73"
    private static let finishedFixKey = "7422b7a7-fe4c-4a8f-a41b-41562a6f2182"
    private static let reviewCleanupKey = "f7741ae5-2491-47a3-bb68-c0a0e57d32c0"
    /// A stopped root with stopped children: history-only from both inbox targets.
    private static let stoppedRootKey = "145f0dcd-266a-42fe-9f97-2f8e58672536"
    private static let stoppedRootChildKey = "608460ea-1677-4f17-9900-99815dff3766"
    /// Root of a stopped two-session thread in "oppi" (Daily upstream mirror sync).
    nonisolated private static let mirrorRootKey = "8bac488b-aa9a-416c-bddd-921a9c51ad8d"
    private static let mirrorChildKey = "2549460f-9896-478b-a1b5-bff6afce5e01"
    /// Synthetic: an idle child of the mirror thread launched into another workspace,
    /// so the thread spans two workspaces.
    nonisolated private static let crossWorkspaceChildKey = "synthetic-cross-workspace-child"
    nonisolated private static let crossWorkspaceName = "kypu"

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
        // Only the cross-workspace test gets the extra workspace and session, so
        // every other test replays the captured snapshot unchanged.
        if name.contains("testWorkspaceListsFoldThreadsAndLinkMembersToTheirRoot") { sessions.append([
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

    /// Folding is the default: a thread is one strip under its root, and tapping the strip lists
    /// every descendant as an indented row, each with its status, swipes, and its own chat.
    func testThreadStripExpandsEveryDescendantInlineAndCollapses() throws {
        let orchestrator = try id(Self.orchestratorKey)
        let donkeyMaster = try id(Self.donkeyMasterKey)
        let finishedFix = try id(Self.finishedFixKey)
        let inbox = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 20), "Inbox missing")
        beat(1)

        let strip = app.buttons["thread.nav.\(orchestrator)"]
        XCTAssertTrue(reveal(strip, in: inbox, timeout: 20), "Orchestrator thread strip missing")
        XCTAssertEqual(strip.value as? String, "Collapsed")
        XCTAssertTrue(
            strip.label.contains("working"),
            "An idle root with working children should summarize its working members: \(strip.label)"
        )
        XCTAssertFalse(
            app.buttons["session.nav.\(donkeyMaster)"].exists,
            "A collapsed thread should not list child sessions as rows"
        )

        // Expanded: every descendant is a row of its own, indented under the root.
        strip.tap()
        XCTAssertTrue(waitForValue(strip, "Expanded"), "Strip did not report Expanded")
        let rootBody = app.buttons["session.nav.\(orchestrator)"]
        XCTAssertTrue(reveal(rootBody, in: inbox), "Thread root row missing")
        // Read it now: revealing a child scrolls the list, and the root's cell may leave it.
        let rootMinX = rootBody.frame.minX
        let working = app.buttons["session.nav.\(donkeyMaster)"]
        XCTAssertTrue(reveal(working, in: inbox), "Expanding should list the working child")
        XCTAssertTrue(working.label.contains("Donkey Master"), working.label)
        XCTAssertGreaterThan(working.frame.minX, rootMinX + 8, "Child rows are indented under their root")
        let finished = app.buttons["session.nav.\(finishedFix)"]
        XCTAssertTrue(reveal(finished, in: inbox), "Expanding should list finished children too")
        XCTAssertTrue(finished.label.contains("Stopped"), "A child row keeps its status: \(finished.label)")
        beat(1.5)

        // A child row keeps the row's swipe actions.
        finished.swipeLeft()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 5), "A stopped child row did not offer Resume")
        XCTAssertFalse(app.buttons["chat.toolbar.files"].waitForExistence(timeout: 1), "Swiping a child row opened a chat")
        // A tap on a row with its actions open only closes them.
        finished.tap()
        XCTAssertTrue(waitForNonExistence(app.buttons["Resume"], timeout: 5), "Tap did not close the swipe actions")
        XCTAssertFalse(app.buttons["chat.toolbar.files"].waitForExistence(timeout: 1), "Closing the actions opened a chat")
        try assertStopped(finishedFix, "after swiping its row")

        // Tapping a child opens its own chat; the list keeps the thread open on return.
        XCTAssertTrue(reveal(finished, in: inbox), "Child row missing after its swipe closed")
        finished.tap()
        try assertOpenedAsEndedHistory(finishedFix, via: "finished child row")
        app.buttons["chat.toolbar.back"].tap()
        XCTAssertTrue(inbox.waitForExistence(timeout: 10), "Back did not return to the inbox")
        XCTAssertTrue(reveal(strip, in: inbox))
        XCTAssertEqual(strip.value as? String, "Expanded", "The thread closed while its child chat was open")

        // Collapsing folds the children away again.
        strip.tap()
        XCTAssertTrue(waitForValue(strip, "Collapsed"), "Strip did not report Collapsed")
        XCTAssertTrue(waitForNonExistence(app.buttons["session.nav.\(donkeyMaster)"], timeout: 5), "Collapse left the child row")
        XCTAssertTrue(waitForNonExistence(finished, timeout: 5))
        beat(1)
    }

    /// An idle thread root can be stopped from its row while its thread is expanded, and the
    /// stop reaches the server.
    func testExpandedThreadRootsKeepStopAndTheirStatus() throws {
        let reviewCleanup = try id(Self.reviewCleanupKey)
        let inbox = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 20), "Inbox missing")
        let strip = app.buttons["thread.nav.\(reviewCleanup)"]
        XCTAssertTrue(reveal(strip, in: inbox, timeout: 20), "Review cleanup thread strip missing")
        strip.tap()
        XCTAssertTrue(waitForValue(strip, "Expanded"), "Strip did not report Expanded")
        let rootRow = app.buttons["session.nav.\(reviewCleanup)"]
        XCTAssertTrue(reveal(rootRow, in: inbox), "Idle review root row missing")
        XCTAssertFalse(rootRow.label.contains("Stopped"), "Review root should start idle: \(rootRow.label)")
        rootRow.swipeLeft()
        let stop = app.buttons["Stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "Idle session row did not offer Stop")
        stop.tap()
        let stopped = expectation(description: "server records the stop")
        DispatchQueue.global().async { [self] in
            for _ in 0..<40 {
                if let status = try? e2eSession(sessionId: reviewCleanup)["status"] as? String, status == "stopped" {
                    stopped.fulfill()
                    return
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        wait(for: [stopped], timeout: 15)
        beat(1)
    }

    /// The root body opens the root's chat and only the labelled Thread strip folds the thread.
    /// They are separate targets, and swiping either one never navigates. Stopped roots and
    /// children open as ended history and stay stopped on the server.
    func testRootBodyAndThreadStripAreDisjointTargetsAndStoppedHistoryStaysStopped() throws {
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
            // UIKit swipe actions have no accessibility identifier; the open
            // swipe exposes them by their visible titles.
            target.swipeLeft()
            XCTAssertTrue(
                app.buttons["Stop"].waitForExistence(timeout: 5),
                "Trailing swipe on the \(name) did not expose Stop"
            )
            assertStillOnInbox("trailing swipe on the \(name)")
            target.swipeRight()
            XCTAssertTrue(waitForNonExistence(app.buttons["Stop"], timeout: 5), "Swipe did not close")
        }
        XCTAssertEqual(strip.value as? String, "Collapsed", "A swipe on the strip folded the thread")

        // One tap on the strip folds the thread open; it does not open the root chat.
        strip.tap()
        XCTAssertTrue(waitForValue(strip, "Expanded"), "Strip tap did not expand the thread")
        XCTAssertFalse(app.buttons["chat.toolbar.files"].exists, "Strip must not open the root chat")
        strip.tap()
        XCTAssertTrue(waitForValue(strip, "Collapsed"))

        // Stopped root: body tap is history-only; expanding its strip lists the stopped child, which is too.
        expandStoppedGroups()
        let stoppedBody = app.buttons["session.nav.\(stoppedRoot)"]
        XCTAssertTrue(reveal(stoppedBody, in: inbox, timeout: 20), "Stopped root body missing")
        stoppedBody.tap()
        try assertOpenedAsEndedHistory(stoppedRoot, via: "stopped root body")
        app.buttons["chat.toolbar.back"].tap()
        XCTAssertTrue(inbox.waitForExistence(timeout: 10), "Back did not return to the inbox")

        let stoppedStrip = app.buttons["thread.nav.\(stoppedRoot)"]
        XCTAssertTrue(reveal(stoppedStrip, in: inbox), "Stopped root Thread strip missing")
        stoppedStrip.tap()
        XCTAssertTrue(waitForValue(stoppedStrip, "Expanded"), "Stopped root strip did not expand")
        let childRow = app.buttons["session.nav.\(stoppedChild)"]
        XCTAssertTrue(reveal(childRow, in: inbox), "Stopped child row missing under its root")
        childRow.tap()
        try assertOpenedAsEndedHistory(stoppedChild, via: "stopped child")
        app.buttons["chat.toolbar.back"].tap()
        XCTAssertTrue(inbox.waitForExistence(timeout: 10), "Back did not return to the inbox")
        try assertStopped(stoppedRoot, "after opening its thread and child")
    }

    // MARK: - Session Rows

    /// Session Rows (Settings → Sessions): the controls repaint an inert preview from the
    /// production row and apply at once; leaving the page keeps the choice on the mounted inbox
    /// and workspace lists; the saved choice survives a relaunch.
    func testSessionRowsPreviewAppliesImmediatelyAcrossListsAndRelaunch() throws {
        let orchestrator = try id(Self.orchestratorKey)
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

        // Each control repaints the preview immediately.
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
        XCTAssertTrue(previewStrip.label.contains("Thread with 4 sessions"), previewStrip.label)
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

        // Restore Defaults returns every control to its default.
        restoreButton.tap()
        for (name, element) in facts { XCTAssertTrue(element.waitForExistence(timeout: 5), "Restore lacks \(name)") }
        XCTAssertTrue(densityButton("Standard").isSelected)
        XCTAssertFalse(restoreButton.isEnabled, "Restore is a no-op on defaults")

        // Leaving the page keeps exactly what the preview showed and applies to the mounted inbox.
        setToggle("cost", on: false)
        setToggle("laneGraph", on: false)
        setDensity("Compact")
        try closeRowEditor()
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

        // Relaunch on the saved choice.
        app.terminate()
        app.launch()
        XCTAssertTrue(inbox.waitForExistence(timeout: 30), "Inbox did not return after relaunch")
        XCTAssertTrue(reveal(strip, in: inbox, timeout: 30), "Thread strip did not return")
        XCTAssertTrue(reveal(rootBody, in: inbox, timeout: 30))
        XCTAssertFalse(rootBody.label.contains(rootCost), "Saved row appearance did not survive relaunch: \(rootBody.label)")
        XCTAssertFalse(strip.label.contains("$"), strip.label)

        // Leave the simulator's saved appearance at the defaults.
        try openRowEditor()
        XCTAssertEqual(toggle("cost").value as? String, "0", "Editor did not open on the saved choice")
        restoreButton.tap()
        try closeRowEditor()
        XCTAssertTrue(reveal(rootBody, in: inbox))
        XCTAssertTrue(rootBody.label.contains(rootCost), "Restored defaults did not return Cost: \(rootBody.label)")
    }

    /// A thread is listed once, in its root's workspace, and says how many workspaces it spans.
    /// Expanded, it lists its member from another workspace there too, naming that workspace.
    /// That member stays a row in its own workspace with an In thread link that opens the root.
    func testWorkspaceListsFoldThreadsAndLinkMembersToTheirRoot() throws {
        let root = try id(Self.mirrorRootKey)
        let localChild = try id(Self.mirrorChildKey)
        let remoteChild = try id(Self.crossWorkspaceChildKey)
        let inbox = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 20), "Inbox missing")

        // All Sessions: one thread row that names both workspaces.
        let inboxStrip = app.buttons["thread.nav.\(root)"]
        XCTAssertTrue(reveal(inboxStrip, in: inbox, timeout: 20), "Mirror thread strip missing from All Sessions")
        XCTAssertTrue(inboxStrip.label.contains("2 workspaces"), inboxStrip.label)
        XCTAssertFalse(app.buttons["session.nav.\(remoteChild)"].exists, "All Sessions must fold the remote child")

        // Root's workspace: the same thread row; its children list under it once expanded.
        let oppiList = try openWorkspaceList("oppi")
        let workspaceStrip = app.buttons["thread.nav.\(root)"]
        XCTAssertTrue(reveal(workspaceStrip, in: oppiList, timeout: 20), "Workspace list did not draw the Thread strip")
        XCTAssertTrue(workspaceStrip.label.contains("2 workspaces"), workspaceStrip.label)
        XCTAssertFalse(
            reveal(app.buttons["session.nav.\(localChild)"], in: oppiList, timeout: 3),
            "A collapsed thread must fold the child in its root's workspace"
        )
        // Looking for the folded child scrolled the list; bring the strip back first.
        XCTAssertTrue(reveal(workspaceStrip, in: oppiList), "Workspace thread strip missing")
        workspaceStrip.tap()
        XCTAssertTrue(waitForValue(workspaceStrip, "Expanded"), "Workspace strip did not expand")
        XCTAssertTrue(reveal(app.buttons["session.nav.\(localChild)"], in: oppiList), "Local child row missing once expanded")
        let remoteRow = app.buttons["session.nav.\(remoteChild)"]
        XCTAssertTrue(reveal(remoteRow, in: oppiList), "The member from another workspace is part of the thread")
        XCTAssertTrue(remoteRow.label.contains(Self.crossWorkspaceName), "The row should name its workspace: \(remoteRow.label)")
        try returnToInbox()

        // Other workspace: the child stays a row, linked to the thread by name and workspace.
        let kypuList = try openWorkspaceList(Self.crossWorkspaceName)
        let kypuRow = app.buttons["session.nav.\(remoteChild)"]
        XCTAssertTrue(reveal(kypuRow, in: kypuList, timeout: 20), "Remote child row missing from its own workspace")
        let link = app.buttons["thread.link.\(remoteChild)"]
        XCTAssertTrue(link.exists, "Remote child has no In thread link")
        XCTAssertTrue(link.label.contains("Daily upstream mirror sync") && link.label.contains("oppi"), link.label)
        XCTAssertFalse(app.buttons["thread.nav.\(root)"].exists, "The thread must not be drawn twice")

        // The link opens the thread's root chat.
        link.tap()
        XCTAssertTrue(
            app.buttons["chat.toolbar.files"].waitForExistence(timeout: 15),
            "In thread link did not open the root chat"
        )
        XCTAssertEqual(try e2eSession(sessionId: root)["status"] as? String, "stopped", "Opening the root must not start it")
    }

    /// Session Threads is always on, so Session Rows always offers the Thread options.
    func testSessionRowsAlwaysOfferThreadOptions() throws {
        let inbox = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 20), "Inbox missing")

        try openRowEditor()
        revealInForm(toggle("laneGraph"))
        XCTAssertTrue(toggle("agentSummary").exists, "Thread options missing from Session Rows")
        try closeRowEditor()
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
        try closeRowEditor()

        let after = try workspaceStoppedRowLabel(stoppedRoot)
        XCTAssertFalse(after.contains("$15.49"), "Saved Cost off must apply to workspace history rows: \(after)")
        XCTAssertTrue(after.contains("Stopped"), "History row lost its status: \(after)")
        try assertStopped(stoppedRoot, "after only viewing its workspace history row")
        try returnToInbox()
        try resetRowDisplayToDefaults()
    }

    /// Opening the editor and changing rows leaves the inbox's own state alone: the
    /// stopped-day group a user toggled and an active search with its results.
    func testSearchAndStoppedGroupStateSurviveRowEditing() throws {
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
        try closeRowEditor()
        XCTAssertTrue(reveal(header, in: inbox))
        XCTAssertTrue(waitForValue(header, chosen), "Editing rows changed the stopped-day group")
        try openRowEditor()
        restoreButton.tap()
        try closeRowEditor()

        // Active search: the query and its result rows survive row edits, and results take the saved look.
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
        try closeRowEditor(returningUntil: search)
        XCTAssertEqual(search.value as? String, "Donkey", "Editing rows changed the search query")
        XCTAssertTrue(result.waitForExistence(timeout: 10), "Search results vanished after editing rows")
        XCTAssertFalse(result.label.contains("$2.17"), "Search results ignored the saved choice: \(result.label)")

        try openRowEditor(viaEdgeSwipe: true)
        restoreButton.tap()
        try closeRowEditor(returningUntil: search)
        XCTAssertEqual(search.value as? String, "Donkey")
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.label.contains("$2.17"), "Restored defaults did not return Cost: \(result.label)")
    }

    // MARK: Session Rows helpers

    private var rowEditor: XCUIElement { app.navigationBars["Session Rows"] }
    private var previewBox: XCUIElement { app.descendants(matching: .any)["sessionRows.preview"] }
    private var previewStrip: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Thread with 4 sessions")).firstMatch
    }

    /// Every optional fact the sample root can show. The relative time drifts while the test runs.
    private var previewFacts: [(name: String, element: XCUIElement)] {
        [
            ("cost", previewFact("$3.14")),
            ("context usage", previewFact("48%")),
            // A session in the main checkout counts its files approximately; the sample has no worktree.
            ("files touched", previewFact("Approximately 7 files touched")),
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

    /// Opens Settings from the sidebar, then Sessions, which opens Session Rows.
    private func openRowEditor(viaEdgeSwipe: Bool = false) throws {
        openSettings(viaEdgeSwipe: viaEdgeSwipe)
        try openRowEditorFromSettings()
    }

    private func openRowEditorFromSettings() throws {
        openSettingsPage("sessions")
        XCTAssertTrue(rowEditor.waitForExistence(timeout: 10), "Session Rows did not open from Settings")
        XCTAssertTrue(previewBox.waitForExistence(timeout: 10), "Preview missing")
    }

    /// Goes back to Settings, then pops back to All Sessions.
    private func closeRowEditor(returningUntil marker: XCUIElement? = nil) throws {
        app.navigationBars["Session Rows"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitForNonExistence(rowEditor, timeout: 10), "Editor did not close")
        XCTAssertTrue(app.buttons["settings.row.sessions"].exists, "Closing the editor should return to Settings")
        try returnToInbox(until: marker)
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

    /// Pushes a section page from the Settings index (`settings.row.<page>`), scrolling to its row.
    private func openSettingsPage(_ page: String) {
        let row = app.buttons["settings.row.\(page)"]
        _ = row.waitForExistence(timeout: 5)
        for _ in 0..<8 where !row.exists || !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable, "Settings row \(page) is not reachable")
        row.tap()
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
        }
        try closeRowEditor()
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

    /// A stopped session opened from its expanded thread shows ended history.
    /// Only an explicit Resume may start a stopped session.
    func testStoppedThreadChildOpensWithoutStartingUntilExplicitResume() throws {
        let orchestrator = try id(Self.orchestratorKey)
        let finishedFix = try id(Self.finishedFixKey)
        try assertStopped(finishedFix, "before opening")

        let inbox = app.collectionViews["workspace.sessionList"]
        let strip = app.buttons["thread.nav.\(orchestrator)"]
        XCTAssertTrue(reveal(strip, in: inbox, timeout: 20), "Orchestrator thread strip missing")
        strip.tap()
        XCTAssertTrue(waitForValue(strip, "Expanded"), "Strip did not expand")
        let finishedRow = app.buttons["session.nav.\(finishedFix)"]
        XCTAssertTrue(reveal(finishedRow, in: inbox), "Stopped child row missing")
        XCTAssertTrue(finishedRow.label.contains("Stopped"), "Row should read stopped first: \(finishedRow.label)")
        // Opening the stopped child is history-only.
        finishedRow.tap()
        try assertOpenedAsEndedHistory(finishedFix, via: "finished child row")
        app.buttons["chat.toolbar.back"].tap()
        XCTAssertTrue(reveal(finishedRow, in: inbox), "Stopped child row missing after returning")
        try assertStopped(finishedFix, "before Resume")

        // Explicit Resume from the row's swipe is the only action that starts a runtime.
        finishedRow.swipeLeft()
        let resume = app.buttons["Resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "Stopped child row did not offer Resume")
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
        beat(2)
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
        // Inbox rows can sit under the bottom toolbar (compose bar), where taps and
        // swipes land on the toolbar instead. Scroll such a row up before returning it.
        func settled() -> Bool {
            guard list.identifier == "workspace.sessionList",
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
