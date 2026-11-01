import Testing
import Foundation
@testable import Oppi

/// On a defaults suite of its own: the app's haptics preference is never touched.
@Suite("AppPreferenceStore.Interaction")
struct InteractionPreferencesTests {
    private typealias Store = AppPreferenceStore.Interaction

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "InteractionPreferencesTests.\(UUID().uuidString)"))
    }

    @Test func hapticFeedbackDefaultsToEnabled() throws {
        #expect(Store.isHapticFeedbackEnabled(in: try makeDefaults()))
    }

    @Test func persistsHapticFeedbackChoice() throws {
        let defaults = try makeDefaults()
        Store.setHapticFeedbackEnabled(false, in: defaults)
        #expect(!Store.isHapticFeedbackEnabled(in: defaults))
        #expect(defaults.object(forKey: "\(AppIdentifiers.subsystem).interaction.hapticFeedback.enabled") as? Bool == false)

        Store.setHapticFeedbackEnabled(true, in: defaults)
        #expect(Store.isHapticFeedbackEnabled(in: defaults))
    }
}
