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

    /// Face ID can only be shown once the scene is active.
    static func waitUntilAppIsActive() async {
        for _ in 0..<30 where UIApplication.shared.applicationState != .active {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    static let lockedDialog = "Oppi is still locked. Unlock Oppi, then try again. Nothing was sent."
}
