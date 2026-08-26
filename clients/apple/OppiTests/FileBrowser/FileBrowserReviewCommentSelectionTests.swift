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

    @Test func workspaceLinkedFileDestinationIsReservedForWorkspaceStack() {
        // compactOnly/treePane stays in-sheet; the workspace destination is not registered there.
        #expect(
            FileBrowserTreeNavigationReducer.shouldUseWorkspaceLinkedFileDestination(
                usesInlineCompactNavigation: true,
                serverId: "server-1"
            ) == false
        )
        #expect(
            FileBrowserTreeNavigationReducer.shouldUseWorkspaceLinkedFileDestination(
                usesInlineCompactNavigation: false,
                serverId: "server-1"
            ) == true
        )
        #expect(
            FileBrowserTreeNavigationReducer.shouldUseWorkspaceLinkedFileDestination(
                usesInlineCompactNavigation: false,
                serverId: nil
            ) == false
        )
        #expect(
            FileBrowserTreeNavigationReducer.shouldUseWorkspaceLinkedFileDestination(
                usesInlineCompactNavigation: false,
                serverId: ""
            ) == false
        )
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
        #expect(FileBrowserContentRenderingPolicy.showsNavigationChrome(for: .pushed, source: .hostFile) == false)
        #expect(FileBrowserContentRenderingPolicy.navigationTitle(
            source: .hostFile,
            path: "/Users/me/secret",
            fileName: "harmless note"
        ) == "/Users/me/secret")
    }

    @Test func fileBrowserKeepsExistingMediaInsteadOfReloadingSamePath() {
        #expect(
            FileBrowserMediaLoadPolicy.shouldReload(
                existing: .video(path: "clips/demo.mp4"),
                requestedPath: "clips/demo.mp4",
                force: false
            ) == false
        )
        #expect(
            FileBrowserMediaLoadPolicy.shouldReload(
                existing: .video(path: "clips/demo.mp4"),
                requestedPath: "clips/other.mp4",
                force: false
            ) == true
        )
        #expect(
            FileBrowserMediaLoadPolicy.shouldReload(
                existing: .video(path: "clips/demo.mp4"),
                requestedPath: "clips/demo.mp4",
                force: true
            ) == true
        )
        #expect(
            FileBrowserMediaLoadPolicy.shouldReload(
                existing: .none,
                requestedPath: "clips/demo.mp4",
                force: false
            ) == true
        )
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

    @Test func wikiLinkedFileTargetCarriesSourceSessionId() {
        let workspace = WorkspaceLinkedFileNavTarget.workspaceFile(
            serverId: "server-1",
            workspaceId: "workspace-1",
            path: "notes/daily.md",
            sourceSessionId: "session-origin"
        )
        let host = WorkspaceLinkedFileNavTarget.hostFile(
            serverId: "server-1",
            workspaceId: "workspace-1",
            path: "/tmp/note.md",
            sourceSessionId: "session-origin"
        )

        #expect(workspace.sourceSessionId == "session-origin")
        #expect(host.sourceSessionId == "session-origin")
        #expect(
            WorkspaceLinkedFileNavTarget.workspaceFile(
                serverId: "server-1",
                workspaceId: "workspace-1",
                path: "notes/daily.md"
            ).sourceSessionId == nil
        )
    }

    @Test func wikiLinkedDestinationAppliesCommentScopeWhenSourceSessionPresent() throws {
        ReviewCommentSelectionActiveRouter.resetForTesting()
        defer { ReviewCommentSelectionActiveRouter.resetForTesting() }

        let router = ReviewCommentSelectionRouter(
            dispatch: { _ in },
            inlineSave: { _, _ in true }
        )
        ReviewCommentSelectionActiveRouter.register(router, sessionId: "session-origin")

        let scope = try #require(
            WorkspaceLinkedFileDestinationView.reviewCommentSelectionScope(
                sourceSessionId: "session-origin"
            )
        )
        #expect(scope.router === router)
        #expect(scope.router.supportsInlineCommentComposer)
    }

    @Test func wikiLinkedDestinationOmitsCommentScopeWithoutSourceSession() {
        ReviewCommentSelectionActiveRouter.resetForTesting()
        defer { ReviewCommentSelectionActiveRouter.resetForTesting() }
        ReviewCommentSelectionActiveRouter.register(
            ReviewCommentSelectionRouter { _ in },
            sessionId: "session-origin"
        )

        #expect(
            WorkspaceLinkedFileDestinationView.reviewCommentSelectionScope(sourceSessionId: nil) == nil
        )
        #expect(
            WorkspaceLinkedFileDestinationView.reviewCommentSelectionScope(
                sourceSessionId: "missing-session"
            ) == nil
        )
    }

    @Test func wikiLinkedDestinationInlineSaveIncrementsRegisteredChatViewStore() async throws {
        ReviewCommentSelectionActiveRouter.resetForTesting()
        defer { ReviewCommentSelectionActiveRouter.resetForTesting() }

        let chatViewComments = ChatReviewCommentsController(store: makeCommentStore())
        chatViewComments.load(localScopeId: "workspace-1", sessionId: "session-origin")
        let chatViewRouter = ReviewCommentSelectionRouter(
            dispatch: { _ in },
            inlineSave: { body, request in
                chatViewComments.save(
                    body: body,
                    request: request,
                    localScopeId: "workspace-1",
                    sessionId: "session-origin"
                ) == nil
            }
        )
        ReviewCommentSelectionActiveRouter.register(chatViewRouter, sessionId: "session-origin")

        let scope = try #require(
            WorkspaceLinkedFileDestinationView.reviewCommentSelectionScope(
                sourceSessionId: "session-origin"
            )
        )
        #expect(scope.router === chatViewRouter)

        let request = ReviewCommentSelectionRequest(
            selectedText: "let answer = 42",
            source: ReviewCommentSourceContext(
                sessionId: "session-origin",
                surface: .fullScreenCode,
                filePath: "Answer.swift"
            )
        )

        let saved = await scope.router.saveInlineComment(body: "Please tighten this.", request: request)

        #expect(saved)
        #expect(chatViewComments.stagedCount == 1)
        #expect(chatViewComments.stagedComments.first?.body == "Please tighten this.")
        #expect(chatViewComments.stagedComments.first?.reference.path == "Answer.swift")
    }

    @Test func registeredChatViewRouterSurvivesCoverAndUnregistersOnRemove() {
        ReviewCommentSelectionActiveRouter.resetForTesting()
        ComposerCanvasActiveDestination.resetForTesting()
        defer {
            ReviewCommentSelectionActiveRouter.resetForTesting()
            ComposerCanvasActiveDestination.resetForTesting()
        }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let anchor = ComposerCanvasDestinationAnchorController()
        host.addChild(anchor)
        host.view.addSubview(anchor.view)
        anchor.didMove(toParent: host)
        anchor.viewDidAppear(false)
        anchor.destination = ComposerCanvasDestination(sessionId: "session-origin") { _, _ in true }
        let router = ReviewCommentSelectionRouter { _ in }
        anchor.reviewCommentSelectionRouter = router

        #expect(ReviewCommentSelectionActiveRouter.router(for: "session-origin") === router)

        anchor.viewDidDisappear(false)
        #expect(ReviewCommentSelectionActiveRouter.router(for: "session-origin") === router)

        anchor.willMove(toParent: nil)
        anchor.removeFromParent()
        #expect(ReviewCommentSelectionActiveRouter.router(for: "session-origin") == nil)
    }

    @Test(arguments: WikiOpenableCommentCase.allCases)
    func wikiOpenableTypeShowsCommentWhenDestinationScopeApplied(fileCase: WikiOpenableCommentCase) throws {
        ReviewCommentSelectionActiveRouter.resetForTesting()
        defer { ReviewCommentSelectionActiveRouter.resetForTesting() }

        let router = ReviewCommentSelectionRouter(
            dispatch: { _ in },
            inlineSave: { _, _ in true }
        )
        ReviewCommentSelectionActiveRouter.register(router, sessionId: "session-origin")
        let scope = try #require(
            WorkspaceLinkedFileDestinationView.reviewCommentSelectionScope(
                sourceSessionId: "session-origin"
            )
        )
        let controller = FullScreenCodeViewController(
            content: .fromText(fileCase.content, filePath: fileCase.path),
            reviewCommentSelectionContext: scope.makeContext(
                sessionId: "session-origin",
                filePath: fileCase.path
            )
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        if fileCase.needsSourceToggle {
            controller.toggleSourceForTesting()
            controller.view.layoutIfNeeded()
        }

        let textView = try #require(timelineAllTextViews(in: controller.view).first {
            timelineRenderedText(of: $0).contains(fileCase.needle)
        })
        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: min(3, (timelineRenderedText(of: textView) as NSString).length)),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))

        #expect(timelineActionTitles(in: menu).contains("Comment"))
    }

    @Test func wikiOpenableTypeKeepsCopyOnlyWithoutSourceSession() throws {
        let controller = FullScreenCodeViewController(
            content: .fromText("let answer = 42", filePath: "Answer.swift")
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()

        let textView = try #require(timelineAllTextViews(in: controller.view).first {
            timelineRenderedText(of: $0).contains("let answer = 42")
        })
        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 3),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))

        #expect(timelineActionTitles(in: menu) == ["Copy"])
    }

    @Test func capturedAddToChatDestinationMatchesSourceSessionOnly() {
        let current = ComposerCanvasDestination(sessionId: "session-origin") { _, _ in true }

        #expect(
            WorkspaceLinkedFileDestinationView.capturedAddToChatDestination(
                sourceSessionId: "session-origin",
                current: current
            )?.sessionId == "session-origin"
        )
        #expect(
            WorkspaceLinkedFileDestinationView.capturedAddToChatDestination(
                sourceSessionId: "other-session",
                current: current
            ) == nil
        )
        #expect(
            WorkspaceLinkedFileDestinationView.capturedAddToChatDestination(
                sourceSessionId: nil,
                current: current
            ) == nil
        )
    }

    @Test func wikiLinkedDestinationInstallsCapturedCanvasDestinationForImagePresent() throws {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }

        var acceptedCount = 0
        let source = ComposerCanvasDestination(sessionId: "session-origin") { _, _ in
            acceptedCount += 1
            return true
        }
        ComposerCanvasActiveDestination.push(
            ComposerCanvasDestination(sessionId: "other-session") { _, _ in true }
        )
        #expect(
            WorkspaceLinkedFileDestinationView.capturedAddToChatDestination(
                sourceSessionId: "session-origin",
                current: ComposerCanvasActiveDestination.current
            ) == nil
        )

        ComposerCanvasActiveDestination.push(source)
        let captured = try #require(
            WorkspaceLinkedFileDestinationView.capturedAddToChatDestination(
                sourceSessionId: "session-origin",
                current: ComposerCanvasActiveDestination.current
            )
        )

        let presenter = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        presenter.loadViewIfNeeded()

        let anchor = ComposerCanvasDestinationAnchorController()
        presenter.addChild(anchor)
        presenter.view.addSubview(anchor.view)
        anchor.didMove(toParent: presenter)
        anchor.viewDidAppear(false)
        anchor.destination = captured

        ComposerCanvasActiveDestination.push(
            ComposerCanvasDestination(sessionId: "later-session") { _, _ in true }
        )

        FullScreenImageViewController.present(image: try makePNG().0, from: presenter)

        let navigation = try #require(presenter.presentedViewController as? UINavigationController)
        let viewer = try #require(navigation.viewControllers.first as? FullScreenImageViewController)
        let host = viewer.makeAnnotateHostForTesting()
        #expect(host.destinationSessionIdForTesting == "session-origin")

        let (image, pngData) = try makePNG()
        let outcome = host.completeAddToChatForTesting(
            attachment: PaperMarkupCanvasSession.makePendingImageAttachment(
                pngData: pngData,
                image: image
            ),
            recognizedText: "note"
        )
        #expect(outcome == .accepted)
        #expect(acceptedCount == 1)
    }

    @Test func wikiLinkedDestinationInstallsCapturedCanvasDestinationForSVGPresent() throws {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }

        var acceptedCount = 0
        let source = ComposerCanvasDestination(sessionId: "session-origin") { _, _ in
            acceptedCount += 1
            return true
        }
        ComposerCanvasActiveDestination.push(source)
        let captured = try #require(
            WorkspaceLinkedFileDestinationView.capturedAddToChatDestination(
                sourceSessionId: "session-origin",
                current: ComposerCanvasActiveDestination.current
            )
        )

        let presenter = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        presenter.loadViewIfNeeded()

        let anchor = ComposerCanvasDestinationAnchorController()
        presenter.addChild(anchor)
        presenter.view.addSubview(anchor.view)
        anchor.didMove(toParent: presenter)
        anchor.viewDidAppear(false)
        anchor.destination = captured

        ComposerCanvasActiveDestination.push(
            ComposerCanvasDestination(sessionId: "later-session") { _, _ in true }
        )

        FullScreenImageDataPreviewPresenter.present(
            data: Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"8\"></svg>".utf8),
            mimeType: "image/svg+xml",
            title: "Preview",
            from: presenter
        )

        let navigation = try #require(presenter.presentedViewController as? UINavigationController)
        let viewer = try #require(
            navigation.viewControllers.first as? FullScreenImageDataPreviewViewController
        )
        let host = viewer.makeAnnotateHostForTesting()
        #expect(host.destinationSessionIdForTesting == "session-origin")

        let (image, pngData) = try makePNG()
        let outcome = host.completeAddToChatForTesting(
            attachment: PaperMarkupCanvasSession.makePendingImageAttachment(
                pngData: pngData,
                image: image
            ),
            recognizedText: "note"
        )
        #expect(outcome == .accepted)
        #expect(acceptedCount == 1)
    }

    @Test func embeddedFileViewerHTMLAnnotateUsesExplicitDestination() throws {
        var acceptedCount = 0
        let destination = ComposerCanvasDestination(sessionId: "session-origin") { _, _ in
            acceptedCount += 1
            return true
        }
        let viewer = EmbeddedFileViewerView(
            content: .html(content: "<p>hello</p>", filePath: "note.html"),
            addToChatDestination: destination
        )
        let controller = viewer.debugMakeControllerForTesting()
        let host = controller.makeAnnotateHostForTesting()
        let (image, pngData) = try makePNG()
        let outcome = host.completeAddToChatForTesting(
            attachment: PaperMarkupCanvasSession.makePendingImageAttachment(
                pngData: pngData,
                image: image
            ),
            recognizedText: "note"
        )

        #expect(host.destinationSessionIdForTesting == "session-origin")
        #expect(outcome == .accepted)
        #expect(acceptedCount == 1)
    }

    @Test func embeddedFileViewerHTMLAnnotateDoesNotStealLiveChatDestination() throws {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }
        ComposerCanvasActiveDestination.push(
            ComposerCanvasDestination(sessionId: "other-chat") { _, _ in true }
        )
        let viewer = EmbeddedFileViewerView(
            content: .html(content: "<p>hello</p>", filePath: "note.html")
        )
        let controller = viewer.debugMakeControllerForTesting()
        let host = controller.makeAnnotateHostForTesting()
        let (image, pngData) = try makePNG()
        let outcome = host.completeAddToChatForTesting(
            attachment: PaperMarkupCanvasSession.makePendingImageAttachment(
                pngData: pngData,
                image: image
            ),
            recognizedText: "note"
        )

        #expect(outcome == .missingDestination)
        #expect(host.didDismissForTesting == false)
        #expect(host.lastFailureMessageForTesting == PaperMarkupCanvasSession.AddToChatFailure.missingDestinationMessage)
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

    private func makeCommentStore() -> ReviewCommentStore {
        let suiteName = "FileBrowserReviewCommentSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return ReviewCommentStore(defaults: defaults, keyPrefix: suiteName)
    }

    private func makePNG() throws -> (UIImage, Data) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let data = try #require(image.pngData())
        return (image, data)
    }
}

enum WikiOpenableCommentCase: String, CaseIterable {
    case markdown
    case code
    case json
    case html
    case org
    case latex
    case mermaid
    case graphviz
    case plain

    var path: String {
        switch self {
        case .markdown: "notes/daily.md"
        case .code: "Answer.swift"
        case .json: "config.json"
        case .html: "note.html"
        case .org: "notes.org"
        case .latex: "math.tex"
        case .mermaid: "flow.mmd"
        case .graphviz: "graph.dot"
        case .plain: "notes.txt"
        }
    }

    var content: String {
        switch self {
        case .markdown: "# Hello world"
        case .code: "let answer = 42"
        case .json: "{\"answer\": 42}"
        case .html: "<p>hello</p>"
        case .org: "* Hello org"
        case .latex: "x^2 + y^2"
        case .mermaid: "graph TD; A-->B"
        case .graphviz: "digraph { a -> b }"
        case .plain: "plain text note"
        }
    }

    var needle: String {
        switch self {
        case .markdown: "Hello world"
        case .code: "let answer = 42"
        case .json: "answer"
        case .html: "hello"
        case .org: "Hello org"
        case .latex: "x^2"
        case .mermaid: "graph TD"
        case .graphviz: "digraph"
        case .plain: "plain text note"
        }
    }

    var needsSourceToggle: Bool {
        switch self {
        case .html, .latex, .mermaid, .org:
            true
        case .markdown, .code, .json, .graphviz, .plain:
            false
        }
    }
}
