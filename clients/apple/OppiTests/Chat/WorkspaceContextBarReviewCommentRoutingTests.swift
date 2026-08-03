import Foundation
import SwiftUI
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
        let scope = try #require(WorkspaceContextBar.makeFileDetailReviewCommentScope(
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

        let scope = try #require(WorkspaceContextBar.makeFileDetailReviewCommentScope(
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
        let sessionStore = SessionStore()
        sessionStore.switchServer(to: "srv1")
        let reviewStatus = makeReviewGitStatus()
        let presentation = WorkspaceContextBarReviewPresentation()
        guard let selectedFile = reviewStatus.files.first else {
            Issue.record("Expected a review file")
            return
        }
        let navigationFiles = reviewStatus.files.map { $0.toReviewFile() }
        let reviewItem = WorkspaceContextBarReviewItem.file(selectedFile)
        let model = WorkspaceContextBarReviewTestModel(gitStatus: reviewStatus)
        let controller = UIHostingController(
            rootView: WorkspaceContextBarReviewTestHost(
                model: model,
                sessionStore: sessionStore,
                reviewPresentation: presentation
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        controller.view.frame = window.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        defer {
            controller.rootView = WorkspaceContextBarReviewTestHost(
                model: model,
                sessionStore: sessionStore,
                reviewPresentation: presentation,
                isVisible: false
            )
            window.isHidden = true
            window.rootViewController = nil
        }

        presentation.navigationFiles = navigationFiles
        presentation.selectedReviewItem = reviewItem

        let presented = await waitForMainActorCondition {
            controller.presentedViewController != nil
        }
        #expect(presented)
        guard let presentedReview = controller.presentedViewController else { return }
        #expect(presentation.selectedReviewItem == reviewItem)
        #expect(presentation.navigationFiles == navigationFiles)

        model.gitStatus = nil
        await Task.yield()

        let remainsPresented = await waitForMainActorConditionToStayTrue(
            for: .milliseconds(500),
            poll: .milliseconds(10)
        ) {
            controller.presentedViewController === presentedReview
        }
        #expect(remainsPresented, "The same file review sheet should remain presented")
        #expect(presentation.selectedReviewItem == reviewItem)
        #expect(presentation.navigationFiles == navigationFiles,
                "The open review should retain its original navigation files")
    }

    @Test func commitReviewSheetSurvivesContextBecomingUnavailable() async throws {
        let sessionStore = SessionStore()
        sessionStore.switchServer(to: "srv1")
        let presentation = WorkspaceContextBarReviewPresentation()
        let reviewItem = WorkspaceContextBarReviewItem.commit(
            GitCommitSummary(sha: "abc1234", message: "Review", date: "2026-08-03")
        )
        let model = WorkspaceContextBarReviewTestModel(gitStatus: makeReviewGitStatus())
        let controller = UIHostingController(
            rootView: WorkspaceContextBarReviewTestHost(
                model: model,
                sessionStore: sessionStore,
                reviewPresentation: presentation
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        controller.view.frame = window.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        defer {
            controller.rootView = WorkspaceContextBarReviewTestHost(
                model: model,
                sessionStore: sessionStore,
                reviewPresentation: presentation,
                isVisible: false
            )
            window.isHidden = true
            window.rootViewController = nil
        }

        presentation.selectedReviewItem = reviewItem

        let presented = await waitForMainActorCondition {
            controller.presentedViewController != nil
        }
        #expect(presented)
        guard let presentedReview = controller.presentedViewController else { return }

        model.gitStatus = nil
        await Task.yield()

        let remainsPresented = await waitForMainActorConditionToStayTrue(
            for: .milliseconds(500),
            poll: .milliseconds(10)
        ) {
            controller.presentedViewController === presentedReview
        }
        #expect(remainsPresented, "The same commit review sheet should remain presented")
        #expect(presentation.selectedReviewItem == reviewItem)
    }

    @Test func parentScopeKeepsInlineComposerVoiceInputForFileDetail() async throws {
        let voiceInputManager = VoiceInputManager()
        let parentScope = ReviewCommentSelectionScope.activeSession(ReviewCommentSelectionRouter(
            dispatch: { _ in },
            inlineSave: { _, _ in true },
            inlineQuickComments: [.fix],
            voiceInputManager: voiceInputManager
        ))

        let scope = try #require(WorkspaceContextBar.makeFileDetailReviewCommentScope(
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

@MainActor @Observable
private final class WorkspaceContextBarReviewTestModel {
    var gitStatus: GitStatus?

    init(gitStatus: GitStatus?) {
        self.gitStatus = gitStatus
    }
}

private struct WorkspaceContextBarReviewTestHost: View {
    @Bindable var model: WorkspaceContextBarReviewTestModel
    let sessionStore: SessionStore
    let reviewPresentation: WorkspaceContextBarReviewPresentation
    var isVisible = true

    var body: some View {
        Group {
            if isVisible {
                WorkspaceContextBar(
                    gitStatus: model.gitStatus,
                    isLoading: false,
                    workspaceId: "w1",
                    sessionId: nil,
                    initialExpanded: true,
                    reviewPresentation: reviewPresentation
                )
            } else {
                EmptyView()
            }
        }
        .environment(sessionStore)
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
