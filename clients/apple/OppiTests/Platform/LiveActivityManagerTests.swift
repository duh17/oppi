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

    @Test @MainActor func relayGetsTokensAndDismissalsOnlyForServersWhoseCardIsOn() {
        let state = LiveActivityRelaySync.state(
            startToken: "5555",
            activityTokens: ["on": "aaaa", "off": "bbbb"],
            dismissedSlots: ["gone", "off"],
            enabledSlots: ["on", "gone"]
        )
        #expect(state == .init(
            startToken: "5555",
            activities: [.init(slot: "on", token: "aaaa")],
            dismissed: ["gone"]
        ))
        // No card on anywhere: the relay can start nothing.
        let none = LiveActivityRelaySync.state(startToken: "5555", activityTokens: ["off": "bbbb"], enabledSlots: [])
        #expect(none == .init(startToken: nil, activities: [], dismissed: []))
    }

    @Test func relayBodyCarriesANullStartTokenToClearIt() throws {
        let body = try JSONEncoder().encode(PushRelayClient.LiveActivityState(startToken: nil, activities: [], dismissed: []))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["startToken"] is NSNull)
        #expect((json["activities"] as? [Any])?.isEmpty == true)
        #expect((json["dismissed"] as? [Any])?.isEmpty == true)
    }
}

@Suite("Live Activity relay upload")
@MainActor
struct LiveActivityRelayUploadTests {
    private static let registration = PushRelayClient.Registration(
        relay: "https://relay.example",
        environment: "sandbox",
        apnsToken: String(repeating: "a", count: 64),
        registrationId: "r_AAAAAAAAAAAAAAAAAAAAAA",
        registrationSecret: "secret",
        appAttestKeyId: nil
    )

    /// What the fake relay saw.
    @MainActor private final class Relay {
        var answers: [Error?]
        var sent: [PushRelayClient.LiveActivityState] = []
        var pauses: [Duration] = []

        init(answers: [Error?]) { self.answers = answers }

        func sync() -> LiveActivityRelaySync {
            LiveActivityRelaySync(
                registrations: { [LiveActivityRelayUploadTests.registration] },
                enabledSlots: { ["slot"] },
                put: { [self] state, _ in
                    sent.append(state)
                    let answer: Error? = answers.isEmpty ? URLError(.cannotConnectToHost) : answers.removeFirst()
                    if let answer { throw answer }
                },
                // Like Task.sleep, a cancelled wait throws.
                sleep: { [self] in
                    try Task.checkCancellation()
                    pauses.append($0)
                }
            )
        }
    }

    @Test func retriesAFailedUploadUntilTheRelayAcceptsIt() async {
        let relay = Relay(answers: [URLError(.notConnectedToInternet), URLError(.timedOut), nil])
        let sync = relay.sync()
        sync.setDismissed(["slot"])
        #expect(!sync.relayHoldsDismissal("slot"))
        await sync.publish().value

        #expect(relay.sent.count == 3)
        #expect(relay.sent.allSatisfy { $0.dismissed == ["slot"] })
        #expect(relay.pauses == [Duration.seconds(1)] + LiveActivityRelaySync.retryDelays.prefix(2))
        #expect(sync.relayHoldsDismissal("slot"))
    }

    @Test func stopsRetryingWhenTheRelayForgotTheRegistration() async {
        let relay = Relay(answers: [PushRelayClient.RelayError.gone])
        let sync = relay.sync()
        await sync.publish().value
        #expect(relay.sent.count == 1)
    }

    @Test func givesUpAfterTheLastRetry() async {
        let relay = Relay(answers: [])
        let sync = relay.sync()
        sync.setDismissed(["slot"])
        await sync.publish().value
        #expect(relay.sent.count == LiveActivityRelaySync.retryDelays.count + 1)
        #expect(!sync.relayHoldsDismissal("slot"))
    }
}
