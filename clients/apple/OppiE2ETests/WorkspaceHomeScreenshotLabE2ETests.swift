import XCTest

/// Paired-server screenshot lab for workspace navigation layout regressions.
///
/// This uses the existing E2E server/pairing harness instead of screenshot-preview
/// mocks, so the toolbar, server pill, workspace catalog refresh, and auth path are
/// the same path the app uses in a real paired simulator.
@MainActor
final class WorkspaceHomeScreenshotLabE2ETests: E2ETestCase {
    nonisolated(unsafe) private var hiddenPreviewWorkspaceName: String?
    nonisolated(unsafe) private var hiddenPreviewActiveSessionId: String?
    nonisolated(unsafe) private var hiddenPreviewStoppedSessionIds: [String] = []

    override var e2eLaunchesWorkspaceHomeOnly: Bool {
        !isQuickSessionComposerTest
    }

    override var e2eLaunchesSessionsInboxOnly: Bool {
        isQuickSessionComposerTest
    }

    override var e2eRequiresFreshLaunch: Bool {
        // This class intentionally mixes launch-only roots. Relaunch every case so
        // shared E2E process state cannot leak a sessions-only launch into the next test.
        true
    }

    nonisolated private var isQuickSessionComposerTest: Bool {
        name.contains("testQuickSessionComposer")
    }

    override func seedE2EFixtures() throws {
        try seedLabWorkspaces(WorkspaceHomeLabScenario.allFixtures)
        if name.contains("testWorkspaceSidebarHidesSessionPreviews") {
            try seedHiddenStoppedPreviewFixture()
        }
    }

    func testWorkspaceHomeWrappingScreenshotLab() throws {
        try runWorkspaceHomeLab(.wrapping)
    }

    func testWorkspaceHomeDenseCountsScreenshotLab() throws {
        try runWorkspaceHomeLab(.denseCounts)
    }

    func testWorkspaceSidebarHidesSessionPreviews() throws {
        let workspaceName = try XCTUnwrap(hiddenPreviewWorkspaceName)
        let activeSessionId = try XCTUnwrap(hiddenPreviewActiveSessionId)
        let stoppedSessionIds = hiddenPreviewStoppedSessionIds

        let workspaceList = openWorkspaceHomeList()
        workspaceList.swipeDown()
        XCTAssertTrue(
            scrollWorkspaceHomeList(workspaceList, toText: workspaceName, timeout: 20),
            "Workspace with mixed active and stopped sessions did not appear after refresh"
        )

        let activePreview = app.descendants(matching: .any)["workspaceHome.sessionPreview.\(activeSessionId)"]
        XCTAssertFalse(
            activePreview.exists,
            "Workspace navigation should not render inline active session previews"
        )

        for stoppedSessionId in stoppedSessionIds {
            let stoppedPreview = app.descendants(matching: .any)["workspaceHome.sessionPreview.\(stoppedSessionId)"]
            XCTAssertFalse(
                stoppedPreview.waitForExistence(timeout: 1),
                "Workspace sidebar should not render stopped session preview \(stoppedSessionId)"
            )
        }
    }

    func testQuickSessionComposerGrowthFitsMeasuredContent() throws {
        let sessionsList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(sessionsList.waitForExistence(timeout: 10), "Sessions inbox not visible")

        tap(app.buttons["workspace.quickSession.start"], named: "quick session button")
        defer { dismissQuickSessionSheetIfNeeded() }

        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(chatInput.waitForExistence(timeout: 10), "Quick Session input not visible")
        let overlay = app.buttons["quickSession.overlay"].firstMatch
        XCTAssertTrue(overlay.waitForExistence(timeout: 5), "Quick Session overlay not visible")
        XCTAssertFalse(app.buttons["quickSession.dismiss"].exists, "Quick Session should not show a close button")
        XCTAssertFalse(
            sessionsList.isHittable,
            "Modal Quick Session must make the background sessions hierarchy inert"
        )
        XCTAssertFalse(app.buttons["Sheet Grabber"].exists, "Quick Session should not use a system sheet container")
        let initialInputHeight = chatInput.frame.height

        tap(chatInput, named: "quick session input", timeout: 5)
        let focusPredicate = NSPredicate(format: "hasKeyboardFocus == true")
        if !focusPredicate.evaluate(with: chatInput) {
            chatInput.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        }
        let focusDeadline = Date().addingTimeInterval(5)
        while !focusPredicate.evaluate(with: chatInput) && Date() < focusDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(focusPredicate.evaluate(with: chatInput), "Quick Session input did not gain keyboard focus")

        chatInput.typeText("first quick session line\nsecond quick session line\nthird quick session line")

        let multilineExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.frame.height > initialInputHeight + 20
            },
            object: chatInput
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [multilineExpectation], timeout: 10),
            .completed,
            "Quick Session input did not grow for multiline content"
        )
        XCTAssertFalse(app.buttons["Sheet Grabber"].exists, "Multiline growth restored the system sheet container")

        try saveLabScreenshot(name: "quick-session-overlay-composer-growth-e2e")

        dismissQuickSessionSheetIfNeeded()
        XCTAssertTrue(
            sessionsList.waitForExistence(timeout: 5),
            "Swiping down on Quick Session must restore the sessions accessibility hierarchy"
        )
        let launchButton = app.buttons["workspace.quickSession.start"]
        XCTAssertTrue(
            launchButton.waitForExistence(timeout: 5) && launchButton.isHittable,
            "Dismissing Quick Session must restore its launch control to the interactive hierarchy"
        )
    }

    func testQuickSessionComposerScrollsInCompactHeight() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer {
            dismissQuickSessionSheetIfNeeded()
            XCUIDevice.shared.orientation = .portrait
        }

        let sessionsList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(sessionsList.waitForExistence(timeout: 10), "Sessions inbox not visible")
        tap(app.buttons["workspace.quickSession.start"], named: "quick session button")

        let input = app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10), "Quick Session input not visible in compact height")
        tap(input, named: "quick session input", timeout: 5)
        input.typeText("one\ntwo\nthree\nfour\nfive\nsix")

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "Keyboard not visible in compact height")
        let viewport = app.scrollViews["quickSession.viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 5), "Bounded Quick Session viewport not visible")
        XCTAssertLessThanOrEqual(
            input.frame.maxY,
            keyboard.frame.minY + 1,
            "Compact-height composer input must stay above the keyboard"
        )
        XCTAssertFalse(app.buttons["quickSession.dismiss"].exists, "Quick Session should not show a close button")

        viewport.swipeUp()
        let workspacePicker = app.buttons["quickSession.workspacePicker"]
        XCTAssertTrue(
            workspacePicker.waitForExistence(timeout: 5) && workspacePicker.isHittable,
            "Compact-height fallback must allow scrolling to the composer controls"
        )
        XCTAssertLessThanOrEqual(
            workspacePicker.frame.maxY,
            keyboard.frame.minY + 1,
            "Scrolled composer controls must remain above the keyboard"
        )
        XCTAssertFalse(app.buttons["Sheet Grabber"].exists, "Compact fallback must not restore a system sheet")
    }

    private func waitForInputValue(
        _ input: XCUIElement,
        containing expected: String,
        timeout: TimeInterval
    ) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = input.value as? String ?? input.label
        while Date() < deadline {
            latest = input.value as? String ?? input.label
            if latest.contains(expected) {
                return latest
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return latest
    }

    private nonisolated func seedHiddenStoppedPreviewFixture() throws {
        let workspaceName = "AAA Stopped Preview Hidden \(UUID().uuidString.prefix(6))"
        let workspaceId = try createLabWorkspace(named: workspaceName)
        hiddenPreviewWorkspaceName = workspaceName
        hiddenPreviewActiveSessionId = try XCTUnwrap(
            createLabSessions(count: 1, workspaceId: workspaceId, stopAfterCreate: false).first
        )
        hiddenPreviewStoppedSessionIds = try createLabSessions(
            count: 2,
            workspaceId: workspaceId,
            stopAfterCreate: true
        )
    }

    private func scrollWorkspaceHomeList(
        _ workspaceList: XCUIElement,
        toText text: String,
        timeout: TimeInterval
    ) -> Bool {
        let target = app.staticTexts[text]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if target.exists { return true }
            workspaceList.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return target.exists
    }

    private nonisolated var currentScenario: WorkspaceHomeLabScenario {
        if name.contains("testWorkspaceHomeDenseCountsScreenshotLab") {
            return .denseCounts
        }
        return .wrapping
    }

    private func runWorkspaceHomeLab(_ scenario: WorkspaceHomeLabScenario) throws {
        let workspaceList = openWorkspaceHomeList()
        workspaceList.swipeDown()

        XCTAssertTrue(
            app.staticTexts[scenario.anchorWorkspaceName].waitForExistence(timeout: 20),
            "Seeded workspace did not appear after refresh"
        )

        try saveLabScreenshot(name: scenario.screenshotName)
    }

    private func openWorkspaceHomeList() -> XCUIElement {
        dismissExtensionSheetIfNeeded(timeout: 3)

        let legacyList = app.collectionViews["workspace.list"]
        if legacyList.isHittable {
            return legacyList
        }

        let sidebar = app.scrollViews["workspace.sidebar.scroll"]
        if !sidebar.isHittable {
            tap(app.buttons["workspace.sidebar.open"], named: "workspace sidebar button")
        }

        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: sidebar
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [hittable], timeout: 5),
            .completed,
            "Workspace sidebar not visible"
        )
        return sidebar
    }

    private func scrollQuickSessionViewport(
        _ viewport: XCUIElement,
        untilHittable controls: [XCUIElement]
    ) -> Bool {
        for _ in 0..<4 {
            if controls.allSatisfy({ $0.exists && $0.isHittable }) {
                return true
            }
            viewport.swipeUp()
        }
        return controls.allSatisfy { $0.exists && $0.isHittable }
    }

    private func dismissQuickSessionSheetIfNeeded() {
        let overlay = app.buttons["quickSession.overlay"].firstMatch
        guard overlay.waitForExistence(timeout: 1) else { return }
        let start = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
}

private enum WorkspaceHomeLabScenario {
    case wrapping
    case denseCounts

    var screenshotName: String {
        switch self {
        case .wrapping:
            return "workspace-home-wrapping-e2e"
        case .denseCounts:
            return "workspace-home-dense-counts-e2e"
        }
    }

    var anchorWorkspaceName: String {
        switch self {
        case .wrapping:
            return "Oppi Config"
        case .denseCounts:
            return "Archive Saturation Workspace"
        }
    }

    static var allFixtures: [E2ELabWorkspaceFixture] {
        WorkspaceHomeLabScenario.wrapping.fixtures + WorkspaceHomeLabScenario.denseCounts.fixtures
    }

    var fixtures: [E2ELabWorkspaceFixture] {
        switch self {
        case .wrapping:
            return [
                E2ELabWorkspaceFixture("Oppi Config", stoppedSessionCount: 4),
                E2ELabWorkspaceFixture("voebb-watchdog", stoppedSessionCount: 2),
                E2ELabWorkspaceFixture("Metro Companion App With A Long Name"),
                E2ELabWorkspaceFixture("Oppi Apple Clients"),
            ]
        case .denseCounts:
            return [
                E2ELabWorkspaceFixture("Archive Saturation Workspace", stoppedSessionCount: 12),
                E2ELabWorkspaceFixture("Active Session Count Workspace", activeSessionCount: 2, stoppedSessionCount: 3),
                E2ELabWorkspaceFixture("Long Workspace Name With Dense Status Metadata", stoppedSessionCount: 8),
            ]
        }
    }
}
