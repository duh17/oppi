import Foundation
import LocalAuthentication
import os.log

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Biometric")

/// Biometric authentication gate for permission approvals.
///
/// Uses Face ID / Touch ID to confirm "Allow" on all permissions when enabled.
/// Falls back to device passcode if biometrics are unavailable.
///
/// Usage flow:
/// 1. Agent requests permission (e.g., `sudo apt install`)
/// 2. User taps "Allow"
/// 3. If enabled: Face ID prompt → success: allow sent → failure: blocked
/// 4. If disabled: allow sent immediately (no biometric)
@MainActor
final class BiometricService {
    static let shared = BiometricService()

    /// Whether biometric gating is enabled at all.
    /// When disabled, all permissions approve with a simple tap.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    private static let enabledKey = "\(AppIdentifiers.subsystem).biometric.enabled"

    private init() {}

    // MARK: - Capability Check

    /// Whether the device supports any form of biometric auth.
    var isBiometricAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// Human-readable name for the biometric type (Face ID, Touch ID, Optic ID).
    var biometricName: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return "Passcode"
        }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        @unknown default: return "Biometrics"
        }
    }

    // MARK: - Authentication

    /// Check if a permission approval requires biometric confirmation.
    var requiresBiometric: Bool { isEnabled }

    /// Authenticate via Face ID / Touch ID / device passcode.
    ///
    /// Returns `true` if authentication succeeded, `false` if the user
    /// cancelled or biometric failed. Never throws — failures are
    /// logged and returned as `false`.
    ///
    /// Uses `.deviceOwnerAuthentication` (biometric + passcode fallback),
    /// not `.deviceOwnerAuthenticationWithBiometrics` (biometric-only).
    /// This ensures the user can always approve even if Face ID is
    /// temporarily unavailable (wet face, sunglasses, etc.).
    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            logger.warning("Biometric unavailable: \(error?.localizedDescription ?? "unknown")")
            return false
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            if success {
                logger.info("Biometric auth succeeded")
            }
            return success
        } catch {
            logger.info("Biometric auth failed/cancelled: \(error.localizedDescription)")
            return false
        }
    }
}
