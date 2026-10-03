import Testing
@testable import Oppi

@Suite("Onboarding idle pairing CTAs")
struct OnboardingIdlePairingCTATests {
    @Test func cameraAvailableOffersQRThenManual() {
        #expect(OnboardingIdlePairingCTA.visible(canScan: true).map(\.title) == [
            "Scan QR Code",
            "Connect through Tailscale",
            "Enter manually",
        ])
    }

    @Test func cameraUnavailableOffersManualConnectAndTailscale() {
        #expect(OnboardingIdlePairingCTA.visible(canScan: false).map(\.title) == [
            "Connect to Server",
            "Connect through Tailscale",
        ])
    }

    @Test func pairingChoicesShareStyleNotSize() {
        #expect(OnboardingIdlePairingCTA.scanQR.prominence == .primary)
        #expect(OnboardingIdlePairingCTA.connectWithoutCamera.prominence == .primary)
        #expect(OnboardingIdlePairingCTA.connectThroughTailscale.prominence == .bordered)
        #expect(OnboardingIdlePairingCTA.enterManually.prominence == .bordered)
        #expect(OnboardingIdlePairingCTA.connectThroughTailscale.accessibilityIdentifier == "onboarding.tailscale")
    }

    @Test func neverOffersNearbyMacPairing() {
        for canScan in [true, false] {
            let titles = OnboardingIdlePairingCTA.visible(canScan: canScan).map(\.title)
            #expect(!titles.contains("Pair Nearby Mac"))
        }
    }
}
