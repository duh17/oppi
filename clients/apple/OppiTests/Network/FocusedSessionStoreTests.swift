import Testing
@testable import Oppi

@Suite("FocusedSessionStore")
@MainActor
struct FocusedSessionStoreTests {
    @Test func focusStoresContextAndAdvancesGeneration() {
        let store = FocusedSessionStore()

        let first = store.focus(sessionId: "s1", workspaceId: "w1")
        let second = store.focus(sessionId: "s2", workspaceId: "w2")

        #expect(first.sessionId == "s1")
        #expect(first.workspaceId == "w1")
        #expect(second.sessionId == "s2")
        #expect(second.workspaceId == "w2")
        #expect(second.generation > first.generation)
        #expect(store.focused == second)
    }

    @Test func clearIfCurrentContextDoesNotClearNewerFocus() {
        let store = FocusedSessionStore()

        let old = store.focus(sessionId: "s1", workspaceId: nil)
        let newer = store.focus(sessionId: "s2", workspaceId: nil)

        store.clearIfCurrent(old)

        #expect(store.focused == newer)
    }

    @Test func clearIfCurrentSessionClearsMatchingFocusOnly() {
        let store = FocusedSessionStore()

        store.focus(sessionId: "s1", workspaceId: nil)
        store.clearIfCurrent(sessionId: "other")
        #expect(store.isFocused("s1"))

        store.clearIfCurrent(sessionId: "s1")
        #expect(store.focused == nil)
    }

    @Test func serverConnectionFocusSetsCommandTarget() {
        let (conn, _) = makeTestConnection()

        conn.focusSession("s2")

        #expect(conn.focusedSessionId == "s2")
        #expect(conn.focusedSessionStore.isFocused("s2"))
    }

    @Test func disconnectClearsFocusedSession() {
        let (conn, _) = makeTestConnection()
        conn._sendMessageForTesting = { _ in }
        conn.focusSession("s1")

        conn.disconnectSession()

        #expect(conn.focusedSessionId == nil)
        #expect(conn.focusedSessionStore.focused == nil)
    }
}
