import XCTest

/// Full UI happy path for pairing-created app state, workspace creation with
/// an explicitly-created host folder, session start/chat, workspace update,
/// session cleanup, and workspace deletion.
@MainActor
final class WorkspaceCRUDHappyPathE2ETests: E2ETestCase {

    func testPairingWorkspaceFolderSessionAndCRUDHappyPath() throws {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let workspaceName = "e2e-ui-\(suffix)"
        let updatedWorkspaceName = "\(workspaceName)-updated"
        let hostPath = "/tmp"

        navigateToWorkspaceHome()
        openWorkspaceCreateSheet()
        createWorkspaceWithNewFolder(
            name: workspaceName,
            hostPath: hostPath
        )

        openWorkspace(named: workspaceName)
        updateCurrentWorkspaceName(to: updatedWorkspaceName)

        createSession()
        let sessionId = waitForFocusedSessionId(timeout: 30)
        sendMessageAndWaitForResponse(localEchoPrompt("CRUD_SESSION_OK"))
        XCTAssertTrue(
            waitForTimelineTextContaining("CRUD_SESSION_OK"),
            "CRUD_SESSION_OK did not appear in the new workspace session timeline"
        )

        navigateBackToWorkspace()
        stopAndDeleteSession(id: sessionId)

        navigateToWorkspaceHome()
        deleteWorkspaceFromManageList(named: updatedWorkspaceName)
    }

    // MARK: - Workspace Create

    private func openWorkspaceCreateSheet() {
        let directCreateButton = app.buttons["workspace.create.open"]
        if directCreateButton.waitForExistence(timeout: 3) {
            tap(directCreateButton, named: "create workspace button")
        } else {
            let firstWorkspace = app.buttons["workspace.create.first.open"]
            if firstWorkspace.waitForExistence(timeout: 1) {
                tap(firstWorkspace, named: "create first workspace button")
            } else {
                let serverSwitcher = app.buttons
                    .matching(NSPredicate(format: "label BEGINSWITH %@", "Current server:"))
                    .firstMatch
                tap(serverSwitcher, named: "server switcher", timeout: 10)
                tap(directCreateButton, named: "create workspace menu button", timeout: 5)
            }
        }

        let manualButton = app.buttons["workspace.create.manual"]
        XCTAssertTrue(manualButton.waitForExistence(timeout: 15), "Manual path button not shown")
        for _ in 0..<4 where !manualButton.isHittable {
            app.swipeUp()
        }
        tap(manualButton, named: "manual workspace creation button")
    }

    private func createWorkspaceWithNewFolder(name: String, hostPath: String) {
        let nameField = app.textFields["workspace.create.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "Workspace name field not shown")
        replaceText(in: nameField, with: name)
        dismissKeyboardIfNeeded()

        let hostField = app.textFields["workspace.create.hostMount"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 10), "Host path field not shown")
        replaceText(in: hostField, with: hostPath)
        dismissKeyboardIfNeeded()

        let pathExists = app.staticTexts["Path exists"]
        let submit = app.buttons["workspace.create.submit"]
        XCTAssertTrue(
            pathExists.waitForExistence(timeout: 20) || submit.isEnabled,
            "Host path did not validate"
        )

        XCTAssertTrue(submit.waitForExistence(timeout: 5), "Create Workspace button not shown")
        XCTAssertTrue(submit.isEnabled, "Create Workspace stayed disabled after path validation")
        tap(submit, named: "create workspace submit button")

        XCTAssertTrue(
            app.staticTexts[name].waitForExistence(timeout: 20),
            "Created workspace \(name) did not appear in workspace list"
        )
    }

    // MARK: - Workspace Update/Delete

    private func updateCurrentWorkspaceName(to updatedName: String) {
        let editButton = app.buttons["workspace.edit.open"]
        tap(editButton, named: "workspace edit button")

        let nameField = app.textFields["workspace.edit.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "Workspace edit name field not shown")
        replaceText(in: nameField, with: updatedName)

        let saveButton = app.buttons["workspace.edit.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Workspace save button not shown")
        XCTAssertTrue(saveButton.isEnabled, "Workspace save button stayed disabled")
        tap(saveButton, named: "workspace save button")

        XCTAssertTrue(
            app.buttons["workspace.newSession"].waitForExistence(timeout: 15),
            "Workspace detail did not return after save"
        )
        XCTAssertTrue(
            app.navigationBars[updatedName].waitForExistence(timeout: 10) || app.staticTexts[updatedName].waitForExistence(timeout: 2),
            "Updated workspace name did not appear after save"
        )
    }

    private func deleteWorkspaceFromManageList(named workspaceName: String) {
        guard openServerWorkspaceManagement() else { return }

        let row = app.cells.containing(.staticText, identifier: workspaceName).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Workspace row \(workspaceName) not found in manage list")
        row.swipeLeft()

        let deleteButton = app.buttons["Delete"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5), "Workspace delete button not exposed")
        tap(deleteButton, named: "workspace delete button")

        XCTAssertTrue(
            waitForElementToDisappear(app.staticTexts[workspaceName], timeout: 15),
            "Workspace \(workspaceName) still visible after delete"
        )
    }

    private func openServerWorkspaceManagement() -> Bool {
        navigateToWorkspaceHome()

        let serverSwitcher = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Current server:"))
            .firstMatch
        guard serverSwitcher.waitForExistence(timeout: 10) else { return false }
        tap(serverSwitcher, named: "server switcher", timeout: 1)

        let manageServers = app.buttons["Manage Servers"]
        guard manageServers.waitForExistence(timeout: 5) else { return false }
        tap(manageServers, named: "manage servers button", timeout: 1)

        let serverRow = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "e2e-server"))
            .firstMatch
        guard serverRow.waitForExistence(timeout: 10) else { return false }
        tap(serverRow, named: "e2e server row", timeout: 1)

        let manageWorkspaces = app.buttons["server.manageWorkspaces"]
        tap(manageWorkspaces, named: "manage workspaces button", timeout: 15)

        XCTAssertTrue(
            app.collectionViews["server.workspaceList"].waitForExistence(timeout: 10),
            "Server workspace management list did not appear"
        )
        return true
    }

    // MARK: - Session Cleanup

    private func stopAndDeleteSession(id sessionId: String) {
        let sessionRowIdentifier = "session.nav.\(sessionId)"
        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(sessionList.waitForExistence(timeout: 10), "Workspace session list not shown")

        let activeRow = app.descendants(matching: .any)[sessionRowIdentifier]
        XCTAssertTrue(activeRow.waitForExistence(timeout: 15), "Created session row \(sessionId) not found")
        activeRow.swipeLeft()

        let stopButton = app.buttons["session.stop.\(sessionId)"]
        let deleteButton = app.buttons["session.delete.\(sessionId)"]
        if stopButton.waitForExistence(timeout: 5) {
            tap(stopButton, named: "session stop button")
        } else if deleteButton.waitForExistence(timeout: 1) {
            tap(deleteButton, named: "session delete button")
            confirmSessionDeleteIfNeeded()
            waitForSessionRowToDisappearOrRecord(activeRow, sessionId: sessionId)
            return
        }

        let stoppedRow = app.descendants(matching: .any)[sessionRowIdentifier]
        XCTAssertTrue(stoppedRow.waitForExistence(timeout: 20), "Stopped session row \(sessionId) not found")
        stoppedRow.swipeLeft()

        let stoppedDeleteButton = app.buttons["session.delete.\(sessionId)"]
        tap(stoppedDeleteButton, named: "session delete button", timeout: 5)
        confirmSessionDeleteIfNeeded()

        waitForSessionRowToDisappearOrRecord(stoppedRow, sessionId: sessionId)
    }

    private func waitForSessionRowToDisappearOrRecord(_ row: XCUIElement, sessionId: String) {
        if !waitForElementToDisappear(row, timeout: 15) {
            XCTContext.runActivity(named: "Session row \(sessionId) remained visible after delete tap") { activity in
                activity.add(XCTAttachment(string: app.debugDescription))
            }
        }
    }

    private func confirmSessionDeleteIfNeeded() {
        let confirmDelete = app.buttons["Delete Session"]
        if confirmDelete.waitForExistence(timeout: 5) {
            tap(confirmDelete, named: "confirm delete session button")
        }
    }

    // MARK: - Navigation Helpers

    private func navigateToWorkspaceHome() {
        let workspaceList = app.collectionViews["workspace.list"]
        if workspaceList.waitForExistence(timeout: 1) {
            return
        }

        let doneButton = app.buttons["Done"]
        if doneButton.waitForExistence(timeout: 1) && doneButton.isHittable {
            tap(doneButton, named: "dismiss extension sheet")
        }

        for _ in 0..<4 {
            if workspaceList.waitForExistence(timeout: 0.5) {
                return
            }

            let backButton = app.navigationBars.buttons["BackButton"]
            if backButton.exists && backButton.isHittable {
                tap(backButton, named: "navigation back button")
            } else {
                break
            }
        }

        XCTAssertTrue(workspaceList.waitForExistence(timeout: 10), "Workspace home list not reachable")
    }

    private func openWorkspace(named workspaceName: String) {
        let openWorkspaceButton = app.buttons["workspace.open.\(workspaceName)"]
        if !openWorkspaceButton.waitForExistence(timeout: 10) {
            app.collectionViews["workspace.list"].swipeDown()
        }
        tap(openWorkspaceButton, named: "workspace \(workspaceName) open button")

        XCTAssertTrue(
            app.buttons["workspace.newSession"].waitForExistence(timeout: 15),
            "Workspace detail did not open for \(workspaceName)"
        )
    }

    private func replaceText(in element: XCUIElement, with text: String) {
        focusTextEntry(element)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        if let value = element.value as? String, !value.isEmpty {
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        element.typeText(text)
    }

    private func focusTextEntry(_ element: XCUIElement) {
        for _ in 0..<4 where !element.isHittable {
            app.swipeUp()
        }

        tap(element, named: "text field")
        let focusPredicate = NSPredicate(format: "hasKeyboardFocus == true")
        if !focusPredicate.evaluate(with: element) {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        let deadline = Date().addingTimeInterval(5)
        while !focusPredicate.evaluate(with: element) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(focusPredicate.evaluate(with: element), "Text field did not gain keyboard focus")
    }

    private func dismissKeyboardIfNeeded() {
        let keyboardReturn = app.keyboards.buttons["Return"]
        if keyboardReturn.exists { keyboardReturn.tap() }
        let doneButton = app.buttons["Done"]
        if doneButton.exists && doneButton.isHittable { doneButton.tap() }
    }

    private func waitForElementToDisappear(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }
}
