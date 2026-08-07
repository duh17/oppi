import SwiftUI
import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("File browser review comment selection")
struct FileBrowserReviewCommentSelectionTests {

    @Test func routerDispatchesReviewCommentRequestWithSource() throws {
        var captured: ReviewCommentSelectionRequest?
        let router = ReviewCommentSelectionRouter { request in
            captured = request
        }
        let source = ReviewCommentSourceContext(
            sessionId: "session-1",
            surface: .fullScreenCode,
            filePath: "test.swift",
            languageHint: "swift"
        )

        router.dispatch(ReviewCommentSelectionRequest(selectedText: "let x = 42", source: source))

        let request = try #require(captured)
        #expect(request.selectedText == "let x = 42")
        #expect(request.source == source)
    }

    @Test func codeBodyShowsCommentMenuWhenEnvironmentRouterSet() throws {
        let codeBody = NativeFullScreenCodeBody(
            content: "let answer = 42",
            language: "swift",
            startLine: 1,
            palette: ThemeRuntimeState.currentThemeID().palette,
            alwaysBounceVertical: true,
            reviewCommentSelectionRouter: ReviewCommentSelectionRouter { _ in },
            reviewCommentSourceContext: ReviewCommentSourceContext(
                sessionId: "session-1",
                surface: .fullScreenCode,
                filePath: "test.swift",
                languageHint: "swift"
            )
        )
        codeBody.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        codeBody.setNeedsLayout()
        codeBody.layoutIfNeeded()

        let textView = try #require(timelineAllTextViews(in: codeBody).first {
            timelineRenderedText(of: $0).contains("let answer = 42")
        })

        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 3),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))

        #expect(timelineActionTitles(in: menu) == ["Comment", "Copy"])
    }

    @Test func markdownDocumentShowsCommentMenuWhenEnvironmentScopeSet() throws {
        let host = UIHostingController(rootView:
            MarkdownFileView(
                content: "Alpha beta gamma",
                filePath: "docs/sandbox.md",
                presentation: .document
            )
            .environment(\.reviewCommentSelectionScope, .activeSession(ReviewCommentSelectionRouter { _ in }))
        )
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let textView = try #require(timelineAllTextViews(in: host.view).first {
            timelineRenderedText(of: $0).contains("Alpha beta gamma")
        })

        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 5),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))

        #expect(timelineActionTitles(in: menu) == ["Comment", "Copy"])
    }

    @Test func markdownDocumentSourceToggleShowsCommentMenuWhenEnvironmentScopeSet() throws {
        let host = UIHostingController(rootView:
            MarkdownFileView(
                content: "# Heading\n\nRaw source body",
                filePath: "docs/sandbox.md",
                presentation: .document
            )
            .environment(\.reviewCommentSelectionScope, .activeSession(ReviewCommentSelectionRouter { _ in }))
        )
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let sourceButton = try #require(timelineAllViews(in: host.view).compactMap { $0 as? UIButton }.first {
            $0.configuration?.title == "Source"
        })
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        sourceButton.sendActions(for: .touchUpInside)
        UIView.setAnimationsEnabled(animationsWereEnabled)
        host.view.layoutIfNeeded()

        let textView = try #require(timelineAllTextViews(in: host.view).first {
            timelineRenderedText(of: $0).contains("# Heading")
        })

        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 9),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))

        #expect(timelineActionTitles(in: menu) == ["Comment", "Copy"])
    }

    @Test func inlineCodeFileViewDispatchesFileLineFromSelection() throws {
        var captured: ReviewCommentSelectionRequest?
        let host = makeHostedInlineFileView(
            CodeFileView(
                content: "let first = 1\nlet second = 2\nlet third = 3",
                language: .swift,
                startLine: 30,
                presentation: .inline,
                filePath: "Sources/App.swift"
            ),
            captured: { captured = $0 }
        )

        try dispatchComment(in: host.view, selectedText: "let second = 2")

        let request = try #require(captured)
        #expect(request.selectedText == "let second = 2")
        #expect(request.source.filePath == "Sources/App.swift")
        #expect(request.source.lineRange == 31...31)
    }

    @Test func inlinePlainTextViewDispatchesFileLineFromSelection() throws {
        var captured: ReviewCommentSelectionRequest?
        let host = makeHostedInlineFileView(
            PlainTextView(
                content: "first\nsecond\nthird",
                startLine: 50,
                presentation: .inline,
                filePath: "notes.txt"
            ),
            captured: { captured = $0 }
        )

        try dispatchComment(in: host.view, selectedText: "second")

        let request = try #require(captured)
        #expect(request.selectedText == "second")
        #expect(request.source.filePath == "notes.txt")
        #expect(request.source.lineRange == 51...51)
    }

    @Test func treeDirectoryNavigationClearsSelectedFile() {
        let selected = FileBrowserSelection(path: "Sources/App.swift", name: "App.swift", size: 42)

        let opened = FileBrowserTreeNavigationReducer.openDirectory(
            path: "Sources/Features/",
            selectedFile: selected
        )
        let breadcrumb = FileBrowserTreeNavigationReducer.popToBreadcrumb(
            path: "Sources/",
            selectedFile: selected
        )

        #expect(opened.treeDirectoryPath == "Sources/Features/")
        #expect(opened.selectedFile == nil)
        #expect(breadcrumb.treeDirectoryPath == "Sources/")
        #expect(breadcrumb.selectedFile == nil)
    }

    @Test func fileNavigationContextMovesToAdjacentFilesWithoutWrapping() {
        let context = FileBrowserNavigationContext(files: [
            FileBrowserSelection(path: "a.png", name: "a.png", size: 10),
            FileBrowserSelection(path: "b.png", name: "b.png", size: 20),
            FileBrowserSelection(path: "c.txt", name: "c.txt", size: 30),
        ])

        #expect(context.selection(adjacentTo: "b.png", direction: .previous)?.path == "a.png")
        #expect(context.selection(adjacentTo: "b.png", direction: .next)?.path == "c.txt")
        #expect(context.selection(adjacentTo: "a.png", direction: .previous) == nil)
        #expect(context.selection(adjacentTo: "c.txt", direction: .next) == nil)
    }

    @Test func horizontalBackSwipePolicyAcceptsOnlyRightDominantSwipes() {
        #expect(HorizontalBackSwipeGesturePolicy.isBackSwipe(translation: CGSize(width: 90, height: 12)))
        #expect(!HorizontalBackSwipeGesturePolicy.isBackSwipe(translation: CGSize(width: 90, height: 90)))
        #expect(!HorizontalBackSwipeGesturePolicy.isBackSwipe(translation: CGSize(width: -90, height: 12)))
        #expect(!HorizontalBackSwipeGesturePolicy.isBackSwipe(translation: CGSize(width: 50, height: 2)))
    }

    @Test func horizontalBackSwipePolicyUsesVelocityToAvoidVerticalPanStealing() {
        #expect(HorizontalBackSwipeGesturePolicy.shouldBegin(velocity: CGPoint(x: 800, y: 80)))
        #expect(!HorizontalBackSwipeGesturePolicy.shouldBegin(velocity: CGPoint(x: 80, y: 800)))
        #expect(!HorizontalBackSwipeGesturePolicy.shouldBegin(velocity: CGPoint(x: -800, y: 80)))
    }

    @Test func navigationSwipePolicyAcceptsOnlyDownDominantModalDismissalSwipes() {
        #expect(NavigationSwipeGesturePolicy.isSwipe(
            translation: CGSize(width: 12, height: 90),
            direction: .down
        ))
        #expect(!NavigationSwipeGesturePolicy.isSwipe(
            translation: CGSize(width: 90, height: 12),
            direction: .down
        ))
        #expect(!NavigationSwipeGesturePolicy.isSwipe(
            translation: CGSize(width: 12, height: -90),
            direction: .down
        ))
        #expect(!NavigationSwipeGesturePolicy.isSwipe(
            translation: CGSize(width: 90, height: 90),
            direction: .down
        ))
    }

    @Test func navigationSwipePolicyUsesVelocityToAvoidHorizontalPanStealingForModalDismissal() {
        #expect(NavigationSwipeGesturePolicy.shouldBegin(
            velocity: CGPoint(x: 80, y: 800),
            direction: .down
        ))
        #expect(!NavigationSwipeGesturePolicy.shouldBegin(
            velocity: CGPoint(x: 800, y: 80),
            direction: .down
        ))
        #expect(!NavigationSwipeGesturePolicy.shouldBegin(
            velocity: CGPoint(x: 80, y: -800),
            direction: .down
        ))
    }

    @Test func fullScreenDismissChromeMapsGestureToVisibleArrowDirection() {
        #expect(FullScreenViewerNavigationChrome.DismissMode.modal.gestureDirection == .down)
        #expect(FullScreenViewerNavigationChrome.DismissMode.embedded.gestureDirection == .right)
    }

    @Test func modalFullScreenCodeInstallsDownDismissPanRecognizer() {
        let controller = FullScreenCodeViewController(
            content: .plainText(content: "build log", filePath: "log.txt"),
            presentationMode: .sheet
        )

        controller.loadViewIfNeeded()

        #expect(rootPanGestureCount(on: controller) == 1)
    }

    @Test func embeddedFullScreenCodeInstallsRootBackPanRecognizer() {
        let controller = FullScreenCodeViewController(
            content: .plainText(content: "build log", filePath: "log.txt"),
            presentationMode: .embedded(onDismiss: {})
        )

        controller.loadViewIfNeeded()

        #expect(rootPanGestureCount(on: controller) == 1)
    }

    @Test func modalImageViewerInstallsDownDismissPanRecognizer() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        let controller = FullScreenImageViewController(image: image)

        controller.loadViewIfNeeded()

        #expect(rootPanGestureCount(on: controller) == 1)
    }

    @Test func filePushTransitionMovesNextFileInFromTrailingEdge() {
        #expect(FileBrowserPushTransitionSpec.spec(for: .next) == .init(insertion: .trailing, removal: .leading))
        #expect(FileBrowserPushTransitionSpec.spec(for: .previous) == .init(insertion: .leading, removal: .trailing))
    }

    @Test func treePaneTextUsesEmbeddedFileViewerWithoutNavigationChrome() {
        #expect(FileBrowserContentRenderingPolicy.textRenderer(for: .treePane) == .embeddedFileViewer)
        #expect(FileBrowserContentRenderingPolicy.showsNavigationChrome(for: .treePane) == false)
        #expect(FileBrowserContentRenderingPolicy.textRenderer(for: .pushed) == .embeddedFileViewer)
        #expect(FileBrowserContentRenderingPolicy.showsNavigationChrome(for: .pushed) == true)
    }

    @Test func fileBrowserBackSwipePolicyYieldsOwnershipToModalHost() {
        #expect(
            FileBrowserContentView.shouldInstallHorizontalBackSwipe(
                allowsHorizontalBackSwipe: false,
                parentOwnsBackSwipe: true
            ) == false
        )
        #expect(
            FileBrowserContentView.shouldInstallHorizontalBackSwipe(
                allowsHorizontalBackSwipe: true,
                parentOwnsBackSwipe: true
            ) == true
        )
    }

    @Test func fileBrowserFileTargetUsesLinkedFileDestinationForHistoryBack() {
        let target = WorkspaceLinkedFileNavTarget.workspaceFile(
            serverId: "server-1",
            workspaceId: "workspace-1",
            path: "notes/daily.md"
        )

        #expect(target == WorkspaceLinkedFileNavTarget(
            serverId: "server-1",
            workspaceId: "workspace-1",
            kind: .workspaceFile(path: "notes/daily.md", fileName: "daily.md")
        ))
    }

    @Test func fileBrowserFileTargetPreservesWorktreeId() {
        let target = WorkspaceLinkedFileNavTarget.workspaceFile(
            serverId: "server-1",
            workspaceId: "workspace-1",
            worktreeId: "wt-feature",
            path: "notes/daily.md"
        )

        #expect(target.worktreeId == "wt-feature")
    }

    @Test func codeBodyKeepsSystemCopyMenuWhenRouterNil() throws {
        let codeBody = NativeFullScreenCodeBody(
            content: "let answer = 42",
            language: "swift",
            startLine: 1,
            palette: ThemeRuntimeState.currentThemeID().palette,
            alwaysBounceVertical: true,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        codeBody.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        codeBody.setNeedsLayout()
        codeBody.layoutIfNeeded()

        let textView = try #require(timelineAllTextViews(in: codeBody).first {
            timelineRenderedText(of: $0).contains("let answer = 42")
        })

        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 3),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))

        // Returning nil from UITextView.editMenuForTextIn suppresses the menu entirely.
        #expect(timelineActionTitles(in: menu) == ["Copy"])
    }

    @Test func documentCodeFileViewShowsCommentMenuWhenEnvironmentScopeSet() throws {
        let host = UIHostingController(rootView:
            CodeFileView(
                content: "let answer = 42",
                language: .swift,
                startLine: 1,
                presentation: .document,
                filePath: "Answer.swift"
            )
            .environment(\.reviewCommentSelectionScope, .activeSession(ReviewCommentSelectionRouter { _ in }))
        )
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let textView = try #require(timelineAllTextViews(in: host.view).first {
            timelineRenderedText(of: $0).contains("let answer = 42")
        })

        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 3),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))

        #expect(timelineActionTitles(in: menu) == ["Comment", "Copy"])
    }

    @Test func documentCodeFileViewShowsSystemCopyMenuWithoutScope() throws {
        let host = UIHostingController(rootView:
            CodeFileView(
                content: "let answer = 42",
                language: .swift,
                startLine: 1,
                presentation: .document,
                filePath: "Answer.swift"
            )
        )
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let textView = try #require(timelineAllTextViews(in: host.view).first {
            timelineRenderedText(of: $0).contains("let answer = 42")
        })

        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 3),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))

        #expect(timelineActionTitles(in: menu) == ["Copy"])
    }

    private struct HostedInlineFileView {
        let host: UIHostingController<AnyView>
        let window: UIWindow

        var view: UIView { host.view }
    }

    private func makeHostedInlineFileView<Content: View>(
        _ view: Content,
        captured: @escaping (ReviewCommentSelectionRequest) -> Void
    ) -> HostedInlineFileView {
        let host = UIHostingController(rootView:
            AnyView(view.environment(
                \.reviewCommentSelectionScope,
                .activeSession(ReviewCommentSelectionRouter { captured($0) })
            ))
        )
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return HostedInlineFileView(host: host, window: window)
    }

    private func dispatchComment(in root: UIView, selectedText: String) throws {
        let textView = try #require(timelineAllTextViews(in: root).first {
            timelineRenderedText(of: $0).contains(selectedText)
        })
        let selectedRange = (timelineRenderedText(of: textView) as NSString).range(of: selectedText)
        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: selectedRange,
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))
        let commentAction = try #require(menu.children.first as? UIAction)
        let button = UIButton(type: .system)
        button.addAction(commentAction, for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
    }

    private func rootPanGestureCount(on controller: UIViewController) -> Int {
        (controller.view.gestureRecognizers ?? []).filter { $0 is UIPanGestureRecognizer }.count
    }
}
