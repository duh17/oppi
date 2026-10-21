import Foundation
import LocalAuthentication

/// Types a saved password at a terminal password prompt (`sudo`, `su`).
///
/// The key is offered only while the terminal is at a prompt that
/// `SSHTerminalPasswordPrompt` recognized (secure entry), on the live screen, and
/// only for a host that has a password to fill. Every tap asks the person with
/// Face ID, Touch ID, or the passcode, naming the host: the password goes to
/// whatever program on this terminal shows the prompt, which is not always the
/// host's own `sudo` (a Herdr pane that ran `ssh` to another machine, for one).
/// The approval is never reused, so `SSHApprovalCache` stays out of this path.
///
/// The bytes are typed as the keyboard would type them: no bracketed paste, and
/// no Return, so the person still decides when the prompt gets its answer.
enum SSHTerminalPasswordFill {
    enum Outcome: Equatable {
        case filled
        /// The person dismissed the prompt. Nothing was sent, and nothing needs saying.
        case cancelled
        /// Nothing was sent. The text says why.
        case failed(String)
    }

    static func isOffered(
        profile: SSHTerminalProfile?,
        secureEntry: Bool,
        inHistory: Bool,
        connected: Bool
    ) -> Bool {
        secureEntry && !inHistory && connected && profile?.hasPasswordToFill == true
    }

    /// The system prompt's reason: `Fill the password for duh@mac-studio`.
    static func reason(for profile: SSHTerminalProfile) -> String {
        "Fill the password for \(profile.endpointLabel)"
    }

    static func accessibilityLabel(for profile: SSHTerminalProfile) -> String {
        "Fill password for \(profile.endpointLabel)"
    }

    /// Asks, reads the password, and sends it with `send` (true when the
    /// terminal accepted the bytes). `stillOffered` runs after the approval and
    /// before the send: a prompt can end while the person is on Face ID, and a
    /// password typed at a shell prompt would show on screen.
    @MainActor
    static func fill(
        profile: SSHTerminalProfile,
        store: SSHTerminalProfileStore = SSHTerminalProfileStore(),
        evaluate: @escaping @Sendable (LAContext, String) async throws -> Void = SSHTerminalProfileStore.askDeviceOwner,
        stillOffered: () -> Bool,
        send: (Data) -> Bool
    ) async -> Outcome {
        var password: Data
        do {
            password = try await store.passwordToFill(for: profile, reason: reason(for: profile), evaluate: evaluate)
        } catch {
            return outcome(for: error)
        }
        // Best effort: the channel's queue keeps its own copy until the pump
        // writes it, and the JSON the Keychain returned cannot be wiped.
        defer { password.resetBytes(in: 0..<password.count) }
        guard !Task.isCancelled, stillOffered() else { return .cancelled }
        return send(password) ? .filled : .failed("The terminal did not accept the input.")
    }

    static func outcome(for error: any Error) -> Outcome {
        if error is CancellationError { return .cancelled }
        switch error as? SSHKeychainError {
        case .status(errSecUserCanceled): return .cancelled
        case .passwordRequired:
            return .failed("The saved password is missing or belongs to a different host. Edit the host to save it again.")
        default:
            return .failed(error.localizedDescription)
        }
    }
}
