@testable import Oppi
import Foundation
import Testing

@Suite("Live Activity counts")
@MainActor
struct LiveActivityCountsTests {
    private func session(
        _ id: String,
        _ state: ProgramStatusState,
        kind: ProgramStatusKind? = nil,
        status: SessionStatus = .busy,
        parent: String? = nil
    ) -> Session {
        var session = makeTestSession(
            id: id,
            status: status,
            programStatus: ProgramStatus(state: state, kind: kind, since: Date()),
            messageCount: 2,
            firstMessage: "go"
        )
        session.parentSessionId = parent
        return session
    }

    @Test func countsTopLevelRunningAndWaitingSessionsOnly() {
        let counts = LiveActivityManager.counts(for: [
            session("a", .working),
            session("b", .working),
            session("c", .blocked, kind: .permission),
            session("d", .blocked, kind: .auth),
            session("e", .done, status: .ready),
            session("f", .idle, status: .ready),
            session("g", .working, status: .stopped),
            session("child-1", .working, parent: "a"),
            session("child-2", .blocked, kind: .question, parent: "a"),
        ])
        #expect(counts == .init(running: 2, needsYou: 2))
    }

    @Test func syncTracksOnlyServersWhoseCardIsOn() {
        let manager = LiveActivityManager(isEnabled: { $0 == "on" }, serverDrivesCard: { _ in false })
        manager.sync(connectionId: "off", sessions: [session("a", .working)])
        manager.sync(connectionId: "on", sessions: [session("a", .working), session("b", .blocked)])
        #expect(manager.countsByServer == ["on": .init(running: 1, needsYou: 1)])

        manager.removeConnection("on")
        #expect(manager.countsByServer.isEmpty)
    }
}

@Suite("Live Activity relay contract")
struct LiveActivityRelayContractTests {
    /// The relay's update payload (protocol/push/spec.md "Live Activity"). ActivityKit decodes
    /// `content-state` and `attributes` with a default `JSONDecoder`; a renamed field breaks
    /// every pushed update.
    @Test func decodesTheRelayTemplate() throws {
        let start = Data("""
        {"aps":{"timestamp":1760000000,"event":"start","content-state":{"running":3,"needsYou":1},\
        "attributes-type":"OppiActivityAttributes","attributes":{"slot":"SSSSSSSSSSSSSSSSSSSSSS"},\
        "input-push-token":1,"alert":{"title":"Oppi","body":"Agents are working."}}}
        """.utf8)
        let aps = try #require(
            (try JSONSerialization.jsonObject(with: start) as? [String: Any])?["aps"] as? [String: Any]
        )
        let contentState = try JSONSerialization.data(withJSONObject: try #require(aps["content-state"]))
        let attributes = try JSONSerialization.data(withJSONObject: try #require(aps["attributes"]))

        #expect(try JSONDecoder().decode(OppiActivityAttributes.ContentState.self, from: contentState)
            == .init(running: 3, needsYou: 1))
        #expect(try JSONDecoder().decode(OppiActivityAttributes.self, from: attributes).slot
            == "SSSSSSSSSSSSSSSSSSSSSS")
        #expect(aps["attributes-type"] as? String == String(describing: OppiActivityAttributes.self))
    }

    @Test func rejectsAContentStateWithoutBothCounts() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(OppiActivityAttributes.ContentState.self, from: Data(#"{"running":1}"#.utf8))
        }
    }
}

@Suite("Live Activity settings")
struct LiveActivitySettingsTests {
    private func defaults() -> UserDefaults {
        let name = "LiveActivitySettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func offByDefaultAndPerServer() {
        let defaults = defaults()
        #expect(!LiveActivitySettings.isEnabled(serverId: "sha256:a", defaults: defaults))
        LiveActivitySettings.setEnabled(true, serverId: "sha256:a", defaults: defaults)
        #expect(LiveActivitySettings.isEnabled(serverId: "sha256:a", defaults: defaults))
        #expect(!LiveActivitySettings.isEnabled(serverId: "sha256:b", defaults: defaults))
    }

    @Test func eachServerKeepsOneRandomSlotInTheRelayFormat() throws {
        let defaults = defaults()
        let a = LiveActivitySettings.slot(serverId: "sha256:a", defaults: defaults)
        let b = LiveActivitySettings.slot(serverId: "sha256:b", defaults: defaults)
        #expect(a.wholeMatch(of: /[A-Za-z0-9_-]{22}/) != nil)
        #expect(a != b)
        #expect(!a.contains("sha256"))
        #expect(LiveActivitySettings.slot(serverId: "sha256:a", defaults: defaults) == a)
        #expect(LiveActivitySettings.serverId(forSlot: b, defaults: defaults) == "sha256:b")

        LiveActivitySettings.setEnabled(true, serverId: "sha256:b", defaults: defaults)
        #expect(LiveActivitySettings.enabledSlots(defaults: defaults) == [b])
    }

    @Test @MainActor func relayGetsTokensOnlyForServersWhoseCardIsOn() {
        let state = LiveActivityRelaySync.state(
            startToken: "5555",
            activityTokens: ["on": "aaaa", "off": "bbbb"],
            enabledSlots: ["on"]
        )
        #expect(state == .init(startToken: "5555", activities: [.init(slot: "on", token: "aaaa")]))
        // No card on anywhere: the relay can start nothing.
        let none = LiveActivityRelaySync.state(startToken: "5555", activityTokens: ["off": "bbbb"], enabledSlots: [])
        #expect(none == .init(startToken: nil, activities: []))
    }

    @Test func relayBodyCarriesANullStartTokenToClearIt() throws {
        let body = try JSONEncoder().encode(PushRelayClient.LiveActivityState(startToken: nil, activities: []))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["startToken"] is NSNull)
        #expect((json["activities"] as? [Any])?.isEmpty == true)
    }
}
