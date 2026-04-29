import Testing
import Foundation
@testable import Oppi

@MainActor
@Suite("InviteBootstrapService")
struct InviteBootstrapServiceTests {
    private let host = "pairing.example.test"

    @Test func trustConfirmationPrecedesPairingTokenExchange() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repoRoot.appendingPathComponent("Oppi/Features/Onboarding/OnboardingView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let trustIndex = try #require(source.range(of: "let trusted = await confirmTrust(reason)")?.lowerBound)
        let pairIndex = try #require(source.range(of: "try await bootstrapAPI.pairDevice")?.lowerBound)

        #expect(trustIndex < pairIndex)
    }

    @Test func pairingFailureMessageForExpiredInvite() {
        let message = InviteBootstrapService.pairingFailureMessage(
            for: APIError.server(status: 401, message: "Invalid or expired pairing token"),
            host: host
        )

        #expect(message == "Invite link expired or was already used. Request a fresh invite.")
    }

    @Test func pairingFailureMessageForRateLimit() {
        let message = InviteBootstrapService.pairingFailureMessage(
            for: APIError.server(status: 429, message: "Too many invalid pairing attempts. Try again later."),
            host: host
        )

        #expect(message == "Too many invalid pairing attempts. Wait a moment, request a fresh invite, and try again.")
    }

    @Test func pairingFailureMessageForNetworkLookupFailure() {
        let message = InviteBootstrapService.pairingFailureMessage(
            for: URLError(.cannotFindHost),
            host: host
        )

        #expect(message == "Could not reach pairing.example.test. Check the address, VPN, or network and try again.")
    }

    @Test func pairingFailureMessageForTLSFailure() {
        let message = InviteBootstrapService.pairingFailureMessage(
            for: URLError(.serverCertificateUntrusted),
            host: host
        )

        #expect(message == "Secure connection to pairing.example.test failed. Verify the invite host and certificate, then try again.")
    }
}
