import Foundation
import Testing
@testable import Oppi

@Suite("Inline review comment annotations")
struct ReviewCommentInlineAnnotationTests {
    @Test func timelineItemIdScopesTimelineAnnotations() {
        let matching = Self.comment(
            id: "c1",
            sessionId: "s1",
            reference: Self.reference(
                source: .timelineText,
                selectedText: "target text",
                timelineItemId: "item-a"
            )
        )
        let otherItem = Self.comment(
            id: "c2",
            sessionId: "s1",
            reference: Self.reference(
                source: .timelineText,
                selectedText: "target text",
                timelineItemId: "item-b"
            )
        )

        let context = SelectedTextSourceContext(
            sessionId: "s1",
            surface: .assistantProse,
            timelineItemId: "item-a"
        )

        let annotations = ReviewCommentInlineAnnotationMatcher.annotations(
            from: [matching, otherItem],
            for: context
        )

        #expect(annotations.map(\.id) == ["c1"])
    }

    @Test func resolvedCommentsAreHiddenInline() {
        let staged = Self.comment(
            id: "c1",
            status: .staged,
            reference: Self.reference(source: .timelineText, selectedText: "selected")
        )
        let resolved = Self.comment(
            id: "c2",
            status: .resolved,
            reference: Self.reference(source: .timelineText, selectedText: "selected")
        )

        let context = SelectedTextSourceContext(sessionId: "s1", surface: .assistantProse)
        let annotations = ReviewCommentInlineAnnotationMatcher.annotations(
            from: [staged, resolved],
            for: context
        )

        #expect(annotations.map(\.id) == ["c1"])
    }

    @Test func languageHintsKeepCodeCommentsOutOfProse() {
        let codeComment = Self.comment(
            id: "c1",
            reference: Self.reference(
                source: .timelineText,
                selectedText: "let value = 42",
                languageHint: "swift",
                timelineItemId: "item-a"
            )
        )

        let proseContext = SelectedTextSourceContext(
            sessionId: "s1",
            surface: .assistantProse,
            timelineItemId: "item-a"
        )
        let codeContext = SelectedTextSourceContext(
            sessionId: "s1",
            surface: .assistantCodeBlock,
            languageHint: "swift",
            timelineItemId: "item-a"
        )

        #expect(ReviewCommentInlineAnnotationMatcher.annotations(from: [codeComment], for: proseContext).isEmpty)
        #expect(ReviewCommentInlineAnnotationMatcher.annotations(from: [codeComment], for: codeContext).map(\.id) == ["c1"])
    }

    @Test func fileAnnotationsRequireMatchingPath() {
        let matching = Self.comment(
            id: "c1",
            reference: Self.reference(source: .file, path: "Sources/App.swift", selectedText: "let app")
        )
        let otherPath = Self.comment(
            id: "c2",
            reference: Self.reference(source: .file, path: "Sources/Other.swift", selectedText: "let app")
        )

        let context = SelectedTextSourceContext(
            sessionId: "s1",
            surface: .fullScreenCode,
            filePath: "Sources/App.swift"
        )

        let annotations = ReviewCommentInlineAnnotationMatcher.annotations(
            from: [matching, otherPath],
            for: context
        )

        #expect(annotations.map(\.id) == ["c1"])
    }

    private static func comment(
        id: String,
        sessionId: String? = "s1",
        status: ReviewCommentStatus = .staged,
        reference: ReviewCommentReference
    ) -> ReviewComment {
        ReviewComment(
            id: id,
            workspaceId: "w1",
            sessionId: sessionId,
            turnId: nil,
            author: .human,
            status: status,
            severity: nil,
            body: "Please check this.",
            attachments: nil,
            reference: reference,
            createdAt: 1,
            updatedAt: 1,
            sentAt: nil
        )
    }

    private static func reference(
        source: ReviewCommentReferenceSource,
        path: String? = nil,
        selectedText: String,
        languageHint: String? = nil,
        timelineItemId: String? = nil
    ) -> ReviewCommentReference {
        ReviewCommentReference(
            source: source,
            label: nil,
            path: path,
            side: nil,
            startLine: nil,
            endLine: nil,
            selectedText: selectedText,
            languageHint: languageHint,
            toolCallId: nil,
            timelineItemId: timelineItemId,
            url: nil
        )
    }
}
