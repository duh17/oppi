import Testing
@testable import Oppi

@Suite("StreamSubscriptionRegistry")
@MainActor
struct StreamSubscriptionRegistryTests {
    @Test func tracksDesiredAndAckedSubscription() {
        let registry = StreamSubscriptionRegistry()

        registry.setDesired(.full, for: "s1")
        registry.markSubscribeSent(sessionId: "s1", requestId: "r1", level: .full)
        registry.markSubscribeAck(sessionId: "s1", requestId: "r1")

        #expect(registry.desiredLevel(for: "s1") == .full)
        #expect(registry.ackState(for: "s1") == .acked(generation: 1, level: .full))
        #expect(registry.routeLevel(for: "s1") == .full)
    }

    @Test func staleAckCannotOverwriteNewerDesiredLevel() {
        let registry = StreamSubscriptionRegistry()

        registry.setDesired(.notifications, for: "s1")
        registry.markSubscribeSent(sessionId: "s1", requestId: "old", level: .notifications)
        registry.setDesired(.full, for: "s1")
        registry.markSubscribeAck(sessionId: "s1", requestId: "old")

        #expect(registry.desiredLevel(for: "s1") == .full)
        #expect(registry.ackState(for: "s1") == .idle)
        #expect(registry.routeLevel(for: "s1") == .full)
    }

    @Test func unsubscribeGenerationCannotClearNewerSubscribeIntent() {
        let registry = StreamSubscriptionRegistry()

        registry.setDesired(.notifications, for: "s1")
        let oldGeneration = registry.generation(for: "s1")
        registry.setDesired(.full, for: "s1")

        registry.markUnsubscribeSent(sessionId: "s1", generation: oldGeneration)

        #expect(registry.desiredLevel(for: "s1") == .full)
    }

    @Test func levelQueriesSeparateDesiredAckedAndInFlight() {
        let registry = StreamSubscriptionRegistry()

        registry.setDesired(.notifications, for: "desired")
        registry.setDesired(.notifications, for: "acked")
        registry.markSubscribeSent(sessionId: "acked", requestId: "r-acked", level: .notifications)
        registry.markSubscribeAck(sessionId: "acked", requestId: "r-acked")
        registry.setDesired(.notifications, for: "pending")
        registry.markSubscribeSent(sessionId: "pending", requestId: "r-pending", level: .notifications)
        registry.setDesired(.full, for: "full")
        registry.markSubscribeSent(sessionId: "full", requestId: "r-full", level: .full)
        registry.markSubscribeAck(sessionId: "full", requestId: "r-full")

        #expect(registry.sessionIds(desired: .notifications) == ["desired", "acked", "pending"])
        #expect(registry.sessionIds(acked: .notifications) == ["acked"])
        #expect(registry.sessionIds(inFlight: .notifications) == ["pending"])
        #expect(registry.sessionIds(desired: .full) == ["full"])
        #expect(registry.sessionIds(acked: .notifications).contains("full") == false)
        #expect(registry.sessionIds(acked: .full) == ["full"])
    }

    @Test func changingDesiredLevelClearsStaleAck() {
        let registry = StreamSubscriptionRegistry()

        registry.setDesired(.notifications, for: "s1")
        registry.markSubscribeSent(sessionId: "s1", requestId: "r1", level: .notifications)
        registry.markSubscribeAck(sessionId: "s1", requestId: "r1")

        registry.setDesired(.full, for: "s1")

        #expect(registry.desiredLevel(for: "s1") == .full)
        #expect(registry.ackState(for: "s1") == .idle)
        #expect(registry.sessionIds(acked: .notifications).contains("s1") == false)
        #expect(registry.routeLevel(for: "s1") == .full)
    }

    @Test func notificationIntentCannotDowngradeFullDesiredLevel() {
        let registry = StreamSubscriptionRegistry()

        registry.setDesired(.full, for: "s1")
        registry.markSubscribeSent(sessionId: "s1", requestId: "full", level: .full)
        registry.markSubscribeAck(sessionId: "s1", requestId: "full")

        registry.setDesired(.notifications, for: "s1")

        #expect(registry.desiredLevel(for: "s1") == .full)
        #expect(registry.ackState(for: "s1") == .acked(generation: 1, level: .full))
        #expect(registry.sessionIds(desired: .notifications).contains("s1") == false)
        #expect(registry.sessionIds(acked: .full) == ["s1"])
    }

    @Test func matchingUnsubscribeClearsDesiredAndAck() {
        let registry = StreamSubscriptionRegistry()

        registry.setDesired(.notifications, for: "s1")
        let generation = registry.generation(for: "s1")
        registry.markSubscribeSent(sessionId: "s1", requestId: "r1", level: .notifications)
        registry.markSubscribeAck(sessionId: "s1", requestId: "r1")

        registry.markUnsubscribeSent(sessionId: "s1", generation: generation)

        #expect(registry.desiredLevel(for: "s1") == .none)
        #expect(registry.ackState(for: "s1") == .idle)
        #expect(registry.routeLevel(for: "s1") == nil)
    }
}
