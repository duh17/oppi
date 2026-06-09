import Foundation
import Testing
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
