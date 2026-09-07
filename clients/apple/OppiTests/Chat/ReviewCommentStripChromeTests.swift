import Foundation
import Testing
@testable import Oppi

@Suite("Review comment strip chrome")
@MainActor
struct ReviewCommentStripChromeTests {
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
                hasMessageQueueDraft: false
            )
        )
        #expect(
            !ReviewCommentStripChrome.shouldShowAboveEditorStrip(
                showsReviewCommentPill: false,
                showsNowPlayingPill: false,
                hasAboveEditorSurface: false,
                showsMessageQueue: false,
                hasMessageQueueDraft: false
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

    @Test("Collapsed pill has count, no Review label, and no chevron")
    func collapsedPillHasCountWithoutReviewLabelOrChevron() throws {
        let source = try reviewCommentStripChromeSource()
        let pill = try reviewCommentsSourceSlice(
            named: "struct ReviewCommentStripPill: View {",
            until: "struct ReviewCommentStashDrawer: View {",
            in: source
        )

        #expect(pill.contains("text.bubble"))
        #expect(pill.contains("pillCountText"))
        #expect(!pill.contains("chevron."))
        #expect(!pill.contains("\"Review\""))
        #expect(pill.contains("pillAccessibilityIdentifier"))
        #expect(pill.contains("pillAccessibilityLabel(count:"))
        #expect(source.contains("static let pillAccessibilityIdentifier = \"chat.reviewComments.pill\""))
    }

    @Test("Pill accessibility keeps the full staged-count phrase")
    func pillAccessibilityKeepsFullStagedCountPhrase() {
        #expect(ReviewCommentStripChrome.pillAccessibilityIdentifier == "chat.reviewComments.pill")
        #expect(ReviewCommentStripChrome.pillAccessibilityLabel(count: 1) == "1 review comment staged")
        #expect(ReviewCommentStripChrome.pillAccessibilityValue(count: 2) == "2 review comments staged")
        #expect(ReviewCommentStripChrome.drawerAccessibilityIdentifier == "chat.reviewComments.drawer")
    }

    @Test("Stash sheet and drawer reuse the same content view")
    func stashSheetAndDrawerReuseTheSameContentView() throws {
        let stashSource = try reviewCommentStashSheetSource()
        #expect(stashSource.contains("struct ReviewCommentStashContent: View"))
        #expect(stashSource.contains("ReviewCommentStashContent("))

        let sheetSlice = try reviewCommentsSourceSlice(
            named: "struct ReviewCommentStashSheet: View {",
            until: "struct ReviewCommentStashContent: View {",
            in: stashSource
        )
        #expect(sheetSlice.contains("ReviewCommentStashContent("))

        let chromeSource = try reviewCommentStripChromeSource()
        #expect(chromeSource.contains("struct ReviewCommentStashDrawer: View"))
        #expect(chromeSource.contains("ReviewCommentStashContent("))
        #expect(chromeSource.contains("chrome: .drawer"))

        let fullScreen = try reviewCommentsFullScreenSource()
        #expect(fullScreen.contains("makeStashSheet() -> ReviewCommentStashSheet?"))
        #expect(fullScreen.contains("return ReviewCommentStashSheet("))
    }

    @Test("Drawer hugs comment content instead of filling a tall empty panel")
    func drawerHugsCommentContentInsteadOfFillingTallPanel() throws {
        let chromeSource = try reviewCommentStripChromeSource()
        let drawer = try reviewCommentsSourceSlice(
            named: "struct ReviewCommentStashDrawer: View {",
            until: "accessibilityIdentifier(ReviewCommentStripChrome.drawerAccessibilityIdentifier)",
            in: chromeSource
        )
        #expect(drawer.contains("chrome: .drawer"))
        #expect(drawer.contains("alignment: .top"))
        #expect(!drawer.contains("fixedSize("))
        #expect(!drawer.contains("frame(height:"))
        #expect(!drawer.contains("maxWidth: .infinity, maxHeight:"))

        let stashSource = try reviewCommentStashSheetSource()
        #expect(stashSource.contains("case drawer"))
        let drawerList = try reviewCommentsSourceSlice(
            named: "case .drawer:",
            until: "private struct ReviewCommentStashSheetChromeModifier",
            in: stashSource
        )
        #expect(drawerList.contains("commentsStack"))
        #expect(!drawerList.contains("ScrollView"))
        #expect(!drawerList.contains("theme.bg.primary"))
    }

    @Test("Chat footer wires the comments pill into the above-editor strip")
    func chatFooterWiresCommentsPillIntoAboveEditorStrip() throws {
        let source = try reviewCommentsChatViewSource()
        #expect(source.contains("ReviewCommentStripPill("))
        #expect(source.contains("showsReviewCommentPill"))
        #expect(source.contains("ReviewCommentStashDrawer("))
        #expect(!source.contains("onReviewCommentsTap"))
        #expect(!source.contains("showReviewCommentStash"))
        #expect(!source.contains("reviewCommentStashSheet"))
    }

    @Test("Control-session composer presents the count pill above the capsule")
    func controlSessionComposerPresentsCountPillAboveCapsule() throws {
        let source = try reviewCommentsGuidedComposerSource()
        #expect(source.contains("ReviewCommentStripPill("))
        #expect(source.contains("reviewCommentPresentation.showsPill"))
        #expect(source.contains("ReviewCommentStashDrawer("))
        #expect(!source.contains("onReviewCommentsTap"))
        #expect(!source.contains("showReviewCommentStash"))
    }
}

private func reviewCommentStripChromeSource() throws -> String {
    try reviewCommentsFeatureSource(path: "Oppi/Features/Chat/ReviewComments/ReviewCommentStripChrome.swift")
}

private func reviewCommentStashSheetSource() throws -> String {
    try reviewCommentsFeatureSource(path: "Oppi/Features/Chat/ReviewComments/ReviewCommentStashSheet.swift")
}

private func reviewCommentsChatViewSource() throws -> String {
    try reviewCommentsFeatureSource(path: "Oppi/Features/Chat/ChatView.swift")
}

private func reviewCommentsGuidedComposerSource() throws -> String {
    try reviewCommentsFeatureSource(path: "Oppi/Features/ControlSessions/GuidedControlSessionComposer.swift")
}

private func reviewCommentsFullScreenSource() throws -> String {
    try reviewCommentsFeatureSource(path: "Oppi/Core/Views/FullScreenCodeViewController.swift")
}

private func reviewCommentsFeatureSource(path: String) throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: path)
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

private func reviewCommentsSourceSlice(
    named marker: String,
    until endMarker: String,
    in source: String
) throws -> String {
    guard let start = source.range(of: marker) else {
        Issue.record("Missing source marker \(marker)")
        throw ReviewCommentStripChromeSourceSliceError.missingMarker(marker)
    }
    guard let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else {
        Issue.record("Missing source end marker \(endMarker)")
        throw ReviewCommentStripChromeSourceSliceError.missingMarker(endMarker)
    }
    return String(source[start.lowerBound..<end.lowerBound])
}

private enum ReviewCommentStripChromeSourceSliceError: Error {
    case missingMarker(String)
}
