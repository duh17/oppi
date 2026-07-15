import XCTest

/// Shared base class for E2E tests.
/// Launches the app and pairs with the E2E server once per test process,
/// then each test method reuses the same app instance.
///
/// Pairing invite tokens are single-use, so relaunching and re-pairing for
/// each test class makes later classes fail with an already-consumed invite.
class E2ETestCase: XCTestCase {

    /// Shared app instance — persists across E2E test classes.
    /// nonisolated(unsafe) is required for Swift 6 strict concurrency — XCTest
    /// runs these UI tests serially in the harness.
    nonisolated(unsafe) private static var _app: XCUIApplication?
    nonisolated(unsafe) static var e2eDeviceTokenCache: String?

    var app: XCUIApplication {
        Self._app!
    }

    /// Terminates the shared app and invalidates the process-wide handle.
    /// The next E2E setup relaunches with the same paired device token.
    func terminateSharedApp() {
        Self._app?.terminate()
        Self._app = nil
    }

    /// Override in focused labs that need the paired workspace list itself,
    /// not the default workspace-detail starting point used by interaction E2Es.
    var e2eLaunchesWorkspaceHomeOnly: Bool {
        false
    }

    /// Override in labs that need the sessions-first inbox without opening a workspace.
    var e2eLaunchesSessionsInboxOnly: Bool {
        false
    }

    /// Override in tests whose behavior starts from the auto-created chat session.
    var e2eStartsInAutoCreatedChat: Bool {
        false
    }

    /// Override in tests that need the workspace detail list without paying for a throwaway chat session.
    var e2eAutoCreatesSessionOnLaunch: Bool {
        true
    }

    /// Override for tests that must control launch-only state such as pending app-group handoff data.
    var e2eRequiresFreshLaunch: Bool {
        false
    }

    /// Override to add launch environment or arguments before the app starts.
    func configureE2ELaunch(_ application: XCUIApplication) {}

    /// Override in labs that need server-side fixtures before the app refreshes.
    func seedE2EFixtures() throws {}

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        try seedE2EFixtures()

        if e2eRequiresFreshLaunch {
            Self._app?.terminate()
            Self._app = nil
        }

        let launchedFresh = Self._app == nil
        if launchedFresh {
            try launchAndPair()
        }
        dismissExtensionSheetIfNeeded(timeout: 0.2)

        if e2eLaunchesWorkspaceHomeOnly {
            try ensureAtWorkspaceHome()
        } else if e2eLaunchesSessionsInboxOnly {
            try ensureAtSessionsInbox()
        } else if e2eStartsInAutoCreatedChat {
            try ensureAtChatSession()
        } else {
            // Navigate back to workspace detail if a previous test left the app elsewhere.
            try ensureAtWorkspaceDetail()
        }
    }

    // MARK: - Launch & Pairing (once per class)

    /// Launches the app, pairs with the E2E server, and navigates to the e2e-workspace.
    private func launchAndPair() throws {
        let inviteURL = try readInviteURL()

        let application = XCUIApplication()
        application.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        application.launchEnvironment["PI_E2E_INVITE_URL"] = inviteURL
        if let deviceToken = try? readDeviceToken() {
            application.launchEnvironment["OPPI_E2E_DEVICE_TOKEN"] = deviceToken
        }
        if !e2eLaunchesWorkspaceHomeOnly && !e2eLaunchesSessionsInboxOnly {
            application.launchEnvironment["OPPI_E2E_AUTO_OPEN_WORKSPACE"] = "e2e-workspace"
            if e2eAutoCreatesSessionOnLaunch {
                application.launchEnvironment["OPPI_E2E_AUTO_CREATE_SESSION"] = "1"
            }
        }
        configureE2ELaunch(application)
        application.launch()
        Self._app = application

        // Dismiss springboard alerts (notification permissions, etc.)
        // 0.5s is enough to detect — no need to block 2s when no alert is present.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 0.5) {
            tap(springboard.alerts.firstMatch.buttons.element(boundBy: 1), named: "SpringBoard alert default button")
        }

        dismissInitialExtensionSheet(in: application)
        if e2eLaunchesWorkspaceHomeOnly {
            revealSplitSidebarIfNeeded(in: application)
        }

        // Poll observable app surfaces instead of paying a fixed launch delay.
        // Fifteen seconds is a failure ceiling; successful launches return as soon
        // as the first paired surface appears.
        let paired = waitForPairedAppSurface(in: application, timeout: 15)
        if e2eLaunchesWorkspaceHomeOnly {
            XCTAssertTrue(
                waitForWorkspaceList(in: application, timeout: 5),
                "Workspace list did not appear after pairing"
            )
            return
        }
        if e2eLaunchesSessionsInboxOnly {
            XCTAssertTrue(
                waitForSessionsInbox(in: application, timeout: 5),
                "Sessions inbox did not appear after pairing"
            )
            return
        }
        XCTAssertTrue(
            paired,
            "Workspace surface did not appear after pairing"
        )
        guard paired else { return }

        if e2eStartsInAutoCreatedChat {
            XCTAssertTrue(
                waitForChatSessionSurface(in: application, timeout: 30),
                "Auto-created chat did not load after pairing"
            )
            return
        }

        if workspaceDetailSurfaceExists(in: application) || chatSessionSurfaceExists(in: application) {
            return
        }

        // Find and open the e2e-workspace. The row body expands previews; the
        // trailing open affordance navigates to workspace detail.
        revealSplitSidebarIfNeeded(in: application)
        let openWorkspaceButton = application.buttons["workspace.open.e2e-workspace"]
        if !waitForElementToExist(openWorkspaceButton, timeout: 10) {
            // Pull to refresh as fallback — then poll again instead of sleeping.
            workspaceListElement(in: application).swipeDown()
        }
        XCTAssertTrue(
            waitForElementToExist(openWorkspaceButton, timeout: 10),
            "Workspace 'e2e-workspace' open button did not appear in list"
        )
        // The workspace row has an expanding row-body button next to the open
        // affordance. Tap the trailing edge of the open control so XCTest does
        // not synthesize the event into the neighboring disclosure button.
        openWorkspaceButton.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()

        // Verify we arrived at workspace detail, or an E2E auto-created session opened directly.
        let detailDeadline = Date().addingTimeInterval(10)
        var openedWorkspaceSurface = workspaceDetailSurfaceExists(in: application) || chatSessionSurfaceExists(in: application)
        while !openedWorkspaceSurface && Date() < detailDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            openedWorkspaceSurface = workspaceDetailSurfaceExists(in: application) || chatSessionSurfaceExists(in: application)
        }
        XCTAssertTrue(
            openedWorkspaceSurface,
            "Workspace detail or auto-created chat did not load after tapping e2e-workspace"
        )
    }

    private func dismissInitialExtensionSheet(in application: XCUIApplication) {
        dismissExtensionSurfaceIfNeeded(in: application, timeout: 0.5)
    }

    func revealSplitSidebarIfNeeded(in application: XCUIApplication) {
        guard !waitForWorkspaceList(in: application, timeout: 0.5) else { return }

        let appSidebarButton = application.buttons["workspace.sidebar.open"]
        if waitForElementToExist(appSidebarButton, timeout: 0.5) {
            tap(appSidebarButton, named: "workspace sidebar button", timeout: 0.5)
            _ = waitForWorkspaceList(in: application, timeout: 2)
            return
        }

        let splitToggle = application.buttons["workspace.split.sidebarToggle"]
        if waitForElementToExist(splitToggle, timeout: 0.5),
           splitToggle.label.localizedCaseInsensitiveContains("show") {
            tap(splitToggle, named: "split sidebar toggle", timeout: 0.5)
            _ = waitForWorkspaceList(in: application, timeout: 2)
            return
        }

        let showSidebarButton = application.buttons["Show Sidebar"]
        guard waitForElementToExist(showSidebarButton, timeout: 0.5) else { return }
        tap(showSidebarButton, named: "show sidebar button", timeout: 0.5)
        _ = waitForWorkspaceList(in: application, timeout: 2)
    }

    private func waitForPairedAppSurface(
        in application: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if workspaceListSurfaceExists(in: application)
                || sessionsInboxSurfaceExists(in: application)
                || workspaceDetailSurfaceExists(in: application)
                || chatSessionSurfaceExists(in: application) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    private func sessionsInboxSurfaceExists(in application: XCUIApplication) -> Bool {
        application.buttons["workspace.quickSession.start"].exists
            && application.collectionViews["workspace.sessionList"].exists
    }

    private func waitForSessionsInbox(
        in application: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if sessionsInboxSurfaceExists(in: application) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return sessionsInboxSurfaceExists(in: application)
    }

    private func workspaceListSurfaceExists(in application: XCUIApplication) -> Bool {
        application.scrollViews["workspace.sidebar.scroll"].exists
            || application.collectionViews["workspace.list"].exists
    }

    private func waitForWorkspaceList(
        in application: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if workspaceListSurfaceExists(in: application) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return workspaceListSurfaceExists(in: application)
    }

    private func workspaceListElement(in application: XCUIApplication) -> XCUIElement {
        let sidebarScroll = application.scrollViews["workspace.sidebar.scroll"]
        return sidebarScroll.exists ? sidebarScroll : application.collectionViews["workspace.list"]
    }

    private func readDeviceToken() throws -> String {
        if let token = Self.e2eDeviceTokenCache, !token.isEmpty {
            return token
        }

        for key in ["OPPI_E2E_DEVICE_TOKEN", "SIMCTL_CHILD_OPPI_E2E_DEVICE_TOKEN"] {
            if let token = ProcessInfo.processInfo.environment[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !token.isEmpty {
                Self.e2eDeviceTokenCache = token
                return token
            }
        }

        let path = "/tmp/oppi-e2e-device-token.txt"
        guard FileManager.default.fileExists(atPath: path) else { return "" }
        let token = try String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            Self.e2eDeviceTokenCache = token
        }
        return token
    }

    /// Reads the invite URL provided by the E2E server harness.
    private func readInviteURL() throws -> String {
        for key in ["PI_E2E_INVITE_URL", "SIMCTL_CHILD_PI_E2E_INVITE_URL"] {
            if let url = ProcessInfo.processInfo.environment[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !url.isEmpty {
                return url
            }
        }

        let path = "/tmp/oppi-e2e-invite.txt"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("No invite URL found in PI_E2E_INVITE_URL or at \(path) — run the Oppi E2E server harness to set up pairing")
        }
        let url = try String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            throw XCTSkip("Invite URL file is empty")
        }
        return url
    }

    // MARK: - State Recovery

    /// Ensures the app is at the workspace home screen before each test.
    /// Handles recovery from chat sessions, workspace detail, or modal sheets.
    private func ensureAtWorkspaceHome() throws {
        if waitForWorkspaceList(in: app, timeout: 0.5) {
            return
        }

        dismissExtensionSheetIfNeeded(timeout: 0.5)
        revealSplitSidebarIfNeeded(in: app)
        if waitForWorkspaceList(in: app, timeout: 2) {
            return
        }

        for _ in 0..<3 {
            guard let backButton = navigationBackButton() else { break }
            tap(backButton, named: "navigation back button", timeout: 0.5)
            revealSplitSidebarIfNeeded(in: app)
            if waitForWorkspaceList(in: app, timeout: 1) { return }
        }

        XCTAssertTrue(waitForWorkspaceList(in: app, timeout: 5), "Workspace home list not reachable")
    }

    /// Ensures the app is at the global sessions inbox before each test.
    private func ensureAtSessionsInbox() throws {
        dismissWorkspaceDrawerIfNeeded()
        if waitForSessionsInbox(in: app, timeout: 0.5) { return }

        dismissExtensionSheetIfNeeded(timeout: 0.5)
        for _ in 0..<3 {
            let showAllSessions = app.buttons["workspace.sidebar.showWorkspaces"]
            if showAllSessions.exists {
                tap(showAllSessions, named: "show all sessions button", timeout: 0.5)
            } else if let backButton = navigationBackButton() {
                tap(backButton, named: "navigation back button", timeout: 0.5)
            } else {
                break
            }
            dismissWorkspaceDrawerIfNeeded()
            if waitForSessionsInbox(in: app, timeout: 1) { return }
        }

        Self._app = nil
        try launchAndPair()
        XCTAssertTrue(
            waitForSessionsInbox(in: app, timeout: 5),
            "Sessions inbox not reachable after relaunch"
        )
    }

    private func dismissWorkspaceDrawerIfNeeded() {
        let sidebarContent = app.buttons["workspace.create.sidebar.open"]
        guard sidebarContent.isHittable else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.50)).tap()
        _ = XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "isHittable == false"),
                object: sidebarContent
            )],
            timeout: 1
        )
    }

    /// Ensures the app is inside a chat session before each test.
    private func ensureAtChatSession() throws {
        dismissExtensionSheetIfNeeded(timeout: 1)

        if waitForChatSessionSurface(in: app, timeout: 3) {
            return
        }

        let newSessionButton = app.buttons["workspace.newSession"]
        if waitForElementToExist(newSessionButton, timeout: 3) {
            tap(newSessionButton, named: "new session button")
            XCTAssertTrue(
                waitForChatSessionSurface(in: app, timeout: 30),
                "Chat session did not appear after creating session"
            )
            return
        }

        Self._app = nil
        try launchAndPair()
        XCTAssertTrue(
            waitForChatSessionSurface(in: app, timeout: 30),
            "Chat session not reachable after relaunch"
        )
    }

    private func workspaceDetailSurfaceExists(in application: XCUIApplication) -> Bool {
        application.buttons["workspace.newSession"].exists
    }

    private func waitForWorkspaceDetailSurface(in application: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if workspaceDetailSurfaceExists(in: application) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return workspaceDetailSurfaceExists(in: application)
    }

    private func chatSessionSurfaceExists(in application: XCUIApplication) -> Bool {
        application.buttons["chat.toolbar.files"].exists
            || application.textViews["chat.input"].exists
            || application.descendants(matching: .any)["chat.input"].exists
    }

    private func waitForChatSessionSurface(in application: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if chatSessionSurfaceExists(in: application) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return chatSessionSurfaceExists(in: application)
    }

    /// Ensures the app is at the workspace detail screen before each test.
    /// Handles recovery from chat sessions, workspace list, or unknown states.
    private func ensureAtWorkspaceDetail() throws {
        dismissExtensionSheetIfNeeded(timeout: 0.2)

        if workspaceDetailSurfaceExists(in: app) {
            clearSessionSearchIfNeeded()
            return
        }

        // Most scenario handoffs leave the app in chat. Do this before any
        // long workspace-detail wait so back navigation does not burn seconds.
        if let backButton = navigationBackButton(), backButton.exists {
            tap(backButton, named: "navigation back button", timeout: 1)
            if waitForWorkspaceDetailSurface(in: app, timeout: 6) {
                clearSessionSearchIfNeeded()
                return
            }
        }

        if waitForWorkspaceDetailSurface(in: app, timeout: 1) {
            clearSessionSearchIfNeeded()
            return
        }

        // Might be at the workspace list — open e2e-workspace
        let openWorkspaceButton = app.buttons["workspace.open.e2e-workspace"]
        if waitForElementToExist(openWorkspaceButton, timeout: 3) {
            tap(openWorkspaceButton, named: "e2e-workspace open button", timeout: 1)
            if waitForWorkspaceDetailSurface(in: app, timeout: 8) {
                clearSessionSearchIfNeeded()
                return
            }
        }

        // Unknown state — force relaunch
        Self._app = nil
        try launchAndPair()
    }

    func dismissExtensionSheetIfNeeded(timeout: TimeInterval = 1) {
        dismissExtensionSurfaceIfNeeded(in: app, timeout: timeout)
    }

    private func clearSessionSearchIfNeeded() {
        let searchField = app.searchFields["Search sessions"]
        guard searchField.exists else { return }
        let rawValue = (searchField.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawValue.isEmpty && rawValue != "Search sessions" else { return }

        if searchField.isHittable {
            searchField.tap()
        } else {
            searchField.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let clearButton = searchField.buttons["Clear text"]
        if clearButton.exists {
            clearButton.tap()
        } else {
            searchField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: min(rawValue.count, 120)))
        }
        dismissKeyboardIfPresent()
    }

    private func dismissKeyboardIfPresent() {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        let searchButton = keyboard.buttons["Search"]
        if searchButton.exists {
            searchButton.tap()
            return
        }
        let returnButton = keyboard.buttons["Return"]
        if returnButton.exists {
            returnButton.tap()
            return
        }
        app.typeText("\n")
    }

    private func dismissExtensionSurfaceIfNeeded(in application: XCUIApplication, timeout: TimeInterval) {
        let buttons = [
            application.buttons["extension.dialog.cancel"],
            application.buttons["Cancel"],
            application.buttons["Done"],
        ]
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            for button in buttons where button.exists {
                if button.isHittable {
                    button.tap()
                } else {
                    button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                }
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
    }

    func tap(_ element: XCUIElement, named name: String, timeout: TimeInterval = 10) {
        if !element.exists {
            XCTAssertTrue(waitForElementToExist(element, timeout: timeout), "\(name) did not appear")
        }
        XCTAssertTrue(element.exists, "\(name) did not appear")
        XCTAssertTrue(element.isEnabled, "\(name) is disabled")

        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    func revealWorkspace(named workspaceName: String, timeout: TimeInterval = 20) -> Bool {
        guard waitForWorkspaceList(in: app, timeout: min(5, timeout)) else { return false }
        let workspaceList = workspaceListElement(in: app)

        let title = app.staticTexts[workspaceName]
        let openButton = app.buttons["workspace.open.\(workspaceName)"]
        if title.exists || openButton.exists { return true }

        let deadline = Date().addingTimeInterval(timeout)
        for _ in 0..<3 where Date() < deadline {
            workspaceList.swipeDown()
            if title.waitForExistence(timeout: 0.5) || openButton.exists { return true }
        }

        while Date() < deadline {
            if title.exists || openButton.exists { return true }
            workspaceList.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return title.exists || openButton.exists
    }

    // MARK: - Session Helpers

    /// Creates a new session by tapping the + button and waits for the app to open it.
    func createSession() {
        if chatSessionSurfaceExists(in: app) {
            return
        }
        if !workspaceDetailSurfaceExists(in: app), waitForChatSessionSurface(in: app, timeout: 1) {
            return
        }

        let newSessionButton = app.buttons["workspace.newSession"]
        XCTAssertTrue(
            waitForElementToExist(newSessionButton, timeout: 10),
            "New session button not found"
        )
        tap(newSessionButton, named: "new session button")

        XCTAssertTrue(
            waitForChatSessionSurface(in: app, timeout: 30),
            "Chat session did not appear after creating session"
        )
    }

    /// Taps the most recent session (first row after the section header) and waits for chat input.
    func enterLatestSession() {
        enterSession(at: 1)
    }

    /// Taps the session at the given cell index and waits for chat input.
    /// Index 0 is the section header; index 1 is the most recent session.
    func enterSession(at index: Int) {
        let sessionList = app.collectionViews["workspace.sessionList"]
        let sessionCell = sessionList.cells.element(boundBy: index)
        XCTAssertTrue(
            waitForElementToExist(sessionCell, timeout: 10),
            "Session cell at index \(index) did not appear"
        )
        tap(sessionCell, named: "session cell at index \(index)")

        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(
            waitForElementToExist(chatInput, timeout: 30),
            "Chat input did not appear after entering session at index \(index)"
        )
    }

    /// Taps a specific session row by stable session id and waits for chat input.
    func enterSession(id sessionId: String) {
        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(
            waitForElementToExist(sessionList, timeout: 10),
            "Session list did not appear before entering session \(sessionId)"
        )

        let rowIdentifier = "session.nav.\(sessionId)"
        let row = app.descendants(matching: .any)[rowIdentifier]
        for _ in 0..<14 where !waitForElementToExist(row, timeout: 0.5) {
            sessionList.swipeUp()
        }
        XCTAssertTrue(
            waitForElementToExist(row, timeout: 10),
            "Session row \(sessionId) did not appear"
        )

        dismissKeyboardIfPresent()
        for attempt in 0..<2 {
            tap(row, named: "session row \(sessionId)")
            if waitForChatSessionSurface(in: app, timeout: attempt == 0 ? 8 : 30) {
                return
            }
            guard app.collectionViews["workspace.sessionList"].exists else { break }
        }

        XCTAssertTrue(
            waitForChatSessionSurface(in: app, timeout: 5),
            "Chat input did not appear after entering session \(sessionId)"
        )
    }

    /// Creates a new session and enters it.
    func createAndEnterSession() {
        createSession()
    }

    /// Opens a known session through Oppi's `oppi://session/<id>` deep link.
    /// Use this when the test needs deterministic session re-entry, not row navigation coverage.
    func openSessionDeepLink(id sessionId: String, timeout: TimeInterval = 20) {
        let encodedSessionId = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId
        guard let url = URL(string: "oppi://session/\(encodedSessionId)") else {
            XCTFail("Invalid session deep link for \(sessionId)")
            return
        }

        // XCUIApplication.open can relaunch the app in UI tests. Do not let the
        // launch-only workspace fixtures race and replace the deep-linked route.
        app.launchEnvironment.removeValue(forKey: "OPPI_E2E_AUTO_OPEN_WORKSPACE")
        app.launchEnvironment.removeValue(forKey: "OPPI_E2E_AUTO_CREATE_SESSION")
        app.open(url)
        XCTAssertTrue(
            waitForChatSessionSurface(in: app, timeout: timeout),
            "Chat input did not appear after opening session deep link \(sessionId)"
        )
        XCTAssertEqual(waitForFocusedSessionId(sessionId, timeout: timeout), sessionId)
    }

    /// Navigates back from a chat session to the workspace detail screen.
    func navigateBackToWorkspace() {
        dismissExtensionSheetIfNeeded(timeout: 1)

        let sessionList = app.collectionViews["workspace.sessionList"]
        if waitForElementToExist(sessionList, timeout: 1) {
            return
        }

        if let backButton = navigationBackButton(), backButton.isHittable {
            tap(backButton, named: "navigation back button")
        }

        XCTAssertTrue(
            waitForElementToExist(sessionList, timeout: 10),
            "Session list did not reappear after navigating back"
        )
    }

    private func navigationBackButton() -> XCUIElement? {
        let candidates = [
            app.buttons["chat.toolbar.back"],
            app.navigationBars.buttons["BackButton"],
            app.navigationBars.buttons["Back"],
        ]
        if let match = candidates.first(where: { $0.exists }) {
            return match
        }
        let standardBack = app.navigationBars.buttons.matching(NSPredicate(format: "label == %@", "Back")).firstMatch
        return standardBack.exists ? standardBack : nil
    }

    // MARK: - Messaging

    func localEchoPrompt(_ marker: String) -> String {
        "Reply with exactly this token and nothing else: \(marker). No markdown. No explanation."
    }

    func waitForTimelineTextContaining(_ text: String, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(
            format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
            text,
            text
        )
        let match = app.descendants(matching: .any).matching(predicate).firstMatch
        if waitForElementToExist(match, timeout: timeout) {
            return true
        }

        let jumpToBottom = app.buttons["chat.jumpToBottom"]
        if jumpToBottom.exists && jumpToBottom.isHittable {
            tap(jumpToBottom, named: "jump to bottom button")
            if waitForElementToExist(match, timeout: 3) {
                return true
            }
        }
        return false
    }

    func waitForElementToExist(
        _ element: XCUIElement,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.1
    ) -> Bool {
        if element.exists {
            return true
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
            if element.exists {
                return true
            }
        }
        return element.exists
    }

    // MARK: - E2E Diagnostics

    @discardableResult
    func waitForE2EDiagnostic(
        _ identifier: String,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line,
        matching predicate: (String) -> Bool
    ) -> String {
        let element = app.staticTexts[identifier]
        if !element.exists {
            XCTAssertTrue(
                waitForElementToExist(element, timeout: 10),
                "E2E diagnostic \(identifier) did not appear",
                file: file,
                line: line
            )
        }
        XCTAssertTrue(
            element.exists,
            "E2E diagnostic \(identifier) did not appear",
            file: file,
            line: line
        )

        let deadline = Date().addingTimeInterval(timeout)
        var latest = element.label
        while Date() < deadline {
            latest = element.label
            if predicate(latest) {
                return latest
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTFail(
            "Diagnostic \(identifier) never matched. Last value: \(latest)",
            file: file,
            line: line
        )
        return latest
    }

    @discardableResult
    func waitForWebSocketConnected(timeout: TimeInterval = 20) -> String {
        waitForE2EDiagnostic("e2e.ws.status", timeout: timeout) { $0 == "connected" }
    }

    @discardableResult
    func waitForRequiredSplitStreamCapabilities(timeout: TimeInterval = 20) -> String {
        waitForE2EDiagnostic("e2e.stream.requiredCapabilities", timeout: timeout) { $0 == "ready" }
    }

    @discardableResult
    func waitForSessionStreamEndpoint(_ expected: String = "split_session", timeout: TimeInterval = 20) -> String {
        waitForE2EDiagnostic("e2e.stream.sessionEndpoint", timeout: timeout) { $0 == expected }
    }

    @discardableResult
    func waitForNoDesiredSubscription(sessionId: String, timeout: TimeInterval = 20) -> String {
        waitForE2EDiagnostic("e2e.ws.desiredSubscriptions", timeout: timeout) { value in
            !hasAnySubscription(value, sessionId: sessionId)
        }
    }

    @discardableResult
    func waitForNoAckedSubscription(sessionId: String, timeout: TimeInterval = 20) -> String {
        waitForE2EDiagnostic("e2e.ws.ackedSubscriptions", timeout: timeout) { value in
            !hasAnySubscription(value, sessionId: sessionId)
        }
    }

    @discardableResult
    func waitForFocusedSessionId(
        _ expected: String? = nil,
        excluding excluded: String? = nil,
        timeout: TimeInterval = 15
    ) -> String {
        waitForE2EDiagnostic("e2e.ws.focusedSession", timeout: timeout) { value in
            value != "none"
                && !value.isEmpty
                && (expected.map { value == $0 } ?? true)
                && (excluded.map { value != $0 } ?? true)
        }
    }

    @discardableResult
    func waitForDesiredSubscription(
        sessionId: String,
        level: String,
        timeout: TimeInterval = 20
    ) -> String {
        waitForE2EDiagnostic("e2e.ws.desiredSubscriptions", timeout: timeout) { value in
            hasSubscription(value, sessionId: sessionId, level: level)
        }
    }

    @discardableResult
    func waitForAckedSubscription(
        sessionId: String,
        level: String,
        timeout: TimeInterval = 20
    ) -> String {
        waitForE2EDiagnostic("e2e.ws.ackedSubscriptions", timeout: timeout) { value in
            hasSubscription(value, sessionId: sessionId, level: level)
        }
    }

    private func hasSubscription(_ value: String, sessionId: String, level: String) -> Bool {
        value
            .split(separator: ",")
            .contains { $0 == "\(sessionId):\(level)" }
    }

    private func hasAnySubscription(_ value: String, sessionId: String) -> Bool {
        value
            .split(separator: ",")
            .contains { $0.hasPrefix("\(sessionId):") }
    }

    /// Types a message, sends it, and waits for the full round-trip to complete
    /// (stop button appears then disappears, chat input reappears).
    func sendMessageAndWaitForResponse(_ message: String, timeout: TimeInterval = 300) {
        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(
            waitForElementToExist(chatInput, timeout: 15),
            "Chat input not available before sending"
        )
        dismissExtensionSheetIfNeeded(timeout: 1)
        chatInput.tap()
        let focusPredicate = NSPredicate(format: "hasKeyboardFocus == true")
        if !focusPredicate.evaluate(with: chatInput) {
            chatInput.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        }
        let focusDeadline = Date().addingTimeInterval(5)
        while !focusPredicate.evaluate(with: chatInput) && Date() < focusDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(focusPredicate.evaluate(with: chatInput), "Chat input did not gain keyboard focus")
        chatInput.typeText(message)

        let sendButton = app.buttons["chat.send"]
        tap(sendButton, named: "send button", timeout: 3)

        // Wait for streaming to start then finish
        let stopButton = app.buttons["chat.stop"]
        if waitForElementToExist(stopButton, timeout: 30) {
            let predicate = NSPredicate(format: "exists == false")
            let exp = XCTNSPredicateExpectation(predicate: predicate, object: stopButton)
            XCTAssertEqual(
                XCTWaiter.wait(for: [exp], timeout: timeout), .completed,
                "Agent did not finish responding within \(Int(timeout))s"
            )
        }

        XCTAssertTrue(
            waitForElementToExist(chatInput, timeout: 15),
            "Chat input did not reappear after response"
        )
    }
}
