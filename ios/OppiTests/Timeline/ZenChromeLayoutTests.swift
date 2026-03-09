import Testing
@testable import Oppi

@Suite("Zen navigation policy")
struct ZenNavigationPolicyTests {
    @Test("zen mode clears navigation title")
    func zenModeClearsNavigationTitle() {
        #expect(ZenNavigationPolicy.navigationTitle(sessionDisplayName: "My Session", isZenMode: true).isEmpty)
    }

    @Test("normal mode keeps session title")
    func normalModeKeepsSessionTitle() {
        #expect(ZenNavigationPolicy.navigationTitle(sessionDisplayName: "My Session", isZenMode: false) == "My Session")
    }

    @Test("stop button shows only while busy")
    func stopButtonShowsOnlyWhileBusy() {
        #expect(ZenNavigationPolicy.showsStopButton(isBusy: true))
        #expect(!ZenNavigationPolicy.showsStopButton(isBusy: false))
    }

    @Test("zen toggle uses filled icon while active")
    func zenToggleUsesFilledIconWhileActive() {
        #expect(ZenNavigationPolicy.zenToggleSystemImage(isZenMode: true) == "viewfinder.circle.fill")
        #expect(ZenNavigationPolicy.zenToggleSystemImage(isZenMode: false) == "viewfinder")
    }

    @Test("zen toggle accessibility label flips with state")
    func zenToggleAccessibilityLabelFlipsWithState() {
        #expect(ZenNavigationPolicy.zenToggleAccessibilityLabel(isZenMode: true) == "Exit zen mode")
        #expect(ZenNavigationPolicy.zenToggleAccessibilityLabel(isZenMode: false) == "Enter zen mode")
    }
}
