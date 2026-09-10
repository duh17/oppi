import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oppi

@Suite("Review comment strip chrome")
@MainActor
struct ReviewCommentStripChromeTests {
    @Test("Opening review clears both extension drawers; either extension placement closes review")
    func reviewAndExtensionDrawersAreExclusiveInBothDirections() throws {
        let chat = try reviewCommentsChatViewSource()
        let toggle = try reviewCommentsSourceSlice(
            named: "private func toggleReviewCommentDrawer", until: "private var timelineTopOverlap", in: chat
        )
        #expect(toggle.contains("extensionDrawerCollapseRequestID &+= 1"))
        #expect(chat.components(separatedBy: "collapseRequestID: extensionDrawerCollapseRequestID").count - 1 == 2)
        #expect(chat.components(separatedBy: "onExpandedEntryChange: handleExtensionDrawerExpansion").count - 1 == 2)
        let panel = try reviewCommentsFeatureSource(path: "Oppi/Features/Chat/Support/ExtensionSurfacePanel.swift")
        #expect(panel.contains(".onChange(of: collapseRequestID)"))
        let collapse = try reviewCommentsSourceSlice(
            named: ".onChange(of: collapseRequestID)", until: ".onChange(of: stripEntries", in: panel
        )
        #expect(collapse.contains("collapseActiveEntry()"))
    }

    @Test("Review UI test uses the same count-aware stash title as the product")
    func reviewUITestUsesCountAwareStashTitle() throws {
        let uiTest = try reviewCommentsFeatureSource(path: "OppiUITests/FullScreenReviewCommentUITests.swift")
        #expect(uiTest.contains("app.navigationBars[\"1 review comment staged\"]"))
        let sheet = try reviewCommentStashSheetSource()
        #expect(sheet.contains("ReviewCommentStripChrome.stashTitle(count:"))
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
        let drawer = try reviewCommentStashDrawerSourceSlice(in: chromeSource)
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

    @Test("Expanded drawer reuses the native-surface expanded viewport cap")
    func expandedDrawerReusesNativeSurfaceExpandedViewportCap() throws {
        let chromeSource = try reviewCommentStripChromeSource()
        let drawer = try reviewCommentStashDrawerSourceSlice(in: chromeSource)
        #expect(drawer.contains("NativeSurfaceViewportScrollContainer("))
        #expect(drawer.contains("ExtensionNativeSurfaceLayout.expandedMaxHeight"))
        #expect(!drawer.contains("maxHeight: .infinity"))
        #expect(!drawer.contains("onDoubleTap"))
        #expect(!drawer.contains(".accessibilityIdentifier("))
        let titleRange = try #require(drawer.range(of: "stashTitle(count:"))
        let viewportRange = try #require(drawer.range(of: "NativeSurfaceViewportScrollContainer("))
        let contentRange = try #require(drawer.range(of: "ReviewCommentStashContent("))
        #expect(titleRange.lowerBound < viewportRange.lowerBound)
        #expect(viewportRange.lowerBound < contentRange.lowerBound)

        let extensionSource = try reviewCommentsFeatureSource(
            path: "Oppi/Features/Chat/Support/ExtensionSurfacePanel.swift"
        )
        #expect(extensionSource.contains("enum ExtensionNativeSurfaceLayout"))
        #expect(extensionSource.contains("static let expandedMaxHeight: CGFloat = 260"))
        #expect(extensionSource.contains("maxHeight: ExtensionNativeSurfaceLayout.expandedMaxHeight"))
        #expect(ExtensionNativeSurfaceLayout.expandedMaxHeight == 260)
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
        let drawer = try reviewCommentStashDrawerSourceSlice(in: chromeSource)
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

/// Title + 10pt stack spacing + 12pt padding on both edges, at default Dynamic Type.
private let maxReviewCommentStashDrawerChromeHeight: CGFloat = 96

private func reviewCommentStashDrawerSourceSlice(in source: String) throws -> String {
    try reviewCommentsSourceSlice(
        named: "struct ReviewCommentStashDrawer: View {",
        until: ".extensionGlassPanel(cornerRadius: 18)",
        in: source
    )
}

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
    let host = UIHostingController(
        rootView: ReviewCommentStashDrawer(
            comments: comments,
            focusedCommentId: nil,
            onEdit: { _ in },
            onDelete: { _ in }
        )
        .environment(\.theme, ThemeID.dark.appTheme)
        .environment(\.themeID, .dark)
        .ignoresSafeArea()
    )
    host.safeAreaRegions = []
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
        window.isHidden = true
        window.rootViewController = nil
    }

    var fitted = CGSize.zero
    var scrollView: UIScrollView?
    _ = await waitForMainActorCondition {
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        fitted = host.sizeThatFits(in: CGSize(width: 390, height: 2_000))
        host.view.frame = CGRect(origin: .zero, size: CGSize(width: 390, height: max(fitted.height, 1)))
        window.frame.size = host.view.frame.size
        host.view.layoutIfNeeded()
        scrollView = firstScrollView(in: host.view)
        return fitted.height > 1 && (scrollView?.bounds.height ?? 0) > 1
    }

    let resolvedScrollView = scrollView ?? firstScrollView(in: host.view)
    return ReviewCommentStashDrawerLayout(
        fittedHeight: fitted.height,
        scrollView: resolvedScrollView,
        identifierCount: viewsWithAccessibilityIdentifier(
            ReviewCommentStripChrome.drawerAccessibilityIdentifier,
            in: host.view
        ).count,
        hasDoubleTapRecognizer: resolvedScrollView.map(hasDoubleTapRecognizer(in:)) ?? false
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
