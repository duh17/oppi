import Testing
@testable import Oppi

@Suite("FocusedSessionStore")
@MainActor
struct FocusedSessionStoreTests {
    @Test func focusStoresContextAndAdvancesGeneration() {
        let store = FocusedSessionStore()

        let first = store.focus(sessionId: "s1")
        let second = store.focus(sessionId: "s2")

        #expect(first.sessionId == "s1")
        #expect(second.sessionId == "s2")
        #expect(second.generation > first.generation)
        #expect(store.focused == second)
    }

    @Test func serverConnectionFocusSetsCommandTarget() async {
        let (conn, _) = await makeTestConnection()

        conn.focusSession("s2")

        #expect(conn.focusedSessionId == "s2")
        #expect(conn.focusedSessionStore.isFocused("s2"))
    }

    @Test func disconnectClearsFocusedSession() async {
        let (conn, _) = await makeTestConnection()
        conn._sendMessageForTesting = { _ in }
        conn.focusSession("s1")

        conn.disconnectSession()

        #expect(conn.focusedSessionId == nil)
        #expect(conn.focusedSessionStore.focused == nil)
    }
}
