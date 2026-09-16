import SwiftUI

/// SwiftUI host for the full-screen staged-comment control.
///
/// ``FullScreenCodeViewController`` owns this chrome for timeline and embedded
/// UIKit readers. Chat file sheets that keep SwiftUI navigation — git context
/// review, commit file diffs — never create that controller, so they install
/// the same control here. Previous-file buttons stay in the original leading
/// slot; stash stacks above them using the same padding as Annotate.
///
/// Environment is read from nested overlay views, not this modifier. A
/// `.environment(\.reviewCommentSelectionScope, …)` applied to the same view
/// before this modifier is visible to those nested views via `content`, but not
/// to `@Environment` on the modifier itself.
struct FullScreenReviewCommentStashOverlay: ViewModifier {
    var isEnabled: Bool = true
    var leadingAccessoryCount: Int = 0

    @State private var stashPresentation: ReviewCommentStripChrome.StashPresentation?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomLeading) {
                FullScreenReviewCommentStashChromeHost(
                    isEnabled: isEnabled,
                    leadingAccessoryCount: leadingAccessoryCount,
                    onOpen: {
                        stashPresentation = ReviewCommentStripChrome.StashPresentation()
                    }
                )
            }
            .sheet(item: $stashPresentation) { presentation in
                FullScreenReviewCommentStashSheetGate(
                    isEnabled: isEnabled,
                    presentation: presentation,
                    onClose: { stashPresentation = nil }
                )
            }
    }
}

extension View {
    func fullScreenReviewCommentStashOverlay(
        isEnabled: Bool = true,
        leadingAccessoryCount: Int = 0
    ) -> some View {
        modifier(
            FullScreenReviewCommentStashOverlay(
                isEnabled: isEnabled,
                leadingAccessoryCount: leadingAccessoryCount
            )
        )
    }
}

private struct FullScreenReviewCommentStashChromeHost: View {
    var isEnabled: Bool
    var leadingAccessoryCount: Int
    var onOpen: () -> Void

    @Environment(\.reviewCommentSelectionScope) private var reviewCommentSelectionScope

    var body: some View {
        if isEnabled,
           let comments = reviewCommentSelectionScope?.router.stash as? ChatReviewCommentsController {
            FullScreenReviewCommentStashChrome(
                comments: comments,
                leadingAccessoryCount: leadingAccessoryCount,
                onOpen: onOpen
            )
        }
    }
}

private struct FullScreenReviewCommentStashSheetGate: View {
    var isEnabled: Bool
    var presentation: ReviewCommentStripChrome.StashPresentation
    var onClose: () -> Void

    @Environment(\.reviewCommentSelectionScope) private var reviewCommentSelectionScope

    var body: some View {
        if isEnabled,
           let comments = reviewCommentSelectionScope?.router.stash as? ChatReviewCommentsController {
            FullScreenReviewCommentStashSheetHost(
                comments: comments,
                presentation: presentation,
                onClose: onClose
            )
        }
    }
}

private struct FullScreenReviewCommentStashChrome: View {
    var comments: ChatReviewCommentsController
    var leadingAccessoryCount: Int
    var onOpen: () -> Void

    var body: some View {
        if comments.stagedCount > 0 {
            Button(action: onOpen) {
                Image(systemName: FullScreenReviewCommentStashControl.systemImage)
                    .font(.system(size: FullScreenFloatingControlChrome.symbolPointSize, weight: .semibold))
                    .foregroundStyle(.themeFg)
                    .frame(
                        width: FullScreenFloatingControlChrome.controlSize,
                        height: FullScreenFloatingControlChrome.controlSize
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .fullScreenFloatingControlGlass(in: Capsule())
            .overlay(alignment: .topTrailing) {
                Text(comments.stagedCount > 99 ? "99+" : "\(comments.stagedCount)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.themeBgDark)
                    .padding(.horizontal, comments.stagedCount >= 10 ? 6 : 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(.themeCyan, in: Capsule())
                    .offset(x: 2, y: -2)
                    .accessibilityHidden(true)
            }
            .accessibilityLabel(FullScreenReviewCommentStashControl.accessibilityLabel)
            .accessibilityIdentifier(FullScreenReviewCommentStashControl.accessibilityIdentifier)
            .accessibilityValue(FullScreenReviewCommentStashControl.accessibilityValue(for: comments.stagedCount))
            .accessibilityAddTraits(.isButton)
            .padding(.leading, FullScreenFloatingControlChrome.leadingPadding)
            .padding(
                .bottom,
                FullScreenReviewCommentStashControl.bottomPadding(
                    leadingAccessoryCount: leadingAccessoryCount
                )
            )
        }
    }
}

private struct FullScreenReviewCommentStashSheetHost: View {
    var comments: ChatReviewCommentsController
    var presentation: ReviewCommentStripChrome.StashPresentation
    var onClose: () -> Void

    var body: some View {
        ReviewCommentStashSheet(
            comments: comments.stagedComments,
            focusedCommentId: nil,
            initialEditingComment: presentation.initialEditingComment,
            onEdit: { comment, body in
                comments.update(comment, body: body) == nil
            },
            onDelete: { comment in
                comments.delete(comment)
            },
            onClose: onClose
        )
    }
}
