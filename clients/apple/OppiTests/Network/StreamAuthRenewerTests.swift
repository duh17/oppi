import Foundation
import Testing
@testable import Oppi

@Suite("StreamAuthRenewer", .serialized)
@MainActor
struct StreamAuthRenewerTests {
    @Test func renewsAMinuteBeforeExpiryThenFromTheServersDeadline() async throws {
        let clock = ManualRenewalClock()
        let tokens = RenewalTokenSource(expiries: ["at_a": clock.now.addingTimeInterval(600)], fresh: ["at_b", "at_c"])
        let socket = RenewalSocketRecorder()
        let renewer = makeRenewer(clock: clock, tokens: tokens)
        renewer.start(token: "at_a", send: socket.send, onRenewed: socket.renewed)

        #expect(await waitForMainActorCondition { clock.sleeps == [540] })
        clock.elapse()
        #expect(await waitForMainActorCondition { socket.sentTokens == ["at_b"] && clock.sleeps.count == 2 })
        #expect(tokens.replaced == ["at_a"])

        renewer.handle(.renewed(expiresAt: clock.now.addingTimeInterval(600)))
        #expect(socket.renewedTokens == ["at_b"])
        #expect(await waitForMainActorCondition { clock.sleeps == [540, StreamAuthRenewer.retryDelay, 540] })

        clock.elapse()
        #expect(await waitForMainActorCondition { socket.sentTokens == ["at_b", "at_c"] })
        #expect(tokens.replaced == ["at_a", "at_b"])
        renewer.stop()
    }

    @Test func refusalRetriesWithATokenNewerThanTheRefusedOne() async throws {
        let clock = ManualRenewalClock()
        let tokens = RenewalTokenSource(expiries: ["at_a": clock.now.addingTimeInterval(600)], fresh: ["at_b", "at_c"])
        let socket = RenewalSocketRecorder()
        let renewer = makeRenewer(clock: clock, tokens: tokens)
        renewer.start(token: "at_a", send: socket.send, onRenewed: socket.renewed)
        #expect(await waitForMainActorCondition { clock.sleeps.count == 1 })
        clock.elapse()
        #expect(await waitForMainActorCondition { socket.sentTokens == ["at_b"] })

        renewer.handle(.refused(reason: "evicted"))
        #expect(await waitForMainActorCondition { clock.sleeps.last == StreamAuthRenewer.retryDelay && clock.sleeps.count == 3 })
        clock.elapse()
        #expect(await waitForMainActorCondition { socket.sentTokens == ["at_b", "at_c"] })
        #expect(tokens.replaced == ["at_a", "at_b"])
        #expect(socket.renewedTokens.isEmpty)
        renewer.stop()
    }

    @Test(arguments: ["past_deadline", "gate_denied", "revoked", "a_reason_this_build_does_not_know"])
    func refusalNoTokenFixesStopsRenewing(reason: String) async throws {
        let clock = ManualRenewalClock()
        let tokens = RenewalTokenSource(expiries: ["at_a": clock.now.addingTimeInterval(600)], fresh: ["at_b"])
        let socket = RenewalSocketRecorder()
        let renewer = makeRenewer(clock: clock, tokens: tokens)
        renewer.start(token: "at_a", send: socket.send, onRenewed: socket.renewed)
        #expect(await waitForMainActorCondition { clock.sleeps.count == 1 })
        clock.elapse()
        #expect(await waitForMainActorCondition { socket.sentTokens == ["at_b"] && clock.sleeps.count == 2 })

        renewer.handle(.refused(reason: reason))
        #expect(await waitForMainActorCondition { !clock.isSleeping })
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(100)) {
            clock.sleeps.count == 2 && !clock.isSleeping
        })
        #expect(socket.sentTokens == ["at_b"])
    }

    @Test func aFailedSendStopsRenewingTheGoneSocket() async throws {
        let clock = ManualRenewalClock()
        let tokens = RenewalTokenSource(expiries: ["at_a": clock.now.addingTimeInterval(600)], fresh: ["at_b", "at_c"])
        let renewer = makeRenewer(clock: clock, tokens: tokens)
        renewer.start(
            token: "at_a",
            send: { _ in throw URLError(.networkConnectionLost) },
            onRenewed: { _ in Issue.record("A failed send renewed") }
        )
        #expect(await waitForMainActorCondition { clock.sleeps.count == 1 })
        clock.elapse()
        #expect(await waitForMainActorCondition { tokens.replaced == ["at_a"] })
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(100)) {
            clock.sleeps.count == 1 && !clock.isSleeping
        })
        #expect(tokens.mints == 1)
    }

    @Test func unansweredRenewalResendsWithoutAnotherMint() async throws {
        let clock = ManualRenewalClock()
        let tokens = RenewalTokenSource(expiries: ["at_a": clock.now.addingTimeInterval(600)], fresh: ["at_b"])
        let socket = RenewalSocketRecorder()
        let renewer = makeRenewer(clock: clock, tokens: tokens)
        renewer.start(token: "at_a", send: socket.send, onRenewed: socket.renewed)
        #expect(await waitForMainActorCondition { clock.sleeps.count == 1 })
        clock.elapse()
        #expect(await waitForMainActorCondition { clock.sleeps.count == 2 })
        clock.elapse()
        #expect(await waitForMainActorCondition { socket.sentTokens == ["at_b", "at_b"] })
        #expect(tokens.mints == 1)

        renewer.handle(.renewed(expiresAt: clock.now.addingTimeInterval(600)))
        #expect(socket.renewedTokens == ["at_b"])
        renewer.stop()
    }

    @Test func unknownExpiryRenewsAtOnceAndStopDropsALateAnswer() async throws {
        let clock = ManualRenewalClock()
        let tokens = RenewalTokenSource(expiries: [:], fresh: ["at_b"])
        let socket = RenewalSocketRecorder()
        let renewer = makeRenewer(clock: clock, tokens: tokens)
        renewer.start(token: "at_a", send: socket.send, onRenewed: socket.renewed)
        #expect(await waitForMainActorCondition { clock.sleeps == [0] })
        clock.elapse()
        #expect(await waitForMainActorCondition { socket.sentTokens == ["at_b"] })

        renewer.stop()
        renewer.handle(.renewed(expiresAt: clock.now.addingTimeInterval(600)))
        #expect(socket.renewedTokens.isEmpty)
    }

    private func makeRenewer(clock: ManualRenewalClock, tokens: RenewalTokenSource) -> StreamAuthRenewer {
        StreamAuthRenewer(
            source: tokens.source,
            streamRole: "test",
            now: { clock.now },
            sleep: clock.sleep
        )
    }
}

/// A clock whose sleeps end only when the test lets them, advancing `now` by the sleep.
@MainActor
final class ManualRenewalClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var sleeps: [TimeInterval] = []
    private var waiter: (id: Int, continuation: CheckedContinuation<Void, Error>)?
    private var nextID = 0

    var isSleeping: Bool { waiter != nil }

    nonisolated var sleep: @Sendable (TimeInterval) async throws -> Void {
        { [self] seconds in try await self.wait(seconds) }
    }

    func elapse() {
        guard let waiter, let seconds = sleeps.last else { return }
        self.waiter = nil
        now = now.addingTimeInterval(seconds)
        waiter.continuation.resume()
    }

    private func wait(_ seconds: TimeInterval) async throws {
        sleeps.append(seconds)
        nextID += 1
        let id = nextID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.install(continuation, id: id)
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    private func install(_ continuation: CheckedContinuation<Void, Error>, id: Int) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        waiter?.continuation.resume(throwing: CancellationError())
        waiter = (id, continuation)
    }

    private func cancel(_ id: Int) {
        guard let waiter, waiter.id == id else { return }
        self.waiter = nil
        waiter.continuation.resume(throwing: CancellationError())
    }
}

/// The device auth session as the renewer sees it: expiries it knows, and the tokens its
/// single-flight refresh hands out, minting only when it still holds the stale token.
final class RenewalTokenSource: @unchecked Sendable {
    private let lock = NSLock()
    private let expiries: [String: Date]
    private var fresh: [String]
    private var current: String?
    private(set) var replaced: [String] = []
    private(set) var mints = 0

    init(expiries: [String: Date], fresh: [String]) {
        self.expiries = expiries
        self.fresh = fresh
    }

    var source: StreamAuthRenewer.Source {
        StreamAuthRenewer.Source(
            expiry: { [self] token in self.expiry(of: token) },
            freshToken: { [self] stale in try self.token(replacing: stale) }
        )
    }

    private func expiry(of token: String) -> Date? {
        lock.withLock { expiries[token] }
    }

    private func token(replacing stale: String) throws -> String {
        try lock.withLock {
            replaced.append(stale)
            if let current, current != stale { return current }
            guard !fresh.isEmpty else { throw URLError(.userAuthenticationRequired) }
            mints += 1
            let minted = fresh.removeFirst()
            current = minted
            return minted
        }
    }
}

@MainActor
final class RenewalSocketRecorder {
    private(set) var sentTokens: [String] = []
    private(set) var renewedTokens: [String] = []

    var send: (String) async throws -> Void {
        { [weak self] text in self?.record(text) }
    }

    var renewed: (String) -> Void {
        { [weak self] token in self?.renewedTokens.append(token) }
    }

    private func record(_ text: String) {
        guard let frame = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String],
              frame["type"] == "auth_renew",
              let token = frame["token"] else {
            Issue.record("Unexpected renewal frame \(text)")
            return
        }
        sentTokens.append(token)
    }
}
