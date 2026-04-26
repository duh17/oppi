import Foundation
import Testing
@testable import Oppi

@Suite("Workspace context bar pi routing")
@MainActor
struct WorkspaceContextBarPiRoutingTests {
    @Test func sessionScopedRouterForwardsReviewCommentToActiveChatInsteadOfQuickSession() throws {
        var forwarded: SelectedTextPiRequest?
        var dismissed = false

        let parentRouter = SelectedTextPiActionRouter { request in
            forwarded = request
        }
        let router = try #require(WorkspaceContextBar.makeFileDetailPiRouter(
            parentRouter: parentRouter,
            fallbackRouter: SelectedTextPiActionRouter { _ in Issue.record("Should not route session-scoped comments to quick session") },
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

        router.dispatch(request)

        #expect(forwarded == request)
        #expect(dismissed == true)
    }

    @Test func missingParentRouterFallsBackToQuickSession() throws {
        var fallback: SelectedTextPiRequest?
        var dismissed = false

        let router = try #require(WorkspaceContextBar.makeFileDetailPiRouter(
            parentRouter: nil,
            fallbackRouter: SelectedTextPiActionRouter { request in
                fallback = request
            },
            dismissFileDetail: { dismissed = true }
        ))

        let request = SelectedTextPiRequest(
            action: PiQuickAction.reviewCommentAction,
            selectedText: "+ changed line",
            source: SelectedTextSourceContext(sessionId: "", surface: .fullScreenDiff)
        )

        router.dispatch(request)

        #expect(fallback == request)
        #expect(dismissed == false)
    }
}
