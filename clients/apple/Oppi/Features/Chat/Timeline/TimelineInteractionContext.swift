import Foundation

/// Lightweight holder for review-comment selection state.
///
/// Lives on `ChatTimelineControllerContext` and is queried at apply-time
/// by row content views that support inline text selection for review comments.
/// Eliminates per-row threading of `reviewCommentSelectionRouter` /
/// `reviewCommentSourceContext` through every UIContentConfiguration struct.
@MainActor
final class TimelineInteractionContext {
    var reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    var sessionId: String = ""
    var reviewComments: [ReviewComment] = []

    /// Context object for renderer plumbing.
    var reviewCommentSelectionContext: ReviewCommentSelectionContext? {
        ReviewCommentSelectionContext(
            router: reviewCommentSelectionRouter,
            sessionId: sessionId
        )
    }

    /// Build a `ReviewCommentSourceContext` for the given surface.
    func sourceContext(
        surface: ReviewCommentSurfaceKind,
        sourceLabel: String? = nil,
        filePath: String? = nil,
        lineRange: ClosedRange<Int>? = nil,
        languageHint: String? = nil,
        timelineItemId: String? = nil
    ) -> ReviewCommentSourceContext? {
        reviewCommentSelectionContext?.sourceContext(
            surface: surface,
            sourceLabel: sourceLabel,
            filePath: filePath,
            lineRange: lineRange,
            languageHint: languageHint,
            timelineItemId: timelineItemId
        )
    }

    func inlineReviewAnnotations(for sourceContext: ReviewCommentSourceContext?) -> [ReviewCommentInlineAnnotation] {
        ReviewCommentInlineAnnotationMatcher.annotations(
            from: reviewComments,
            for: sourceContext
        )
    }
}
