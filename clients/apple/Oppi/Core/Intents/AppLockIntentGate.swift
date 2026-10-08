import UIKit

/// App Lock gate for Siri and Shortcuts intents that start agent work.
///
/// Intents run in the app process but never show the lock cover by
/// themselves. Inside the App Lock timeout they behave as opening Oppi would:
/// no prompt. Once a lock is due they bring Oppi forward and unlock through
/// the cover before any server request.
@MainActor
enum AppLockIntentGate {
    /// Returns true when the intent may contact the server.
    static func unlockIfNeeded(
        service: AppLockService = .shared,
        continueInForeground: () async throws -> Void,
        waitUntilActive: () async -> Void = waitUntilAppIsActive
    ) async -> Bool {
        guard service.requiresUnlock() else { return true }
        do {
            try await continueInForeground()
        } catch {
            return false
        }
        await waitUntilActive()
        return await service.unlock()
    }

    /// Server, workspace, and session locks for an intent that creates or
    /// sends. A locked target needs Oppi forward to show the device-auth
    /// prompt; when that cannot happen, or the prompt is cancelled, the intent
    /// must send nothing. Returns true when the intent may proceed.
    static func authorizeScope(
        _ target: ScopedLockTarget,
        locks: ScopedLockService = .shared,
        isActive: () -> Bool = { UIApplication.shared.applicationState == .active },
        continueInForeground: () async throws -> Void,
        waitUntilActive: () async -> Void = waitUntilAppIsActive
    ) async -> Bool {
        guard locks.isLocked(target) else { return true }
        if !isActive() {
            do {
                try await continueInForeground()
            } catch {
                return false
            }
            await waitUntilActive()
        }
        return await locks.authorize(target)
    }

    static let scopeLockedDialog = "That workspace is locked in Oppi. Open Oppi and unlock it, then try again. Nothing was sent."

    /// Face ID can only be shown once the scene is active.
    static func waitUntilAppIsActive() async {
        for _ in 0..<30 where UIApplication.shared.applicationState != .active {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    static let lockedDialog = "Oppi is still locked. Unlock Oppi, then try again. Nothing was sent."
}
