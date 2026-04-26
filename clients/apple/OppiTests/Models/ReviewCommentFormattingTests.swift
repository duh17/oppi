import Foundation
import Testing
@testable import Oppi

@Suite("Review comment formatting")
@MainActor
struct ReviewCommentFormattingTests {
    @Test func reviewBlockIncludesReferenceLinesAndSelectedText() {
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
        #expect(block.contains("Location: `Sources/App.swift`:12-14 (new, git diff)"))
        #expect(block.contains("Context:"))
        #expect(block.contains("```swift"))
        #expect(block.contains("if enabled"))
        #expect(block.contains("    run()"))
        #expect(!block.contains("> if enabled"))
        #expect(block.contains("Comment:"))
        #expect(block.contains("Please simplify this branch."))
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
