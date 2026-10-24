import Foundation
import Testing
@testable import Oppi

// swiftlint:disable force_unwrapping

/// The push discovery card: when it becomes due, and when it shows.
@Suite("Push discovery card")
@MainActor
struct PushDiscoveryTests {
    private func makeDefaults() -> UserDefaults {
        let name = "push-discovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - When it shows

    @Test func showsOnlyWhenDueAvailableAndNotYetOn() {
        let cases: [(stage: PushDiscovery.Stage?, available: Bool, enabled: Bool, shows: Bool)] = [
            (.ready, true, false, true),
            // Nothing finished or asked yet.
            (nil, true, false, false),
            // Dismissed, or push on once: never again.
            (.closed, true, false, false),
            // The server's operator turned push off, or this build or device cannot register.
            (.ready, false, false, false),
            // Already on.
            (.ready, true, true, false),
        ]
        for row in cases {
            #expect(
                PushDiscovery.shouldShow(stage: row.stage, pushAvailable: row.available, pushEnabled: row.enabled) == row.shows,
                "stage \(String(describing: row.stage)), available \(row.available), enabled \(row.enabled)"
            )
        }
    }

    @Test func serverThatOffersNoRelayOffersNoPush() {
        #expect(!PushDiscovery.isPushAvailable(relay: nil))
    }

    // MARK: - When it becomes due

    @Test func theFirstFinishedOrBlockedSessionMakesItDue_andNothingAfterChangesIt() {
        let defaults = makeDefaults()
        #expect(PushDiscovery.stage(serverId: "srv", defaults: defaults) == nil)

        PushDiscovery.noteAttention(serverId: "srv", pushEnabled: false, defaults: defaults)
        #expect(PushDiscovery.stage(serverId: "srv", defaults: defaults) == .ready)

        PushDiscovery.close(serverId: "srv", defaults: defaults)
        PushDiscovery.noteAttention(serverId: "srv", pushEnabled: false, defaults: defaults)
        #expect(PushDiscovery.stage(serverId: "srv", defaults: defaults) == .closed)
    }

    @Test func aServerThatAlreadyUsesPushNeverGetsTheCard() {
        let defaults = makeDefaults()
        PushDiscovery.noteAttention(serverId: "srv", pushEnabled: true, defaults: defaults)
        #expect(PushDiscovery.stage(serverId: "srv", defaults: defaults) == .closed)
    }

    @Test func stageIsPerServer() {
        let defaults = makeDefaults()
        PushDiscovery.noteAttention(serverId: "one", pushEnabled: false, defaults: defaults)
        #expect(PushDiscovery.stage(serverId: "two", defaults: defaults) == nil)
    }

    @Test func removingAServerForgetsItsStage() {
        let defaults = makeDefaults()
        PushDiscovery.noteAttention(serverId: "srv", pushEnabled: false, defaults: defaults)
        PushDiscovery.forget(serverId: "srv", defaults: defaults)
        #expect(PushDiscovery.stage(serverId: "srv", defaults: defaults) == nil)
    }

    // MARK: - Live events

    /// A connection to a server with its own id, so the stage it records is this test's.
    private func makeConnection() throws -> (conn: ServerConnection, serverId: String) {
        let conn = ServerConnection()
        conn.configure(credentials: makeTestCredentials(fingerprint: "sha256:push-discovery-\(UUID().uuidString)"))
        let serverId = try #require(conn.currentServerId)
        PushDiscovery.forget(serverId: serverId)
        return (conn, serverId)
    }

    /// A turn that ends on a running session, and a question it waits on, are the two
    /// first moments; both come through the connection the app already runs.
    @Test func aSessionFinishingMakesTheCardDue() throws {
        let (conn, serverId) = try makeConnection()
        defer { PushDiscovery.forget(serverId: serverId) }
        conn.sessionStore.switchServer(to: serverId)
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .busy))

        _ = conn.applySharedStoreUpdate(for: .agentSettled, sessionId: "s1")

        #expect(PushDiscovery.stage(serverId: serverId) == .ready)
    }

    @Test func aSessionAskingForInputMakesTheCardDue() throws {
        let (conn, serverId) = try makeConnection()
        defer { PushDiscovery.forget(serverId: serverId) }
        let ask = AskRequest(id: "ask-1", sessionId: "s1", questions: [], allowCustom: false, timeout: nil)

        conn.storeAskRequest(ask, for: "s1", isFocusedSession: false)

        #expect(PushDiscovery.stage(serverId: serverId) == .ready)
    }

    @Test func aSessionThatIsStillWorkingLeavesTheCardAlone() throws {
        let (conn, serverId) = try makeConnection()
        defer { PushDiscovery.forget(serverId: serverId) }
        conn.sessionStore.switchServer(to: serverId)
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .ready))

        _ = conn.applySharedStoreUpdate(for: .agentStart, sessionId: "s1")

        #expect(PushDiscovery.stage(serverId: serverId) == nil)
    }
}
