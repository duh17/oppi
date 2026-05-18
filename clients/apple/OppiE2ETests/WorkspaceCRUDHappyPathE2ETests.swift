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
        let hostPath = "~/workspace/\(workspaceName)"
        let expandedHostPath = NSString(string: hostPath).expandingTildeInPath

        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: expandedHostPath)
        }

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
        let createButton = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.create."))
            .firstMatch

        if createButton.waitForExistence(timeout: 10) {
            createButton.tap()
        } else {
            let firstWorkspace = app.buttons["Create First Workspace"]
            XCTAssertTrue(firstWorkspace.waitForExistence(timeout: 10), "Create workspace button not found")
            firstWorkspace.tap()
        }

        let manualButton = app.buttons["workspace.create.manual"]
        XCTAssertTrue(manualButton.waitForExistence(timeout: 15), "Manual path button not shown")
        for _ in 0..<4 where !manualButton.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(manualButton.isHittable, "Manual path button is offscreen or not hittable")
        manualButton.tap()
    }

    private func createWorkspaceWithNewFolder(name: String, hostPath: String) {
        let nameField = app.textFields["workspace.create.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "Workspace name field not shown")
        nameField.tap()
        nameField.typeText(name)

        let hostField = app.textFields["workspace.create.hostMount"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 10), "Host path field not shown")
        hostField.tap()
        hostField.typeText(hostPath)

        let createMissingFolder = app.buttons["workspace.create.createMissingFolder"]
        XCTAssertTrue(
            createMissingFolder.waitForExistence(timeout: 20),
            "Missing-path create button did not appear for \(hostPath)"
        )
        createMissingFolder.tap()

        let confirmCreateFolder = app.buttons["workspace.create.confirmCreateFolder"]
        XCTAssertTrue(confirmCreateFolder.waitForExistence(timeout: 5), "Inline create confirmation not shown")
        confirmCreateFolder.tap()

        XCTAssertTrue(
            app.staticTexts["Path exists"].waitForExistence(timeout: 20),
            "Host path did not validate after creating folder"
        )

        let submit = app.buttons["workspace.create.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5), "Create Workspace button not shown")
        XCTAssertTrue(submit.isEnabled, "Create Workspace stayed disabled after folder creation")
        submit.tap()

        XCTAssertTrue(
            app.staticTexts[name].waitForExistence(timeout: 20),
            "Created workspace \(name) did not appear in workspace list"
        )
    }

    // MARK: - Workspace Update/Delete

    private func updateCurrentWorkspaceName(to updatedName: String) {
        let editButton = app.buttons["workspace.edit.open"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 10), "Workspace edit button not found")
        editButton.tap()

        let nameField = app.textFields["workspace.edit.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "Workspace edit name field not shown")
        replaceText(in: nameField, with: updatedName)

        let saveButton = app.buttons["workspace.edit.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Workspace save button not shown")
        XCTAssertTrue(saveButton.isEnabled, "Workspace save button stayed disabled")
        saveButton.tap()

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
        openServerWorkspaceManagement()

        let row = app.cells.containing(.staticText, identifier: workspaceName).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Workspace row \(workspaceName) not found in manage list")
        row.swipeLeft()

        let deleteButton = app.buttons["Delete"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5), "Workspace delete button not exposed")
        deleteButton.tap()

        XCTAssertTrue(
            waitForElementToDisappear(app.staticTexts[workspaceName], timeout: 15),
            "Workspace \(workspaceName) still visible after delete"
        )
    }

    private func openServerWorkspaceManagement() {
        navigateToWorkspaceHome()

        let serverSettings = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "server.settings."))
            .firstMatch
        XCTAssertTrue(serverSettings.waitForExistence(timeout: 10), "Server settings button not found")
        serverSettings.tap()

        let manageWorkspaces = app.buttons["server.manageWorkspaces"]
        XCTAssertTrue(manageWorkspaces.waitForExistence(timeout: 15), "Manage Workspaces link not found")
        manageWorkspaces.tap()

        XCTAssertTrue(
            app.collectionViews["server.workspaceList"].waitForExistence(timeout: 10),
            "Server workspace management list did not appear"
        )
    }

    // MARK: - Session Cleanup

    private func stopAndDeleteSession(id sessionId: String) {
        let sessionRowIdentifier = "session.nav.\(sessionId)"
        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(sessionList.waitForExistence(timeout: 10), "Workspace session list not shown")

        let activeRow = app.descendants(matching: .any)[sessionRowIdentifier]
        XCTAssertTrue(activeRow.waitForExistence(timeout: 15), "Created session row \(sessionId) not found")
        activeRow.swipeLeft()

        if app.buttons["Stop"].waitForExistence(timeout: 5) {
            app.buttons["Stop"].tap()
        } else if app.buttons["Delete"].waitForExistence(timeout: 1) {
            app.buttons["Delete"].tap()
            confirmSessionDeleteIfNeeded()
            XCTAssertTrue(
                waitForElementToDisappear(activeRow, timeout: 15),
                "Session row \(sessionId) still visible after delete"
            )
            return
        }

        let stoppedRow = app.descendants(matching: .any)[sessionRowIdentifier]
        XCTAssertTrue(stoppedRow.waitForExistence(timeout: 20), "Stopped session row \(sessionId) not found")
        stoppedRow.swipeLeft()

        let deleteButton = app.buttons["Delete"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5), "Session delete button not exposed")
        deleteButton.tap()
        confirmSessionDeleteIfNeeded()

        XCTAssertTrue(
            waitForElementToDisappear(stoppedRow, timeout: 15),
            "Session row \(sessionId) still visible after delete"
        )
    }

    private func confirmSessionDeleteIfNeeded() {
        let confirmDelete = app.buttons["Delete Session"]
        if confirmDelete.waitForExistence(timeout: 5) {
            confirmDelete.tap()
        }
    }

    // MARK: - Navigation Helpers

    private func navigateToWorkspaceHome() {
        let workspaceList = app.collectionViews["workspace.list"]
        if workspaceList.waitForExistence(timeout: 1) {
            return
        }

        for _ in 0..<4 {
            if workspaceList.waitForExistence(timeout: 0.5) {
                return
            }

            let backButton = app.navigationBars.buttons.firstMatch
            if backButton.exists && backButton.isHittable {
                backButton.tap()
            } else {
                break
            }
        }

        XCTAssertTrue(workspaceList.waitForExistence(timeout: 10), "Workspace home list not reachable")
    }

    private func openWorkspace(named workspaceName: String) {
        let workspaceLabel = app.staticTexts[workspaceName]
        if !workspaceLabel.waitForExistence(timeout: 10) {
            app.collectionViews["workspace.list"].swipeDown()
        }
        XCTAssertTrue(workspaceLabel.waitForExistence(timeout: 10), "Workspace \(workspaceName) not visible")
        workspaceLabel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        XCTAssertTrue(
            app.buttons["workspace.newSession"].waitForExistence(timeout: 15),
            "Workspace detail did not open for \(workspaceName)"
        )
    }

    private func replaceText(in element: XCUIElement, with text: String) {
        element.tap()
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        if let value = element.value as? String, !value.isEmpty {
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        element.typeText(text)
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
