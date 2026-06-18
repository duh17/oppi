import XCTest

@MainActor
final class CodeBlockWrappingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Code block wrapping UI test is simulator-only")
#endif
        continueAfterFailure = false
    }

    func testWrapToggleKeepsCodeBlockHeaderCompactInExpandedParent() throws {
        app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--code-block-wrapping-harness",
            "-ApplePersistenceIgnoreState",
            "YES",
        ])
        app.launchEnvironment["PI_CODE_BLOCK_WRAPPING_HARNESS"] = "1"
        app.launch()

        XCTAssertEqual(
            waitForDiagnostic("harness.ready", timeout: 10, matching: { $0 == 1 }),
            1,
            "Code block wrapping harness did not become ready"
        )

        let wrapButton = app.buttons.matching(identifier: "markdown.codeBlock.wrap").firstMatch
        XCTAssertTrue(wrapButton.waitForExistence(timeout: 4), "Code block wrap toggle should be visible")
        wrapButton.tap()

        XCTAssertEqual(
            waitForDiagnostic("diag.codeBlockWrap.wrapEnabled", timeout: 4, matching: { $0 == 1 }),
            1,
            "Wrap diagnostics did not observe the tapped-on state"
        )

        let blockHeight = waitForDiagnostic(
            "diag.codeBlockWrap.blockHeight",
            timeout: 4,
            matching: { 80 ... 260 ~= $0 }
        )
        let headerHeight = waitForDiagnostic(
            "diag.codeBlockWrap.headerHeight",
            timeout: 4,
            matching: { 20 ... 32 ~= $0 }
        )
        let headerTop = waitForDiagnostic(
            "diag.codeBlockWrap.headerTop",
            timeout: 4,
            matching: { 0 ... 8 ~= $0 }
        )
        let headerGap = waitForDiagnostic(
            "diag.codeBlockWrap.headerGap",
            timeout: 4,
            matching: { 0 ... 8 ~= $0 }
        )

        XCTAssertLessThanOrEqual(blockHeight, 260, "Code block should hug its content instead of filling the expanded parent")
        XCTAssertLessThanOrEqual(headerHeight, 32, "Code block header should stay one compact row")
        XCTAssertLessThanOrEqual(headerTop, 8, "Code block header should stay pinned to the top of the block")
        XCTAssertLessThanOrEqual(headerGap, 8, "Code content should start directly below the header")
    }

    private func waitForDiagnostic(
        _ id: String,
        timeout: TimeInterval,
        matching predicate: (Int) -> Bool
    ) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        let element = app.descendants(matching: .any)[id]
        var lastValue: Int?

        while Date() < deadline {
            if element.waitForExistence(timeout: 0.2), let value = parseDiagnosticValue(element) {
                lastValue = value
                if predicate(value) {
                    return value
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTFail("Diagnostic \(id) did not reach an accepted value; last=\(lastValue.map(String.init) ?? "nil")")
        return lastValue ?? -1
    }

    private func parseDiagnosticValue(_ element: XCUIElement) -> Int? {
        let candidates = [element.value as? String, element.label]
        for candidate in candidates {
            guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                continue
            }
            if let value = Int(raw) { return value }
            if let range = raw.range(of: "-?\\d+", options: .regularExpression) {
                return Int(String(raw[range]))
            }
        }
        return nil
    }
}
