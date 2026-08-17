import Foundation
import LocalAuthentication
import os.log

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Biometric")

/// Biometric authentication gate for sensitive local actions.
///
/// Uses Face ID / Touch ID with device passcode fallback when enabled.
@MainActor
final class BiometricService {
    static let shared = BiometricService()

    /// Whether biometric gating is enabled at all.
    var isEnabled: Bool {
        get { AppPreferences.Biometric.isEnabled }
        set { AppPreferences.Biometric.setEnabled(newValue) }
    }

    // Cached once on init — biometry type doesn't change during app lifetime.
    private let cachedBiometricName: String

    private init() {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            switch context.biometryType {
            case .none: cachedBiometricName = "Biometrics"
            case .faceID: cachedBiometricName = "Face ID"
            case .touchID: cachedBiometricName = "Touch ID"
            case .opticID: cachedBiometricName = "Optic ID"
            @unknown default: cachedBiometricName = "Biometrics"
            }
        } else {
            cachedBiometricName = "Passcode"
        }
    }

    // MARK: - Capability Check

    /// Human-readable name for the biometric type (Face ID, Touch ID, Optic ID).
    /// Cached at init — Secure Enclave query runs once, not per-access.
    var biometricName: String { cachedBiometricName }

    // MARK: - Authentication

    /// Authenticate via Face ID / Touch ID / device passcode when enabled.
    ///
    /// Returns `true` if authentication is disabled or succeeded, `false`
    /// if the user cancelled or biometric failed. Never throws — failures
    /// are logged and returned as `false`.
    ///
    /// Uses `.deviceOwnerAuthentication` (biometric + passcode fallback),
    /// not `.deviceOwnerAuthenticationWithBiometrics` (biometric-only).
    /// This ensures the user can always approve even if Face ID is
    /// temporarily unavailable (wet face, sunglasses, etc.).
    func authenticate(reason: String) async -> Bool {
        guard isEnabled else {
            logger.info("Biometric auth skipped because local setting is disabled")
            return true
        }

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
                logger.warning("Biometric auth succeeded")
            }
            return success
        } catch {
            logger.warning("Biometric auth failed/cancelled: \(error.localizedDescription)")
            return false
        }
    }
}
