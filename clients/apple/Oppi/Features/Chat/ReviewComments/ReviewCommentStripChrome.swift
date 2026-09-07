import SwiftUI

enum ReviewCommentStripChrome {
    static let pillAccessibilityIdentifier = "chat.reviewComments.pill"
    static let drawerAccessibilityIdentifier = "chat.reviewComments.drawer"

    struct ExpansionState: Equatable {
        var commentsExpanded: Bool
        var nowPlayingExpanded: Bool
    }

    static func stashTitle(count: Int) -> String {
        "\(count) review \(count == 1 ? "comment" : "comments") staged"
    }

    static func pillAccessibilityLabel(count: Int) -> String {
        stashTitle(count: count)
    }

    static func pillAccessibilityValue(count: Int) -> String {
        stashTitle(count: count)
    }

    static func pillCountText(count: Int) -> String {
        "\(count) \(count == 1 ? "comment" : "comments")"
    }

    static func shouldShowPill(stagedCount: Int, isDraftingComment: Bool) -> Bool {
        stagedCount > 0 && !isDraftingComment
    }

    static func shouldShowAboveEditorStrip(
        showsReviewCommentPill: Bool,
        showsNowPlayingPill: Bool,
        hasAboveEditorSurface: Bool,
        showsMessageQueue: Bool,
        hasMessageQueueDraft: Bool
    ) -> Bool {
        showsReviewCommentPill
            || showsNowPlayingPill
            || hasAboveEditorSurface
            || showsMessageQueue
            || hasMessageQueueDraft
    }

    static func toggleComments(_ state: ExpansionState) -> ExpansionState {
        let commentsExpanded = !state.commentsExpanded
        return ExpansionState(
            commentsExpanded: commentsExpanded,
            nowPlayingExpanded: commentsExpanded ? false : state.nowPlayingExpanded
        )
    }

    static func toggleNowPlaying(_ state: ExpansionState) -> ExpansionState {
        let nowPlayingExpanded = !state.nowPlayingExpanded
        return ExpansionState(
            commentsExpanded: nowPlayingExpanded ? false : state.commentsExpanded,
            nowPlayingExpanded: nowPlayingExpanded
        )
    }
}

struct ReviewCommentStripPill: View {
    let count: Int
    var isExpanded = false
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.themeCyan)
                    .accessibilityHidden(true)

                Text(ReviewCommentStripChrome.pillCountText(count: count))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 6)
            .extensionStripPillSurface(isActive: isExpanded, activeStroke: .themeCyan)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(ReviewCommentStripChrome.pillAccessibilityIdentifier)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(ReviewCommentStripChrome.pillAccessibilityLabel(count: count))
        .accessibilityValue(ReviewCommentStripChrome.pillAccessibilityValue(count: count))
        .accessibilityHint(
            isExpanded
                ? "Collapses the staged review comments"
                : "Shows the review comments staged for the next message"
        )
    }
}

struct ReviewCommentStashDrawer: View {
    let comments: [ReviewComment]
    let focusedCommentId: String?
    let onEdit: (ReviewComment, String) -> Bool
    let onDelete: (ReviewComment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(ReviewCommentStripChrome.stashTitle(count: comments.count))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.themeFg)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ReviewCommentStashContent(
                comments: comments,
                focusedCommentId: focusedCommentId,
                onEdit: onEdit,
                onDelete: onDelete
            )
        }
        .padding(.bottom, 10)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: 420)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .extensionGlassPanel(cornerRadius: 18)
        .accessibilityIdentifier(ReviewCommentStripChrome.drawerAccessibilityIdentifier)
    }
}
