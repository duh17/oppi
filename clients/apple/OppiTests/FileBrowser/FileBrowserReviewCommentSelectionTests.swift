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

    @Test func foldedColumnBackStaysInsideTheFileBrowser() {
        let selected = FileBrowserSelection(path: "src/App.swift", name: "App.swift", size: 12)

        #expect(
            FileBrowserTreeNavigationReducer.usesInPlaceDirectoryNavigation(
                showsColumn: false,
                treeDirectoryPathIsSet: true,
                usesInlineCompactNavigation: false
            )
        )
        #expect(
            FileBrowserTreeNavigationReducer.usesInPlaceDirectoryNavigation(
                showsColumn: false,
                treeDirectoryPathIsSet: false,
                usesInlineCompactNavigation: false
            ) == false
        )
        #expect(
            FileBrowserTreeNavigationReducer.columnBackAction(
                selectedFile: selected,
                treeDirectoryPath: "src/components/",
                initialPath: "",
                currentDirectoryPath: "src/components/"
            ) == .clearSelectedFile
        )
        #expect(
            FileBrowserTreeNavigationReducer.columnBackAction(
                selectedFile: nil,
                treeDirectoryPath: "src/components/",
                initialPath: "",
                currentDirectoryPath: "src/components/"
            ) == .popToDirectory("src/")
        )
        #expect(
            FileBrowserTreeNavigationReducer.columnBackAction(
                selectedFile: nil,
                treeDirectoryPath: "",
                initialPath: "",
                currentDirectoryPath: ""
            ) == .useStackBack
        )
        #expect(
            FileBrowserTreeNavigationReducer.columnBackAction(
                selectedFile: nil,
                treeDirectoryPath: nil,
                initialPath: "",
                currentDirectoryPath: "src/"
            ) == .useStackBack
        )
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
        // compactOnly stays in-sheet; the workspace destination is not registered there.
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
        #expect(FileBrowserContentRenderingPolicy.showsNavigationChrome(for: .treePane) == false)
        #expect(FileBrowserContentRenderingPolicy.showsNavigationChrome(for: .pushed) == true)
        #expect(FileBrowserContentRenderingPolicy.showsNavigationChrome(for: .pushed, source: .hostFile) == false)
        #expect(FileBrowserContentRenderingPolicy.navigationTitle(
            source: .hostFile,
            path: "/Users/me/secret",
            fileName: "harmless note"
        ) == "/Users/me/secret")
    }

    @Test(arguments: [FileBrowserContentChromeMode.pushed, .treePane])
    func textMountsFullScreenCodeViewController(chromeMode: FileBrowserContentChromeMode) async throws {
        let client = FileBrowserTextMountURLProtocol.makeClient()
        let host = UIHostingController(rootView:
            FileBrowserContentView(
                workspaceId: FileBrowserTextMountURLProtocol.workspaceId,
                filePath: FileBrowserTextMountURLProtocol.filePath,
                fileName: FileBrowserTextMountURLProtocol.fileName,
                chromeMode: chromeMode
            )
            .environment(\.apiClient, client)
        )
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let mounted = await waitForMainActorCondition {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            return firstFullScreenCodeViewController(in: host) != nil
        }
        #expect(mounted)
        let controller = try #require(firstFullScreenCodeViewController(in: host))
        controller.view.layoutIfNeeded()
        #expect(timelineAllTextViews(in: controller.view).contains {
            timelineRenderedText(of: $0).contains(FileBrowserTextMountURLProtocol.needle)
        })
    }

    /// AVKit fullscreen from an inline Markdown video is a UIKit full-screen
    /// modal over this view. SwiftUI reports disappear/appear around it, and a
    /// same-path reload rebuilt the reader, replacing every inline player.
    @Test func textReaderSurvivesFullScreenModalCoverWithoutRemount() async throws {
        let client = FileBrowserTextMountURLProtocol.makeClient()
        let host = UIHostingController(rootView:
            FileBrowserContentView(
                workspaceId: FileBrowserTextMountURLProtocol.workspaceId,
                filePath: FileBrowserTextMountURLProtocol.filePath,
                fileName: FileBrowserTextMountURLProtocol.fileName,
                chromeMode: .pushed
            )
            .environment(\.apiClient, client)
        )
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let mounted = await waitForMainActorCondition(timeout: .seconds(5)) {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            return firstFullScreenCodeViewController(in: host) != nil
        }
        #expect(mounted)
        let reader = try #require(firstFullScreenCodeViewController(in: host))

        let cover = UIViewController()
        cover.modalPresentationStyle = .fullScreen
        host.present(cover, animated: false)
        let covered = await waitForMainActorCondition { host.view.window == nil }
        #expect(covered, "full-screen modal did not take the reader out of the window")
        cover.dismiss(animated: false)
        let uncovered = await waitForMainActorCondition { host.view.window != nil }
        #expect(uncovered)

        let kept = await waitForMainActorConditionToStayTrue(for: .seconds(1)) {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            return firstFullScreenCodeViewController(in: host) === reader
        }
        #expect(kept, "returning from a full-screen modal remounted the file reader")
        reader.view.layoutIfNeeded()
        #expect(timelineAllTextViews(in: reader.view).contains {
            timelineRenderedText(of: $0).contains(FileBrowserTextMountURLProtocol.needle)
        })
    }

    /// Re-showing the view (full-screen modal, or a pop back from a pushed
    /// wiki link) must still pick up a file that changed while it was covered.
    @Test func textReaderShowsChangedFileAfterFullScreenModalCover() async throws {
        let response = FileBrowserMutableTextURLProtocol.Response(body: "file-browser-revalidate-before")
        let client = FileBrowserMutableTextURLProtocol.makeClient(response: response)
        let host = UIHostingController(rootView:
            FileBrowserContentView(
                workspaceId: FileBrowserMutableTextURLProtocol.workspaceId,
                filePath: FileBrowserMutableTextURLProtocol.filePath,
                fileName: FileBrowserMutableTextURLProtocol.filePath,
                chromeMode: .pushed
            )
            .environment(\.apiClient, client)
        )
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        func showsText(_ needle: String) -> Bool {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            guard let reader = firstFullScreenCodeViewController(in: host) else { return false }
            reader.view.layoutIfNeeded()
            return timelineAllTextViews(in: reader.view).contains {
                timelineRenderedText(of: $0).contains(needle)
            }
        }

        let mounted = await waitForMainActorCondition(timeout: .seconds(5)) {
            showsText("file-browser-revalidate-before")
        }
        #expect(mounted)

        let cover = UIViewController()
        cover.modalPresentationStyle = .fullScreen
        host.present(cover, animated: false)
        let covered = await waitForMainActorCondition { host.view.window == nil }
        #expect(covered, "full-screen modal did not take the reader out of the window")
        response.set(body: "file-browser-revalidate-after")
        cover.dismiss(animated: false)

        let refreshed = await waitForMainActorCondition(timeout: .seconds(5)) {
            showsText("file-browser-revalidate-after")
        }
        #expect(refreshed, "returning to the file view kept stale text after the file changed")
    }

    /// Exercise the real SwiftUI task on re-show, not just status classification.
    @Test(arguments: [401, 403, 404], [false, true])
    func textReaderReplacesStaleTextAfterDefinitiveFailure(status: Int, coded: Bool) async throws {
        let message = status == 404 ? "File no longer exists" : "File access denied"
        try await checkReaderAfterReShow(status: status, message: message, keepsReader: false, coded: coded)
    }

    @Test(arguments: [200, 408, 500, 503, URLError.notConnectedToInternet.rawValue, URLError.timedOut.rawValue])
    func textReaderKeepsIdentityAfterUnchangedTextOrTransientFailure(status: Int) async throws {
        try await checkReaderAfterReShow(status: status, message: "Temporary failure", keepsReader: true)
    }

    private func checkReaderAfterReShow(
        status: Int, message: String, keepsReader: Bool, coded: Bool = true
    ) async throws {
        let text = "file-browser-revalidate-kept-text"
        let response = FileBrowserMutableTextURLProtocol.Response(body: text)
        let client = FileBrowserMutableTextURLProtocol.makeClient(response: response)
        let host = UIHostingController(rootView:
            FileBrowserContentView(
                workspaceId: FileBrowserMutableTextURLProtocol.workspaceId,
                filePath: FileBrowserMutableTextURLProtocol.filePath,
                fileName: FileBrowserMutableTextURLProtocol.filePath,
                chromeMode: .pushed
            )
            .environment(\.apiClient, client)
        )
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let mounted = await waitForMainActorCondition(timeout: .seconds(5)) {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            return firstFullScreenCodeViewController(in: host) != nil
        }
        #expect(mounted, "initial reads: \(response.requestCount)")
        let reader = try #require(firstFullScreenCodeViewController(in: host))
        let cover = UIViewController()
        cover.modalPresentationStyle = .fullScreen
        host.present(cover, animated: false)
        let covered = await waitForMainActorCondition { host.view.window == nil }
        #expect(covered)
        let errorBody = coded
            ? "{\"error\":\"\(message)\",\"code\":\"file_error\"}"
            : "{\"error\":\"\(message)\"}"
        response.set(body: status == 200 ? text : errorBody, status: status)
        let readsBefore = response.requestCount
        cover.dismiss(animated: false)
        let reRead = await waitForMainActorCondition(timeout: .seconds(5)) {
            response.requestCount > readsBefore && host.view.window != nil
        }
        #expect(reRead, "re-show must actually re-read the file")

        if keepsReader {
            let kept = await waitForMainActorConditionToStayTrue(for: .seconds(1)) {
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                return firstFullScreenCodeViewController(in: host) === reader
            }
            #expect(kept, "a transient failure or unchanged text must not remount the reader")
            reader.view.layoutIfNeeded()
            #expect(timelineAllTextViews(in: reader.view).contains {
                timelineRenderedText(of: $0).contains(text)
            })
        } else {
            let unavailable = await waitForMainActorCondition(timeout: .seconds(5)) {
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                return firstFullScreenCodeViewController(in: host) == nil
            }
            #expect(unavailable, "definitive failure left the stale reader mounted")
            let cleared = await waitForMainActorConditionToStayTrue(for: .seconds(1)) {
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                return firstFullScreenCodeViewController(in: host) == nil
                    && !timelineAllTextViews(in: host.view).contains {
                        timelineRenderedText(of: $0).contains(text)
                    }
                    && !timelineAllLabels(in: host.view).contains {
                        $0.text?.contains(text) == true
                    }
            }
            #expect(cleared, "no reader or stale text may remain after \(status)")

            // A later successful re-show must recover, rather than pinning the
            // file in a terminal unavailable state or resurrecting cached text.
            let recoveryCover = UIViewController()
            recoveryCover.modalPresentationStyle = .fullScreen
            host.present(recoveryCover, animated: false)
            let coveredAgain = await waitForMainActorCondition { host.view.window == nil }
            #expect(coveredAgain)
            let freshText = "file-browser-recovered-fresh-text"
            response.set(body: freshText)
            let readsBeforeRecovery = response.requestCount
            recoveryCover.dismiss(animated: false)
            let recovered = await waitForMainActorCondition(timeout: .seconds(5)) {
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                guard response.requestCount > readsBeforeRecovery,
                      let freshReader = firstFullScreenCodeViewController(in: host),
                      freshReader !== reader else { return false }
                freshReader.view.layoutIfNeeded()
                return timelineAllTextViews(in: freshReader.view).contains {
                    timelineRenderedText(of: $0).contains(freshText)
                }
            }
            #expect(recovered, "a later 200 must show fresh text after \(status)")
        }
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

    @Test func currentFileRoutingUsesSessionRawForWorkspaceAndHostBrowseForControl() throws {
        let workspaceTarget = try #require(ChatView.currentToolFileTarget(
            serverId: "server-origin",
            routeScope: .workspace("workspace-origin"),
            sessionId: "session-origin",
            path: "/workspace/docs/current.md"
        ))
        let controlTarget = try #require(ChatView.currentToolFileTarget(
            serverId: "server-origin",
            routeScope: .control,
            sessionId: "control-session",
            path: "notes/current.md"
        ))

        #expect(workspaceTarget.kind == .sessionFile(
            path: "/workspace/docs/current.md",
            fileName: "current.md",
            sessionId: "session-origin"
        ))
        #expect(controlTarget.kind == .hostFile(
            path: "notes/current.md",
            fileName: "current.md"
        ))
        #expect(controlTarget.workspaceId.isEmpty)
        #expect(controlTarget.controlSessionId == "control-session")
        let controlContent = WorkspaceLinkedFileDestinationView(target: controlTarget)
            .debugFileContentForTesting(
                store: .constant(FullScreenMarkdownViewportRestoreState())
            )
        #expect(controlContent.debugControlSessionIdForTesting == "control-session")
        #expect(ChatView.currentToolFileTarget(
            serverId: "server-origin",
            routeScope: nil,
            sessionId: "unknown-session",
            path: "/tmp/unknown.md"
        ) == nil)
    }

    @Test func linkedFileConstructionPreservesPerKindContextAndRestoreBinding() throws {
        let navigation = FileBrowserNavigationContext(files: [
            FileBrowserSelection(path: "docs/current.md", name: "current.md", size: nil),
            FileBrowserSelection(path: "docs/child.md", name: "child.md", size: nil),
        ])
        let anchor = SourceLineAnchor(startLine: 2, endLine: 4)
        for kind: WorkspaceLinkedFileKind in [
            .workspaceFile(path: "docs/current.md", fileName: "current.md"),
            .sessionFile(path: "docs/current.md", fileName: "current.md", sessionId: "exact-session"),
            .hostFile(path: "docs/current.md", fileName: "current.md"),
        ] {
            let target = WorkspaceLinkedFileNavTarget(
                serverId: "origin-server", workspaceId: "origin-workspace", worktreeId: "origin-worktree",
                kind: kind, navigationContext: navigation, lineAnchor: anchor,
                sourceSessionId: "review-session", controlSessionId: "control-session"
            )
            var restore = FullScreenMarkdownViewportRestoreState()
            let binding = Binding(get: { restore }, set: { restore = $0 })
            let destination = WorkspaceLinkedFileDestinationView(target: target)
            var anchorNotice: String?
            let content = destination.debugFileContentForTesting(
                workspaceRuntime: .sandbox, onLineAnchorNotice: { anchorNotice = $0 }, store: binding
            )
            #expect(content.workspaceRuntime == (content.source == .hostFile ? nil : .sandbox))
            content.onLineAnchorNotice?("Line out of range")
            #expect(anchorNotice == "Line out of range")
            guard case .connecting = destination.debugConnectionStateForTesting else {
                Issue.record("Linked reader must start connecting")
                return
            }
            #expect(content.serverId == "origin-server")
            #expect(content.workspaceId == "origin-workspace")
            #expect(content.filePath == "docs/current.md")
            #expect(content.fileName == "current.md")
            #expect(content.lineAnchor == anchor)
            #expect(content.chromeMode == .pushed)
            switch kind {
            case .workspaceFile:
                #expect(content.source == .workspaceFile)
                #expect(content.sessionId == "review-session")
                #expect(content.worktreeId == "origin-worktree")
                #expect(content.navigationContext == navigation)
                #expect(content.controlSessionId == nil)
            case .sessionFile:
                #expect(content.source == .sessionFile(sessionId: "exact-session"))
                #expect(content.sessionId == "exact-session")
                #expect(content.worktreeId == nil)
                #expect(content.navigationContext == nil)
                #expect(content.controlSessionId == nil)
            case .hostFile:
                #expect(content.source == .hostFile)
                #expect(content.sessionId == "review-session")
                #expect(content.worktreeId == nil)
                #expect(content.navigationContext == nil)
                #expect(content.controlSessionId == "control-session")
            }
            let store = try #require(content.markdownViewportRestore)
            store.wrappedValue[content.filePath] = .top
            #expect(restore[content.filePath] == .top)
        }
    }

    @Test func linkedFileConnectionStateSurfacesFailureOrCarriesExactConnection() {
        let connection = ServerConnection()
        for available in [nil, connection] {
            let state = WorkspaceLinkedFileConnectionState(preparationSucceeded: false, connection: available)
            guard case .failed(let message) = state else {
                Issue.record("Failed preparation must not use even an available connection")
                return
            }
            #expect(message == "Could not connect to this server.")
        }
        guard case .failed(let message) = WorkspaceLinkedFileConnectionState(
            preparationSucceeded: true, connection: nil
        ) else {
            Issue.record("Missing connection must fail, not stay connecting")
            return
        }
        #expect(message == "The server connection is unavailable.")
        guard case .connected(let resolved) = WorkspaceLinkedFileConnectionState(
            preparationSucceeded: true, connection: connection
        ) else {
            Issue.record("Prepared connection must be carried by the connected state")
            return
        }
        #expect(resolved === connection)
    }

    @Test func currentFileTargetKeepsExactServerWorkspaceSessionAndPath() {
        let target = WorkspaceLinkedFileNavTarget.sessionFile(
            serverId: "server-origin",
            workspaceId: "workspace-origin",
            sessionId: "session-origin",
            path: "/workspace/docs/current.md",
            sourceSessionId: "session-origin"
        )
        let destination = WorkspaceLinkedFileDestinationView(target: target)
        let store = Binding.constant(FullScreenMarkdownViewportRestoreState())
        let content = destination.debugFileContentForTesting(store: store)

        #expect(target.serverId == "server-origin")
        #expect(target.workspaceId == "workspace-origin")
        #expect(target.worktreeId == nil)
        #expect(target.sourceSessionId == "session-origin")
        #expect(content.debugServerIdForTesting == "server-origin")
        #expect(content.debugSessionIdForTesting == "session-origin")
        #expect(content.debugSourceForTesting == .sessionFile(sessionId: "session-origin"))
        guard case .sessionFile(let path, let fileName, let sessionId) = target.kind else {
            Issue.record("Expected exact session file target")
            return
        }
        #expect(path == "/workspace/docs/current.md")
        #expect(fileName == "current.md")
        #expect(sessionId == "session-origin")
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

    private func rootPanGestureCount(on controller: UIViewController) -> Int {
        (controller.view.gestureRecognizers ?? []).filter { $0 is UIPanGestureRecognizer }.count
    }

    private func firstFullScreenCodeViewController(in root: UIViewController) -> FullScreenCodeViewController? {
        if let match = root as? FullScreenCodeViewController {
            return match
        }
        for child in root.children {
            if let found = firstFullScreenCodeViewController(in: child) {
                return found
            }
        }
        if let presented = root.presentedViewController,
           let found = firstFullScreenCodeViewController(in: presented) {
            return found
        }
        return firstFullScreenCodeViewController(in: root.view)
    }

    private func firstFullScreenCodeViewController(in view: UIView) -> FullScreenCodeViewController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let match = current as? FullScreenCodeViewController {
                return match
            }
            responder = current.next
        }
        for subview in view.subviews {
            if let found = firstFullScreenCodeViewController(in: subview) {
                return found
            }
        }
        return nil
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

private final class FileBrowserTextMountURLProtocol: URLProtocol, @unchecked Sendable {
    static let host = "file-browser-text-mount.test"
    static let workspaceId = "ws-text-mount"
    static let filePath = "notes.txt"
    static let fileName = "notes.txt"
    static let needle = "file-browser-uikit-host-oracle"

    static func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FileBrowserTextMountURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://\(host)") ?? URL(fileURLWithPath: "/"),
            token: "test-token",
            configuration: config
        )
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = Data(Self.needle.utf8)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "text/plain; charset=utf-8",
                "Content-Length": "\(body.count)",
            ]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Serves independently controlled file responses for each hosted reader.
private final class FileBrowserMutableTextURLProtocol: URLProtocol, @unchecked Sendable {
    static let workspaceId = "ws-mutable-text"
    static let filePath = "changing.txt"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: Response] = [:]

    final class Response: @unchecked Sendable {
        private let lock = NSLock()
        private var body: String
        private var status = 200
        private var reads = 0

        init(body: String) { self.body = body }

        var requestCount: Int { lock.withLock { reads } }

        func set(body: String, status: Int = 200) {
            lock.withLock {
                self.body = body
                self.status = status
            }
        }

        func next() -> (Data, Int) {
            lock.withLock {
                reads += 1
                return (Data(body.utf8), status)
            }
        }
    }

    static func makeClient(response: Response) -> APIClient {
        let host = "\(UUID().uuidString.lowercased()).file-browser-mutable-text.test"
        lock.withLock { responses[host] = response }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FileBrowserMutableTextURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://\(host)") ?? URL(fileURLWithPath: "/"),
            token: "test-token",
            configuration: config
        )
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".file-browser-mutable-text.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let configured = Self.lock.withLock({ Self.responses[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (body, status) = configured.next()
        if status < 0 {
            client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: status)))
            return
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "text/plain; charset=utf-8",
                "Content-Length": "\(body.count)",
            ]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
