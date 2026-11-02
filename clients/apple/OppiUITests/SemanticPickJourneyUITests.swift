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

    func testTwentyChoiceAmbiguityPickerReachesFirstAndLastWithoutDiagramActivation() throws {
        app = OppiTestLaunch.makeApp()
        app.launchArguments.append("--semantic-pick-harness")
        app.launchEnvironment["PI_SEMANTIC_PICK_HARNESS"] = "1"
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.descendants(matching: .any)["harness.ready"].waitUntilExists(timeout: 15))
        app.buttons["semantic-pick.diagram.ambiguity"].tap()
        XCTAssertTrue(app.buttons["semantic-pick.enter"].waitUntilExists(timeout: 5))

        func openChooser() {
            app.buttons["semantic-pick.enter"].tap()
            let target = app.buttons["semantic-pick.target.slice.1"]
            XCTAssertTrue(target.waitUntilExists(timeout: 5))
            target.tap()
            XCTAssertTrue(app.scrollViews["semantic-pick.chooser-scroll"].waitUntilExists(timeout: 5))
        }

        openChooser()
        let first = app.buttons["semantic-pick.choice.slice:1"]
        XCTAssertTrue(first.waitUntilExists(timeout: 3) && first.isHittable)
        first.tap()
        XCTAssertTrue(app.buttons["semantic-pick.comment"].waitUntilExists(timeout: 3))
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
        XCTAssertTrue(app.buttons["semantic-pick.comment"].waitUntilExists(timeout: 3))
    }
}
