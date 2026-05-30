import SwiftUI

/// Embeds ``FullScreenCodeViewController`` inside a SwiftUI NavigationStack.
///
/// The UIKit view controller provides its own internal `UINavigationController`
/// with Liquid Glass floating pills — identical chrome to the sheet presentation
/// used by the timeline full-screen viewer. The hosting SwiftUI view should hide
/// its navigation bar (`.toolbarVisibility(.hidden, for: .navigationBar)`) to
/// avoid double nav bars.
///
/// The dismiss (back) button calls SwiftUI's `dismiss()` to pop the navigation.
///
/// Review comment selection routing: reads from `\.reviewCommentSelectionScope`
/// in the SwiftUI environment when no explicit router is provided. This means new
/// callers get comment routing for free as long as the environment is set by an
/// ancestor (which `ContentView` does at the root level).
///
/// Usage:
/// ```swift
/// NavigationLink {
///     EmbeddedFileViewerView(
///         content: .fromText(text, filePath: path)
///     )
///     .ignoresSafeArea(edges: .top)
///     .toolbarVisibility(.hidden, for: .navigationBar)
/// } label: { ... }
/// ```
struct EmbeddedFileViewerView: UIViewControllerRepresentable {
    let content: FullScreenCodeContent
    var reviewCommentSelectionContext: ReviewCommentSelectionContext?
    var reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    var reviewCommentSessionId: String?
    var reviewCommentSourceLabel: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.reviewCommentSelectionScope) private var reviewCommentSelectionScope

    /// Effective action context for this embedded fullscreen presentation.
    private var effectiveReviewCommentSelectionContext: ReviewCommentSelectionContext? {
        reviewCommentSelectionContext
            ?? reviewCommentSelectionRouter.map { ReviewCommentSelectionContext(router: $0, sessionId: reviewCommentSessionId, sourceLabel: reviewCommentSourceLabel) }
            ?? reviewCommentSelectionScope?.makeContext(
                sessionId: reviewCommentSessionId,
                sourceLabel: reviewCommentSourceLabel
            )
    }

    func makeUIViewController(context: Context) -> FullScreenCodeViewController {
        let dismissAction = dismiss
        return FullScreenCodeViewController(
            content: content,
            presentationMode: .embedded(onDismiss: { dismissAction() }),
            reviewCommentSelectionContext: effectiveReviewCommentSelectionContext
        )
    }

    func updateUIViewController(
        _ uiViewController: FullScreenCodeViewController,
        context: Context
    ) {
        // Content is immutable — nothing to update.
    }
}
