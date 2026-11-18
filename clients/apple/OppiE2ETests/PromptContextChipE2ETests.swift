import Foundation
import XCTest

/// Comments sent with a message, against the real server: a prompt carrying a file-line
/// comment and a PDF comment as context items shows the typed text with one chip per
/// comment (never the pasted block), and the file chip opens the real workspace file at
/// the commented lines. Run through `clients/apple/scripts/e2e.sh --native --durable
/// --faux-model` (iPad: `OPPI_SIM_DEVICE_PROFILE=ipad`): only a durable session hides the
/// rendered block behind the chips.
@MainActor
final class PromptContextChipE2ETests: E2ETestCase {
    nonisolated(unsafe) private var workspaceId = ""
    nonisolated(unsafe) private var sessionId = ""

    private static let filename = "CartTotals.swift"
    private static let source = (1...40).map { line in
        switch line {
        case 12: "    let total = items.reduce(0) { $0 + $1.price }"
        case 13: "    let tax = (total * rate).rounded(.toNearestOrEven)"
        case 14: "    return total + tax"
        default: "// CartTotals line \(line)"
        }
    }.joined(separator: "\n") + "\n"

    override var e2eLaunchesSessionsInboxOnly: Bool { true }
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }
    override var e2eRequiresFreshLaunch: Bool { true }

    override func configureE2ELaunch(_ application: XCUIApplication) {
        application.launchArguments += [
            "-dev.chenda.Oppi.theme.mode", "manual",
            "-dev.chenda.Oppi.theme.id", "dark",
        ]
    }

    override func seedE2EFixtures() throws {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let file = try createLabWorkspaceFileFixture(
            directoryName: "checkout-\(suffix)",
            filename: Self.filename,
            base64: Data(Self.source.utf8).base64EncodedString()
        )
        workspaceId = try createLabWorkspace(named: "Checkout \(suffix)", hostMount: file.hostMount)
        var body: [String: Any] = ["name": "Cart totals cleanup"]
        if E2ELabServerContext.durableSessions { body["engine"] = "durable" }
        let created = try e2eLabAPIJSON(method: "POST", path: "/workspaces/\(workspaceId)/sessions", body: body)
        sessionId = try XCTUnwrap((created["session"] as? [String: Any])?["id"] as? String, "Session create missing id")
    }

    func testCommentChipsShowAndTheFileChipOpensItsLines() throws {
        guard E2ELabServerContext.durableSessions else {
            throw XCTSkip("Context chips need a durable session (e2e.sh --durable)")
        }
        XCTAssertTrue(app.collectionViews["workspace.sessionList"].waitForExistence(timeout: 20), "All Sessions did not appear")
        openSessionDeepLink(id: sessionId)

        let requestId = UUID().uuidString
        let response = try e2eLabAPIJSON(
            method: "POST",
            path: "/workspaces/\(workspaceId)/sessions/\(sessionId)/command",
            body: [
                "type": "prompt",
                "requestId": requestId,
                "message": "Can you fix both of these before the TestFlight build?",
                "context": [
                    [
                        "id": "comment-line",
                        "source": "file",
                        "path": Self.filename,
                        "startLine": 12,
                        "endLine": 14,
                        "quote": "    let total = items.reduce(0) { $0 + $1.price }",
                        "note": "total shadows the stored property; rename it and keep the tax rounding.",
                    ],
                    [
                        "id": "comment-pdf",
                        "source": "file",
                        "path": "docs/field-guide.pdf",
                        "startPage": 3,
                        "endPage": 4,
                        "quote": "Pair from the old pairing screen.",
                        "note": "These install steps still mention the old pairing screen.",
                    ],
                ],
            ]
        )
        let accepted = (response["messages"] as? [[String: Any]] ?? []).contains {
            $0["requestId"] as? String == requestId && $0["success"] as? Bool == true
        }
        XCTAssertTrue(accepted, "The server refused the prompt with context: \(response)")

        let chips = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND identifier CONTAINS %@", "chat.timeline.user.", ".context.")
        )
        let lineChip = chips.matching(NSPredicate(format: "identifier ENDSWITH %@", ".context.0")).firstMatch
        let pdfChip = chips.matching(NSPredicate(format: "identifier ENDSWITH %@", ".context.1")).firstMatch
        XCTAssertTrue(lineChip.waitForExistence(timeout: 20), "The file-line comment chip did not render")
        XCTAssertTrue(pdfChip.waitForExistence(timeout: 5), "The PDF comment chip did not render")
        XCTAssertEqual(lineChip.label, "Comment CartTotals.swift:12–14")
        XCTAssertEqual(pdfChip.label, "Comment field-guide.pdf pp. 3–4")
        XCTAssertTrue(
            waitForTimelineTextContaining("Can you fix both of these before the TestFlight build?", timeout: 10),
            "The typed text is the bubble's text"
        )
        // The busy-send tip pops over the composer and takes the next tap; close it first.
        let tipDismiss = app.buttons["feature-tip.dismiss"]
        if tipDismiss.waitForExistence(timeout: 2) {
            tap(tipDismiss, named: "busy send tip dismiss", timeout: 1)
        }
        try saveLabScreenshot(name: "pane-context-chips")

        tap(lineChip, named: "file-line comment chip", timeout: 5)
        let code = app.textViews["Source code"]
        XCTAssertTrue(code.waitForExistence(timeout: 15), "The chip did not open CartTotals.swift")
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Focused lines 12 through 14"),
            object: code
        )
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 10), .completed,
                       "The file opened, but not at lines 12–14: \(code.value as? String ?? "no value")")
        Thread.sleep(forTimeInterval: 1)
        try saveLabScreenshot(name: "pane-context-chip-opened")
    }
}
