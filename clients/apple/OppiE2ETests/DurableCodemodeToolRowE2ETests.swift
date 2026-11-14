import XCTest

/// A real `codemode` call on the scripted faux model (`faux:codemode`): the server declares the
/// `code` argument's role, and the collapsed row titles itself with the script's first line,
/// the way the expanded cell does, while the call runs and after it ends.
///
/// Run with `e2e.sh --native --durable --faux-model`; skipped otherwise.
@MainActor
final class DurableCodemodeToolRowE2ETests: E2ETestCase {
    private static let firstLine = "const rows = [];"
    /// Typed into the composer as one line; the faux model turns each `\n` into a line break.
    /// The bash sleep keeps the script running long enough to see the running row.
    private static let script = [
        firstLine,
        #"const names = ["Lake Union loop", "Green Lake", "Burke-Gilman", "Alki"];"#,
        "for (let i = 1; i <= 12; i++) {",
        "  const km = (5 + (i * 37 % 160) / 10).toFixed(1);",
        #"  const pace = `${4 + (i % 3)}:${String(10 + (i * 7) % 50).padStart(2, "0")}`;"#,
        "  rows.push(`| ${i} | ${names[i % names.length]} | ${km} km | ${pace} /km |`);",
        "}",
        #"await tools.bash({ command: "sleep 10" });"#,
        #"return rows.length + " routes";"#,
    ].joined(separator: #"\n"#)

    override var e2eAutoCreatesSessionOnLaunch: Bool { false }

    func testCollapsedCodemodeRowShowsTheScriptsFirstLine() throws {
        guard E2ELabServerContext.durableSessions else {
            throw XCTSkip("Needs e2e.sh --native --durable --faux-model")
        }

        createSession()
        waitForWebSocketConnected()
        let sessionId = waitForFocusedSessionId(timeout: 20)
        waitForAckedSubscription(sessionId: sessionId, level: "full")
        sendMessage("faux:codemode \(Self.script)")

        let timeline = app.collectionViews["chat.timeline"]
        // The title grows with the streamed arguments; it settles on the whole first line.
        let header = timeline.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'chat.timeline.row.' AND identifier ENDSWITH '.header' AND label == %@",
            Self.firstLine
        )).firstMatch
        XCTAssertTrue(waitForElementToExist(header, timeout: 90), "No codemode row titled with the script's first line")
        XCTAssertTrue(app.buttons["chat.stop"].exists, "The turn ended before the running row was seen")
        try saveLabScreenshot(name: "codemode-collapsed-running")

        let stopped = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.buttons["chat.stop"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 120), .completed, "The turn did not end")
        try saveLabScreenshot(name: "codemode-collapsed-done")
        XCTAssertEqual(header.label, Self.firstLine, "Collapsed finished row title")

        tap(header, named: "codemode row header")
        let expanded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS 'Expanded'"),
            object: header
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 10), .completed, "The row did not expand")
        try saveLabScreenshot(name: "codemode-expanded-done")
        XCTAssertEqual(header.label, Self.firstLine, "Expanded row title")
    }
}
