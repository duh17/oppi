import Testing
import Foundation
@testable import Oppi

@Suite("AppPreferences.Interaction", .serialized)
struct InteractionPreferencesTests {
    private let hapticFeedbackEnabledKey = "\(AppIdentifiers.subsystem).interaction.hapticFeedback.enabled"

    @Test func hapticFeedbackDefaultsToEnabled() {
        UserDefaults.standard.removeObject(forKey: hapticFeedbackEnabledKey)
        defer { UserDefaults.standard.removeObject(forKey: hapticFeedbackEnabledKey) }

        #expect(AppPreferences.Interaction.isHapticFeedbackEnabled)
    }

    @Test func persistsHapticFeedbackChoice() {
        UserDefaults.standard.removeObject(forKey: hapticFeedbackEnabledKey)
        defer { UserDefaults.standard.removeObject(forKey: hapticFeedbackEnabledKey) }

        AppPreferences.Interaction.setHapticFeedbackEnabled(false)
        #expect(!AppPreferences.Interaction.isHapticFeedbackEnabled)

        AppPreferences.Interaction.setHapticFeedbackEnabled(true)
        #expect(AppPreferences.Interaction.isHapticFeedbackEnabled)
    }
}
