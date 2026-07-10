import XCTest

/// iPad screenshot lab for the adaptive split shell.
///
/// Runs against the real paired E2E server so the captured view includes the
/// production pairing, workspace refresh, session creation, and chat timeline
/// path instead of preview-only fixtures.
@MainActor
final class IPadAdaptiveShellScreenshotE2ETests: E2ETestCase {
    private let anchorWorkspaceName = "iPad Layout Workspace"

    override var e2eLaunchesWorkspaceHomeOnly: Bool {
        true
    }

    override func setUpWithError() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        try super.setUpWithError()
    }

    override func seedE2EFixtures() throws {
        let defaultModel = ProcessInfo.processInfo.environment["E2E_MODEL"] ?? "omlx/Qwen3.6-27B-8bit"
        let workspaceId = try createLabWorkspace(named: anchorWorkspaceName, defaultModel: defaultModel)
        try createLabSessions(count: 1, workspaceId: workspaceId, stopAfterCreate: false)
        try createLabSessions(count: 2, workspaceId: workspaceId, stopAfterCreate: true)

        try seedLabWorkspaces([
            E2ELabWorkspaceFixture("Long iPad Sidebar Workspace Name", stoppedSessionCount: 3),
            E2ELabWorkspaceFixture("Sandbox Review Queue", activeSessionCount: 1),
        ])
    }

    func testIPadMainAndChatTimelineScreenshots() throws {
        try prepareIPadLandscapeCanvas()

        let workspaceList = app.scrollViews["workspace.sidebar.scroll"]
        XCTAssertTrue(workspaceList.waitForExistence(timeout: 15), "Workspace sidebar not visible")
        dismissExtensionSheetIfNeeded(timeout: 3)
        workspaceList.swipeDown()

        XCTAssertTrue(
            app.staticTexts[anchorWorkspaceName].waitForExistence(timeout: 20),
            "Seeded iPad workspace did not appear after refresh"
        )

        try saveLabScreenshot(name: "ipad-main-workspace-home")

        openWorkspaceCreateForm()
        try saveLabScreenshot(name: "ipad-workspace-create-form")
        dismissWorkspaceCreateForm()

        let openWorkspaceButton = app.buttons["workspace.open.\(anchorWorkspaceName)"]
        XCTAssertTrue(openWorkspaceButton.waitForExistence(timeout: 10), "iPad workspace open button missing")
        openWorkspaceButton.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()

        XCTAssertTrue(
            app.collectionViews["workspace.sessionList"].waitForExistence(timeout: 15),
            "Workspace session-list column did not appear after selecting workspace"
        )

        openWorkspaceEditForm()
        try saveLabScreenshot(name: "ipad-workspace-edit-form")

        dismissWorkspaceEditForm()

        createSession()
        sendMessageAndWaitForResponse(localEchoPrompt("IPAD_CHAT_TIMELINE_OK"), timeout: 240)

        XCTAssertTrue(
            waitForTimelineTextContaining("IPAD_CHAT_TIMELINE_OK", timeout: 20),
            "IPAD_CHAT_TIMELINE_OK did not appear in the timeline"
        )

        dismissKeyboardIfNeeded()
        assertSplitSidebarHiddenForFullWidthChat()
        try saveLabScreenshot(name: "ipad-chat-timeline")

        openSessionOutlineSurface()
        try saveLabScreenshot(name: "ipad-session-outline-fullscreen")
        openSessionTreeIfAvailable()
        try saveLabScreenshot(name: "ipad-session-tree-fullscreen")
        dismissPresentedNavigationSurface(title: "Session Outline")

        openContextInspectorSurface()
        try saveLabScreenshot(name: "ipad-context-inspector-fullscreen")
        dismissPresentedNavigationSurface(title: "Context")

        navigateBackToWorkspace()

        let filesButton = app.buttons["workspace.files.open"]
        XCTAssertTrue(filesButton.waitForExistence(timeout: 10), "Workspace files button missing")
        tap(filesButton, named: "workspace files button")
        XCTAssertTrue(
            app.navigationBars["Files"].waitForExistence(timeout: 10),
            "File browser did not open in the iPad detail column"
        )
        try saveLabScreenshot(name: "ipad-file-browser")
    }

    private func openWorkspaceCreateForm() {
        showWorkspaceHomeListIfNeeded()

        let createButton = app.buttons["workspace.create.sidebar.open"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 5), "Create workspace sidebar button missing")
        tap(createButton, named: "create workspace sidebar button", timeout: 1)

        let manualButton = app.buttons["workspace.create.manual"]
        XCTAssertTrue(manualButton.waitForExistence(timeout: 15), "Manual create button not shown")
        for _ in 0..<4 where !manualButton.isHittable {
            app.swipeUp()
        }
        tap(manualButton, named: "manual workspace creation button")

        XCTAssertTrue(
            app.textFields["workspace.create.name"].waitForExistence(timeout: 10),
            "Workspace create form did not appear"
        )
    }

    private func dismissWorkspaceCreateForm() {
        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "Workspace create cancel button missing")
        tap(cancelButton, named: "workspace create cancel button", timeout: 1)

        XCTAssertTrue(
            app.scrollViews["workspace.sidebar.scroll"].waitForExistence(timeout: 10),
            "Workspace sidebar did not return after dismissing create form"
        )
    }

    private func openWorkspaceEditForm() {
        let editButton = app.buttons["workspace.edit.open"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 10), "Workspace edit button missing")
        tap(editButton, named: "workspace edit button")

        XCTAssertTrue(
            app.textFields["workspace.edit.name"].waitForExistence(timeout: 15)
                || app.navigationBars["Edit Workspace"].waitForExistence(timeout: 2),
            "Workspace edit form did not appear"
        )
    }

    private func dismissWorkspaceEditForm() {
        let sessionList = app.collectionViews["workspace.sessionList"]
        if sessionList.waitForExistence(timeout: 1) {
            return
        }

        let doneButton = app.buttons["workspace.edit.done"]
        if doneButton.waitForExistence(timeout: 2) {
            tap(doneButton, named: "workspace edit done button", timeout: 1)
        } else {
            let backButton = app.navigationBars["Edit Workspace"].buttons["Back"]
            XCTAssertTrue(backButton.waitForExistence(timeout: 5), "Workspace edit back button missing")
            tap(backButton, named: "workspace edit back button", timeout: 1)
        }

        XCTAssertTrue(
            sessionList.waitForExistence(timeout: 10),
            "Workspace session-list column did not return after dismissing edit form"
        )
    }

    private func prepareIPadLandscapeCanvas(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCUIDevice.shared.orientation = .landscapeLeft

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let size = app.frame.size
            if min(size.width, size.height) >= 700,
               size.width >= 980,
               size.width >= size.height {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        let size = app.frame.size
        try XCTSkipUnless(
            min(size.width, size.height) >= 700,
            "iPad adaptive shell screenshots require an iPad-sized simulator",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            size.width,
            980,
            "iPad adaptive shell screenshots require a landscape canvas wide enough for the split shell. App frame: \(size)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            size.width,
            size.height,
            "iPad adaptive shell screenshots require landscape orientation. App frame: \(size)",
            file: file,
            line: line
        )
    }

    private func assertSplitSidebarHiddenForFullWidthChat() {
        let splitToggle = app.buttons["workspace.split.sidebarToggle"]
        XCTAssertTrue(splitToggle.waitForExistence(timeout: 10), "Split sidebar toggle missing in chat")
        XCTAssertTrue(
            splitToggle.label.localizedCaseInsensitiveContains("show"),
            "Chat should hide the split sidebar by default"
        )

        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertFalse(
            sessionList.waitForExistence(timeout: 1) && sessionList.isHittable,
            "Chat timeline should not share width with the session list"
        )
    }

    private func openSessionOutlineSurface() {
        let outlineButton = app.buttons["chat.toolbar.outline"]
        XCTAssertTrue(outlineButton.waitForExistence(timeout: 10), "Session outline toolbar button missing")
        tap(outlineButton, named: "session outline toolbar button", timeout: 1)

        let outlineNavigationBar = app.navigationBars["Session Outline"]
        XCTAssertTrue(outlineNavigationBar.waitForExistence(timeout: 10), "Session outline did not open")
        assertNavigationSurfaceFillsScreen(outlineNavigationBar, name: "Session outline")
    }

    private func openSessionTreeIfAvailable() {
        let treeButton = app.buttons["Tree"]
        if treeButton.waitForExistence(timeout: 3) {
            tap(treeButton, named: "session tree tab", timeout: 1)
            let itemCount = app.staticTexts
                .matching(NSPredicate(format: "label ENDSWITH %@", "items"))
                .firstMatch
            XCTAssertTrue(
                itemCount.waitForExistence(timeout: 10),
                "Session tree content did not appear"
            )
        }
    }

    private func openContextInspectorSurface() {
        let contextButton = app.buttons["chat.toolbar.context"]
        XCTAssertTrue(contextButton.waitForExistence(timeout: 10), "Context inspector toolbar button missing")
        tap(contextButton, named: "context inspector toolbar button", timeout: 1)

        let contextNavigationBar = app.navigationBars["Context"]
        XCTAssertTrue(contextNavigationBar.waitForExistence(timeout: 10), "Context inspector did not open")
        assertNavigationSurfaceFillsScreen(contextNavigationBar, name: "Context inspector")
    }

    private func assertNavigationSurfaceFillsScreen(_ element: XCUIElement, name: String) {
        let minimumWidth = app.frame.width * 0.88
        XCTAssertGreaterThanOrEqual(
            element.frame.width,
            minimumWidth,
            "\(name) should present full-screen on iPad. Surface width: \(element.frame.width), app width: \(app.frame.width)"
        )
    }

    private func dismissPresentedNavigationSurface(title: String) {
        let navigationBar = app.navigationBars[title]
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 5), "\(title) navigation bar missing before dismissal")

        let doneButton = navigationBar.buttons["Done"]
        if doneButton.waitForExistence(timeout: 2) {
            tap(doneButton, named: "\(title) done button", timeout: 1)
        } else {
            tap(app.buttons["Done"], named: "\(title) done button", timeout: 1)
        }

        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: navigationBar)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 8),
            .completed,
            "\(title) did not dismiss"
        )
    }

    private func showWorkspaceHomeListIfNeeded() {
        let workspaceList = app.scrollViews["workspace.sidebar.scroll"]
        for _ in 0..<4 {
            revealSplitDetailSidebarIfNeeded()

            if workspaceList.waitForExistence(timeout: 1) {
                return
            }

            let showWorkspacesButton = app.buttons["workspace.sidebar.showWorkspaces"]
            if showWorkspacesButton.waitForExistence(timeout: 1) {
                tap(showWorkspacesButton, named: "show workspaces button", timeout: 1)
                if workspaceList.waitForExistence(timeout: 3) {
                    return
                }
            }

            let backButton = app.navigationBars.buttons.firstMatch
            guard backButton.waitForExistence(timeout: 1) else { break }
            tap(backButton, named: "navigation back button", timeout: 1)
        }

        XCTAssertTrue(
            workspaceList.waitForExistence(timeout: 10),
            "Workspace list did not appear after returning to workspace sidebar"
        )
    }

    private func revealSplitDetailSidebarIfNeeded() {
        if app.scrollViews["workspace.sidebar.scroll"].waitForExistence(timeout: 1) {
            return
        }

        let splitToggle = app.buttons["workspace.split.sidebarToggle"]
        if splitToggle.waitForExistence(timeout: 2) {
            if splitToggle.label.localizedCaseInsensitiveContains("show") {
                tap(splitToggle, named: "split sidebar toggle", timeout: 1)
            }
            return
        }

        let showSidebarButton = app.buttons["Show Sidebar"]
        if showSidebarButton.waitForExistence(timeout: 1) {
            tap(showSidebarButton, named: "show sidebar button", timeout: 1)
            return
        }

        let lowercaseShowSidebarButton = app.buttons["Show sidebar"]
        if lowercaseShowSidebarButton.waitForExistence(timeout: 1) {
            tap(lowercaseShowSidebarButton, named: "show sidebar button", timeout: 1)
        }
    }

    private func dismissKeyboardIfNeeded() {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }

        let hideKeyboardButton = app.buttons["Hide keyboard"]
        if hideKeyboardButton.waitForExistence(timeout: 2) {
            tap(hideKeyboardButton, named: "hide keyboard", timeout: 1)
            return
        }

        let workspaceNavigationBar = app.navigationBars[anchorWorkspaceName]
        if workspaceNavigationBar.waitForExistence(timeout: 2) {
            workspaceNavigationBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

}
