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

    @Test func treePaneTextUsesEmbeddedFileViewerWithoutNavigationChrome() {
        #expect(FileBrowserContentRenderingPolicy.textRenderer(for: .treePane) == .embeddedFileViewer)
        #expect(FileBrowserContentRenderingPolicy.showsNavigationChrome(for: .treePane) == false)
        #expect(FileBrowserContentRenderingPolicy.textRenderer(for: .pushed) == .embeddedFileViewer)
        #expect(FileBrowserContentRenderingPolicy.showsNavigationChrome(for: .pushed) == true)
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

    @Test func codeBodyNoCommentMenuWhenRouterNil() throws {
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

        let menu = textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 3),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        )

        #expect(menu == nil)
    }
}
