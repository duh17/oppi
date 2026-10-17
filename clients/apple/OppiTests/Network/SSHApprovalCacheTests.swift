import Foundation
import LocalAuthentication
import Synchronization
import Testing
@testable import Oppi

@Suite("SSH approval reuse", .serialized)
struct SSHApprovalCacheTests {
    private final class Clock: Sendable {
        private let value = Mutex<TimeInterval>(1000)
        var now: TimeInterval { value.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
    }

    /// Counts the prompts and the contexts `use` saw.
    private final class Probe: Sendable {
        let prompts = Mutex(0)
        // Held, not compared by address: a released context's address can be reused.
        let used = Mutex<[LAContext]>([])
        func evaluate(_ context: LAContext) async throws { prompts.withLock { $0 += 1 } }
        func use(_ context: LAContext) async throws -> Int {
            used.withLock { $0.append(context) }
            return 1
        }
    }

    private func distinctCount(_ contexts: [LAContext]) -> Int {
        contexts.reduce(into: [LAContext]()) { unique, context in
            if !unique.contains(where: { $0 === context }) { unique.append(context) }
        }.count
    }

    private func makeCache(_ clock: Clock) -> SSHApprovalCache {
        SSHApprovalCache(now: { clock.now })
    }

    private func approve(_ cache: SSHApprovalCache, _ purpose: SSHApprovalCache.Purpose, _ probe: Probe) async throws {
        _ = try await cache.approved(for: purpose, evaluate: { try await probe.evaluate($0) }, use: { try await probe.use($0) })
    }

    @Test func approvalIsReusedWithinFiveMinutesAndAskedAgainAfter() async throws {
        let clock = Clock()
        let cache = makeCache(clock)
        let probe = Probe()
        try await approve(cache, .deviceKeySigning, probe)
        clock.advance(SSHApprovalCache.reuseWindow - 1)
        try await approve(cache, .deviceKeySigning, probe)
        #expect(probe.prompts.withLock { $0 } == 1)
        // The reused context is the one that was approved.
        #expect(distinctCount(probe.used.withLock { $0 }) == 1)
        clock.advance(1)
        try await approve(cache, .deviceKeySigning, probe)
        #expect(probe.prompts.withLock { $0 } == 2)
        #expect(distinctCount(probe.used.withLock { $0 }) == 2)
    }

    @Test func approvalsAreKeptPerPurpose() async throws {
        let cache = makeCache(Clock())
        let probe = Probe()
        try await approve(cache, .deviceKeySigning, probe)
        try await approve(cache, .savedPassword(account: "a"), probe)
        try await approve(cache, .savedPassword(account: "b"), probe)
        #expect(probe.prompts.withLock { $0 } == 3)
        try await approve(cache, .savedPassword(account: "a"), probe)
        #expect(probe.prompts.withLock { $0 } == 3)
    }

    @Test func invalidatingEverythingMakesTheNextSignInAsk() async throws {
        let cache = makeCache(Clock())
        let probe = Probe()
        try await approve(cache, .deviceKeySigning, probe)
        try await approve(cache, .savedPassword(account: "a"), probe)
        cache.invalidateAll()
        #expect(cache.context(for: .deviceKeySigning) == nil)
        #expect(cache.context(for: .savedPassword(account: "a")) == nil)
        try await approve(cache, .deviceKeySigning, probe)
        #expect(probe.prompts.withLock { $0 } == 3)
    }

    @Test func aFailedUseOfTheKeptApprovalDropsItAndAsksOnceInTheSameCall() async throws {
        let cache = makeCache(Clock())
        let probe = Probe()
        try await approve(cache, .deviceKeySigning, probe)
        struct Expired: Error {}
        let calls = Mutex(0)
        let value: Int = try await cache.approved(
            for: .deviceKeySigning,
            evaluate: { try await probe.evaluate($0) },
            use: { _ in
                // The first use is the kept context, which no longer signs.
                if calls.withLock({ defer { $0 += 1 }; return $0 }) == 0 { throw Expired() }
                return 7
            }
        )
        #expect(value == 7)
        #expect(probe.prompts.withLock { $0 } == 2)
    }

    @Test func failureWithAFreshApprovalRethrowsAndLeavesNothingKept() async throws {
        let cache = makeCache(Clock())
        let probe = Probe()
        struct Refused: Error {}
        await #expect(throws: Refused.self) {
            _ = try await cache.approved(for: .deviceKeySigning, evaluate: { try await probe.evaluate($0) }, use: { _ in throw Refused() })
        }
        #expect(cache.context(for: .deviceKeySigning) == nil)
        struct Cancelled: Error {}
        await #expect(throws: Cancelled.self) {
            _ = try await cache.approved(for: .deviceKeySigning, evaluate: { _ in throw Cancelled() }, use: { try await probe.use($0) })
        }
        #expect(cache.context(for: .deviceKeySigning) == nil)
        try await approve(cache, .deviceKeySigning, probe)
        #expect(probe.prompts.withLock { $0 } == 2)
    }

    @Test func approvalThatArrivesAfterCancellationIsNeverKept() async throws {
        let cache = makeCache(Clock())
        let (started, startedSink) = AsyncStream<Void>.makeStream()
        let (release, releaseSink) = AsyncStream<Void>.makeStream()
        let attempt = Task {
            try await cache.approved(
                for: .deviceKeySigning,
                evaluate: { _ in
                    startedSink.yield(())
                    // A late system success that ignores cancellation.
                    for await _ in release { break }
                },
                use: { _ in 1 }
            )
        }
        await started.first { _ in true }
        attempt.cancel()
        releaseSink.yield(())
        await #expect(throws: CancellationError.self) { _ = try await attempt.value }
        #expect(cache.context(for: .deviceKeySigning) == nil)
    }

    @Test func onlyCredentialFailuresEndAnApproval() {
        let host = SSHHostKey(openSSH: "ssh-ed25519 AAAA")
        let credential: [any Error] = [
            SSHKeychainError.status(-25293), SSHKeychainError.passwordRequired,
            SSHIdentityKeyStoreError.authenticationExpired,
            SSHConnectionError.authenticationFailed, SSHConnectionError.publicKeyNotAllowed,
            SSHConnectionError.keyExchangeFailed("signing needs interaction"),
        ]
        let unrelated: [any Error] = [
            SSHConnectionError.unknownHostKey(host), SSHConnectionError.connectionClosed,
            SSHConnectionError.requestTimedOut, SSHPreflightFailure.dialTimedOut,
        ]
        for error in credential { #expect(SSHApprovalCache.isAuthenticationFailure(error)) }
        for error in unrelated { #expect(!SSHApprovalCache.isAuthenticationFailure(error)) }
    }

    @Test func savedPasswordReadsReuseTheKeptApprovalForTheSameHostOnly() async throws {
        let name = "SSHApprovalCacheTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = ContextRecordingKeychain()
        let store = SSHTerminalProfileStore(defaults: defaults, keychain: keychain)
        let first = SSHTerminalProfile(host: "one.ts.net", username: "alice", savesPassword: true)
        let second = SSHTerminalProfile(host: "two.ts.net", username: "alice", savesPassword: true)
        try store.save(first, password: "one-secret")
        try store.save(second, password: "two-secret")
        let clock = Clock()
        let cache = makeCache(clock)

        #expect(try await store.approvedPassword(for: first, approvals: cache) == "one-secret")
        #expect(try await store.approvedPassword(for: first, approvals: cache) == "one-secret")
        #expect(try await store.approvedPassword(for: second, approvals: cache) == "two-secret")
        let loads = keychain.loads.withLock { $0 }
        #expect(loads.count == 3)
        // Every read carries an approved context; the same host reuses it, another host does not.
        #expect(loads.allSatisfy { $0.context != nil })
        #expect(loads[0].context === loads[1].context)
        #expect(loads[0].context !== loads[2].context)

        clock.advance(SSHApprovalCache.reuseWindow)
        #expect(try await store.approvedPassword(for: first, approvals: cache) == "one-secret")
        #expect(keychain.loads.withLock { $0 }[3].context !== loads[0].context)
    }
}

private final class ContextRecordingKeychain: SSHCredentialStoring, Sendable {
    struct Load: Sendable { var context: LAContext? }
    let items = Mutex<[String: Data]>([:])
    let loads = Mutex<[Load]>([])

    func load(account: String, requirePresence: Bool, authenticationContext: LAContext?) throws -> Data? {
        loads.withLock { $0.append(Load(context: authenticationContext)) }
        return items.withLock { $0[account] }
    }
    func save(_ data: Data, account: String, requirePresence: Bool) throws { items.withLock { $0[account] = data } }
    func delete(account: String) throws { _ = items.withLock { $0.removeValue(forKey: account) } }
}
