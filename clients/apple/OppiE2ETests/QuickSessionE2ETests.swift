import XCTest

/// Focused Quick Session coverage kept outside the release gate.
final class QuickSessionE2ETests: E2ETestCase {
    override var e2eLaunchesWorkspaceHomeOnly: Bool { true }

    @MainActor
    func testQuickSessionChoosesWorkspaceModelThinkingAndSendsToChat() throws {
        XCTAssertTrue(waitForElementToExist(app.collectionViews["workspace.list"], timeout: 20), "Workspace home did not appear")

        tap(app.buttons["workspace.quickSession.start"], named: "quick session button")
        let input = app.textViews["chat.input"]
        XCTAssertTrue(waitForElementToExist(input, timeout: 20), "Quick Session input did not appear")

        tap(app.buttons["quickSession.workspacePicker"], named: "quick session workspace picker", timeout: 5)
        let workspaceRow = app.buttons["quickSession.workspace.e2e-workspace"]
        XCTAssertTrue(waitForElementToExist(workspaceRow, timeout: 10), "E2E workspace did not appear in Quick Session picker")
        tap(workspaceRow, named: "e2e workspace quick session row", timeout: 1)
        let expectedWorkspaceId = try e2eWorkspaceId()

        tap(app.buttons["session.toolbar.model"], named: "quick session model picker", timeout: 5)
        let modelRow = firstElement(identifierPrefix: "model.picker.row.")
        XCTAssertTrue(waitForElementToExist(modelRow, timeout: 20), "Model picker did not show any selectable model")
        let selectedModel = String(modelRow.identifier.dropFirst("model.picker.row.".count))
        tap(modelRow, named: "first model row", timeout: 1)
        XCTAssertTrue(waitForElementToExist(input, timeout: 10), "Quick Session input did not return after model selection")

        tap(app.buttons["session.toolbar.thinking"], named: "quick session thinking menu", timeout: 5)
        tap(app.buttons["High"], named: "High thinking option", timeout: 5)

        let marker = "E2E_QUICK_SESSION_SEND_OK"
        typeIntoTextView(input, text: marker)
        tap(app.buttons["chat.send"], named: "quick session send button", timeout: 5)

        XCTAssertTrue(waitForElementToExist(app.textViews["chat.input"], timeout: 30), "Created chat did not open")
        let sessionId = waitForFocusedSessionId(timeout: 30)
        XCTAssertTrue(waitForTimelineTextContaining(marker, timeout: 30), "Quick Session prompt did not appear in the created chat")

        let session = try e2eSession(sessionId: sessionId)
        XCTAssertEqual(session["workspaceId"] as? String, expectedWorkspaceId)
        let actualModel = try XCTUnwrap(session["model"] as? String, "Quick Session did not send the selected model override")
        XCTAssertTrue(
            actualModel == selectedModel || selectedModel.hasSuffix("/\(actualModel)"),
            "Quick Session model mismatch. selected=\(selectedModel), actual=\(actualModel)"
        )
        XCTAssertEqual(session["thinkingLevel"] as? String, "high")
    }

    @MainActor
    private func typeIntoTextView(_ element: XCUIElement, text: String) {
        tap(element, named: "text input", timeout: 5)
        let focusPredicate = NSPredicate(format: "hasKeyboardFocus == true")
        if !focusPredicate.evaluate(with: element) {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        }
        let deadline = Date().addingTimeInterval(5)
        while !focusPredicate.evaluate(with: element) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(focusPredicate.evaluate(with: element), "Text input did not gain keyboard focus")
        element.typeText(text)
    }

    @MainActor
    private func firstElement(identifierPrefix: String) -> XCUIElement {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }
}
