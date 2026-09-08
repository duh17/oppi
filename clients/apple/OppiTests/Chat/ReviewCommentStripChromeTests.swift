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

    @Test("Pill uses exclusive double-tap before single-tap")
    func pillUsesExclusiveDoubleTapBeforeSingleTap() throws {
        let source = try reviewCommentStripChromeSource()
        let pill = try reviewCommentsSourceSlice(
            named: "struct ReviewCommentStripPill: View {",
            until: "struct ReviewCommentStashDrawer: View {",
            in: source
        )
        #expect(pill.contains("TapGesture(count: 2)"))
        #expect(pill.contains(".exclusively(before:"))
        #expect(pill.contains("TapGesture(count: 1)"))
        #expect(pill.contains("Open Full Screen"))
        #expect(pill.contains("onOpenFullScreen"))
        #expect(pill.contains("minHeight: 44") || pill.contains("height: 44"))
        #expect(!pill.contains("highPriorityGesture"))
        #expect(!pill.contains("Button(action: onToggle)"))
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

    @Test("Chat footer peeks the drawer on single tap and presents the stash sheet on double-tap or Edit")
    func chatFooterPeeksDrawerOnSingleTapAndPresentsStashSheetOnDoubleTapOrEdit() throws {
        let source = try reviewCommentsChatViewSource()
        #expect(source.contains("ReviewCommentStripPill("))
        #expect(source.contains("showsReviewCommentPill"))
        #expect(source.contains("ReviewCommentStashDrawer("))
        #expect(!source.contains("onReviewCommentsTap"))
        #expect(source.contains("onToggle: toggleReviewCommentDrawer"))
        #expect(source.contains("onOpenFullScreen:"))
        #expect(source.contains("reviewCommentStashPresentation"))
        #expect(source.contains("reviewCommentStashSheet"))
        #expect(source.contains("sheet(item: $reviewCommentStashPresentation)"))
        #expect(source.contains("presentReviewCommentStashSheet()"))
        #expect(source.contains("presentReviewCommentStashSheet(editing:"))
        #expect(source.contains("initialEditingComment:"))

        let presenter = try reviewCommentsSourceSlice(
            named: "private func presentReviewCommentStashSheet",
            until: "private func reviewCommentStashSheet",
            in: source
        )
        #expect(presenter.contains("reviewCommentDrawerExpanded = false"))
        #expect(presenter.contains("ReviewCommentStripChrome.StashPresentation(editing: comment)"))
        #expect(presenter.contains("dismissKeyboard()"))
        #expect(!presenter.contains("reviewCommentDrawerExpanded = true"))

        let sheet = try reviewCommentsSourceSlice(
            named: "private func reviewCommentStashSheet",
            until: "private var reviewCommentStashDrawer",
            in: source
        )
        #expect(sheet.contains("ReviewCommentStashSheet("))
        #expect(sheet.contains("initialEditingComment: presentation.initialEditingComment"))
        #expect(!sheet.contains("extensionToast"))
        #expect(!sheet.contains("reviewCommentDrawerExpanded = true"))

        let drawer = try reviewCommentsSourceSlice(
            named: "private var reviewCommentStashDrawer",
            until: "private var shareRedactionSheet",
            in: source
        )
        #expect(drawer.contains("presentReviewCommentStashSheet(editing:"))
        #expect(!drawer.contains("ReviewCommentEditorView"))
        #expect(!drawer.contains("comment, body"))
    }

    @Test("Control-session composer peeks the drawer on single tap and presents the stash sheet on double-tap or Edit")
    func controlSessionComposerPeeksDrawerOnSingleTapAndPresentsStashSheetOnDoubleTapOrEdit() throws {
        let source = try reviewCommentsGuidedComposerSource()
        #expect(source.contains("ReviewCommentStripPill("))
        #expect(source.contains("reviewCommentPresentation.showsPill"))
        #expect(source.contains("ReviewCommentStashDrawer("))
        #expect(!source.contains("onReviewCommentsTap"))
        #expect(source.contains("onToggle: toggleReviewCommentDrawer"))
        #expect(source.contains("onOpenFullScreen:"))
        #expect(source.contains("reviewCommentStashPresentation"))
        #expect(source.contains("reviewCommentStashSheet"))
        #expect(source.contains("sheet(item: $reviewCommentStashPresentation)"))
        #expect(source.contains("presentReviewCommentStashSheet()"))
        #expect(source.contains("presentReviewCommentStashSheet(editing:"))
        #expect(source.contains("initialEditingComment:"))

        let presenter = try reviewCommentsSourceSlice(
            named: "private func presentReviewCommentStashSheet",
            until: "private func reviewCommentStashSheet",
            in: source
        )
        #expect(presenter.contains("reviewCommentDrawerExpanded = false"))
        #expect(presenter.contains("ReviewCommentStripChrome.StashPresentation(editing: comment)"))
        #expect(presenter.contains("resignFirstResponder"))
        #expect(!presenter.contains("reviewCommentDrawerExpanded = true"))

        #expect(!source.contains("ReviewCommentEditorView"))
        #expect(!source.contains("error = updateError"))
    }

    @Test("Drawer chrome does not inline the comment editor")
    func drawerChromeDoesNotInlineTheCommentEditor() throws {
        let chromeSource = try reviewCommentStripChromeSource()
        let drawer = try reviewCommentsSourceSlice(
            named: "struct ReviewCommentStashDrawer: View {",
            until: "accessibilityIdentifier(ReviewCommentStripChrome.drawerAccessibilityIdentifier)",
            in: chromeSource
        )
        #expect(drawer.contains("chrome: .drawer"))
        #expect(drawer.contains("onRequestEdit:"))
        #expect(!drawer.contains("ReviewCommentEditorView"))
        #expect(!drawer.contains("Form {"))

        let stashSource = try reviewCommentStashSheetSource()
        let content = try reviewCommentsSourceSlice(
            named: "struct ReviewCommentStashContent: View {",
            until: "private var commentsStack",
            in: stashSource
        )
        #expect(content.contains("initialEditingComment"))
        #expect(content.contains("chrome == .sheet"))
        #expect(content.contains("ReviewCommentEditorView("))
        #expect(content.contains("editingCommentBinding.wrappedValue = nil"))
        #expect(content.contains(".onAppear"))
        #expect(content.contains("editingComment = initialEditingComment"))
    }

    @Test("Stash sheet can open already editing a comment")
    func stashSheetCanOpenAlreadyEditingAComment() throws {
        let stashSource = try reviewCommentStashSheetSource()
        let sheet = try reviewCommentsSourceSlice(
            named: "struct ReviewCommentStashSheet: View {",
            until: "enum ReviewCommentStashChrome",
            in: stashSource
        )
        #expect(sheet.contains("initialEditingComment"))
        #expect(sheet.contains("ReviewCommentStashContent("))
        #expect(sheet.contains("initialEditingComment: initialEditingComment"))

        #expect(stashSource.contains("State(initialValue:"))
        #expect(stashSource.contains("editingComment = initialEditingComment"))
        #expect(stashSource.contains(".onAppear"))
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
