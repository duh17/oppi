import XCTest

@MainActor
final class CodeGutterAlignmentUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Code gutter alignment UI test is simulator-only")
#endif
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testWrappedCodeGutterAlignsWithLogicalLines() throws {
        app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--code-gutter-alignment-harness",
            "-ApplePersistenceIgnoreState",
            "YES",
        ])
        app.launchEnvironment["PI_CODE_GUTTER_ALIGNMENT_HARNESS"] = "1"
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["harness.ready"].waitForExistence(timeout: 10),
            "Code gutter harness did not become ready"
        )
        XCTAssertEqual(readDiagnostic("diag.codeGutter.ready", timeout: 4), 1)

        let rowCount = readDiagnostic("diag.codeGutter.rowCount", timeout: 4)
        let maxDeltaHundredths = readDiagnostic("diag.codeGutter.maxDeltaHundredths", timeout: 4)
        let firstGapHundredths = readDiagnostic("diag.codeGutter.firstGapHundredths", timeout: 4)
        let lineHeightHundredths = readDiagnostic("diag.codeGutter.lineHeightHundredths", timeout: 4)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "wrapped-code-gutter-alignment"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertEqual(rowCount, 3, "Only logical source lines should receive gutter numbers")
        XCTAssertLessThanOrEqual(
            maxDeltaHundredths,
            50,
            "Gutter numbers should draw within 0.5 pt of the code line fragment"
        )
        XCTAssertGreaterThan(
            firstGapHundredths,
            lineHeightHundredths * 2,
            "The second line number must skip the wrapped continuation rows from the first logical line"
        )
    }

    private func readDiagnostic(_ id: String, timeout: TimeInterval) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        let element = app.descendants(matching: .any)[id]

        while Date() < deadline {
            if element.waitForExistence(timeout: 0.2), let value = parseDiagnosticValue(element) {
                return value
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTFail("Could not read diagnostic \(id)")
        return -1
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
