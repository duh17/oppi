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
}
