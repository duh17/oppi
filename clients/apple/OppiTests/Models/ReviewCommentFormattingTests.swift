import Foundation
import Testing
@testable import Oppi

@Suite("Review comment formatting")
@MainActor
struct ReviewCommentFormattingTests {
    @Test func reviewBlockIncludesWhereSelectedTextAndComment() {
        let comment = ReviewComment(
            id: "c1",
            workspaceId: "w1",
            sessionId: "s1",
            turnId: nil,
            author: .human,
            status: .staged,
            severity: nil,
            body: "Please simplify this branch.",
            attachments: nil,
            reference: ReviewCommentReference(
                source: .gitDiff,
                label: nil,
                path: "Sources/App.swift",
                side: "new",
                startLine: 12,
                endLine: 14,
                selectedText: "if enabled {\n    run()\n}",
                toolCallId: nil,
                timelineItemId: nil,
                url: nil
            ),
            createdAt: 1,
            updatedAt: 1,
            sentAt: nil
        )

        let block = ReviewCommentStore.reviewBlock(for: [comment])

        #expect(block.contains("## Review comments"))
        #expect(block.contains("### Comment 1"))
        #expect(block.contains("**Where:** `Sources/App.swift`:12-14 (new, git diff)"))
        #expect(block.contains("**Selected text:**"))
        #expect(block.contains("```swift"))
        #expect(block.contains("if enabled"))
        #expect(block.contains("    run()"))
        #expect(block.contains("**Comment:**"))
        #expect(block.contains("> Please simplify this branch."))
    }

    @Test func reviewBlockIncludesTimelineSelectedText() {
        let comment = ReviewComment(
            id: "c1",
            workspaceId: "w1",
            sessionId: "s1",
            turnId: nil,
            author: .human,
            status: .staged,
            severity: nil,
            body: "Explain this.",
            attachments: nil,
            reference: ReviewCommentReference(
                source: .timelineText,
                label: "Thinking",
                path: nil,
                side: nil,
                startLine: nil,
                endLine: nil,
                selectedText: "what seems to be the default device.\nMaybe I should run the installation.",
                toolCallId: nil,
                timelineItemId: nil,
                url: nil
            ),
            createdAt: 1,
            updatedAt: 1,
            sentAt: nil
        )

        let block = ReviewCommentStore.reviewBlock(for: [comment])

        #expect(block.contains("**Where:** Thinking (timeline text)"))
        #expect(block.contains("**Selected text:**"))
        #expect(block.contains("what seems to be the default device."))
        #expect(block.contains("Maybe I should run the installation."))
        #expect(block.contains("**Comment:**\n\n> Explain this."))
        #expect(!block.contains("Location:"))
        #expect(!block.contains("Context:"))
    }

    @Test func reviewBlockIgnoresAlreadySentComments() {
        let sent = ReviewComment(
            id: "c1",
            workspaceId: "w1",
            sessionId: "s1",
            turnId: nil,
            author: .human,
            status: .sent,
            severity: nil,
            body: "Already sent",
            attachments: nil,
            reference: ReviewCommentReference(
                source: .timelineText,
                label: "Assistant message",
                path: nil,
                side: nil,
                startLine: nil,
                endLine: nil,
                selectedText: nil,
                toolCallId: nil,
                timelineItemId: nil,
                url: nil
            ),
            createdAt: 1,
            updatedAt: 1,
            sentAt: 2
        )

        #expect(ReviewCommentStore.reviewBlock(for: [sent]).isEmpty)
    }
}
