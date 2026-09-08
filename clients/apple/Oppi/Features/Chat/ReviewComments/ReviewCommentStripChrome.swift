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

    enum PillAction: Equatable {
        case peek
        case sheet
    }

    /// Chat and control-session pills: tap peeks the drawer, double-tap opens the stash sheet.
    static func pillAction(tapCount: Int) -> PillAction? {
        switch tapCount {
        case 1: return .peek
        case 2: return .sheet
        default: return nil
        }
    }

    /// Fresh identity per present so list vs already-editing cannot reuse `@State`.
    struct StashPresentation: Identifiable, Equatable {
        let id: UUID
        let initialEditingComment: ReviewComment?

        init(editing comment: ReviewComment? = nil) {
            id = UUID()
            initialEditingComment = comment
        }
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
    let onOpenFullScreen: () -> Void

    var body: some View {
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
        .accessibilityHidden(true)
        .extensionStripPillSurface(isActive: isExpanded, activeStroke: .themeCyan)
        .overlay {
            Color.clear
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityElement()
                .accessibilityIdentifier(ReviewCommentStripChrome.pillAccessibilityIdentifier)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(ReviewCommentStripChrome.pillAccessibilityLabel(count: count))
                .accessibilityValue(ReviewCommentStripChrome.pillAccessibilityValue(count: count))
                .accessibilityHint(
                    isExpanded
                        ? "Collapses the staged review comments"
                        : "Shows the review comments staged for the next message"
                )
                .accessibilityAction(named: Text("Open Full Screen"), onOpenFullScreen)
                .gesture(
                    TapGesture(count: 2).onEnded {
                        handleTaps(2)
                    }
                    .exclusively(before: TapGesture(count: 1).onEnded {
                        handleTaps(1)
                    })
                )
        }
    }

    private func handleTaps(_ tapCount: Int) {
        switch ReviewCommentStripChrome.pillAction(tapCount: tapCount) {
        case .peek:
            onToggle()
        case .sheet:
            onOpenFullScreen()
        case nil:
            break
        }
    }
}

struct ReviewCommentStashDrawer: View {
    let comments: [ReviewComment]
    let focusedCommentId: String?
    let onEdit: (ReviewComment) -> Void
    let onDelete: (ReviewComment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ReviewCommentStripChrome.stashTitle(count: comments.count))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.themeComment)
                .frame(maxWidth: .infinity, alignment: .leading)

            ReviewCommentStashContent(
                comments: comments,
                focusedCommentId: focusedCommentId,
                onDelete: onDelete,
                chrome: .drawer,
                onRequestEdit: onEdit
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .top)
        .extensionGlassPanel(cornerRadius: 18)
        .accessibilityIdentifier(ReviewCommentStripChrome.drawerAccessibilityIdentifier)
    }
}
