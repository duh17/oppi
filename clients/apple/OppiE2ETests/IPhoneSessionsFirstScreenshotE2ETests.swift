import UIKit
import XCTest

/// iPhone screenshot lab for the sessions-first inbox.
///
/// Runs through the paired E2E server so the screenshot includes the same
/// pairing, workspace refresh, and session projection path as the app uses
/// outside preview mode.
@MainActor
final class IPhoneSessionsFirstScreenshotE2ETests: E2ETestCase {
    private let anchorWorkspaceName = "e2e-workspace"
    private let stoppedIncognitoSessionName = "Hidden Incognito Session"
    nonisolated(unsafe) private var swipeRegressionSessionId: String?
    nonisolated(unsafe) private var swipeRegressionStoppedSessionId: String?
    nonisolated(unsafe) private var themeSwitchSessionId: String?
    nonisolated(unsafe) private var activeScheduleId: String?
    nonisolated(unsafe) private var archivedScheduleId: String?
    nonisolated(unsafe) private var nativeEditorAgentId: String?
    nonisolated(unsafe) private var nativeEditorScheduleId: String?
    nonisolated(unsafe) private var customCronScheduleId: String?

    override var e2eLaunchesSessionsInboxOnly: Bool {
        true
    }

    override var e2eAutoCreatesSessionOnLaunch: Bool {
        false
    }

    override func configureE2ELaunch(_ application: XCUIApplication) {
        application.launchArguments += [
            "-dev.chenda.Oppi.theme.id", "light",
        ]
    }

    override func seedE2EFixtures() throws {
        let anchorWorkspaceId = try e2eWorkspaceId(named: anchorWorkspaceName)

        if name.contains("testThemeSwitchRefreshesMountedInboxAndSidebar") {
            themeSwitchSessionId = try createLabSessions(
                count: 1,
                workspaceId: anchorWorkspaceId,
                stopAfterCreate: false
            ).first
            _ = try createLabWorkspace(named: "Theme Switch Workspace")
        } else if name.contains("testSessionRowLeadingSwipeDoesNotNavigate") {
            swipeRegressionSessionId = try createLabSessions(
                count: 1,
                workspaceId: anchorWorkspaceId,
                stopAfterCreate: false
            ).first
            swipeRegressionStoppedSessionId = try createLabSessions(
                count: 1,
                workspaceId: anchorWorkspaceId,
                stopAfterCreate: true
            ).first
        } else if name.contains("testIPhoneAllActiveSessionsInboxScreenshot") {
            try createLabSessions(count: 1, workspaceId: anchorWorkspaceId, stopAfterCreate: false)
            let secondWorkspaceId = try createLabWorkspace(named: "Sidebar Review Queue")
            try createLabSessions(count: 1, workspaceId: secondWorkspaceId, stopAfterCreate: false)
        } else if name.contains("testIPhoneRecentStoppedSessionsInboxScreenshot") {
            try createLabSessions(count: 1, workspaceId: anchorWorkspaceId, stopAfterCreate: true)
            let response = try e2eLabAPIJSON(
                method: "POST",
                path: "/workspaces/\(anchorWorkspaceId)/sessions",
                body: [
                    "name": stoppedIncognitoSessionName,
                    "ephemeral": true,
                ]
            )
            let session = try XCTUnwrap(
                response["session"] as? [String: Any],
                "Incognito session create response missing session"
            )
            let sessionId = try XCTUnwrap(
                session["id"] as? String,
                "Incognito session create response missing id"
            )
            _ = try e2eLabAPIJSON(
                method: "POST",
                path: "/workspaces/\(anchorWorkspaceId)/sessions/\(sessionId)/stop"
            )
        } else if name.contains("testIPhoneAllSessionsSidebarEdgeSwipeScreenshot") {
            _ = try createLabWorkspace(named: "Sidebar Review Queue")
        } else if name.contains("testIPhoneWorkspaceScopedSeparateControlsScreenshot") {
            try createLabSessions(count: 1, workspaceId: anchorWorkspaceId, stopAfterCreate: false)
            try createLabSessions(count: 2, workspaceId: anchorWorkspaceId, stopAfterCreate: true)
        } else if name.contains("testIPhoneHierarchicalBackSwipeNavigation") {
            try createLabSessions(count: 1, workspaceId: anchorWorkspaceId, stopAfterCreate: false)
        } else if name.contains("testIPhoneWorkspaceSidebarScrolls") {
            for index in 1...18 {
                _ = try createLabWorkspace(named: "Scroll Workspace \(index)")
            }
        } else if name.contains("testNativeAgentEditorSavesReplacePromptAndThinking") {
            let response = try e2eLabAPIJSON(
                method: "POST",
                path: "/agents",
                body: [
                    "name": "Native editor reviewer",
                    "instructions": [
                        "mode": "append",
                        "text": "Review carefully.",
                    ],
                    "sessionDefaults": ["thinkingLevel": "medium"],
                ]
            )
            let agent = try XCTUnwrap(response["agent"] as? [String: Any])
            nativeEditorAgentId = try XCTUnwrap(agent["id"] as? String)
        } else if name.contains("testNativeScheduleEditorSavesThinkingAndPrompt") {
            nativeEditorScheduleId = try createScheduleFixture(
                name: "Native schedule editor",
                expression: "0 7 * * *",
                workspaceId: anchorWorkspaceId
            )
        } else if name.contains("testNativeCustomScheduleEditorScreenshot") {
            customCronScheduleId = try createScheduleFixture(
                name: "Custom cron editor",
                expression: "0 7 1 * *",
                workspaceId: anchorWorkspaceId
            )
        } else if name.contains("testScheduleScreenCreatesAndRestoresWithSimpleControls") {
            activeScheduleId = try createScheduleFixture(
                name: "Daily telemetry review",
                expression: "0 7 * * *",
                workspaceId: anchorWorkspaceId
            )
            let archivedId = try createScheduleFixture(
                name: "Archived smoke test",
                expression: "30 9 * * 1",
                workspaceId: anchorWorkspaceId
            )
            archivedScheduleId = archivedId
            _ = try e2eLabAPIJSON(method: "POST", path: "/schedules/\(archivedId)/archive")
        }
    }

    func testSessionRowLeadingSwipeDoesNotNavigate() throws {
        XCUIDevice.shared.orientation = .portrait

        let sessionId = try XCTUnwrap(swipeRegressionSessionId, "Swipe regression session was not seeded")
        let stoppedSessionId = try XCTUnwrap(
            swipeRegressionStoppedSessionId,
            "Stopped swipe regression session was not seeded"
        )
        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(sessionList.waitForExistence(timeout: 15), "iPhone sessions inbox did not appear")
        sessionList.swipeDown()

        let row = app.buttons["session.nav.\(sessionId)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Seeded session row did not appear")

        row.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.50))
            .press(
                forDuration: 0.05,
                thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.50))
            )

        XCTAssertTrue(sessionList.exists, "Leading session-row swipe navigated away from All Sessions")
        XCTAssertFalse(app.collectionViews["chat.timeline"].exists, "Leading session-row swipe opened chat")

        row.swipeLeft()
        XCTAssertTrue(
            app.buttons["session.stop.\(sessionId)"].waitForExistence(timeout: 5),
            "Trailing session-row swipe did not expose Stop"
        )
        row.swipeRight()

        let stoppedRow = app.buttons["session.nav.\(stoppedSessionId)"]
        XCTAssertTrue(stoppedRow.waitForExistence(timeout: 10), "Seeded stopped session row did not appear")
        stoppedRow.swipeLeft()
        XCTAssertTrue(
            app.buttons["session.resume.\(stoppedSessionId)"].waitForExistence(timeout: 5),
            "Trailing stopped-session swipe did not expose Resume"
        )
        XCTAssertTrue(
            app.buttons["session.delete.\(stoppedSessionId)"].waitForExistence(timeout: 5),
            "Trailing stopped-session swipe did not expose Delete"
        )
        stoppedRow.swipeRight()

        tap(row, named: "session row")
        XCTAssertTrue(
            app.collectionViews["chat.timeline"].waitForExistence(timeout: 15),
            "Tapping the session row did not open chat"
        )
    }

    func testIPhoneAllActiveSessionsInboxScreenshot() throws {
        XCUIDevice.shared.orientation = .portrait

        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(sessionList.waitForExistence(timeout: 15), "iPhone sessions inbox did not appear")
        sessionList.swipeDown()

        XCTAssertTrue(
            app.staticTexts[anchorWorkspaceName].waitForExistence(timeout: 20)
                || app.staticTexts["Sidebar Review Queue"].waitForExistence(timeout: 2)
                || app.staticTexts["Screenshot Lab Session 1"].waitForExistence(timeout: 2),
            "Seeded iPhone active session rows did not appear after refresh"
        )
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Current server:")).firstMatch.waitForExistence(timeout: 10),
            "Server switcher pill did not appear on the right side of the sessions inbox"
        )

        try saveLabScreenshot(name: "iphone-all-active-sessions-inbox-e2e")
    }

    func testServerMenuShowsOneConsolidatedConnectionStatus() throws {
        XCUIDevice.shared.orientation = .portrait

        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(sessionList.waitForExistence(timeout: 15), "iPhone sessions inbox did not appear")
        let serverSwitcher = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Current server:")
        ).firstMatch
        tap(serverSwitcher, named: "server switcher", timeout: 10)

        let consolidatedStatus = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Connected via paired HTTP")
        )
        XCTAssertTrue(
            consolidatedStatus.firstMatch.waitForExistence(timeout: 5),
            "Server menu did not show the connected state and active route in one row"
        )
        XCTAssertEqual(consolidatedStatus.count, 1, "Server menu duplicated the consolidated status row")
        XCTAssertFalse(
            app.descendants(matching: .any)["Connected"].exists,
            "Server menu retained the redundant generic Connected row"
        )

        try saveLabScreenshot(name: "iphone-server-menu-consolidated-connection-e2e")
    }

    func testThemeSwitchRefreshesMountedInboxAndSidebar() throws {
        XCUIDevice.shared.orientation = .portrait

        let sessionId = try XCTUnwrap(themeSwitchSessionId, "Theme-switch session was not seeded")
        let sessionRow = app.buttons["session.nav.\(sessionId)"]
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 15), "Theme-switch session row did not appear")

        selectManualTheme("OLED")
        openWorkspaceSidebar()

        let workspaceRow = app.buttons["workspace.open.Theme Switch Workspace"]
        XCTAssertTrue(workspaceRow.waitForExistence(timeout: 10), "Theme-switch workspace row did not appear")
        XCTAssertGreaterThan(
            pixelFraction(in: workspaceRow.screenshot().image, crop: CGRect(x: 0.20, y: 0, width: 0.58, height: 1)) { $0 > 0.35 },
            0.005,
            "Sidebar text retained low-luminance Light theme colors after switching to OLED"
        )
        try saveLabScreenshot(name: "iphone-theme-switch-oled-sidebar-e2e")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.50)).tap()
        XCTAssertTrue(
            waitForHittable(app.buttons["workspace.sidebar.open"], timeout: 5),
            "Sidebar did not close before switching back to Light"
        )

        selectManualTheme("Light")
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 10), "Session row did not return after theme switch")
        XCTAssertGreaterThan(
            pixelFraction(in: sessionRow.screenshot().image, crop: CGRect(x: 0.03, y: 0, width: 0.70, height: 0.42)) { $0 < 0.35 },
            0.005,
            "Session text retained high-luminance OLED colors after switching to Light"
        )
        try saveLabScreenshot(name: "iphone-theme-switch-light-inbox-e2e")
    }

    func testIPhoneRecentStoppedSessionsInboxScreenshot() throws {
        XCUIDevice.shared.orientation = .portrait

        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(sessionList.waitForExistence(timeout: 15), "iPhone sessions inbox did not appear")
        sessionList.swipeDown()

        let stoppedHeader = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "workspace.sessionList.stopped-day-")
        ).firstMatch
        XCTAssertTrue(stoppedHeader.waitForExistence(timeout: 15), "Recent stopped section did not appear")

        let stoppedRowTitle = app.staticTexts.matching(identifier: "Screenshot Lab Session 1").firstMatch
        XCTAssertTrue(stoppedRowTitle.waitForExistence(timeout: 10), "Today's stopped session was not expanded")
        XCTAssertFalse(
            app.staticTexts[stoppedIncognitoSessionName].exists,
            "Stopped incognito session should disappear from All Sessions"
        )
        XCTAssertTrue(
            waitForStableFrame(of: stoppedRowTitle, timeout: 2),
            "Stopped session row did not settle before screenshot capture"
        )
        try saveLabScreenshot(name: "iphone-recent-stopped-sessions-inbox-e2e")

        tap(stoppedHeader, named: "recent stopped section")
        let rowCollapsed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: stoppedRowTitle
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [rowCollapsed], timeout: 5),
            .completed,
            "Recent stopped section did not collapse"
        )
    }

    func testIPhoneAllSessionsSidebarEdgeSwipeScreenshot() throws {
        XCUIDevice.shared.orientation = .portrait

        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(sessionList.waitForExistence(timeout: 15), "iPhone sessions inbox did not appear")
        sessionList.swipeDown()

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.50))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.50))
            )
        let createWorkspaceButton = app.buttons["workspace.create.sidebar.open"]
        if !waitForHittable(createWorkspaceButton, timeout: 2) {
            tap(app.buttons["workspace.sidebar.open"], named: "workspace sidebar button")
        }
        XCTAssertTrue(waitForHittable(createWorkspaceButton, timeout: 10), "Sidebar did not open")
        XCTAssertFalse(app.buttons["workspace.sidebar.close"].exists, "Sidebar should not show a redundant close button")
        XCTAssertTrue(app.staticTexts["Oppi"].exists, "Sidebar should identify the app-level navigation surface")
        XCTAssertTrue(app.staticTexts["Workspaces"].exists, "Sidebar should label the workspace collection")
        XCTAssertTrue(
            waitForHittable(app.buttons["workspace.agents.open"], timeout: 5),
            "Agents destination missing from the sidebar"
        )
        XCTAssertTrue(
            waitForHittable(app.buttons["workspace.schedules.open"], timeout: 5),
            "Schedules destination missing from the sidebar"
        )
        XCTAssertTrue(
            waitForHittable(app.buttons["workspace.create.sidebar.open"], timeout: 5),
            "New Workspace must remain reachable in the sidebar footer"
        )
        XCTAssertTrue(
            waitForHittable(app.buttons["workspace.settings.open"], timeout: 5),
            "App Settings must be pinned below New Workspace"
        )

        try saveLabScreenshot(name: "iphone-sidebar-agents-schedules-e2e")

        tap(app.buttons["workspace.sidebar.disclosure"], named: "Workspaces disclosure")
        XCTAssertFalse(
            app.buttons["workspace.open.\(anchorWorkspaceName)"].exists,
            "Collapsed Workspaces section must hide workspace rows"
        )
        XCTAssertTrue(
            waitForHittable(createWorkspaceButton, timeout: 5),
            "New Workspace must remain reachable while Workspaces is collapsed"
        )
        XCTAssertTrue(
            waitForHittable(app.buttons["workspace.settings.open"], timeout: 5),
            "App Settings must remain reachable while Workspaces is collapsed"
        )
        try saveLabScreenshot(name: "iphone-sidebar-workspaces-collapsed-e2e")
        tap(app.buttons["workspace.sidebar.disclosure"], named: "Workspaces disclosure")
        XCTAssertTrue(
            app.buttons["workspace.open.\(anchorWorkspaceName)"].waitForExistence(timeout: 5),
            "Workspaces disclosure did not expand again"
        )

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.50))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.50))
            )
        XCTAssertTrue(
            waitForNotHittable(createWorkspaceButton, timeout: 5),
            "Left swipe did not dismiss the workspace sidebar"
        )
    }

    func testAgentGuidedComposerLaunchesExistingControlSessionTimeline() throws {
        XCUIDevice.shared.orientation = .portrait

        openWorkspaceSidebar()
        tap(app.buttons["workspace.agents.open"], named: "Agents sidebar destination")
        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 10))

        XCTAssertFalse(app.buttons["agents.create.open"].exists, "Manual Agent creation button must be absent")
        XCTAssertTrue(app.buttons["guided.agents.create.workspacePicker"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["session.toolbar.model"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["session.toolbar.thinking"].waitForExistence(timeout: 10))
        if app.buttons["chat.voiceInput"].exists {
            XCTAssertTrue(app.buttons["chat.voiceInput"].isHittable, "Agent composer dictation was not usable")
        }

        let composer = app.textViews["chat.input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Agent guided composer did not appear")
        composer.tap()
        composer.typeText("Create a release reviewer")
        tap(app.buttons["chat.send"], named: "Agent guided prompt send")

        XCTAssertTrue(
            app.navigationBars["Agent: Create a release reviewer"].waitForExistence(timeout: 15),
            "Control session did not open in the existing chat destination"
        )
        XCTAssertTrue(
            app.textViews["chat.input"].waitForExistence(timeout: 15),
            "Existing chat composer did not appear for the control session"
        )
        XCTAssertFalse(
            app.buttons["chat.toolbar.files"].exists,
            "Workspace-only Files control must stay absent from a control session"
        )
        try saveLabScreenshot(name: "iphone-control-session-existing-chat-e2e")
    }

    func testNativeAgentEditorSavesReplacePromptAndThinking() throws {
        XCUIDevice.shared.orientation = .portrait

        let agentId = try XCTUnwrap(nativeEditorAgentId, "Native editor Agent was not seeded")
        openWorkspaceSidebar()
        tap(app.buttons["workspace.agents.open"], named: "Agents sidebar destination")
        tap(app.buttons["agents.row.\(agentId)"], named: "native editor Agent", timeout: 10)
        tap(app.buttons["agents.detail.edit"], named: "native Agent Edit", timeout: 10)

        XCTAssertTrue(app.navigationBars["Edit Agent"].waitForExistence(timeout: 10))
        let promptMode = app.segmentedControls["agent.nativeEdit.promptMode"]
        XCTAssertTrue(promptMode.waitForExistence(timeout: 5), "Append/Replace control did not appear")
        tap(promptMode.buttons["Replace"], named: "Replace prompt mode")
        XCTAssertTrue(promptMode.buttons["Replace"].isSelected)
        XCTAssertTrue(app.buttons["agent.nativeEdit.model"].exists, "Model picker did not appear")
        XCTAssertTrue(app.buttons["agent.nativeEdit.thinking"].exists, "Thinking picker did not appear")

        tap(app.buttons["agent.nativeEdit.thinking"], named: "Agent thinking picker")
        tap(app.buttons["Max"], named: "Max Agent thinking")
        replaceText(in: app.textViews["agent.nativeEdit.prompt"], with: "Use only native instructions.")
        try saveLabScreenshot(name: "iphone-native-agent-editor-e2e")
        tap(app.buttons["agent.nativeEdit.save"], named: "Save native Agent edit")
        XCTAssertTrue(app.navigationBars["Native editor reviewer"].waitForExistence(timeout: 10))

        let response = try e2eLabAPIJSON(method: "GET", path: "/agents/\(agentId)")
        let storedAgent = try XCTUnwrap(response["agent"] as? [String: Any])
        let definition = try XCTUnwrap(storedAgent["definition"] as? [String: Any])
        let instructions = try XCTUnwrap(definition["instructions"] as? [String: Any])
        let defaults = try XCTUnwrap(definition["sessionDefaults"] as? [String: Any])
        XCTAssertEqual(instructions["mode"] as? String, "replace")
        XCTAssertEqual(instructions["text"] as? String, "Use only native instructions.")
        XCTAssertEqual(defaults["thinkingLevel"] as? String, "max")
    }

    func testNativeScheduleEditorSavesThinkingAndPrompt() throws {
        XCUIDevice.shared.orientation = .portrait

        let scheduleId = try XCTUnwrap(nativeEditorScheduleId, "Native editor schedule was not seeded")
        openWorkspaceSidebar()
        tap(app.buttons["workspace.schedules.open"], named: "Schedules sidebar destination")
        tap(app.buttons["schedules.row.\(scheduleId)"], named: "native editor schedule", timeout: 10)
        tap(app.buttons["schedule.detail.nativeEdit"], named: "native Schedule Edit", timeout: 10)

        XCTAssertTrue(app.navigationBars["Edit Schedule"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["schedule.nativeEdit.cadence"].exists)
        XCTAssertTrue(app.buttons["schedule.nativeEdit.timeZone"].exists)
        replaceText(in: app.textViews["schedule.nativeEdit.prompt"], with: "Run the edited native briefing.")
        app.swipeUp()
        XCTAssertTrue(app.buttons["schedule.nativeEdit.model"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["schedule.nativeEdit.thinking"].waitForExistence(timeout: 5))
        tap(app.buttons["schedule.nativeEdit.thinking"], named: "Schedule thinking picker")
        tap(app.buttons["High"], named: "High Schedule thinking")
        try saveLabScreenshot(name: "iphone-native-schedule-editor-e2e")
        tap(app.buttons["schedule.nativeEdit.save"], named: "Save native Schedule edit")
        XCTAssertTrue(app.navigationBars["Native schedule editor"].waitForExistence(timeout: 10))

        let response = try e2eLabAPIJSON(method: "GET", path: "/schedules/\(scheduleId)")
        let storedSchedule = try XCTUnwrap(response["schedule"] as? [String: Any])
        let action = try XCTUnwrap(storedSchedule["action"] as? [String: Any])
        XCTAssertEqual(action["prompt"] as? String, "Run the edited native briefing.")
        XCTAssertEqual(action["thinkingLevel"] as? String, "high")
    }

    func testNativeCustomScheduleEditorScreenshot() throws {
        XCUIDevice.shared.orientation = .portrait

        let scheduleId = try XCTUnwrap(customCronScheduleId, "Custom cron schedule was not seeded")
        openWorkspaceSidebar()
        tap(app.buttons["workspace.schedules.open"], named: "Schedules sidebar destination")
        tap(app.buttons["schedules.row.\(scheduleId)"], named: "custom cron schedule", timeout: 10)
        tap(app.buttons["schedule.detail.nativeEdit"], named: "native Schedule Edit", timeout: 10)

        XCTAssertTrue(app.navigationBars["Edit Schedule"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["schedule.nativeEdit.cronExpression"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons["schedule.nativeEdit.timeZone"].isEnabled,
            "Custom schedule time zone remained disabled"
        )
        try saveLabScreenshot(name: "iphone-native-schedule-custom-cron-editor-e2e")
    }

    func testScheduleScreenCreatesAndRestoresWithSimpleControls() throws {
        XCUIDevice.shared.orientation = .portrait

        let activeId = try XCTUnwrap(activeScheduleId, "Active schedule was not seeded")
        let archivedId = try XCTUnwrap(archivedScheduleId, "Archived schedule was not seeded")
        openWorkspaceSidebar()
        tap(app.buttons["workspace.schedules.open"], named: "Schedules sidebar destination")
        XCTAssertTrue(app.navigationBars["Schedules"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.buttons["schedules.row.\(activeId)"].waitForExistence(timeout: 10),
            "Active schedule card did not appear"
        )
        XCTAssertFalse(
            app.buttons["schedules.row.\(archivedId)"].exists,
            "Archived schedule should be hidden by default"
        )
        XCTAssertFalse(app.buttons["schedules.more"].exists, "Manual Schedule creation menu must be absent")
        XCTAssertTrue(app.buttons["guided.schedules.create.workspacePicker"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["session.toolbar.model"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["session.toolbar.thinking"].waitForExistence(timeout: 10))
        if app.buttons["chat.voiceInput"].exists {
            XCTAssertTrue(app.buttons["chat.voiceInput"].isHittable, "Schedule composer dictation was not usable")
        }

        tap(app.buttons["schedules.row.\(activeId)"], named: "active schedule detail")
        let whenLabel = app.staticTexts["schedule.detail.when"]
        XCTAssertTrue(whenLabel.waitForExistence(timeout: 10), "Human when label missing on schedule detail")
        let whenText = whenLabel.label.lowercased()
        XCTAssertFalse(whenText.contains("cron"), "Detail still surfaces cron syntax: \(whenLabel.label)")
        XCTAssertFalse(whenText.contains("* * *"), "Detail still surfaces cron fields: \(whenLabel.label)")
        XCTAssertTrue(
            app.switches["schedule.detail.enabled"].waitForExistence(timeout: 5),
            "Enabled toggle missing on schedule detail"
        )
        XCTAssertTrue(
            app.buttons["schedule.detail.edit"].waitForExistence(timeout: 5),
            "Edit with Oppi missing on schedule detail"
        )
        try saveLabScreenshot(name: "iphone-schedule-detail-human-when-e2e")

        tap(app.buttons["schedule.detail.edit"], named: "guided schedule revision")
        XCTAssertTrue(app.navigationBars["Revise Daily telemetry review"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["schedule.edit.save"].exists, "Schedule revision must not expose the manual form")
        tap(app.buttons["Cancel"], named: "dismiss guided revision")
        tap(app.navigationBars["Daily telemetry review"].buttons.firstMatch, named: "schedule detail back button")

        tap(app.buttons["schedules.filter"], named: "schedule status filter")
        tap(app.buttons["Archived"], named: "Archived schedules")
        let archivedRow = app.buttons["schedules.row.\(archivedId)"]
        XCTAssertTrue(archivedRow.waitForExistence(timeout: 10), "Archived schedule was not recoverable")
        archivedRow.swipeLeft()
        tap(app.buttons["Restore"], named: "Restore archived schedule")
        XCTAssertTrue(
            app.buttons["schedules.row.\(archivedId)"].waitForExistence(timeout: 10),
            "Restored schedule did not return to Active"
        )

        try saveLabScreenshot(name: "iphone-simple-schedules-e2e")

        let expectedWorkspaceId = try e2eWorkspaceId()
        tap(app.buttons["session.toolbar.model"], named: "schedule model picker")
        let modelTitle = app.staticTexts["E2E oMLX Model"]
        XCTAssertTrue(modelTitle.waitForExistence(timeout: 20), "Schedule model picker had no model")
        let modelIdentifier = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "omlx/")
        ).firstMatch
        XCTAssertTrue(modelIdentifier.waitForExistence(timeout: 5), "Schedule model ID was not visible")
        let selectedModel = modelIdentifier.label
        tap(modelTitle, named: "schedule model")
        tap(app.buttons["session.toolbar.thinking"], named: "schedule thinking picker")
        tap(app.buttons["session.toolbar.thinking.option.high"], named: "High schedule thinking")

        let composer = app.textViews["chat.input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Schedule prompt composer did not appear")
        composer.tap()
        composer.typeText("Brief me on coaching trends every Monday morning")
        tap(app.buttons["chat.send"], named: "schedule prompt send")

        XCTAssertTrue(
            app.navigationBars["Schedule: Brief me on coaching trends every Monday morning"].waitForExistence(timeout: 15),
            "Schedule prompt did not open the control session"
        )
        XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout: 15))
        let sessionId = waitForFocusedSessionId(timeout: 20)
        let session = try e2eSession(sessionId: sessionId)
        XCTAssertNil(session["workspaceId"], "Workspace context must not bind the control-session runtime")
        XCTAssertEqual(session["thinkingLevel"] as? String, "high")
        let actualModel = try XCTUnwrap(session["model"] as? String)
        XCTAssertTrue(actualModel == selectedModel || selectedModel.hasSuffix("/\(actualModel)"))
        XCTAssertTrue(
            (session["firstMessage"] as? String)?.contains("Canonical workspace ID: \(expectedWorkspaceId)") == true,
            "Tailored prompt did not include canonical workspace context"
        )
    }

    func testIPhoneSidebarAgentsAndSchedulesNavigate() throws {
        XCUIDevice.shared.orientation = .portrait

        openWorkspaceSidebar()
        tap(app.buttons["workspace.agents.open"], named: "Agents sidebar destination")
        XCTAssertTrue(
            app.navigationBars["Agents"].waitForExistence(timeout: 10),
            "Agents management did not open from the compact sidebar"
        )

        tap(app.navigationBars["Agents"].buttons.firstMatch, named: "Agents back button")
        XCTAssertTrue(
            app.collectionViews["workspace.sessionList"].waitForExistence(timeout: 10),
            "Sessions inbox did not return after leaving Agents"
        )

        openWorkspaceSidebar()
        tap(app.buttons["workspace.schedules.open"], named: "Schedules sidebar destination")
        XCTAssertTrue(
            app.navigationBars["Schedules"].waitForExistence(timeout: 10),
            "Schedules management did not open from the compact sidebar"
        )
    }

    func testIPhoneWorkspaceScopedSeparateControlsScreenshot() throws {
        XCUIDevice.shared.orientation = .portrait
        openAnchorWorkspace()

        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(sessionList.waitForExistence(timeout: 15), "Workspace-scoped sessions inbox did not appear")
        XCTAssertTrue(app.buttons["All Sessions"].waitForExistence(timeout: 10), "Native All Sessions back button missing")
        XCTAssertTrue(app.buttons["workspace.files.open"].waitForExistence(timeout: 10), "Workspace files button missing")
        XCTAssertTrue(app.buttons["workspace.newSession"].waitForExistence(timeout: 10), "New session button missing")

        try saveLabScreenshot(name: "iphone-workspace-scoped-separated-controls-e2e")

        swipeBack()
        XCTAssertTrue(app.staticTexts["All Sessions"].waitForExistence(timeout: 5), "Edge swipe did not return to All Sessions")
    }

    func testSavingWorkspaceSettingsReturnsToScopedSessions() throws {
        XCUIDevice.shared.orientation = .portrait
        openAnchorWorkspace()
        XCTAssertTrue(
            app.buttons["workspace.newSession"].waitForExistence(timeout: 10),
            "Workspace-scoped session list did not appear before editing"
        )

        tap(app.buttons["workspace.edit.open"], named: "workspace edit button")
        let saveButton = app.buttons["workspace.edit.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 10), "Workspace save button did not appear")
        XCTAssertTrue(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "isEnabled == true"),
                    object: saveButton
                )],
                timeout: 10
            ) == .completed,
            "Workspace save button did not become enabled"
        )
        tap(saveButton, named: "workspace save button")

        XCTAssertTrue(
            app.buttons["workspace.newSession"].waitForExistence(timeout: 15),
            "Save did not return to the workspace-scoped session list"
        )
        XCTAssertFalse(
            app.buttons["workspace.quickSession.start"].exists,
            "Save returned to All Sessions instead of the workspace-scoped session list"
        )
        XCTAssertTrue(
            app.buttons["All Sessions"].waitForExistence(timeout: 5),
            "Workspace-scoped session list lost its All Sessions back destination"
        )
    }

    func testIPhoneHierarchicalBackSwipeNavigation() throws {
        XCUIDevice.shared.orientation = .portrait
        openAnchorWorkspace()

        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(sessionList.waitForExistence(timeout: 15), "Workspace-scoped sessions inbox did not appear")

        let sessionButton = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "session.nav.")
        ).firstMatch
        XCTAssertTrue(sessionButton.waitForExistence(timeout: 15), "Workspace session row did not appear")
        tap(sessionButton, named: "workspace session row")
        XCTAssertTrue(app.collectionViews["chat.timeline"].waitForExistence(timeout: 15), "Chat timeline did not appear")

        swipeBack()
        XCTAssertTrue(app.buttons["All Sessions"].waitForExistence(timeout: 10), "Chat swipe did not return to workspace sessions")

        swipeBack()
        XCTAssertTrue(app.staticTexts["All Sessions"].waitForExistence(timeout: 10), "Workspace swipe did not return to All Sessions")
    }

    func testAssistantAvatarPickerIncludesOfficialPi() throws {
        XCUIDevice.shared.orientation = .portrait

        let serverSwitcher = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Current server:")
        ).firstMatch
        tap(serverSwitcher, named: "server switcher", timeout: 10)
        tap(app.buttons["App Settings"], named: "app settings", timeout: 5)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings did not open")

        let avatarSetting = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Assistant Avatar")
        ).firstMatch
        tap(avatarSetting, named: "assistant avatar setting", timeout: 5)
        XCTAssertTrue(
            app.navigationBars["Assistant Avatar"].waitForExistence(timeout: 5),
            "Assistant avatar picker did not open"
        )

        let officialPi = app.buttons["assistant.avatarPicker.option.officialPi"]
        XCTAssertTrue(officialPi.waitForExistence(timeout: 5), "Official Pi avatar option did not appear")
        try saveLabScreenshot(name: "iphone-official-pi-avatar-picker-e2e")

        tap(officialPi, named: "official Pi avatar", timeout: 5)
        XCTAssertTrue(
            app.navigationBars["Assistant Avatar"].exists,
            "Choosing an assistant avatar must remain a draft until Save"
        )
        tap(app.buttons["assistant.avatarPicker.save"], named: "assistant avatar Save", timeout: 5)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Avatar picker did not dismiss")
        XCTAssertTrue(
            app.staticTexts["Official Pi"].waitForExistence(timeout: 5),
            "Settings did not show Official Pi as the selected avatar"
        )

        tap(avatarSetting, named: "assistant avatar setting", timeout: 5)
        XCTAssertTrue(
            app.buttons["assistant.avatarPicker.emojiGenmoji"].waitForExistence(timeout: 5),
            "Assistant picker did not expose Choose Emoji or Genmoji"
        )
        XCTAssertFalse(
            app.buttons["assistant.avatarPicker.option.default"].exists,
            "Assistant picker must not offer a standalone Default reset"
        )
        tap(app.buttons["assistant.avatarPicker.cancel"], named: "assistant avatar Cancel", timeout: 5)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Avatar picker did not dismiss")
    }

    func testIPhoneWorkspaceDeepLinkPresentsPrefilledCreate() throws {
        XCUIDevice.shared.orientation = .portrait
        let url = try XCTUnwrap(
            URL(string: "oppi://workspace?path=/tmp&name=Deep%20Link%20Workspace")
        )
        app.open(url)

        let nameField = app.textFields["workspace.create.name"]
        let pathField = app.textFields["workspace.create.hostMount"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 20), "Workspace deep link did not open the create form")
        XCTAssertTrue(pathField.waitForExistence(timeout: 5), "Workspace deep link path field did not appear")
        XCTAssertEqual(nameField.value as? String, "Deep Link Workspace")
        XCTAssertEqual(pathField.value as? String, "/tmp")

        let iconButton = app.buttons["workspace.create.icon"]
        for _ in 0..<5 where !iconButton.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(iconButton.waitForExistence(timeout: 5), "Workspace create icon control did not appear")
        tap(iconButton, named: "workspace create icon", timeout: 5)
        XCTAssertTrue(
            app.collectionViews["workspace.iconPicker.list"].waitForExistence(timeout: 5),
            "Workspace create did not use the shared icon picker"
        )
        try saveLabScreenshot(name: "iphone-workspace-create-icon-picker-e2e")
        tap(app.buttons["workspace.iconPicker.cancel"], named: "workspace icon picker Cancel", timeout: 5)
        XCTAssertEqual(iconButton.value as? String, "Default workspace icon")
    }

    func testIPhoneWorkspaceSidebarScrolls() throws {
        XCUIDevice.shared.orientation = .portrait

        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(sessionList.waitForExistence(timeout: 15), "iPhone sessions inbox did not appear")
        sessionList.swipeDown()
        tap(app.buttons["workspace.sidebar.open"], named: "workspace sidebar button")

        XCTAssertTrue(
            waitForHittable(app.buttons["workspace.create.sidebar.open"], timeout: 10),
            "Workspace sidebar did not appear"
        )

        let lastWorkspace = app.buttons["workspace.open.Scroll Workspace 9"]
        for _ in 0..<6 where !lastWorkspace.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: 0.82))
                .press(
                    forDuration: 0.05,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: 0.22))
                )
        }
        XCTAssertTrue(lastWorkspace.isHittable, "Workspace sidebar did not scroll to the final workspace")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.50)).tap()
        XCTAssertTrue(
            waitForHittable(app.buttons["workspace.sidebar.open"], timeout: 5),
            "Tapping the session card did not dismiss the workspace sidebar"
        )
    }

    nonisolated private func createScheduleFixture(name: String, expression: String, workspaceId: String) throws -> String {
        let response = try e2eLabAPIJSON(
            method: "POST",
            path: "/schedules",
            body: [
                "name": name,
                "trigger": [
                    "type": "cron",
                    "expression": expression,
                    "timeZone": "America/Los_Angeles",
                ],
                "action": [
                    "type": "new_session",
                    "workspaceId": workspaceId,
                    "prompt": name,
                ],
            ]
        )
        let schedule = try XCTUnwrap(response["schedule"] as? [String: Any])
        return try XCTUnwrap(schedule["id"] as? String)
    }

    private func replaceText(in element: XCUIElement, with text: String) {
        let currentValue = element.value as? String ?? ""
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.80)).tap()
        if !currentValue.isEmpty {
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count))
        }
        element.typeText(text)
        XCTAssertEqual(element.value as? String, text)
    }

    private func selectManualTheme(_ themeName: String) {
        let serverSwitcher = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Current server:")
        ).firstMatch
        tap(serverSwitcher, named: "server switcher", timeout: 10)
        tap(app.buttons["App Settings"], named: "app settings", timeout: 5)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings did not open")

        let themePicker = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Theme", "Theme,")
        ).firstMatch
        tap(themePicker, named: "manual theme picker", timeout: 5)
        tap(app.buttons[themeName], named: "\(themeName) theme", timeout: 5)

        let backButton = app.navigationBars["Settings"].buttons.firstMatch
        tap(backButton, named: "settings back button", timeout: 5)
        XCTAssertTrue(
            app.collectionViews["workspace.sessionList"].waitForExistence(timeout: 10),
            "Sessions inbox did not return after selecting \(themeName)"
        )
    }

    private func openWorkspaceSidebar() {
        tap(app.buttons["workspace.sidebar.open"], named: "workspace sidebar button", timeout: 5)
        XCTAssertTrue(
            waitForHittable(app.buttons["workspace.create.sidebar.open"], timeout: 10),
            "Workspace sidebar did not open"
        )
    }

    private func pixelFraction(
        in image: UIImage,
        crop normalizedCrop: CGRect,
        matches: (CGFloat) -> Bool
    ) -> Double {
        guard let source = image.cgImage else { return 0 }
        let crop = CGRect(
            x: CGFloat(source.width) * normalizedCrop.minX,
            y: CGFloat(source.height) * normalizedCrop.minY,
            width: CGFloat(source.width) * normalizedCrop.width,
            height: CGFloat(source.height) * normalizedCrop.height
        ).integral
        guard let cropped = source.cropping(to: crop), cropped.width > 0, cropped.height > 0 else { return 0 }

        let bytesPerRow = cropped.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * cropped.height)
        guard let context = CGContext(
            data: &pixels,
            width: cropped.width,
            height: cropped.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))

        var matchingPixels = 0
        let pixelCount = cropped.width * cropped.height
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = CGFloat(pixels[offset]) / 255
            let green = CGFloat(pixels[offset + 1]) / 255
            let blue = CGFloat(pixels[offset + 2]) / 255
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            if matches(luminance) {
                matchingPixels += 1
            }
        }
        return pixelCount > 0 ? Double(matchingPixels) / Double(pixelCount) : 0
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitForHittableState(true, of: element, timeout: timeout)
    }

    private func waitForNotHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitForHittableState(false, of: element, timeout: timeout)
    }

    private func waitForHittableState(
        _ isHittable: Bool,
        of element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == %@", NSNumber(value: isHittable)),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForStableFrame(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var previousFrame: CGRect?
        var stableSampleCount = 0

        while Date() < deadline {
            if element.exists {
                let frame = element.frame
                if !frame.isEmpty {
                    if frame == previousFrame {
                        stableSampleCount += 1
                        if stableSampleCount >= 2 {
                            return true
                        }
                    } else {
                        previousFrame = frame
                        stableSampleCount = 0
                    }
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        return false
    }

    private func openAnchorWorkspace() {
        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(sessionList.waitForExistence(timeout: 5), "Sessions inbox missing before workspace selection")
        sessionList.swipeDown()
        tap(app.buttons["workspace.sidebar.open"], named: "workspace sidebar button")
        let openWorkspaceButton = app.buttons["workspace.open.\(anchorWorkspaceName)"]
        XCTAssertTrue(openWorkspaceButton.waitForExistence(timeout: 10), "Anchor workspace did not appear in sidebar")
        tap(openWorkspaceButton, named: "anchor workspace button")
    }

    private func swipeBack() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.50))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.50))
            )
    }
}
