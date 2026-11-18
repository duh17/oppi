import Foundation
import Testing
import UIKit
@testable import Oppi

/// Staged comments leave as context items beside the typed text, and the user's message shows
/// that text with each comment in full as a card, never the model's pasted block.
@Suite("Prompt context send")
@MainActor
struct PromptContextSendTests {
    private static let lineComment = PromptContextItem(comment: ReviewComment(
        id: "comment-line",
        workspaceId: "w1",
        sessionId: "s1",
        turnId: nil,
        author: .human,
        status: .staged,
        severity: nil,
        body: "Rename total; it shadows the property.",
        attachments: nil,
        reference: ReviewCommentReference(
            source: .file,
            path: "Sources/Checkout/App.swift",
            startLine: 12,
            endLine: 14,
            selectedText: "let total = items.count"
        ),
        createdAt: 1,
        updatedAt: 1,
        sentAt: nil
    ))
    private static let pdfComment = PromptContextItem(comment: ReviewComment(
        id: "comment-pdf",
        workspaceId: "w1",
        sessionId: "s1",
        turnId: nil,
        author: .human,
        status: .staged,
        severity: nil,
        body: "Is this still true above the tree line?",
        attachments: nil,
        reference: ReviewCommentReference(
            source: .file,
            path: "docs/field-guide.pdf",
            selectedText: "Carry two litres per person",
            startPage: 2,
            endPage: 2
        ),
        createdAt: 2,
        updatedAt: 2,
        sentAt: nil
    ))

    @Test func commentsTravelAsContextAndTheRowShowsThemInFull() async throws {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        var sent: [ClientMessage] = []
        connection._sendMessageForTesting = { sent.append($0) }
        connection._sendAckTimeoutForTesting = .seconds(2)
        let context = [Self.lineComment, Self.pdfComment]

        let result = handler.sendPrompt(
            text: "Please fix these.",
            attachments: [],
            context: context,
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )
        #expect(result.isEmpty)
        _ = await waitForTestCondition { await MainActor.run { !sent.isEmpty } }

        // The wire carries the typed text and the items; the server renders the block.
        let prompt = try #require(sent.first)
        guard case .prompt(let message, _, let sentContext, _, _, _) = prompt else {
            Issue.record("Expected a prompt, got \(prompt)")
            return
        }
        #expect(message == "Please fix these.")
        #expect(sentContext == context)
        let wire = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(prompt)) as? [String: Any]
        )
        let wireItems = try #require(wire["context"] as? [[String: Any]])
        #expect(wireItems.count == 2)
        #expect(wireItems[0]["path"] as? String == "Sources/Checkout/App.swift")
        #expect(wireItems[0]["startLine"] as? Int == 12)
        #expect(wireItems[0]["quote"] as? String == "let total = items.count")
        #expect(wireItems[1]["startPage"] as? Int == 2)
        #expect(wireItems[1]["note"] as? String == "Is this still true above the tree line?")

        // The optimistic row holds the typed text and the places.
        guard case .userMessage(let id, let text, _, _, let rowContext) = reducer.items.first else {
            Issue.record("Expected the optimistic user row")
            return
        }
        #expect(text == "Please fix these.")
        #expect(rowContext == context)

        // Drawn: the text, then each comment in full — its place, quote and note — and the
        // place opens it, by touch and by VoiceOver alike.
        var opened: [PromptContextItem] = []
        let view = UserTimelineRowContentView(configuration: UserTimelineRowConfiguration(
            text: text,
            images: [],
            context: rowContext,
            onOpenContextItem: { item, _ in opened.append(item) },
            canFork: false,
            onFork: nil,
            itemID: id
        ))
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        view.layoutIfNeeded()

        let scope = "chat.timeline.user.\(id).context"
        let linePlace = try #require(subview(identified: "\(scope).comment-line.place", in: view))
        let pdfPlace = try #require(subview(identified: "\(scope).comment-pdf.place", in: view))
        #expect(linePlace.accessibilityLabel == "App.swift:12–14")
        #expect(pdfPlace.accessibilityLabel == "field-guide.pdf p. 2")
        #expect(linePlace.accessibilityTraits.contains(.button))
        let lineCard = try #require(subview(identified: "\(scope).comment-line", in: view))
        let pdfCard = try #require(subview(identified: "\(scope).comment-pdf", in: view))
        #expect(allLabels(in: lineCard).contains("let total = items.count"), "The code quote shows")
        #expect(allLabels(in: lineCard).contains("Rename total; it shadows the property."))
        #expect(allLabels(in: pdfCard).contains("Carry two litres per person"), "The PDF quote shows")
        #expect(allLabels(in: pdfCard).contains("Is this still true above the tree line?"))
        #expect(!allText(in: view).contains("pane-context"), "The model's block never shows")

        #expect(linePlace.accessibilityActivate())
        #expect(opened == [Self.lineComment])
        (linePlace as? UIControl)?.sendActions(for: .touchUpInside)
        #expect(opened == [Self.lineComment, Self.lineComment])

        // Comments alone draw only their cards: no text area above them.
        let alone = UserTimelineRowContentView(configuration: UserTimelineRowConfiguration(
            text: "",
            images: [],
            context: [Self.pdfComment],
            canFork: false,
            onFork: nil,
            itemID: "alone"
        ))
        alone.frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        alone.layoutIfNeeded()
        #expect(visibleTextViews(in: alone).isEmpty, "A comments-only message draws a text area")
        #expect(subview(identified: "chat.timeline.user.alone.context.comment-pdf.note", in: alone) != nil)
        let request = Self.lineComment.openRequest(serverID: "server-1", workspaceID: "w1", sessionID: "s1")
        guard case .resourceReference(let reference) = request else {
            Issue.record("A file comment opens its file, got \(String(describing: request))")
            return
        }
        #expect(reference.target == "Sources/Checkout/App.swift")
        #expect(reference.lineAnchor == SourceLineAnchor(startLine: 12, endLine: 14))
    }

    /// An older server would drop the comments and still acknowledge the send, so the app
    /// sends them only where `capabilities.promptContext` says the server takes them.
    @Test func commentsGoOnlyToAServerThatTakesThem() {
        let connection = ServerConnection()
        let items = [Self.lineComment]
        #expect(connection.promptContextSendRefusal(items)?.contains("still loading") == true)
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        #expect(connection.promptContextSendRefusal(items)?.contains("Update the server") == true)
        #expect(connection.promptContextSendRefusal([]) == nil, "A message without comments always goes")
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true, promptContext: true)
        #expect(connection.promptContextSendRefusal(items) == nil)
    }

    @Test func commentsPastTheLimitsSayHowManyToRemove() {
        let small = Array(repeating: Self.lineComment, count: 25)
        #expect(PromptContextItem.sendLimitRefusal(small)
            == "A message can carry 20 comments. Remove 5 comments to send; the rest stay staged.")

        var long = Self.lineComment
        long.quote = String(repeating: "q", count: 3_900)
        long.note = String(repeating: "n", count: 3_900)
        // About 8 KB each: four fit in 32 KB, so six of ten must go.
        let refusal = PromptContextItem.sendLimitRefusal(Array(repeating: long, count: 10))
        #expect(refusal == "These comments are too long to send together. Remove 6 comments to send; the rest stay staged.")
        #expect(PromptContextItem.sendLimitRefusal(Array(repeating: long, count: 4)) == nil)

        var wordy = Self.lineComment
        wordy.note = String(repeating: "n", count: 4_001)
        #expect(PromptContextItem.sendLimitRefusal([Self.lineComment, wordy])?.hasPrefix("Comment 2 is longer") == true)
    }

    /// Comments staged before capture trimmed long selections are trimmed when sent.
    @Test func aLongSelectionStagedEarlierIsTrimmedWhenSent() {
        let selection = String(repeating: "x", count: 9_000)
        let item = PromptContextItem(comment: ReviewComment(
            id: "old", workspaceId: "w1", sessionId: "s1", turnId: nil, author: .human, status: .staged,
            severity: nil, body: "Too long", attachments: nil,
            reference: ReviewCommentReference(source: .file, path: "a.swift", selectedText: selection),
            createdAt: 1, updatedAt: 1, sentAt: nil
        ))
        #expect(item.quote?.utf16.count ?? 0 <= PromptContextItem.maxTextLength)
        #expect(item.quote?.hasSuffix("… trimmed, 9,000 characters") == true)
    }

    @Test func commentsAloneAreAMessage() async throws {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        var sent: [ClientMessage] = []
        connection._sendMessageForTesting = { sent.append($0) }
        connection._sendAckTimeoutForTesting = .seconds(2)

        #expect(handler.sendPrompt(
            text: "",
            attachments: [],
            context: [Self.pdfComment],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        ).isEmpty)
        _ = await waitForTestCondition { await MainActor.run { !sent.isEmpty } }
        guard case .prompt(let message, _, let context, _, _, _) = sent.first else {
            Issue.record("Expected a prompt")
            return
        }
        #expect(message.isEmpty)
        #expect(context == [Self.pdfComment])
        guard case .userMessage(_, let text, _, _, let rowContext) = reducer.items.first else {
            Issue.record("Expected the optimistic user row")
            return
        }
        #expect(text.isEmpty)
        #expect(rowContext == [Self.pdfComment])
    }
}

private func subview(identified identifier: String, in root: UIView) -> UIView? {
    if root.accessibilityIdentifier == identifier { return root }
    for child in root.subviews {
        if let match = subview(identified: identifier, in: child) { return match }
    }
    return nil
}

private func visibleTextViews(in root: UIView) -> [UITextView] {
    guard !root.isHidden else { return [] }
    return ((root as? UITextView).map { [$0] } ?? []) + root.subviews.flatMap { visibleTextViews(in: $0) }
}

private func allLabels(in root: UIView) -> [String] {
    ((root as? UILabel)?.text.map { [$0] } ?? []) + root.subviews.flatMap { allLabels(in: $0) }
}

private func allText(in root: UIView) -> String {
    ((root as? UITextView)?.text ?? "") + root.subviews.map { allText(in: $0) }.joined()
}
