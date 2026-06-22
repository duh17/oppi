import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("BiometricService")
struct BiometricServiceTests {
    @Test func authenticateReturnsSuccessWithoutPromptWhenDisabled() async {
        let original = AppPreferences.Biometric.isEnabled
        AppPreferences.Biometric.setEnabled(false)
        defer { AppPreferences.Biometric.setEnabled(original) }

        let allowed = await BiometricService.shared.authenticate(reason: "Confirm test action")

        #expect(allowed)
    }

    @Test func biometricPreferenceDefaultsOn() {
        let key = "\(AppIdentifiers.subsystem).biometric.enabled"
        let original = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        #expect(AppPreferences.Biometric.isEnabled)
    }
}
