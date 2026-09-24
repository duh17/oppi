import XCTest

@MainActor
final class SemanticPickJourneyUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Semantic pick journey is simulator-only")
#endif
        continueAfterFailure = false
    }

    func testPickCommentStashProducesReadablePrompt() throws {
        app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--semantic-pick-harness",
            "-ApplePersistenceIgnoreState",
            "YES",
        ])
        app.launchEnvironment["PI_SEMANTIC_PICK_HARNESS"] = "1"
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["harness.ready"].waitForExistence(timeout: 15),
            "Semantic pick harness did not become ready"
        )

        try commentOn(
            diagram: "semantic-pick.diagram.flowchart",
            target: "semantic-pick.target.node.A",
            expected: ["**Diagram object:** Start · A", "A[Start]"]
        )
        try commentOn(
            diagram: "semantic-pick.diagram.pie",
            target: "semantic-pick.target.slice.1",
            expected: ["**Diagram object:** Cats", "Cats"]
        )
        try commentOn(
            diagram: "semantic-pick.diagram.sequence",
            target: "semantic-pick.target.participant.Alice",
            expected: ["**Diagram object:** Host · Alice", "Alice"]
        )

        XCTAssertEqual(diagnostic("diag.semantic.stagedCount"), "3")
        let prompt = diagnostic("diag.semantic.prompt")
        XCTAssertTrue(prompt.contains("## Review comments"), "Outgoing prompt was not built from the stash: \(prompt)")
        XCTAssertTrue(prompt.contains("**Diagram object:**"), "Outgoing prompt omitted the object reference: \(prompt)")
        XCTAssertFalse(prompt.contains("node:A"), "Outgoing prompt leaked an internal target ID: \(prompt)")
        XCTAssertFalse(prompt.contains("utf8-byte"), "Outgoing prompt leaked byte offsets: \(prompt)")
    }

    func testTwentyChoiceAmbiguityPickerReachesFirstAndLastWithoutDiagramActivation() throws {
        app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--semantic-pick-harness",
            "-ApplePersistenceIgnoreState",
            "YES",
        ])
        app.launchEnvironment["PI_SEMANTIC_PICK_HARNESS"] = "1"
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.descendants(matching: .any)["harness.ready"].waitForExistence(timeout: 15))
        app.buttons["semantic-pick.diagram.ambiguity"].tap()
        XCTAssertTrue(app.buttons["semantic-pick.enter"].waitForExistence(timeout: 5))

        func openChooser() {
            app.buttons["semantic-pick.enter"].tap()
            let target = app.buttons["semantic-pick.target.slice.1"]
            XCTAssertTrue(target.waitForExistence(timeout: 5))
            target.tap()
            XCTAssertTrue(app.scrollViews["semantic-pick.chooser-scroll"].waitForExistence(timeout: 5))
        }

        openChooser()
        let first = app.buttons["semantic-pick.choice.slice:1"]
        XCTAssertTrue(first.waitForExistence(timeout: 3) && first.isHittable)
        first.tap()
        XCTAssertTrue(app.buttons["semantic-pick.comment"].waitForExistence(timeout: 3))
        app.buttons["semantic-pick.leave"].tap()

        openChooser()
        let chooser = app.scrollViews["semantic-pick.chooser-scroll"]
        let last = app.buttons["semantic-pick.choice.slice:20"]
        for _ in 0..<16 where !last.isHittable {
            let start = chooser.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
            let end = chooser.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
            start.press(forDuration: 0.05, thenDragTo: end)
            XCTAssertFalse(app.buttons["semantic-pick.comment"].exists, "Scrolling the chooser selected the diagram behind it")
        }
        XCTAssertTrue(
            last.exists && last.isHittable,
            "Last ambiguity choice was not reachable; chooser frame \(chooser.frame), last frame \(last.frame)"
        )
        last.tap()
        XCTAssertTrue(app.buttons["semantic-pick.comment"].waitForExistence(timeout: 3))
    }

    private func commentOn(diagram: String, target: String, expected: [String]) throws {
        let diagramButton = app.buttons[diagram]
        XCTAssertTrue(diagramButton.waitForExistence(timeout: 5), "Missing diagram switch \(diagram)")
        diagramButton.tap()

        let pick = app.buttons["semantic-pick.enter"]
        XCTAssertTrue(pick.waitForExistence(timeout: 8), "Pick object did not appear for \(diagram)")
        pick.tap()
        if diagram == "semantic-pick.diagram.flowchart" {
            let canvas = app.scrollViews.firstMatch
            XCTAssertTrue(canvas.waitForExistence(timeout: 5))
            canvas.pinch(withScale: 1.3, velocity: 1)
        }

        let object = app.buttons[target]
        XCTAssertTrue(object.waitForExistence(timeout: 8), "Selectable object \(target) was not exposed")
        object.tap()

        let comment = app.buttons["semantic-pick.comment"]
        XCTAssertTrue(comment.waitForExistence(timeout: 5), "Comment did not appear after tapping \(target)")
        comment.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["review-comment.inline-composer"].waitForExistence(timeout: 5),
            "Comment did not open the existing composer"
        )
        let fix = app.buttons["Fix"]
        if fix.waitForExistence(timeout: 2) {
            fix.tap()
        } else {
            let input = app.textViews["review-comment.inline-input"]
            XCTAssertTrue(input.waitForExistence(timeout: 2))
            input.tap()
            input.typeText("Check this object")
        }
        let save = app.buttons["Save comment"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review-comment.inline-composer"].waitForNonExistence(timeout: 5)
        )

        let prompt = diagnostic("diag.semantic.prompt")
        for fragment in expected {
            XCTAssertTrue(
                prompt.contains(fragment),
                "Outgoing prompt for \(target) missing \(fragment): \(prompt)"
            )
        }
    }

    private func diagnostic(_ identifier: String) -> String {
        let element = app.descendants(matching: .any)[identifier]
        _ = element.waitForExistence(timeout: 2)
        let value = element.value as? String
        if let value, !value.isEmpty, value != identifier {
            return value
        }
        return element.label
    }
}
