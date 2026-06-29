import Testing
@testable import Oppi

@Suite("SessionWorktreeIndicatorPresentation")
struct SessionWorktreeIndicatorPresentationTests {
    @Test func hidesForSessionsWithoutASeparateWorktree() {
        var session = makeTestSession()

        #expect(SessionWorktreeIndicatorPresentation(session: session) == nil)

        session.worktreeId = "main"
        #expect(SessionWorktreeIndicatorPresentation(session: session) == nil)

        session.worktreeId = "  "
        #expect(SessionWorktreeIndicatorPresentation(session: session) == nil)
    }

    @Test func showsForNonMainWorktreeSessions() throws {
        var session = makeTestSession()
        session.worktreeId = " wt_feature "

        let presentation = try #require(SessionWorktreeIndicatorPresentation(session: session))
        #expect(presentation.worktreeId == "wt_feature")
        #expect(presentation.accessibilityLabel == "Worktree session")
    }
}
