import UIKit

// The chat's footer drawers: now playing, review comments, and extension
// notifications, plus the context bar's expansion.

extension ChatViewController {
    var showsNowPlayingPill: Bool {
        InAppNowPlayingChrome.shouldShowChatPill(
            hasActivePlayback: audioPlayer.hasActivePlayback,
            playbackItemID: InAppNowPlayingChrome.playbackItemID(
                playingItemID: audioPlayer.playingItemID,
                loadingItemID: audioPlayer.loadingItemID
            ),
            visibleStripItemIDs: model.visibleAudioStripItemIDs
        )
    }

    var showsReviewCommentPill: Bool {
        ReviewCommentStripChrome.shouldShowPill(
            stagedCount: reviewComments.stagedCount,
            isDraftingComment: model.activeReviewCommentRequest != nil
        )
    }

    var notifyChipState: ExtensionNotifyChipStore.SessionState? {
        connection.extensionNotifyChipStore.state(for: sessionId)
    }

    var showsNotifyChip: Bool {
        notifyChipState != nil
    }

    // MARK: - Drawers

    func toggleNowPlayingDrawer() {
        let next = ReviewCommentStripChrome.toggleNowPlaying(
            .init(
                commentsExpanded: model.reviewCommentDrawerExpanded,
                nowPlayingExpanded: model.nowPlayingDrawerExpanded
            )
        )
        model.reviewCommentDrawerExpanded = next.commentsExpanded
        model.nowPlayingDrawerExpanded = next.nowPlayingExpanded
        if model.nowPlayingDrawerExpanded {
            collapseNotifyChip()
            dismissKeyboard()
        }
    }

    func toggleReviewCommentDrawer() {
        let next = ReviewCommentStripChrome.toggleComments(
            .init(
                commentsExpanded: model.reviewCommentDrawerExpanded,
                nowPlayingExpanded: model.nowPlayingDrawerExpanded
            )
        )
        model.reviewCommentDrawerExpanded = next.commentsExpanded
        model.nowPlayingDrawerExpanded = next.nowPlayingExpanded
        if model.reviewCommentDrawerExpanded {
            // Extension panels own their selection; ask both placements to
            // collapse without hiding their pills or resetting their content.
            model.extensionDrawerCollapseRequestID &+= 1
            collapseNotifyChip()
            dismissKeyboard()
        }
    }

    func handleExtensionDrawerExpansion(_ expanded: Bool) {
        if model.extensionDrawerExpanded != expanded { model.extensionDrawerExpanded = expanded }
        // Children whose call returned stream only while a drawer could list them.
        sessionManager.followsReturnedChildren = expanded
        if expanded {
            model.reviewCommentDrawerExpanded = false
            collapseNotifyChip()
            dismissKeyboard()
        }
    }

    func toggleNotifyChip() {
        guard let state = notifyChipState else { return }
        let expanding = !state.isExpanded
        connection.extensionNotifyChipStore.setExpanded(expanding, sessionId: sessionId)
        if expanding {
            model.reviewCommentDrawerExpanded = false
            model.nowPlayingDrawerExpanded = false
            model.extensionDrawerCollapseRequestID &+= 1
            dismissKeyboard()
        }
    }

    func collapseNotifyChip() {
        connection.extensionNotifyChipStore.setExpanded(false, sessionId: sessionId)
    }
}
