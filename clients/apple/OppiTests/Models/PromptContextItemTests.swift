import Foundation
import Testing
@testable import Oppi

/// What a staged comment sends: the server renders the block, so the client's part is the
/// place it names, the quote, and the note.
@Suite("Prompt context items")
@MainActor
struct PromptContextItemTests {
    @Test func patchHeaderPathsSendTheFileTheyName() {
        let item = PromptContextItem(comment: comment(reference: ReviewCommentReference(
            source: .gitDiff,
            path: "patch: *** Begin Patch\n*** Update File: /Users/example/workspace/oppi/clients/apple/Oppi/Features/Chat/ChatView.swift",
            startLine: 612,
            endLine: 616,
            selectedText: "ForEach(QuickCommentTemplate.quickCommentTemplates)"
        )))

        #expect(item.path == "clients/apple/Oppi/Features/Chat/ChatView.swift")
        #expect(item.placeTitle == "ChatView.swift:612–616")
    }

    @Test func workspacePathsAreShortenedUnlessVerbatimIsRequested() {
        let absolutePath = "/Users/example/workspace/oppi/.pi/skills/review/references/checklist.md"
        let staged = comment(reference: ReviewCommentReference(
            source: .file,
            path: absolutePath,
            startLine: 8,
            endLine: 8,
            selectedText: "Run focused checks."
        ))

        #expect(PromptContextItem(comment: staged).path == ".pi/skills/review/references/checklist.md")
        #expect(PromptContextItem(comment: staged, pathFormatting: .verbatim).path == absolutePath)
    }

    /// A PDF selection has no lines: it names the file and the pages the quote spans, and
    /// keeps them across a reload.
    @Test func pdfCommentSendsItsPagesAndQuoteAcrossAReload() throws {
        let suite = "PromptContextItemTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReviewCommentStore(defaults: defaults, keyPrefix: "pdf")
        let request = ReviewCommentSelectionRequest(
            selectedText: "Carry two litres per person",
            source: ReviewCommentSourceContext(
                sessionId: "s1",
                surface: .fullScreenSource,
                filePath: "docs/field-guide.pdf"
            ),
            pageRange: 2...3
        )
        #expect(ChatReviewCommentsController(store: store)
            .save(body: "Which spring?", request: request, localScopeId: "w1", sessionId: "s1") == nil)

        let reloaded = ReviewCommentStore(defaults: defaults, keyPrefix: "pdf")
        reloaded.load(workspaceId: "w1", sessionId: "s1")
        let item = try #require(reloaded.contextItems().first)
        #expect(item.path == "docs/field-guide.pdf")
        #expect(item.startPage == 2 && item.endPage == 3)
        #expect(item.startLine == nil)
        #expect(item.quote == "Carry two litres per person")
        #expect(item.note == "Which spring?")
        #expect(item.placeTitle == "field-guide.pdf pp. 2–3")
        #expect(item.opensPlace)
    }

    /// A comment on a chat message is placed by the message's start, read past Markdown marks
    /// and cut at a word, so its card never reads just "Chat".
    @Test func chatMessageCommentIsPlacedByTheMessageStart() {
        #expect(PromptContextItem.chatMessageTitle("\n## **Results** come back\n\nMore.") == "Results come back")
        #expect(PromptContextItem.chatMessageTitle("```swift\nlet x = 1\n```") == "let x = 1")
        #expect(PromptContextItem.chatMessageTitle("2. `oppi` restarts\tthe server") == "oppi restarts the server")
        #expect(PromptContextItem.chatMessageTitle(
            "Not yet. Clef-Flash is one of the last two models still running on the mini, after LiquidAI."
        ) == "Not yet. Clef-Flash is one of the last two models still…")
        #expect(PromptContextItem.chatMessageTitle("---\n\n") == nil)

        let labelled = PromptContextItem(comment: comment(reference: ReviewCommentReference(
            source: .timelineText,
            label: PromptContextItem.chatMessageTitle("Not yet. Clef-Flash is still running."),
            selectedText: "Clef-Flash is still running"
        )))
        #expect(labelled.placeTitle == "Not yet. Clef-Flash is still running.")
        #expect(labelled.quoteCodeLanguage == nil)
        let unlabelled = PromptContextItem(comment: comment(reference: ReviewCommentReference(source: .timelineText)))
        #expect(unlabelled.placeTitle == "Chat message")
    }

    private func comment(reference: ReviewCommentReference) -> ReviewComment {
        ReviewComment(
            id: "c1",
            workspaceId: "w1",
            sessionId: "s1",
            turnId: nil,
            author: .human,
            status: .staged,
            severity: nil,
            body: "Look here.",
            attachments: nil,
            reference: reference,
            createdAt: 1,
            updatedAt: 1,
            sentAt: nil
        )
    }
}
