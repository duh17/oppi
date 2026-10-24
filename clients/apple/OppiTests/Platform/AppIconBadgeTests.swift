import Foundation
import Testing
@testable import Oppi

/// The app icon badge counts sessions waiting on the user, once each, across servers.
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
            needingYou: recount.needingYou,
            loadedServerIds: recount.loadedServerIds,
            pairedServerIds: paired ?? Set(stores.keys)
        )
        return badge.count
    }

    @Test func countsOnlySessionsWaitingOnTheUser() {
        let store = loadedStore("a", [
            session("lead-blocked", .blocked, kind: .permission),
            session("child-blocked", .blocked, kind: .question, parent: "lead-blocked"),
            session("lead-done", .done),
            session("lead-error", .error),
            session("child-done", .done, parent: "lead-blocked"),
            session("child-error", .error, parent: "lead-blocked"),
            session("working", .working),
            session("cancelled", .idle),
        ])

        #expect(store.sessionIdsNeedingYou == ["lead-blocked", "child-blocked"])
    }

    /// Opening a waiting session does not answer it; the badge holds until the session stops
    /// waiting.
    @Test func aWaitingSessionCountsDownWhenItStopsWaitingNotWhenItIsOpened() {
        let store = loadedStore("a", [session("ask", .blocked, kind: .question)])
        #expect(badge(stores: ["a": store]) == 1)

        store.markSeen(sessionId: "ask")
        #expect(badge(stores: ["a": store]) == 1)

        // The user answered: the server reports the session working again.
        store.sessions = [session("ask", .working)]
        #expect(badge(stores: ["a": store]) == 0)
    }

    @Test func serversAddUpAndASessionCountsOnce() {
        let a = loadedStore("a", [session("s1", .blocked, kind: .question), session("s2", .blocked, kind: .auth)])
        // The same session id on another server is another session.
        let b = loadedStore("b", [session("s1", .blocked, kind: .permission)])
        var stored = SessionBadge()
        // A push already recorded s1 on a; the recount does not count it twice.
        stored.insert(.init(serverId: "a", sessionId: "s1"))

        #expect(badge(stores: ["a": a, "b": b], stored: stored) == 3)
    }

    /// A stored badge from the old rule names finished runs too; the first recount of a loaded
    /// server drops them. A paired server that has not loaded keeps its pushed entries until it
    /// does.
    @Test func aRecountDropsPushedEntriesForLoadedServersOnly() {
        let a = loadedStore("a", [session("now-blocked", .blocked, kind: .permission)])
        let notLoaded = SessionStore()
        notLoaded.switchServer(to: "b")
        var stored = SessionBadge()
        stored.insert(.init(serverId: "a", sessionId: "finished-run"))
        stored.insert(.init(serverId: "b", sessionId: "pushed"))
        stored.insert(.init(serverId: "unpaired", sessionId: "pushed"))

        // a's recount replaces what pushes recorded for it; b keeps its push; an unpaired server drops.
        #expect(badge(stores: ["a": a, "b": notLoaded], stored: stored, paired: ["a", "b"]) == 2)
    }

    @Test func aPushCountsOnlyWhenItsSessionIsBlocked() {
        func key(_ event: PushPlaintext.Event) -> SessionBadge.Key? {
            SessionBadge.key(
                serverId: "a",
                plaintext: PushPlaintext(v: 1, ts: 0, event: event, sessionId: "s", title: "T", body: "B")
            )
        }

        #expect(key(.blocked) == .init(serverId: "a", sessionId: "s"))
        // A failed run and an agent's message do not wait on the user.
        #expect(key(.error) == nil)
        #expect(key(.notify) == nil)
        #expect(key(.pairingApproval) == nil)
        #expect(key(.deviceEnrolled) == nil)
    }
}
