import Foundation
import Testing
import UIKit
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

        let context = ReviewCommentSourceContext(
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

        let context = ReviewCommentSourceContext(sessionId: "s1", surface: .assistantProse)
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

        let proseContext = ReviewCommentSourceContext(
            sessionId: "s1",
            surface: .assistantProse,
            timelineItemId: "item-a"
        )
        let codeContext = ReviewCommentSourceContext(
            sessionId: "s1",
            surface: .assistantCodeBlock,
            languageHint: "swift",
            timelineItemId: "item-a"
        )

        #expect(ReviewCommentInlineAnnotationMatcher.annotations(from: [codeComment], for: proseContext).isEmpty)
        #expect(ReviewCommentInlineAnnotationMatcher.annotations(from: [codeComment], for: codeContext).map(\.id) == ["c1"])
    }

    @Test func fullScreenThinkingMatchesTimelineThinkingComments() {
        let comment = Self.comment(
            id: "c1",
            reference: Self.reference(
                source: .timelineText,
                selectedText: "reasoned text",
                timelineItemId: "thinking-a"
            )
        )
        let context = ReviewCommentSourceContext(
            sessionId: "s1",
            surface: .fullScreenThinking,
            timelineItemId: "thinking-a"
        )

        let annotations = ReviewCommentInlineAnnotationMatcher.annotations(
            from: [comment],
            for: context
        )

        #expect(annotations.map(\.id) == ["c1"])
    }

    @MainActor
    @Test func fullScreenToolContextsCanStayScopedToToolOutput() {
        let selectionContext = ReviewCommentSelectionContext(
            dispatcher: ReviewCommentSelectionRouter(dispatch: { _ in }),
            sessionId: "s1",
            sourceLabel: "tool output",
            timelineItemId: "tool-a",
            sourceSurfaceOverride: .toolExpandedText
        )
        let sourceContext = selectionContext.sourceContext(
            surface: .fullScreenCode,
            languageHint: "swift"
        )

        #expect(sourceContext.surface == .toolExpandedText)
        #expect(sourceContext.reviewCommentReferenceSource == .toolOutput)
        #expect(sourceContext.timelineItemId == "tool-a")
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

        let context = ReviewCommentSourceContext(
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

    @MainActor
    @Test func bubbleFramesStayInContentCoordinatesWhenTextViewScrolls() {
        let selected = "line 8 target"
        let text = (1...30)
            .map { line in line == 8 ? selected : "line \(line) filler" }
            .joined(separator: "\n")
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 320, height: 120))
        textView.isScrollEnabled = true
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.attributedText = NSAttributedString(
            string: text,
            attributes: [.font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)]
        )
        textView.layoutIfNeeded()

        let comment = Self.comment(
            id: "c1",
            reference: Self.reference(source: .file, path: "Sources/App.swift", selectedText: selected)
        )
        let context = ReviewCommentSourceContext(
            sessionId: "s1",
            surface: .fullScreenCode,
            filePath: "Sources/App.swift"
        )
        let annotations = ReviewCommentInlineAnnotationMatcher.annotations(from: [comment], for: context)
        ReviewCommentInlineAnnotationRenderer.apply(to: textView, annotations: annotations, sourceContext: context)

        guard let bubble = textView.subviews.first(where: { $0 is UIButton }) else {
            Issue.record("Expected an inline review bubble")
            return
        }
        let initialFrame = bubble.frame

        textView.contentOffset = CGPoint(x: 0, y: 60)
        ReviewCommentInlineAnnotationRenderer.repositionBubbleButtons(in: textView)

        #expect(abs(bubble.frame.minY - initialFrame.minY) < 1)
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
