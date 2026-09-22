import XCTest

/// Finger-input proof for the DEBUG-only fixture backed by the production HTML
/// render view, picker, inline composer, router, and review-comment store.
@MainActor
final class HTMLDOMAnnotationE2ETests: XCTestCase {
    private var app: XCUIApplication!

    func testBrowsePickParentCommentStashBrowseAndCancelWithRealTouches() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("HTML DOM annotation harness is simulator-only")
#endif
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "--html-dom-annotation-harness"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["diag.html.ready"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitForDiagnostic("diag.html.ready", equals: "1"), "HTML fixture did not become ready")
        let pageInput = app.textFields["Harness page input"]
        XCTAssertTrue(pageInput.waitForExistence(timeout: 5), "Fixture input missing")
        pageInput.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "Real WebKit keyboard did not appear")
        pageInput.typeText("SEED")
        XCTAssertTrue(waitForDiagnostic("diag.html.inputValue", equals: "SEED"))
        XCTAssertTrue(waitForDiagnostic("diag.html.nativePageResponder", equals: "1"))

        let pick = app.buttons["html.pick.enter"]
        XCTAssertTrue(pick.waitForExistence(timeout: 5), "Pick Element control missing")
        pick.tap()
        XCTAssertTrue(waitUntil { !self.app.keyboards.firstMatch.exists }, "Pick did not resign the native keyboard")
        XCTAssertTrue(waitForDiagnostic("diag.html.nativePageResponder", equals: "0"))
        XCTAssertEqual(diagnosticValue("diag.html.inputValue"), "SEED")
        app.buttons["html.pick.exit"].tap()

        let webView = app.webViews["html.annotation.webview"]
        XCTAssertTrue(webView.waitForExistence(timeout: 5), "Production WKWebView missing")
        let leaf = app.buttons["Leaf target"]
        let scrollStart = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.78))
        let scrollEnd = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.58))
        scrollStart.press(forDuration: 0.1, thenDragTo: scrollEnd)
        XCTAssertTrue(leaf.waitForExistence(timeout: 3) && leaf.isHittable, "Leaf target did not become tappable after real browsing scroll; frame \(leaf.frame)")
        XCTAssertTrue(leaf.frame.midY > 220 && leaf.frame.midY < app.frame.maxY - 120, "Leaf target was not scrolled into the safe screen region; frame \(leaf.frame)")
        XCTAssertEqual(diagnosticValue("diag.html.pageZoomPercent"), "100", "Initial production WKWebView pageZoom was not installed")
        XCTAssertEqual(diagnosticValue("diag.html.pageEvents"), "none")

        let shield = app.otherElements["html.pick.shield"]
        let selection = app.staticTexts["html.pick.label"]
        let highlight = app.otherElements["html.pick.highlight"]
        for zoom in ["100", "125", "135"] {
            let zoomButton = app.buttons["html.reader.zoom.\(zoom)"]
            XCTAssertTrue(zoomButton.waitForExistence(timeout: 3), "Missing reader zoom \(zoom)")
            zoomButton.tap()
            XCTAssertTrue(
                waitForDiagnostic("diag.html.pageZoomPercent", equals: zoom),
                "Reader zoom \(zoom) did not apply; actual \(diagnosticValue("diag.html.pageZoomPercent"))"
            )
            bringIntoSafeRegion(leaf, in: webView)
            let independentlyMeasuredTarget = leaf.frame
            pick.tap()
            assertSelectedLeaf(
                targetFrame: independentlyMeasuredTarget,
                shield: shield,
                selection: selection,
                highlight: highlight,
                label: "reader zoom \(zoom)"
            )
            app.buttons["html.pick.exit"].tap()
        }

        app.buttons["html.reader.zoom.100"].tap()
        XCTAssertTrue(waitForDiagnostic("diag.html.pageZoomPercent", equals: "100"))
        bringIntoSafeRegion(leaf, in: webView)
        let metricsBeforePinch = diagnosticValue("diag.html.viewportMetrics")
        webView.pinch(withScale: 1.5, velocity: 1)
        XCTAssertTrue(
            waitUntil { self.diagnosticValue("diag.html.viewportMetrics") != metricsBeforePinch },
            "Physical pinch did not change the real WebKit viewport metrics"
        )
        bringIntoSafeRegion(leaf, in: webView)
        let pinchedTarget = leaf.frame
        let eventsAfterBrowsePinch = diagnosticValue("diag.html.pageEvents")
        XCTAssertFalse(eventsAfterBrowsePinch.contains("click"), "Browse pinch unexpectedly clicked the page")
        pick.tap()
        assertSelectedLeaf(
            targetFrame: pinchedTarget,
            shield: shield,
            selection: selection,
            highlight: highlight,
            label: "physical Browse-mode pinch"
        )
        XCTAssertEqual(
            diagnosticValue("diag.html.pageEvents"),
            eventsAfterBrowsePinch,
            "Pick gesture reached page event handlers after the real Browse-mode pinch"
        )

        app.buttons["html.pick.parent"].tap()
        XCTAssertTrue(waitUntil { selection.label.contains("div#inner") }, "Select Parent did not choose the production parent")
        app.buttons["html.pick.comment"].tap()

        let commentInput = app.textViews["review-comment.inline-input"]
        XCTAssertTrue(commentInput.waitForExistence(timeout: 5), "Inline comment composer missing")
        commentInput.tap()
        commentInput.typeText("Parent needs a clearer label.")
        app.buttons["review-comment.inline-save"].tap()
        XCTAssertTrue(waitForDiagnostic("diag.html.stagedCount", equals: "1"), "Comment did not reach the production stash")
        app.buttons["html.pick.exit"].tap()

        leaf.tap()
        XCTAssertTrue(
            waitUntil { self.diagnosticValue("diag.html.pageEvents").hasSuffix("click") },
            "Browse did not restore a complete page click sequence"
        )

        let eventsBeforeCancelledPick = diagnosticValue("diag.html.pageEvents")
        pick.tap()
        XCTAssertTrue(shield.waitForExistence(timeout: 3))
        let currentTarget = leaf.frame
        shieldCoordinate(shield, at: CGPoint(x: currentTarget.midX, y: currentTarget.midY)).tap()
        XCTAssertTrue(waitForDiagnostic("diag.html.selectedID", equals: "leaf"))
        XCTAssertTrue(selection.label.contains("button#leaf"))
        XCTAssertEqual(diagnosticValue("diag.html.pageEvents"), eventsBeforeCancelledPick)
        app.buttons["html.pick.comment"].tap()
        XCTAssertTrue(commentInput.waitForExistence(timeout: 5))
        commentInput.tap()
        commentInput.typeText("Cancel this draft.")
        app.buttons["review-comment.inline-dismiss"].tap()
        XCTAssertTrue(waitUntil { !commentInput.exists }, "Cancelled composer remained visible")
        XCTAssertEqual(diagnosticValue("diag.html.stagedCount"), "1", "Cancel staged another comment")
        app.buttons["html.pick.exit"].tap()
        let eventsBeforeFinalBrowseTap = diagnosticValue("diag.html.pageEvents")
        leaf.tap()
        XCTAssertTrue(
            waitUntil { self.diagnosticValue("diag.html.pageEvents") != eventsBeforeFinalBrowseTap },
            "Browsing was not restored after cancel"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "html-dom-annotation-final-browse"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertSelectedLeaf(
        targetFrame: CGRect,
        shield: XCUIElement,
        selection: XCUIElement,
        highlight: XCUIElement,
        label: String
    ) {
        XCTAssertTrue(shield.waitForExistence(timeout: 3), "Native pick shield missing at \(label)")
        shieldCoordinate(shield, at: CGPoint(x: targetFrame.midX, y: targetFrame.midY)).tap()
        XCTAssertTrue(
            waitForDiagnostic("diag.html.selectedID", equals: "leaf"),
            "Leaf was not selected at \(label); status \(diagnosticValue("diag.html.selectionStatus")) DOM rect \(diagnosticValue("diag.html.targetRect")) AX frame \(targetFrame) metrics \(diagnosticValue("diag.html.viewportMetrics"))"
        )
        XCTAssertTrue(selection.exists && selection.label.contains("button#leaf"))
        XCTAssertTrue(highlight.waitForExistence(timeout: 3), "Native selection highlight missing at \(label)")
        XCTAssertEqual(highlight.frame.minX, targetFrame.minX, accuracy: 6, "minX at \(label)")
        XCTAssertEqual(highlight.frame.minY, targetFrame.minY, accuracy: 6, "minY at \(label)")
        XCTAssertEqual(highlight.frame.width, targetFrame.width, accuracy: 6, "width at \(label)")
        XCTAssertEqual(highlight.frame.height, targetFrame.height, accuracy: 6, "height at \(label)")
    }

    private func bringIntoSafeRegion(_ leaf: XCUIElement, in webView: XCUIElement) {
        for _ in 0..<6 {
            let frame = leaf.frame
            if leaf.exists, leaf.isHittable,
               frame.midY > 220, frame.midY < app.frame.maxY - 120 {
                return
            }
            if frame.midY >= app.frame.maxY - 120 || !leaf.exists {
                webView.swipeUp()
            } else {
                webView.swipeDown()
            }
        }
        XCTAssertTrue(leaf.exists && leaf.isHittable, "Leaf did not reach a safe region; frame \(leaf.frame)")
    }

    private func diagnosticValue(_ identifier: String) -> String {
        let element = app.descendants(matching: .any)[identifier]
        return element.value as? String ?? ""
    }

    private func waitForDiagnostic(_ identifier: String, equals expected: String, timeout: TimeInterval = 5) -> Bool {
        waitUntil(timeout: timeout) { self.diagnosticValue(identifier) == expected }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func shieldCoordinate(_ shield: XCUIElement, at screenPoint: CGPoint) -> XCUICoordinate {
        let frame = shield.frame
        return shield.coordinate(withNormalizedOffset: CGVector(
            dx: (screenPoint.x - frame.minX) / frame.width,
            dy: (screenPoint.y - frame.minY) / frame.height
        ))
    }
}
