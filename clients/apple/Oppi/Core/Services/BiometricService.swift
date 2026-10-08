import Foundation
import os.log

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Biometric")

/// "Confirm New Servers": device authentication before trusting a new server
/// fingerprint or a changed server identity. Separate from App Lock.
@MainActor
final class BiometricService {
    static let shared = BiometricService()

    /// Whether Confirm New Servers is on.
    var isEnabled: Bool {
        get { AppPreferences.Biometric.isEnabled }
        set { AppPreferences.Biometric.setEnabled(newValue) }
    }

    private init() {}

    /// Authenticate via Face ID / Touch ID / device passcode when enabled.
    ///
    /// Returns `true` if Confirm New Servers is off or authentication
    /// succeeded, `false` if the user cancelled or it failed.
    func authenticate(reason: String) async -> Bool {
        guard isEnabled else {
            logger.info("Server trust confirmation skipped because local setting is disabled")
            return true
        }
        let outcome = await DeviceOwnerAuthentication.authenticate(reason: reason)
        logger.info("Server trust confirmation outcome: \(String(describing: outcome), privacy: .public)")
        return outcome == .success
    }
}
