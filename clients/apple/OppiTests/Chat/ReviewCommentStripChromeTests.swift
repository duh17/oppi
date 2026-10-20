import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Review comment strip chrome")
@MainActor
struct ReviewCommentStripChromeTests {
    @Test("Opening review closes now playing and collapses extension drawers; an extension drawer closes review")
    func reviewAndExtensionDrawersAreExclusive() {
        let (connection, _) = makeTestConnection(sessionId: "drawers")
        let chat = ChatViewController(sessionId: "drawers", connection: connection, navigation: AppNavigation())
        chat.model.nowPlayingDrawerExpanded = true
        let collapseRequest = chat.model.extensionDrawerCollapseRequestID

        chat.toggleReviewCommentDrawer()
        #expect(chat.model.reviewCommentDrawerExpanded)
        #expect(!chat.model.nowPlayingDrawerExpanded)
        #expect(chat.model.extensionDrawerCollapseRequestID == collapseRequest + 1)

        chat.handleExtensionDrawerExpansion(true)
        #expect(!chat.model.reviewCommentDrawerExpanded)

        chat.toggleNowPlayingDrawer()
        #expect(chat.model.nowPlayingDrawerExpanded)
        chat.toggleReviewCommentDrawer()
        #expect(!chat.model.nowPlayingDrawerExpanded)
    }

    @Test("Collapsed pill title keeps the full staged-count phrase")
    func collapsedPillTitleKeepsStagedCountPhrase() {
        #expect(ReviewCommentStripChrome.stashTitle(count: 1) == "1 review comment staged")
        #expect(ReviewCommentStripChrome.stashTitle(count: 2) == "2 review comments staged")
    }

    @Test("Collapsed pill count text names the comments")
    func collapsedPillCountTextNamesTheComments() {
        #expect(ReviewCommentStripChrome.pillCountText(count: 1) == "1 comment")
        #expect(ReviewCommentStripChrome.pillCountText(count: 12) == "12 comments")
        #expect(!ReviewCommentStripChrome.pillCountText(count: 2).localizedCaseInsensitiveContains("review"))
    }

    @Test("Pill shows when comments are staged and no inline draft is active")
    func pillShowsWhenCommentsAreStagedWithoutInlineDraft() {
        #expect(ReviewCommentStripChrome.shouldShowPill(stagedCount: 1, isDraftingComment: false))
        #expect(ReviewCommentStripChrome.shouldShowPill(stagedCount: 3, isDraftingComment: false))
    }

    @Test("Pill hides when no comments are staged or an inline draft is active")
    func pillHidesWhenEmptyOrDrafting() {
        #expect(!ReviewCommentStripChrome.shouldShowPill(stagedCount: 0, isDraftingComment: false))
        #expect(!ReviewCommentStripChrome.shouldShowPill(stagedCount: 2, isDraftingComment: true))
        #expect(!ReviewCommentStripChrome.shouldShowPill(stagedCount: 0, isDraftingComment: true))
    }

    @Test("Above-editor strip is visible when only staged comments exist")
    func aboveEditorStripIsVisibleWhenOnlyCommentsExist() {
        #expect(
            ReviewCommentStripChrome.shouldShowAboveEditorStrip(
                showsReviewCommentPill: true,
                showsNowPlayingPill: false,
                hasAboveEditorSurface: false,
                showsMessageQueue: false,
                showsNotifyChip: false
            )
        )
        #expect(
            !ReviewCommentStripChrome.shouldShowAboveEditorStrip(
                showsReviewCommentPill: false,
                showsNowPlayingPill: false,
                hasAboveEditorSurface: false,
                showsMessageQueue: false,
                showsNotifyChip: false
            )
        )
    }

    @Test("Above-editor strip is visible when only a notify chip exists")
    func aboveEditorStripIsVisibleWhenOnlyNotifyChipExists() {
        #expect(
            ReviewCommentStripChrome.shouldShowAboveEditorStrip(
                showsReviewCommentPill: false,
                showsNowPlayingPill: false,
                hasAboveEditorSurface: false,
                showsMessageQueue: false,
                showsNotifyChip: true
            )
        )
    }

    @Test("Expanding comments collapses the now-playing drawer")
    func expandingCommentsCollapsesNowPlayingDrawer() {
        let expanded = ReviewCommentStripChrome.toggleComments(
            .init(commentsExpanded: false, nowPlayingExpanded: true)
        )
        #expect(expanded.commentsExpanded)
        #expect(!expanded.nowPlayingExpanded)

        let collapsed = ReviewCommentStripChrome.toggleComments(expanded)
        #expect(!collapsed.commentsExpanded)
        #expect(!collapsed.nowPlayingExpanded)
    }

    @Test("Expanding now-playing collapses the comments drawer")
    func expandingNowPlayingCollapsesCommentsDrawer() {
        let expanded = ReviewCommentStripChrome.toggleNowPlaying(
            .init(commentsExpanded: true, nowPlayingExpanded: false)
        )
        #expect(!expanded.commentsExpanded)
        #expect(expanded.nowPlayingExpanded)
    }

    @Test("Pill action peeks on a single tap and opens the sheet on a double-tap")
    func pillActionPeeksOnSingleTapAndOpensSheetOnDoubleTap() {
        #expect(ReviewCommentStripChrome.pillAction(tapCount: 1) == .peek)
        #expect(ReviewCommentStripChrome.pillAction(tapCount: 2) == .sheet)
        #expect(ReviewCommentStripChrome.pillAction(tapCount: 0) == nil)
        #expect(ReviewCommentStripChrome.pillAction(tapCount: 3) == nil)
    }

    @Test("Each stash presentation gets a fresh identity")
    func eachStashPresentationGetsAFreshIdentity() {
        let first = ReviewCommentStripChrome.StashPresentation()
        let second = ReviewCommentStripChrome.StashPresentation()
        #expect(first.id != second.id)
        #expect(first.initialEditingComment == nil)
        #expect(second.initialEditingComment == nil)
    }

    @Test("Pill accessibility keeps the full staged-count phrase")
    func pillAccessibilityKeepsFullStagedCountPhrase() {
        #expect(ReviewCommentStripChrome.pillAccessibilityIdentifier == "chat.reviewComments.pill")
        #expect(ReviewCommentStripChrome.pillAccessibilityLabel(count: 1) == "1 review comment staged")
        #expect(ReviewCommentStripChrome.pillAccessibilityValue(count: 2) == "2 review comments staged")
        #expect(ReviewCommentStripChrome.drawerAccessibilityIdentifier == "chat.reviewComments.drawer")
    }

    @Test("Short staged-comment peek hugs content below the expanded native-surface cap")
    func shortPeekHugsContentBelowExpandedNativeSurfaceCap() async throws {
        let layout = await measureReviewCommentStashDrawer(
            comments: [
                stashDrawerComment(id: "short-1", body: "Keep this."),
            ]
        )
        let cap = ExtensionNativeSurfaceLayout.expandedMaxHeight

        let scrollView = try #require(layout.scrollView)
        let chrome = layout.fittedHeight - scrollView.bounds.height
        #expect(layout.fittedHeight > 1)
        #expect(scrollView.bounds.height > 1)
        #expect(scrollView.bounds.height < cap)
        #expect(layout.fittedHeight < cap)
        #expect(chrome >= 8)
        #expect(chrome <= maxReviewCommentStashDrawerChromeHeight)
        #expect(scrollView.contentSize.height <= cap + 0.5 || !scrollView.isScrollEnabled)
        #expect(!scrollView.isScrollEnabled)
        #expect(!layout.hasDoubleTapRecognizer)
        #expect(layout.identifierCount == 1)
        #expect(scrollView.accessibilityIdentifier == ReviewCommentStripChrome.drawerAccessibilityIdentifier)
    }

    @Test("Long staged-comment peek stays within the expanded native-surface height and scrolls")
    func longPeekStaysWithinExpandedNativeSurfaceHeightAndScrolls() async throws {
        let comments = (1...8).map { index in
            stashDrawerComment(
                id: "long-\(index)",
                body: "Comment \(index) should stay inside the bounded peek instead of covering the chat timeline.",
                selectedText: "let value = computeValue(\(index))\nreturn value"
            )
        }
        let layout = await measureReviewCommentStashDrawer(comments: comments)
        let cap = ExtensionNativeSurfaceLayout.expandedMaxHeight

        let scrollView = try #require(layout.scrollView)
        let chrome = layout.fittedHeight - scrollView.bounds.height
        #expect(layout.fittedHeight > 1)
        #expect(scrollView.bounds.height <= cap + 0.5)
        #expect(layout.fittedHeight <= cap + maxReviewCommentStashDrawerChromeHeight + 0.5)
        #expect(chrome >= 8)
        #expect(chrome <= maxReviewCommentStashDrawerChromeHeight)
        #expect(scrollView.contentSize.height > cap + 0.5)
        #expect(scrollView.isScrollEnabled)
        #expect(!layout.hasDoubleTapRecognizer)
        #expect(layout.identifierCount == 1)
        #expect(scrollView.accessibilityIdentifier == ReviewCommentStripChrome.drawerAccessibilityIdentifier)
    }
}

/// Title + 10pt stack spacing + 12pt padding on both edges, at default Dynamic Type.
private let maxReviewCommentStashDrawerChromeHeight: CGFloat = 96

private struct ReviewCommentStashDrawerLayout {
    var fittedHeight: CGFloat
    var scrollView: UIScrollView?
    var identifierCount: Int
    var hasDoubleTapRecognizer: Bool
}

@MainActor
private func measureReviewCommentStashDrawer(
    comments: [ReviewComment]
) async -> ReviewCommentStashDrawerLayout {
    let drawer = ReviewCommentStashDrawerView()
    drawer.apply(comments: comments, themeID: .dark)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.addSubview(drawer)
    window.makeKeyAndVisible()
    defer { window.isHidden = true }

    let fitted = drawer.systemLayoutSizeFitting(
        CGSize(width: 390, height: UIView.layoutFittingCompressedSize.height),
        withHorizontalFittingPriority: .required,
        verticalFittingPriority: .fittingSizeLevel
    )
    drawer.frame = CGRect(origin: .zero, size: CGSize(width: 390, height: fitted.height))
    drawer.layoutIfNeeded()
    // The viewport decides whether it scrolls once it has laid out its content.
    drawer.setNeedsLayout()
    drawer.layoutIfNeeded()
    let scrollView = firstScrollView(in: drawer)
    scrollView?.superview?.setNeedsLayout()
    scrollView?.superview?.layoutIfNeeded()
    return ReviewCommentStashDrawerLayout(
        fittedHeight: fitted.height,
        scrollView: scrollView,
        identifierCount: viewsWithAccessibilityIdentifier(
            ReviewCommentStripChrome.drawerAccessibilityIdentifier,
            in: drawer
        ).count,
        hasDoubleTapRecognizer: scrollView.map(hasDoubleTapRecognizer(in:)) ?? false
    )
}

private func firstScrollView(in view: UIView) -> UIScrollView? {
    if let scrollView = view as? UIScrollView {
        return scrollView
    }
    for subview in view.subviews {
        if let found = firstScrollView(in: subview) {
            return found
        }
    }
    return nil
}

private func viewsWithAccessibilityIdentifier(_ identifier: String, in view: UIView) -> [UIView] {
    var matches: [UIView] = []
    if view.accessibilityIdentifier == identifier {
        matches.append(view)
    }
    for subview in view.subviews {
        matches.append(contentsOf: viewsWithAccessibilityIdentifier(identifier, in: subview))
    }
    return matches
}

private func hasDoubleTapRecognizer(in scrollView: UIScrollView) -> Bool {
    (scrollView.gestureRecognizers ?? []).contains { recognizer in
        (recognizer as? UITapGestureRecognizer)?.numberOfTapsRequired == 2
    }
}

private func stashDrawerComment(
    id: String,
    body: String,
    selectedText: String? = nil
) -> ReviewComment {
    ReviewComment(
        id: id,
        workspaceId: "workspace-1",
        sessionId: "session-1",
        turnId: nil,
        author: .human,
        status: .staged,
        severity: nil,
        body: body,
        attachments: nil,
        reference: ReviewCommentReference(
            source: .file,
            label: nil,
            path: "App.swift",
            side: nil,
            startLine: 1,
            endLine: 4,
            selectedText: selectedText,
            languageHint: "swift",
            toolCallId: nil,
            timelineItemId: nil,
            url: nil
        ),
        createdAt: 1,
        updatedAt: 1,
        sentAt: nil
    )
}
