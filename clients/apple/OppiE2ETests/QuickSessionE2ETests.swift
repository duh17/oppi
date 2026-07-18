import XCTest

/// Focused Quick Session coverage kept outside the release gate.
final class QuickSessionE2ETests: E2ETestCase {
    override var e2eLaunchesSessionsInboxOnly: Bool { true }

    @MainActor
    func testQuickSessionChoosesWorkspaceModelThinkingAndSendsToChat() throws {
        XCTAssertTrue(
            waitForElementToExist(app.collectionViews["workspace.sessionList"], timeout: 20),
            "Sessions inbox did not appear"
        )

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
        assertThinkingMenuRunsFromMaxToOff()
        tap(thinkingOption("high"), named: "High thinking option", timeout: 5)

        let marker = "E2E_QUICK_SESSION_SEND_OK"
        typeIntoTextView(input, text: marker)
        tap(app.buttons["chat.send"], named: "quick session send button", timeout: 5)

        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(waitForElementToExist(chatInput, timeout: 30), "Created chat did not open")
        let sessionId = waitForFocusedSessionId(timeout: 30)
        XCTAssertTrue(waitForTimelineTextContaining(marker, timeout: 30), "Quick Session prompt did not appear in the created chat")

        focusTextView(chatInput)
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 5),
            "Normal chat keyboard did not appear before opening the thinking picker"
        )
        tap(app.buttons["session.toolbar.thinking"], named: "normal chat thinking menu", timeout: 5)
        assertThinkingMenuRunsFromMaxToOff()
        tap(thinkingOption("high"), named: "current High thinking option", timeout: 5)

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
    func testQuickSessionDraftSurvivesDismissalAndRelaunch() {
        XCTAssertTrue(
            waitForElementToExist(app.collectionViews["workspace.sessionList"], timeout: 20),
            "Sessions inbox did not appear"
        )

        let marker = "E2E_QUICK_SESSION_RESTORED_\(UUID().uuidString)"
        openQuickSession()
        replaceText(in: app.textViews["chat.input"], with: marker)
        dismissQuickSession()

        openQuickSession()
        XCTAssertEqual(
            app.textViews["chat.input"].value as? String,
            marker,
            "Quick Session draft did not survive overlay dismissal"
        )
        dismissQuickSession()

        app.terminate()
        app.launch()
        XCTAssertTrue(
            waitForElementToExist(app.collectionViews["workspace.sessionList"], timeout: 30),
            "Sessions inbox did not return after relaunch"
        )

        openQuickSession()
        let restoredInput = app.textViews["chat.input"]
        XCTAssertEqual(
            restoredInput.value as? String,
            marker,
            "Quick Session draft did not survive app relaunch"
        )

        replaceText(in: restoredInput, with: "")
        dismissQuickSession()
    }

    @MainActor
    private func openQuickSession() {
        tap(app.buttons["workspace.quickSession.start"], named: "quick session button", timeout: 10)
        XCTAssertTrue(
            waitForElementToExist(app.textViews["chat.input"], timeout: 20),
            "Quick Session input did not appear"
        )
    }

    @MainActor
    private func dismissQuickSession() {
        let overlay = app.buttons["quickSession.overlay"].firstMatch
        XCTAssertTrue(overlay.waitForExistence(timeout: 5), "Quick Session overlay did not appear")
        let start = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        start.press(forDuration: 0.05, thenDragTo: end)

        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: overlay
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [dismissed], timeout: 5),
            .completed,
            "Quick Session did not dismiss"
        )
    }

    @MainActor
    private func replaceText(in element: XCUIElement, with text: String) {
        focusTextView(element)
        let currentValue = element.value as? String ?? ""
        if !currentValue.isEmpty {
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count))
        }
        if !text.isEmpty {
            element.typeText(text)
        }
        XCTAssertEqual(element.value as? String, text)
    }

    @MainActor
    private func assertThinkingMenuRunsFromMaxToOff() {
        let expectedOptions = [
            (id: "xhigh", label: "Max"),
            (id: "high", label: "High"),
            (id: "medium", label: "Medium"),
            (id: "low", label: "Low"),
            (id: "minimal", label: "Minimal"),
            (id: "off", label: "Off"),
        ]
        let options = expectedOptions.map { thinkingOption($0.id) }
        for (option, expected) in zip(options, expectedOptions) {
            XCTAssertTrue(
                option.waitForExistence(timeout: 5),
                "Thinking option \(expected.label) did not appear"
            )
            XCTAssertEqual(option.label, expected.label)
        }
        for (upper, lower) in zip(options, options.dropFirst()) {
            XCTAssertLessThan(
                upper.frame.midY,
                lower.frame.midY,
                "Thinking menu must run from Max at the top to Off at the bottom"
            )
        }
    }

    private func thinkingOption(_ level: String) -> XCUIElement {
        app.buttons["session.toolbar.thinking.option.\(level)"]
    }

    @MainActor
    private func typeIntoTextView(_ element: XCUIElement, text: String) {
        focusTextView(element)
        element.typeText(text)
    }

    @MainActor
    private func focusTextView(_ element: XCUIElement) {
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
    }

    @MainActor
    private func firstElement(identifierPrefix: String) -> XCUIElement {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }
}
