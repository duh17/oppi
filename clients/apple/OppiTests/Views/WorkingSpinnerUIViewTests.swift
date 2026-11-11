import Foundation
import Testing
import UIKit
@testable import Oppi

/// Reduce Motion: braille and Game of Life hold their frame, shown, until it turns off.
/// (The orb's still frame is `OrbMetalTests`'.) Driven through each view's `isFrozen`,
/// which `WorkingSpinnerUIView` sets from the system setting, because the spinner's
/// style is a process-wide preference other suites write concurrently.
@Suite("Spinner Reduce Motion")
@MainActor
struct SpinnerReduceMotionTests {
    @Test("braille and Game of Life stop ticking while frozen and stay shown")
    func frozenSpinnersHoldStill() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        window.makeKeyAndVisible()
        defer { hideTestWindow(window) }
        let braille = BrailleSpinnerUIView()
        let life = GameOfLifeUIView(gridSize: 6)

        for (name, view, ticking, freeze) in [
            ("braille", braille as UIView, { braille.isTicking }, { braille.isFrozen = $0 }),
            ("life", life as UIView, { life.isTicking }, { life.isFrozen = $0 }),
        ] as [(String, UIView, () -> Bool, (Bool) -> Void)] {
            window.addSubview(view)
            #expect(ticking(), "\(name) ticks in a window")
            freeze(true)
            #expect(!ticking(), "\(name) holds its frame under Reduce Motion")
            #expect(!view.isHidden && view.window != nil, "\(name) still shows its frame")
            freeze(false)
            #expect(ticking(), "\(name) ticks again when Reduce Motion turns off")
            view.removeFromSuperview()
            #expect(!ticking(), "\(name) stops out of the window")
        }
    }
}

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
