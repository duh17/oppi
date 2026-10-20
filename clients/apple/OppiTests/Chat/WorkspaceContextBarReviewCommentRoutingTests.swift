import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Workspace context bar review comment routing")
@MainActor
struct WorkspaceContextBarReviewCommentRoutingTests {
    @Test func parentScopeForwardsReviewCommentAfterDismissingFileDetail() throws {
        var forwarded: ReviewCommentSelectionRequest?
        var dismissed = false

        let parentScope = ReviewCommentSelectionScope.activeSession(ReviewCommentSelectionRouter { request in
            forwarded = request
        })
        let scope = try #require(WorkspaceContextBarView.makeFileDetailReviewCommentScope(
            parentScope: parentScope,
            fallbackScope: nil,
            dismissFileDetail: { dismissed = true }
        ))

        let request = ReviewCommentSelectionRequest(
            selectedText: "+ changed line",
            source: ReviewCommentSourceContext(
                sessionId: "s1",
                surface: .fullScreenDiff,
                filePath: "Sources/App.swift"
            )
        )

        scope.router.dispatch(request)

        #expect(forwarded == request)
        #expect(dismissed == true)
    }

    @Test func missingParentScopeReturnsFallbackScope() throws {
        var fallback: ReviewCommentSelectionRequest?
        var dismissed = false
        let fallbackScope = ReviewCommentSelectionScope.activeSession(ReviewCommentSelectionRouter { request in
            fallback = request
        })

        let scope = try #require(WorkspaceContextBarView.makeFileDetailReviewCommentScope(
            parentScope: nil,
            fallbackScope: fallbackScope,
            dismissFileDetail: { dismissed = true }
        ))

        let request = ReviewCommentSelectionRequest(
            selectedText: "+ changed line",
            source: ReviewCommentSourceContext(sessionId: "s1", surface: .fullScreenDiff)
        )

        scope.router.dispatch(request)

        #expect(fallback == request)
        #expect(dismissed == false)
    }

    @Test func fileReviewSheetAndNavigationSurviveContextBecomingUnavailable() async throws {
        let fixture = ContextBarFixture()
        defer { fixture.tearDown() }

        let row = try #require(fixture.button(labelContaining: "src/App.swift"))
        row.sendActions(for: .primaryActionTriggered)

        let presented = await waitForMainActorCondition {
            fixture.screen.presentedViewController != nil
        }
        #expect(presented)
        let container = try #require(fixture.screen.presentedViewController as? UINavigationController)
        let review = try #require(container.viewControllers.first as? WorkspaceReviewFileDetailViewController)
        let navigationFiles = makeReviewGitStatus().files.map { $0.toReviewFile() }
        #expect(review.configuration.file.path == "src/App.swift")
        #expect(review.configuration.navigationFiles == navigationFiles)

        fixture.bar.context.gitStatus = nil
        fixture.bar.updatePropertiesIfNeeded()

        let remainsPresented = await waitForMainActorConditionToStayTrue(
            for: .milliseconds(500),
            poll: .milliseconds(10)
        ) {
            fixture.screen.presentedViewController === container
        }
        #expect(remainsPresented, "The same file review sheet should remain presented")
        #expect(review.configuration.navigationFiles == navigationFiles,
                "The open review should retain its original navigation files")
    }

    @Test func commitReviewSheetSurvivesContextBecomingUnavailable() async throws {
        let fixture = ContextBarFixture()
        defer { fixture.tearDown() }

        let row = try #require(fixture.button(labelContaining: "abc1234"))
        row.sendActions(for: .primaryActionTriggered)

        let presented = await waitForMainActorCondition {
            fixture.screen.presentedViewController != nil
        }
        #expect(presented)
        let container = try #require(fixture.screen.presentedViewController as? UINavigationController)
        let commit = try #require(container.viewControllers.first as? CommitDetailViewController)
        #expect(commit.configuration.commit.sha == "abc1234")

        fixture.bar.context.gitStatus = nil
        fixture.bar.updatePropertiesIfNeeded()

        let remainsPresented = await waitForMainActorConditionToStayTrue(
            for: .milliseconds(500),
            poll: .milliseconds(10)
        ) {
            fixture.screen.presentedViewController === container
        }
        #expect(remainsPresented, "The same commit review sheet should remain presented")
    }

    @Test func parentScopeKeepsInlineComposerVoiceInputForFileDetail() async throws {
        let voiceInputManager = VoiceInputManager()
        let parentScope = ReviewCommentSelectionScope.activeSession(ReviewCommentSelectionRouter(
            dispatch: { _ in },
            inlineSave: { _, _ in true },
            inlineQuickComments: [.fix],
            voiceInputManager: voiceInputManager
        ))

        let scope = try #require(WorkspaceContextBarView.makeFileDetailReviewCommentScope(
            parentScope: parentScope,
            fallbackScope: nil,
            dismissFileDetail: {}
        ))

        let request = ReviewCommentSelectionRequest(
            selectedText: "+ changed line",
            source: ReviewCommentSourceContext(sessionId: "s1", surface: .fullScreenDiff)
        )

        #expect(scope.router.supportsInlineCommentComposer)
        #expect(scope.router.voiceInputManager === voiceInputManager)
        #expect(await scope.router.saveInlineComment(body: "Fix this.", request: request))
    }
}

/// An expanded bar on a workspace's Git status, pinned to the top of a screen
/// in a window, presenting from that screen.
@MainActor
private struct ContextBarFixture {
    let screen = UIViewController()
    let bar: WorkspaceContextBarView
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))

    init() {
        let connection = ServerConnection()
        connection.sessionStore.switchServer(to: "srv1")
        bar = WorkspaceContextBarView(
            context: .init(gitStatus: makeReviewGitStatus(), workspaceId: "w1"),
            options: .init(initiallyExpanded: true),
            connection: connection,
            apiClient: nil,
            navigation: AppNavigation()
        )
        bar.presenter = screen
        screen.traitOverrides.appRootEnvironment = makeTestAppRoot()
        bar.translatesAutoresizingMaskIntoConstraints = false
        screen.view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: screen.view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: screen.view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: screen.view.trailingAnchor),
        ])
        window.rootViewController = screen
        window.makeKeyAndVisible()
        bar.updatePropertiesIfNeeded()
        screen.view.layoutIfNeeded()
    }

    func button(labelContaining text: String) -> UIButton? {
        timelineAllViews(in: bar)
            .compactMap { $0 as? UIButton }
            .first { $0.accessibilityLabel?.contains(text) == true }
    }

    func tearDown() {
        screen.presentedViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }
}

@MainActor
private func makeReviewGitStatus() -> GitStatus {
    GitStatus(
        isGitRepo: true,
        branch: "main",
        headSha: "abc1234",
        ahead: 0,
        behind: 0,
        dirtyCount: 2,
        untrackedCount: 0,
        stagedCount: 0,
        files: [
            GitFileStatus(status: " M", path: "src/App.swift", addedLines: 2, removedLines: 1),
            GitFileStatus(status: " M", path: "README.md", addedLines: 1, removedLines: 0),
        ],
        totalFiles: 2,
        addedLines: 3,
        removedLines: 1,
        stashCount: 0,
        lastCommitMessage: "Review",
        lastCommitDate: nil,
        recentCommits: [GitCommitSummary(sha: "abc1234", message: "Review", date: "2026-08-03")]
    )
}
