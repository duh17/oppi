import Testing
import UIKit
@testable import Oppi

/// The destination pills before Quick Session finishes setting up: dimmed, so
/// VoiceOver must hear them as not enabled, and a pill whose tap does nothing
/// must not react to a press.
@Suite("Quick Session pills")
@MainActor
struct QuickSessionPillTests {
    @Test("Incognito and engine pills report not enabled until setup finishes")
    func pillsAreNotEnabledWhileSetupRuns() throws {
        let durableKey = AppPreferences.Experiments.durableSessionsKey
        let hadDurable = UserDefaults.standard.object(forKey: durableKey)
        UserDefaults.standard.set(true, forKey: durableKey)
        defer {
            if let hadDurable {
                UserDefaults.standard.set(hadDurable, forKey: durableKey)
            } else {
                UserDefaults.standard.removeObject(forKey: durableKey)
            }
        }

        let client = APIClient(baseURL: try #require(URL(string: "http://127.0.0.1:1")), token: "sk_test", configuration: .ephemeral)
        let root = try makeTestAppRoot(readyServerId: "sha256:qs-pills-\(UUID().uuidString)", apiClient: client)
        try #require(root.coordinator.activeConnection).setSplitStreamCapabilitiesForTesting(durableSessions: true)

        let controller = QuickSessionViewController(root: root, onDismiss: {})
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            controller.tearDown()
            window.isHidden = true
            window.rootViewController = nil
        }

        // Setup runs in a Task that cannot start before this test yields, so
        // the model is still uninitialized for everything below.
        controller.view.layoutIfNeeded()
        #expect(!controller.model.isInitialized)
        #expect(!controller.incognitoPill.isHidden)
        #expect(!controller.enginePill.isHidden)
        #expect(controller.incognitoPill.accessibilityTraits.contains(.notEnabled))
        #expect(controller.incognitoPill.accessibilityTraits.contains(.toggleButton))
        #expect(controller.enginePill.accessibilityTraits.contains(.notEnabled))

        controller.model.isInitialized = true
        controller.view.layoutIfNeeded()
        #expect(!controller.incognitoPill.accessibilityTraits.contains(.notEnabled))
        #expect(controller.incognitoPill.accessibilityTraits.contains(.toggleButton))
        #expect(!controller.enginePill.accessibilityTraits.contains(.notEnabled))
    }

    @Test("A pill whose tap does nothing keeps its alpha while pressed")
    func fixedPillDoesNotDimOnPress() {
        let tappable = QuickSessionPillButton()
        let fixed = QuickSessionPillButton()
        fixed.dimsWhenPressed = false

        tappable.isHighlighted = true
        fixed.isHighlighted = true

        #expect(tappable.alpha < 1)
        #expect(fixed.alpha == 1)
    }
}
