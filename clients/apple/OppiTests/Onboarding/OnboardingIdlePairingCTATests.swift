import Testing
@testable import Oppi

@Suite("Onboarding idle pairing CTAs")
struct OnboardingIdlePairingCTATests {
    @Test func cameraAvailableOffersQRThenManual() {
        #expect(OnboardingIdlePairingCTA.visible(canScan: true).map(\.title) == [
            "Scan QR Code",
            "Enter manually",
        ])
    }

    @Test func cameraUnavailableOffersManualConnect() {
        #expect(OnboardingIdlePairingCTA.visible(canScan: false).map(\.title) == [
            "Connect to Server",
        ])
    }

    @Test func neverOffersNearbyMacPairing() {
        for canScan in [true, false] {
            let titles = OnboardingIdlePairingCTA.visible(canScan: canScan).map(\.title)
            #expect(!titles.contains("Pair Nearby Mac"))
        }
    }
}
