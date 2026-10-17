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

    @Test func countsEachThreadOnce() {
        let counts = LiveActivityManager.counts(for: [
            session("a", .working),
            session("b", .working),
            session("c", .blocked, kind: .permission),
            session("d", .blocked, kind: .auth),
            session("e", .done, status: .ready),
            session("f", .idle, status: .ready),
            session("g", .working, status: .stopped),
            // A lead idling while its subagents work runs, once.
            session("lead", .idle, status: .ready),
            session("lead-child-1", .working, parent: "lead"),
            session("lead-child-2", .working, parent: "lead"),
            session("lead-grandchild", .working, parent: "lead-child-1"),
            // A blocked subagent makes its working lead's thread need you.
            session("child-1", .working, parent: "a"),
            session("child-2", .blocked, kind: .question, parent: "b"),
            // Finished subagents add nothing.
            session("child-3", .done, status: .ready, parent: "f"),
        ])
        #expect(counts == .init(running: 2, needsYou: 3))
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
        #expect(LiveActivitySettings.enabledServers(defaults: defaults) == ["sha256:b": b])
        // Turning a card on gives its server a slot the relay can list.
        LiveActivitySettings.setEnabled(true, serverId: "sha256:c", defaults: defaults)
        #expect(LiveActivitySettings.enabledServers(defaults: defaults)["sha256:c"] != nil)
    }

    @Test @MainActor func eachRegistrationListsOnlyItsOwnServersCardsWithTheirPermissions() {
        let cards = [
            LiveActivityRelaySync.Card(slot: "on", registrationId: "r_A", permissionId: "p_on"),
            LiveActivityRelaySync.Card(slot: "gone", registrationId: "r_A", permissionId: "p_gone"),
            LiveActivityRelaySync.Card(slot: "other", registrationId: "r_B", permissionId: "p_other"),
        ]
        let state = LiveActivityRelaySync.state(
            startToken: "5555",
            activityTokens: ["on": "aaaa", "gone": "bbbb", "off": "cccc"],
            dismissedSlots: ["gone", "off"],
            cards: cards,
            registrationId: "r_A"
        )
        #expect(state == .init(startToken: "5555", activities: [
            // A dismissed card has no token.
            .init(permissionId: "p_gone", slot: "gone", token: nil, dismissed: true),
            .init(permissionId: "p_on", slot: "on", token: "aaaa", dismissed: false),
        ]))
        // A registration that lists no card gets no start token, so it can start nothing.
        let none = LiveActivityRelaySync.state(
            startToken: "5555",
            activityTokens: ["off": "cccc"],
            dismissedSlots: [],
            cards: cards,
            registrationId: "r_C"
        )
        #expect(none == .init(startToken: nil, activities: []))
    }

    @Test func relayBodyCarriesNullsForNoStartTokenAndNoCard() throws {
        let body = try JSONEncoder().encode(PushRelayClient.LiveActivityState(
            startToken: nil,
            activities: [.init(permissionId: "p_a", slot: "s", token: nil, dismissed: false)]
        ))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(json.keys) == ["startToken", "activities"])
        #expect(json["startToken"] is NSNull)
        let activity = try #require((json["activities"] as? [[String: Any]])?.first)
        #expect(Set(activity.keys) == ["permissionId", "slot", "token", "dismissed"])
        #expect(activity["token"] is NSNull)
    }

    @Test func sendTokenNamesItsRegistrationAndPermission() {
        let parsed = PushRelayClient.permission(ofSendToken: "osp1.r_AAA.p_BBB.secret")
        #expect(parsed?.registrationId == "r_AAA")
        #expect(parsed?.permissionId == "p_BBB")
        #expect(PushRelayClient.permission(ofSendToken: "osp1.r_AAA.p_BBB") == nil)
        #expect(PushRelayClient.permission(ofSendToken: "osp2.r_AAA.p_BBB.secret") == nil)
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

    private static func defaults() -> UserDefaults {
        let name = "LiveActivityRelayUploadTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// What the fake relay saw.
    @MainActor private final class Relay {
        var answers: [Error?]
        var sent: [PushRelayClient.LiveActivityState] = []
        var pauses: [Duration] = []
        let defaults: UserDefaults

        init(answers: [Error?], defaults: UserDefaults = LiveActivityRelayUploadTests.defaults()) {
            self.answers = answers
            self.defaults = defaults
        }

        /// A sync as the app builds it at launch; a second call is the app after a relaunch.
        func sync() -> LiveActivityRelaySync {
            LiveActivityRelaySync(
                registrations: { [LiveActivityRelayUploadTests.registration] },
                cards: {
                    [.init(slot: "slot", registrationId: LiveActivityRelayUploadTests.registration.registrationId, permissionId: "p_A")]
                },
                put: { [self] state, _ in
                    sent.append(state)
                    let answer: Error? = answers.isEmpty ? URLError(.cannotConnectToHost) : answers.removeFirst()
                    if let answer { throw answer }
                },
                // Like Task.sleep, a cancelled wait throws.
                sleep: { [self] in
                    try Task.checkCancellation()
                    pauses.append($0)
                },
                defaults: defaults
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
        #expect(relay.pauses == [Duration.seconds(1)] + LiveActivityRelaySync.retryDelays.prefix(2))
        #expect(relay.sent.allSatisfy { $0.dismissedSlots == ["slot"] && $0.activities.map(\.permissionId) == ["p_A"] })
        #expect(sync.relayHoldsDismissal("slot"))
    }

    @Test func aFreshDismissalIsNotHeldUntilTheRelayAcceptsIt() async {
        let relay = Relay(answers: [nil])
        let sync = relay.sync()
        sync.setDismissed(["slot"])
        await sync.publish().value
        #expect(sync.relayHoldsDismissal("slot"))

        // The counts reached zero; the relay never accepts that state.
        sync.setDismissed([])
        await sync.publish().value
        #expect(!sync.relayHoldsDismissal("slot"))
        // The person dismissed the next card: what the relay accepted last is not this.
        sync.setDismissed(["slot"])
        #expect(!sync.relayHoldsDismissal("slot"), "an upload is in flight")
    }

    @Test func aStateTheRelayNeverAcceptedIsSentAgainAfterARelaunch() async {
        let relay = Relay(answers: [])
        let first = relay.sync()
        first.setDismissed(["slot"])
        await first.publish().value
        #expect(relay.sent.count == LiveActivityRelaySync.retryDelays.count + 1)
        #expect(!first.relayHoldsDismissal("slot"))

        // The app was killed. At launch the same state goes out again, until accepted.
        relay.sent = []
        relay.answers = [nil]
        let relaunched = relay.sync()
        relaunched.setDismissed(["slot"])
        await relaunched.publish().value
        #expect(relay.sent.map(\.dismissedSlots) == [["slot"]])
        #expect(relaunched.relayHoldsDismissal("slot"))

        // Accepted state survives a relaunch too: nothing to send, and the dismissal is held.
        relay.sent = []
        let again = relay.sync()
        again.setDismissed(["slot"])
        await again.publish().value
        #expect(relay.sent.isEmpty)
        #expect(again.relayHoldsDismissal("slot"))
    }

    @Test func stopsRetryingWhenTheRelayForgotTheRegistration() async {
        let relay = Relay(answers: [PushRelayClient.RelayError.gone])
        let sync = relay.sync()
        await sync.publish().value
        #expect(relay.sent.count == 1)
    }
}

@Suite("Live Activity dismissals", .serialized)
@MainActor
struct LiveActivityDismissalTests {
    private typealias Card = LiveActivityManager.ListedCard

    private func defaults() -> UserDefaults {
        let name = "LiveActivityDismissalTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aListedCardDismissedWhileItShowedWorkIsADismissal() {
        let working = LiveActivityManager.Counts(running: 1, needsYou: 0)
        let listed = [
            Card(id: "dismissed", slot: "a", state: .dismissed, counts: working),
            // Ended at zero by the app or a server, then removed: not the person's doing.
            Card(id: "ended-at-zero", slot: "b", state: .dismissed, counts: LiveActivityManager.noCounts),
            // Counted already, before the app was killed.
            Card(id: "counted", slot: "c", state: .dismissed, counts: working),
            // A live card for the slot came after the dismissed one.
            Card(id: "old", slot: "d", state: .dismissed, counts: working),
            Card(id: "new", slot: "d", state: .active, counts: working),
            Card(id: "ended", slot: "e", state: .ended, counts: working),
        ]
        #expect(LiveActivityManager.uncountedDismissals(in: listed, counted: ["counted"]).map(\.id) == ["dismissed"])
    }

    @Test func aDismissalSurvivesTheAppBeingKilledUntilTheCountsReachZero() async {
        let defaults = defaults()
        LiveActivitySettings.setEnabled(true, serverId: "sha256:srv", defaults: defaults)
        let slot = LiveActivitySettings.slot(serverId: "sha256:srv", defaults: defaults)
        var sent: [PushRelayClient.LiveActivityState] = []
        func launch() -> (LiveActivityManager, LiveActivityRelaySync) {
            let sync = LiveActivityRelaySync(
                registrations: {
                    [PushRelayClient.Registration(
                        relay: "https://relay.example", environment: "sandbox",
                        apnsToken: String(repeating: "a", count: 64), registrationId: "r_A",
                        registrationSecret: "secret", appAttestKeyId: nil
                    )]
                },
                cards: { [.init(slot: slot, registrationId: "r_A", permissionId: "p_A")] },
                put: { state, _ in sent.append(state) },
                sleep: { _ in try Task.checkCancellation() },
                defaults: defaults
            )
            let manager = LiveActivityManager(
                isEnabled: { $0 == "sha256:srv" },
                serverDrivesCard: { _ in true },
                relaySync: sync,
                defaults: defaults
            )
            return (manager, sync)
        }

        let (first, _) = launch()
        first.recordDismissal(slot: slot, activityId: "card-1")

        // Relaunched: the dismissal holds before any card is requested, and the relay hears it.
        let (second, sync) = launch()
        #expect(second.dismissedSlots == [slot])
        await sync.publish().value
        #expect(sent.last?.dismissedSlots == [slot])

        // The counts reached zero: the dismissal is over, and stays over after a relaunch.
        second.sync(connectionId: "sha256:srv", sessions: [])
        let (third, _) = launch()
        #expect(third.dismissedSlots.isEmpty)
    }
}
