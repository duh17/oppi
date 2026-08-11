import XCTest

@MainActor
final class WikiLineAnchorHarnessUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Wiki line-anchor harness is simulator-only")
#endif
        continueAfterFailure = false
    }

    func testWikiLineAnchorHarnessFocusesCodeAndRenderedMarkdown() throws {
        launchHarness()

        let codeLink = waitForLink(named: "Open code lines", timeout: 10)
        codeLink.tap()

        let codeOpened = waitForDiagnostic("diag.wikiAnchor.codeOpened", timeout: 5) { $0 == 1 }
        let codeHighlightEnclosureCount = waitForDiagnostic(
            "diag.wikiAnchor.codeHighlightEnclosureCount",
            timeout: 5
        ) { $0 == 1 }
        let codeHighlightGeometry = waitForDiagnostic(
            "diag.wikiAnchor.codeHighlightGeometry",
            timeout: 5
        ) { $0 == 1 }
        let codeGutterMarkerCount = waitForDiagnostic(
            "diag.wikiAnchor.codeGutterMarkerCount",
            timeout: 5
        ) { $0 == 1 }
        let codeFocusY = waitForDiagnostic("diag.wikiAnchor.codeFocusYHundredths", timeout: 5) { $0 > 0 }
        let codeUpperThird = waitForDiagnostic("diag.wikiAnchor.codeUpperThird", timeout: 5) { $0 == 1 }
        recordDiagnostics(
            name: "wiki-line-anchor-code-diagnostics",
            values: [
                "opened": codeOpened,
                "enclosureCount": codeHighlightEnclosureCount,
                "geometry": codeHighlightGeometry,
                "gutterMarkerCount": codeGutterMarkerCount,
                "focusYHundredths": codeFocusY,
                "upperThird": codeUpperThird,
            ]
        )
        saveScreenshot(name: "wiki-line-anchor-code")

        let dismissButton = app.buttons["fullscreen-code.dismiss"]
        XCTAssertTrue(dismissButton.waitForExistence(timeout: 5), "Anchored code viewer did not expose dismiss control")
        dismissButton.tap()
        _ = waitForDiagnostic("diag.wikiAnchor.codeOpened", timeout: 5) { $0 == 0 }

        let markdownLink = waitForLink(named: "Open markdown lines", timeout: 5)
        markdownLink.tap()

        let markdownOpened = waitForDiagnostic("diag.wikiAnchor.markdownOpened", timeout: 5) { $0 == 1 }
        let markdownHighlightCount = waitForDiagnostic("diag.wikiAnchor.markdownHighlightCount", timeout: 5) { $0 > 0 }
        let markdownHighlightEnclosureCount = waitForDiagnostic(
            "diag.wikiAnchor.markdownHighlightEnclosureCount",
            timeout: 5
        ) { $0 == 1 }
        let markdownHighlightAligned = waitForDiagnostic(
            "diag.wikiAnchor.markdownHighlightAligned",
            timeout: 5
        ) { $0 == 1 }
        let markdownVisibleHighlightCount = waitForDiagnostic(
            "diag.wikiAnchor.markdownVisibleHighlightCount",
            timeout: 5
        ) { $0 >= 2 }
        let markdownVisibleHighlightGeometryCount = waitForDiagnostic(
            "diag.wikiAnchor.markdownVisibleHighlightGeometryCount",
            timeout: 5
        ) { $0 == 1 }
        let markdownHighlightArea = waitForDiagnostic(
            "diag.wikiAnchor.markdownHighlightAreaHundredths",
            timeout: 5
        ) { $0 > 0 }
        let markdownHighlightFrontmost = waitForDiagnostic(
            "diag.wikiAnchor.markdownHighlightFrontmost",
            timeout: 5
        ) { $0 == 1 }
        let markdownFocusY = waitForDiagnostic("diag.wikiAnchor.markdownFocusYHundredths", timeout: 5) { $0 > 0 }
        let markdownUpperThird = waitForDiagnostic("diag.wikiAnchor.markdownUpperThird", timeout: 5) { $0 == 1 }
        recordDiagnostics(
            name: "wiki-line-anchor-markdown-diagnostics",
            values: [
                "opened": markdownOpened,
                "highlightCount": markdownHighlightCount,
                "enclosureCount": markdownHighlightEnclosureCount,
                "aligned": markdownHighlightAligned,
                "visibleHighlightCount": markdownVisibleHighlightCount,
                "visibleHighlightGeometryCount": markdownVisibleHighlightGeometryCount,
                "highlightAreaHundredths": markdownHighlightArea,
                "highlightFrontmost": markdownHighlightFrontmost,
                "focusYHundredths": markdownFocusY,
                "upperThird": markdownUpperThird,
            ]
        )
        saveScreenshot(name: "wiki-line-anchor-markdown")
    }

    private func launchHarness() {
        app = XCUIApplication()
        app.launchArguments = [
            "--wiki-line-anchor-harness",
            "-ApplePersistenceIgnoreState",
            "YES",
        ]
        app.launchEnvironment["PI_WIKI_LINE_ANCHOR_HARNESS"] = "1"
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["harness.ready"].waitForExistence(timeout: 10),
            "Wiki line-anchor harness did not become ready"
        )
    }

    private func waitForLink(named label: String, timeout: TimeInterval) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let candidates = [
                app.links[label],
                app.staticTexts[label],
                app.descendants(matching: .any)[label],
            ]
            if let match = candidates.first(where: { $0.exists && !$0.frame.isEmpty }) {
                return match
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTFail("Wiki line-anchor link \(label) did not appear")
        return app.descendants(matching: .any)[label]
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
            if element.exists, let value = parseDiagnosticValue(element) {
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
        for candidate in [element.value as? String, element.label] {
            guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                continue
            }
            if let value = Int(raw) {
                return value
            }
            if let range = raw.range(of: "-?\\d+", options: .regularExpression) {
                return Int(String(raw[range]))
            }
        }
        return nil
    }

    private func recordDiagnostics(name: String, values: [String: Int]) {
        let text = values.keys.sorted().map { key in
            "\(key)=\(values[key].map(String.init) ?? "?")"
        }.joined(separator: "\n") + "\n"
        print("[wiki-line-anchor] \(name): \(text.replacingOccurrences(of: "\n", with: " "))")

        let attachment = XCTAttachment(data: Data(text.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let directory = URL(fileURLWithPath: "/tmp/oppi-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: directory.appendingPathComponent("\(name).txt"), options: .atomic)
    }

    private func saveScreenshot(name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let directory = URL(fileURLWithPath: "/tmp/oppi-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(
            to: directory.appendingPathComponent("\(name).png"),
            options: .atomic
        )
    }
}
