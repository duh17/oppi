import Foundation
import Testing
@testable import Oppi

/// The app icon badge counts sessions that owe the user a look, once each, across servers.
@Suite("App icon badge")
@MainActor
struct AppIconBadgeTests {
    /// After the store's seen baseline, so a done or error outcome is unseen until marked.
    private let later = Date().addingTimeInterval(3600)

    private func session(
        _ id: String,
        _ state: ProgramStatusState,
        kind: ProgramStatusKind? = nil,
        since: Date? = nil,
        parent: String? = nil
    ) -> Session {
        var session = makeTestSession(
            id: id,
            status: state == .working || state == .blocked ? .busy : .ready,
            programStatus: ProgramStatus(state: state, kind: kind, since: since ?? later)
        )
        session.parentSessionId = parent
        return session
    }

    private func loadedStore(_ serverId: String, _ sessions: [Session]) -> SessionStore {
        let store = SessionStore()
        store.switchServer(to: serverId)
        store.sessions = sessions
        store.markSyncSucceeded()
        return store
    }

    private func badge(
        stores: [String: SessionStore],
        stored: SessionBadge = SessionBadge(),
        paired: Set<String>? = nil
    ) -> Int {
        let recount = AppIconBadgeService.recount(stores: stores)
        var badge = stored
        badge.reconcile(
            owed: recount.owed,
            loadedServerIds: recount.loadedServerIds,
            pairedServerIds: paired ?? Set(stores.keys)
        )
        return badge.count
    }

    @Test func countsWaitingSessionsAndUnseenTopLevelOutcomes() {
        let store = loadedStore("a", [
            session("lead-done", .done),
            session("lead-error", .error),
            session("lead-blocked", .blocked, kind: .permission),
            session("child-blocked", .blocked, kind: .question, parent: "lead-done"),
            session("child-done", .done, parent: "lead-done"),
            session("child-error", .error, parent: "lead-done"),
            session("cancelled", .idle),
            session("working", .working),
            session("seen-done", .done, since: Date(timeIntervalSince1970: 1)),
        ])

        #expect(store.sessionIdsOwingALook == ["lead-done", "lead-error", "lead-blocked", "child-blocked"])
    }

    @Test func markingASessionSeenCountsItDown() {
        let store = loadedStore("a", [session("done", .done), session("blocked", .blocked, kind: .auth)])
        #expect(badge(stores: ["a": store]) == 2)

        store.markSeen(sessionId: "done")
        #expect(badge(stores: ["a": store]) == 1)

        // A waiting session still waits after the user looks at it.
        store.markSeen(sessionId: "blocked")
        #expect(badge(stores: ["a": store]) == 1)
    }

    @Test func serversAddUpAndASessionCountsOnce() {
        let a = loadedStore("a", [session("s1", .done), session("s2", .blocked, kind: .question)])
        // The same session id on another server is another session.
        let b = loadedStore("b", [session("s1", .blocked, kind: .permission)])
        var stored = SessionBadge()
        // A push already recorded s2 on a; the recount does not count it twice.
        stored.insert(.init(serverId: "a", sessionId: "s2"))

        #expect(badge(stores: ["a": a, "b": b], stored: stored) == 3)
    }

    @Test func aServerNotLoadedYetKeepsItsPushedSessions() {
        let a = loadedStore("a", [session("s1", .done)])
        let notLoaded = SessionStore()
        notLoaded.switchServer(to: "b")
        var stored = SessionBadge()
        stored.insert(.init(serverId: "a", sessionId: "answered-elsewhere"))
        stored.insert(.init(serverId: "b", sessionId: "pushed"))
        stored.insert(.init(serverId: "unpaired", sessionId: "pushed"))

        // a's recount replaces what pushes recorded for it; b keeps its push; an unpaired server drops.
        #expect(badge(stores: ["a": a, "b": notLoaded], stored: stored, paired: ["a", "b"]) == 2)
    }
}
