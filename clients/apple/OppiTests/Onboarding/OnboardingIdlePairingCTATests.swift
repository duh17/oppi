import Testing
@testable import Oppi

@Suite("Onboarding idle pairing CTAs")
struct OnboardingIdlePairingCTATests {
    @Test func cameraOffersSetUpThenScanThenManual() {
        #expect(OnboardingIdlePairingCTA.visible(canScan: true) == [.setUpComputer, .scanQR, .enterManually])
    }

    @Test func withoutCameraNeverOffersScanning() {
        #expect(OnboardingIdlePairingCTA.visible(canScan: false) == [.setUpComputer, .enterManually])
    }

    /// The Mac has no in-app Tailscale node, so set-up would open a page that cannot connect.
    @Test func withoutAnInAppTailnetNeverOffersSetUp() {
        #expect(OnboardingIdlePairingCTA.visible(canScan: false, canSetUpComputer: false) == [.enterManually])
        #expect(OnboardingIdlePairingCTA.visible(canScan: true, canSetUpComputer: false) == [.scanQR, .enterManually])
    }
}
