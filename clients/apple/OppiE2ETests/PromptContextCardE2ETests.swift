import Foundation
import UIKit
import XCTest

/// Comments sent with a message, against the real server: each shows in the user's message
/// in full, as a card with its place, the selected text and the note, never the pasted block.
/// A message with a file-line, a PDF-page and a chat-message comment shows all three; a
/// comment sent alone, queued while the agent answers, shows the same card in the queue and
/// then as a message with no empty text; the file card's place opens the real workspace file
/// at the commented lines. Run through `clients/apple/scripts/e2e.sh --native --durable
/// --faux-model` (iPad: `OPPI_SIM_DEVICE_PROFILE=ipad`): only a durable session hides the
/// rendered block behind the cards.
@MainActor
final class PromptContextCardE2ETests: E2ETestCase {
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

    private static let question = "Where is tax rounded?"
    /// The faux model's answer starts by echoing the question; a comment on that answer is
    /// placed by its start, as the app names it when the comment is made.
    private static let answerTitle = "Durable faux reply to: \(question)"
    private static let lineQuote = """
        let total = items.reduce(0) { $0 + $1.price }
        let tax = (total * rate).rounded(.toNearestOrEven)
        return total + tax
    """
    private static let lineNote = "total shadows the stored property; rename it and keep the tax rounding."
    private static let pdfQuote = "Open Settings, then Pair New Device, and scan the code on the Mac."
    private static let pdfNote = "These install steps still mention the old pairing screen."
    private static let chatQuote = "When the turn ends, the committed reply replaces the live row."
    private static let chatNote = "Does the swap keep my scroll position when I'm reading further up?"
    private static let aloneQuote = "It streams in small chunks so the app shows a live row first."
    private static let aloneNote = "How small? On cellular the row stutters for me."

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

    func testCommentsShowInFullAndTheFileCardOpensItsLines() throws {
        guard E2ELabServerContext.durableSessions else {
            throw XCTSkip("Context cards need a durable session (e2e.sh --durable)")
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        XCTAssertTrue(app.collectionViews["workspace.sessionList"].waitForExistence(timeout: 20), "All Sessions did not appear")
        openSessionDeepLink(id: sessionId)

        // An answer to comment on.
        try send("prompt", message: Self.question, context: [])
        XCTAssertTrue(waitForTimelineTextContaining("End of faux reply.", timeout: 60), "The first answer did not finish")

        try send("prompt", message: "Can you fix these before the TestFlight build?", context: [
            [
                "id": "lineComment",
                "source": "file",
                "path": Self.filename,
                "startLine": 12,
                "endLine": 14,
                "quote": Self.lineQuote,
                "note": Self.lineNote,
            ],
            [
                "id": "pdfComment",
                "source": "file",
                "path": "docs/field-guide.pdf",
                "startPage": 3,
                "quote": Self.pdfQuote,
                "note": Self.pdfNote,
            ],
            [
                "id": "chatComment",
                "source": "timeline_text",
                "label": Self.answerTitle,
                "quote": Self.chatQuote,
                "note": Self.chatNote,
            ],
        ])
        // A comment alone, queued behind the answer that is streaming.
        try send("follow_up", message: "", context: [
            [
                "id": "aloneComment",
                "source": "timeline_text",
                "label": Self.answerTitle,
                "quote": Self.aloneQuote,
                "note": Self.aloneNote,
            ],
        ])

        let line = card(in: "chat.timeline.user.", "lineComment")
        XCTAssertTrue(line.note.waitForExistence(timeout: 20), "The file-line comment's card did not render")
        XCTAssertEqual(line.place.label, "CartTotals.swift:12–14")
        XCTAssertEqual(line.quote.label, Self.lineQuote)
        XCTAssertEqual(line.note.label, Self.lineNote)
        let pdf = card(in: "chat.timeline.user.", "pdfComment")
        XCTAssertEqual(pdf.place.label, "field-guide.pdf p. 3")
        XCTAssertEqual(pdf.quote.label, Self.pdfQuote)
        XCTAssertEqual(pdf.note.label, Self.pdfNote)
        let chat = card(in: "chat.timeline.user.", "chatComment")
        XCTAssertEqual(chat.place.label, Self.answerTitle, "A chat-message comment is placed by the message it quotes")
        XCTAssertEqual(chat.quote.label, Self.chatQuote)
        XCTAssertEqual(chat.note.label, Self.chatNote)
        XCTAssertTrue(
            waitForTimelineTextContaining("Can you fix these before the TestFlight build?", timeout: 10),
            "The typed text is the bubble's text"
        )
        dismissBusySendTip()
        for element in [line.quote, line.note, pdf.quote, pdf.note, chat.quote, chat.note] {
            XCTAssertTrue(isOnScreen(element), "\(element.identifier) is not visible in the bubble")
        }
        try saveLabScreenshot(name: "pane-context-cards-message-\(device)")

        // The queued comment shows the card it will send.
        let queuePill = app.descendants(matching: .any)["extension-strip-aboveEditor-pill-message-queue"]
        tap(queuePill, named: "message queue pill", timeout: 10)
        let queued = card(in: "chat.messageQueue.context.", "aloneComment")
        XCTAssertTrue(queued.note.waitForExistence(timeout: 10), "The queued comment's card did not render")
        XCTAssertEqual(queued.place.label, Self.answerTitle)
        XCTAssertEqual(queued.quote.label, Self.aloneQuote)
        XCTAssertEqual(queued.note.label, Self.aloneNote)
        try saveLabScreenshot(name: "pane-context-cards-queue-\(device)")
        tap(queuePill, named: "message queue pill", timeout: 5)

        // Sent once the answer ends: a message that is only its card.
        let alone = card(in: "chat.timeline.user.", "aloneComment")
        if !alone.note.waitForExistence(timeout: 60) {
            _ = waitForTimelineTextContaining(Self.aloneNote, timeout: 3)
        }
        XCTAssertTrue(alone.note.exists, "The comment sent alone did not render as a message")
        XCTAssertEqual(alone.quote.label, Self.aloneQuote)
        // No empty text area: the message row holds the card and no text view.
        let aloneRow = app.cells.containing(.any, identifier: alone.note.identifier).firstMatch
        XCTAssertTrue(aloneRow.exists, "The comment-only message row is missing")
        XCTAssertEqual(aloneRow.textViews.count, 0, "The comment-only message draws a text area")
        Thread.sleep(forTimeInterval: 1)
        try saveLabScreenshot(name: "pane-context-cards-alone-\(device)")

        // The file card's place opens the file at the commented lines.
        var swipes = 0
        while !line.place.isHittable, swipes < 6 {
            app.collectionViews.firstMatch.swipeDown()
            swipes += 1
        }
        tap(line.place, named: "file-line comment place", timeout: 5)
        let code = app.textViews["Source code"]
        XCTAssertTrue(code.waitForExistence(timeout: 15), "The place did not open CartTotals.swift")
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Focused lines 12 through 14"),
            object: code
        )
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 10), .completed,
                       "The file opened, but not at lines 12–14: \(code.value as? String ?? "no value")")
        Thread.sleep(forTimeInterval: 1)
        try saveLabScreenshot(name: "pane-context-cards-opened-\(device)")
    }

    private func send(_ type: String, message: String, context: [[String: Any]]) throws {
        let requestId = UUID().uuidString
        var body: [String: Any] = ["type": type, "requestId": requestId, "message": message]
        if !context.isEmpty { body["context"] = context }
        let response = try e2eLabAPIJSON(
            method: "POST",
            path: "/workspaces/\(workspaceId)/sessions/\(sessionId)/command",
            body: body
        )
        let accepted = (response["messages"] as? [[String: Any]] ?? []).contains {
            $0["requestId"] as? String == requestId && $0["success"] as? Bool == true
        }
        XCTAssertTrue(accepted, "The server refused the \(type): \(response)")
    }

    /// A card's place, quote and note, by the comment's id under `prefix` (a timeline row or
    /// the queue).
    private func card(in prefix: String, _ commentId: String) -> (place: XCUIElement, quote: XCUIElement, note: XCUIElement) {
        func part(_ name: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                prefix,
                ".\(commentId).\(name)"
            )).firstMatch
        }
        return (part("place"), part("quote"), part("note"))
    }

    private func isOnScreen(_ element: XCUIElement) -> Bool {
        guard element.exists, !element.frame.isEmpty else { return false }
        return app.windows.firstMatch.frame.contains(CGPoint(x: element.frame.midX, y: element.frame.midY))
    }

    /// The busy-send tip pops over the composer and takes the next tap; close it first.
    private func dismissBusySendTip() {
        let tipDismiss = app.buttons["feature-tip.dismiss"]
        if tipDismiss.waitForExistence(timeout: 2) {
            tap(tipDismiss, named: "busy send tip dismiss", timeout: 1)
        }
    }
}
