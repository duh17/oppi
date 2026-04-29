import Foundation
import Testing
@testable import Oppi

@Suite("Workspace context bar pi routing")
@MainActor
struct WorkspaceContextBarPiRoutingTests {
    @Test func sessionScopedActionScopeForwardsReviewCommentToActiveChatInsteadOfQuickSession() throws {
        var forwarded: SelectedTextPiRequest?
        var dismissed = false

        let parentScope = SelectedTextActionScope.activeSession(SelectedTextPiActionRouter { request in
            forwarded = request
        })
        let scope = try #require(WorkspaceContextBar.makeFileDetailActionScope(
            parentScope: parentScope,
            fallbackScope: .quickSession(SelectedTextPiActionRouter { _ in Issue.record("Should not route session-scoped comments to quick session") }),
            dismissFileDetail: { dismissed = true }
        ))

        let request = SelectedTextPiRequest(
            action: PiQuickAction.reviewCommentAction,
            selectedText: "+ changed line",
            source: SelectedTextSourceContext(
                sessionId: "s1",
                surface: .fullScreenDiff,
                filePath: "Sources/App.swift"
            )
        )

        scope.router.dispatch(request)

        #expect(forwarded == request)
        #expect(dismissed == true)
    }

    @Test func missingParentScopeFallsBackToQuickSession() throws {
        var fallback: SelectedTextPiRequest?
        var dismissed = false

        let scope = try #require(WorkspaceContextBar.makeFileDetailActionScope(
            parentScope: nil,
            fallbackScope: .quickSession(SelectedTextPiActionRouter { request in
                fallback = request
            }),
            dismissFileDetail: { dismissed = true }
        ))

        let request = SelectedTextPiRequest(
            action: PiQuickAction.reviewCommentAction,
            selectedText: "+ changed line",
            source: SelectedTextSourceContext(sessionId: "", surface: .fullScreenDiff)
        )

        scope.router.dispatch(request)

        #expect(fallback == request)
        #expect(dismissed == false)
    }
}
