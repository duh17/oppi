import Foundation
import Testing
import UIKit
@testable import Oppi

/// A live spinner follows a style change, and one posted off the main thread must not trap it.
///
/// The style change reaches this view through `NotificationCenter`, and
/// `AppearanceStylePreferenceTests` posts it from whatever thread Swift Testing gives the
/// test (not the main actor). A selector observer without a delivery queue ran the main-actor
/// update on that thread and killed the test host with
/// `Fatal error: Incorrect actor executor assumption` whenever another suite in the same
/// shard held a live spinner (`WorkingIndicatorLiveTailPinTests` does, in the same shard as
/// the appearance suite). Both writers of this key in the shard write `.working`, so a
/// concurrent suite cannot supersede the style this test expects.
@Suite("Working spinner style change")
@MainActor
struct WorkingSpinnerStyleChangeTests {
    @Test("Spinner style change posted off the main thread does not trap a live spinner")
    func spinnerStyleChangeOffMainDoesNotTrapLiveSpinner() async {
        let spinner = WorkingSpinnerUIView(side: 20)
        let key = AppPreferenceStore.Appearance.spinnerStyleKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // A style other than `.working` gives the posted change somewhere to move to.
        AppPreferenceStore.Appearance.setSpinnerStyle(.brailleDots)
        await Task.detached {
            AppPreferenceStore.Appearance.setSpinnerStyle(.working)
        }.value

        // Delivery is a main-queue hop now, so let it land before reading the style.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while spinner.style != .working, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(spinner.style == .working)
    }
}
