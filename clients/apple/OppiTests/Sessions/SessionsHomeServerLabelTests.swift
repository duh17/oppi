import Testing
@testable import Oppi

@Suite("Sessions Home Server Label")
struct SessionsHomeServerLabelTests {
    @Test func runtimeLabelUsesCanonicalHostname() {
        #expect(SessionsHomeServerLabel.runtimeLabel(from: "Mac-Studio.local") == "mac-studio")
    }

    @Test func runtimeLabelKeepsIPAddress() {
        #expect(SessionsHomeServerLabel.runtimeLabel(from: "192.168.1.23") == "192.168.1.23")
    }

    @Test func displayLabelPrefersRuntimeHostnameOverPairedName() {
        let label = SessionsHomeServerLabel.displayLabel(
            runtimeLabel: "mac-studio",
            pairedLabel: "mac-mini",
            fallbackServerId: "sha256:abcdef123456"
        )

        #expect(label == "mac-studio")
    }

    @Test func displayLabelFallsBackToPairedNameThenIdPrefix() {
        #expect(SessionsHomeServerLabel.displayLabel(
            runtimeLabel: nil,
            pairedLabel: "mac-mini",
            fallbackServerId: "sha256:abcdef123456"
        ) == "mac-mini")
        #expect(SessionsHomeServerLabel.displayLabel(
            runtimeLabel: nil,
            pairedLabel: nil,
            fallbackServerId: "sha256:abcdef123456"
        ) == "sha256:a")
    }
}
