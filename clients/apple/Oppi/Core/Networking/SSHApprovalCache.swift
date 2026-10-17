import Foundation
import LocalAuthentication
import Synchronization

/// Keeps an SSH sign-in approval for a few minutes so a reconnect right after
/// the person approved does not ask for Face ID, Touch ID, or the passcode again.
///
/// What is kept is this app's own approval: the `LAContext` that the person
/// evaluated, for one purpose (the device key, or one saved password). It is
/// not the system's biometric reuse (`touchIDAuthenticationAllowableReuseDuration`),
/// which would let any fresh context skip the prompt after a device unlock.
///
/// An entry ends when any of these happens, and the next sign-in then asks
/// again:
/// - `reuseWindow` passes since the person approved;
/// - App Lock locks or covers Oppi (`invalidateAll`);
/// - a use of the approval fails, or a sign-in fails on credentials;
/// - the experiment is turned off or the host is deleted.
///
/// Cached contexts are `interactionNotAllowed`, so neither NIOSSH's synchronous
/// signer nor a later Keychain read can present UI on the strength of them.
final class SSHApprovalCache: Sendable {
    enum Purpose: Hashable, Sendable {
        case deviceKeySigning
        /// One saved password; each host has its own Keychain account.
        case savedPassword(account: String)
    }

    static let reuseWindow: TimeInterval = 5 * 60
    static let shared = SSHApprovalCache()

    private struct Entry {
        let context: LAContext
        let approvedAt: TimeInterval
        /// Hygiene only: lookups enforce the window on their own.
        let expiry: Task<Void, Never>
    }

    private let entries = Mutex<[Purpose: Entry]>([:])
    private let window: TimeInterval
    private let now: @Sendable () -> TimeInterval

    init(
        window: TimeInterval = SSHApprovalCache.reuseWindow,
        now: @escaping @Sendable () -> TimeInterval = { AppLockClock.monotonicNow() }
    ) {
        self.window = window
        self.now = now
    }

    /// The context approved for `purpose` within the window. A stale entry is
    /// invalidated and dropped here.
    func context(for purpose: Purpose) -> LAContext? {
        let (context, stale) = entries.withLock { entries -> (LAContext?, Entry?) in
            guard let entry = entries[purpose] else { return (nil, nil) }
            let age = now() - entry.approvedAt
            // Monotonic time never goes back within a boot; treat it as expired if it does.
            if age >= 0, age < window { return (entry.context, nil) }
            entries[purpose] = nil
            return (nil, entry)
        }
        if let stale { retire(stale) }
        return context
    }

    func store(_ context: LAContext, for purpose: Purpose) {
        let approvedAt = now()
        let window = window
        let expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(window))
            guard !Task.isCancelled else { return }
            _ = self?.context(for: purpose)
        }
        let replaced = entries.withLock { entries -> Entry? in
            let previous = entries[purpose]
            entries[purpose] = Entry(context: context, approvedAt: approvedAt, expiry: expiry)
            return previous
        }
        if let replaced, replaced.context !== context { retire(replaced) } else { replaced?.expiry.cancel() }
    }

    func invalidate(_ purpose: Purpose) {
        let removed = entries.withLock { $0.removeValue(forKey: purpose) }
        if let removed { retire(removed) }
    }

    func invalidateAll() {
        let removed = entries.withLock { entries -> [Entry] in
            let all = Array(entries.values)
            entries.removeAll()
            return all
        }
        removed.forEach(retire)
    }

    private func retire(_ entry: Entry) {
        entry.expiry.cancel()
        entry.context.invalidate()
    }

    /// Runs `use` with an approved context for `purpose`: the cached one when
    /// the person approved within the window, otherwise a fresh one that
    /// `evaluate` approves (the system prompt) before `use` runs.
    ///
    /// A cached context that fails in `use` is dropped, and the person is asked
    /// once, in this same call. A fresh approval is cached only after `use`
    /// succeeded with it. Any failure leaves nothing cached for `purpose`.
    func approved<Value: Sendable>(
        for purpose: Purpose,
        evaluate: @escaping @Sendable (LAContext) async throws -> Void,
        use: @escaping @Sendable (LAContext) async throws -> Value
    ) async throws -> Value {
        if let cached = context(for: purpose) {
            do {
                return try await use(cached)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                invalidate(purpose)
            }
        }
        try Task.checkCancellation()
        let fresh = LAContext()
        do {
            try await withTaskCancellationHandler {
                try await evaluate(fresh)
            } onCancel: {
                // Dismisses a prompt in flight. A late system success is
                // refused by the check below.
                fresh.invalidate()
            }
            try Task.checkCancellation()
            let value = try await use(fresh)
            try Task.checkCancellation()
            store(fresh, for: purpose)
            return value
        } catch {
            fresh.invalidate()
            invalidate(purpose)
            throw error
        }
    }

    /// Credential failures end an approval. Host trust and network failures
    /// say nothing about it.
    static func isAuthenticationFailure(_ error: any Error) -> Bool {
        if error is SSHKeychainError || error is SSHIdentityKeyStoreError { return true }
        switch error as? SSHConnectionError {
        case .authenticationFailed, .publicKeyNotAllowed, .passwordNotAllowed, .signInTimedOut,
             // Signing without UI that the context no longer allows maps here.
             .keyExchangeFailed:
            return true
        default:
            return false
        }
    }

    /// The system prompt (Face ID, Touch ID, or the passcode). The context is
    /// left without any way to prompt again: whatever uses it later either
    /// signs or reads silently, or fails.
    /// On the simulator there is no hardware presence to evaluate.
    static func evaluateDeviceOwner(
        _ context: LAContext,
        reason: String = "Sign in to your SSH host",
        failure: @Sendable (any Error) -> any Error
    ) async throws {
        context.localizedReason = reason
        context.touchIDAuthenticationAllowableReuseDuration = 0
        #if !targetEnvironment(simulator)
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            throw failure(error)
        }
        #endif
        context.interactionNotAllowed = true
    }
}

// An evaluated context is handed between the approval prompt, the Keychain read,
// and the signer on different threads; LocalAuthentication serializes its use.
extension LAContext: @retroactive @unchecked Sendable {}
