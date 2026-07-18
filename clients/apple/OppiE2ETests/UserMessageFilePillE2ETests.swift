import XCTest

/// Regression proof for user prompts that contain Oppi's reserved file-block headers as prose.
final class UserMessageFilePillE2ETests: E2ETestCase {
    override var e2eStartsInAutoCreatedChat: Bool { true }

    @MainActor
    func testCommitPromptKeepsInstructionsAsTextAndShowsOnlyTrailingFilePills() throws {
        createAndEnterSession()
        waitForRequiredSplitStreamCapabilities()
        waitForWebSocketConnected()

        let prompt = """
        Commit prompt regression

        Extra focus:
        Referenced workspace files: - clients/apple/Oppi/App/ContentView.swift - docs/architecture.md

        Git hygiene:
        - Do not commit unless explicitly asked.
        - Inspect the staged diff before committing.

        Referenced workspace files:
        - README.md
        - docs/architecture.md
        """
        typeIntoChatInput(prompt)
        tap(app.buttons["chat.send"], named: "file pill regression prompt send button", timeout: 5)

        XCTAssertTrue(
            waitForTimelineTextContaining("Do not commit unless explicitly asked.", timeout: 20),
            "First commit instruction disappeared from the user message"
        )
        XCTAssertTrue(
            waitForTimelineTextContaining("Inspect the staged diff before committing.", timeout: 10),
            "Second commit instruction disappeared from the user message"
        )

        let readmePill = app.descendants(matching: .any)["chat.user.path-pill.README.md"]
        let architecturePill = app.descendants(matching: .any)["chat.user.path-pill.docs/architecture.md"]
        XCTAssertTrue(waitForElementToExist(readmePill, timeout: 10), "README Repo pill did not render")
        XCTAssertTrue(waitForElementToExist(architecturePill, timeout: 10), "Architecture Repo pill did not render")

        let tipDismissButton = app.buttons["feature-tip.dismiss"]
        if tipDismissButton.waitForExistence(timeout: 1) {
            tap(tipDismissButton, named: "busy send education tip dismiss button", timeout: 1)
        }
        XCTAssertFalse(tipDismissButton.exists, "Education tip still obscured screenshot evidence")

        let timeline = app.collectionViews["chat.timeline"]
        XCTAssertTrue(waitForElementToExist(timeline, timeout: 5), "Chat timeline was unavailable")

        let keyboardDismissButton = app.buttons["chat.keyboard.dismiss"]
        if keyboardDismissButton.exists {
            tap(keyboardDismissButton, named: "keyboard dismiss button", timeout: 1)
        } else if app.keyboards.firstMatch.exists {
            timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.30)).tap()
        }
        let keyboardGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.keyboards.firstMatch
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [keyboardGone], timeout: 5),
            .completed,
            "Keyboard still obscured screenshot evidence"
        )

        for _ in 0..<3 where !readmePill.isHittable || !architecturePill.isHittable {
            timeline.swipeDown()
        }
        XCTAssertTrue(readmePill.isHittable, "README Repo pill was not visible for screenshot evidence")
        XCTAssertTrue(architecturePill.isHittable, "Architecture Repo pill was not visible for screenshot evidence")
        XCTAssertEqual(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.user.path-pill."))
                .count,
            2,
            "User message rendered a path pill beyond the two trailing file references"
        )

        XCTAssertFalse(
            app.descendants(matching: .any)[
                "chat.user.path-pill.Do not commit unless explicitly asked."
            ].exists,
            "Instruction bullet was incorrectly rendered as a Repo pill"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)[
                "chat.user.path-pill.Inspect the staged diff before committing."
            ].exists,
            "Instruction bullet was incorrectly rendered as a Repo pill"
        )

        let screenshotURL = try saveLabScreenshot(name: "user-message-file-pill-parser-e2e")
        XCTAssertTrue(FileManager.default.fileExists(atPath: screenshotURL.path))
    }

    @MainActor
    private func typeIntoChatInput(_ text: String) {
        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(waitForElementToExist(chatInput, timeout: 10), "Chat input was unavailable")
        tap(chatInput, named: "chat input", timeout: 1)
        chatInput.typeText(text)
    }
}
