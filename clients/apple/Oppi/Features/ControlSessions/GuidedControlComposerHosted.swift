import SwiftUI

/// The SwiftUI pieces `GuidedControlComposerController` hosts: the
/// review-comment stash sheet, and the staged-comment pill and drawer above
/// the composer (the chat hosts the same views).
@MainActor
enum GuidedControlComposerHosted {
    static func reviewCommentStash(
        _ model: GuidedControlComposerModel,
        presentation: ReviewCommentStripChrome.StashPresentation
    ) -> RouterScreen {
        .hosted { [weak model] in
            guard let model, let comments = model.configuration.stagedComments else { return AnyView(EmptyView()) }
            return AnyView(ReviewCommentStashContent(
                comments: comments.stagedComments,
                focusedCommentId: nil,
                onEdit: { comment, body in comments.update(comment, body: body) == nil },
                onDelete: { comments.delete($0) },
                onClose: { [weak model] in model?.reviewCommentStashPresentation = nil },
                initialEditingComment: presentation.initialEditingComment
            ))
        }
    }

    static func reviewCommentStrip(_ model: GuidedControlComposerModel, root: AppRootEnvironment) -> HostedLeaf {
        HostFactory.leaf(GuidedControlReviewCommentStrip(model: model), root: root)
    }
}

/// The staged-comment pill and, while open, its drawer.
private struct GuidedControlReviewCommentStrip: View {
    let model: GuidedControlComposerModel

    var body: some View {
        if model.reviewCommentPresentation.showsPill, let comments = model.configuration.stagedComments {
            VStack(alignment: .leading, spacing: 8) {
                ReviewCommentStripPill(
                    count: model.reviewCommentPresentation.pendingCount,
                    isExpanded: model.reviewCommentDrawerExpanded,
                    onToggle: { model.toggleReviewCommentDrawer() },
                    onOpenFullScreen: { model.presentReviewCommentStash() }
                )
                if model.reviewCommentDrawerExpanded {
                    ReviewCommentStashDrawer(
                        comments: comments.stagedComments,
                        focusedCommentId: nil,
                        onEdit: { model.presentReviewCommentStash(editing: $0) },
                        onDelete: { comments.delete($0) }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
        }
    }
}
