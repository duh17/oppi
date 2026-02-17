import Testing
@testable import Oppi

@Suite("ConnectionSecurityPolicy")
struct ConnectionSecurityPolicyTests {
    private func profile(
        requireTlsOutsideTailnet: Bool,
        allowInsecureHttpInTailnet: Bool,
        requirePinnedServerIdentity: Bool = true
    ) -> ServerSecurityProfile {
        ServerSecurityProfile(
            configVersion: 2,
            profile: "tailscale-permissive",
            requireTlsOutsideTailnet: requireTlsOutsideTailnet,
            allowInsecureHttpInTailnet: allowInsecureHttpInTailnet,
            requirePinnedServerIdentity: requirePinnedServerIdentity,
            identity: .init(enabled: true, algorithm: "ed25519", keyId: "srv", fingerprint: "sha256:test"),
            invite: .init(format: "v2-signed", maxAgeSeconds: 600)
        )
    }

    @Test func allowsTailnetHostWhenPolicyPermitsInsecureTailnet() {
        let violation = ConnectionSecurityPolicy.evaluate(
            host: "myhost.tail12345.ts.net",
            profile: profile(requireTlsOutsideTailnet: true, allowInsecureHttpInTailnet: true)
        )

        #expect(violation == nil)
    }

    @Test func blocksTailnetHostWhenPolicyDisallowsInsecureTailnet() {
        let violation = ConnectionSecurityPolicy.evaluate(
            host: "myhost.tail12345.ts.net",
            profile: profile(requireTlsOutsideTailnet: true, allowInsecureHttpInTailnet: false)
        )

        #expect(violation == .insecureTailnetTransportBlocked(host: "myhost.tail12345.ts.net"))
    }

    @Test func blocksPublicHostWhenTlsRequiredOutsideTailnet() {
        let violation = ConnectionSecurityPolicy.evaluate(
            host: "example.com",
            profile: profile(requireTlsOutsideTailnet: true, allowInsecureHttpInTailnet: true)
        )

        #expect(violation == .insecurePublicTransportBlocked(host: "example.com"))
    }

    @Test func allowsPublicHostWhenTlsOutsideTailnetNotRequired() {
        let violation = ConnectionSecurityPolicy.evaluate(
            host: "example.com",
            profile: profile(requireTlsOutsideTailnet: false, allowInsecureHttpInTailnet: true)
        )

        #expect(violation == nil)
    }

    @Test func allowsLocalHostEvenWhenTlsRequiredOutsideTailnet() {
        let violation = ConnectionSecurityPolicy.evaluate(
            host: "192.168.1.10",
            profile: profile(requireTlsOutsideTailnet: true, allowInsecureHttpInTailnet: true)
        )

        #expect(violation == nil)
    }

    @Test func classifiesTailnetCgnatIpv4AsTailnet() {
        let violation = ConnectionSecurityPolicy.evaluate(
            host: "100.101.102.103",
            profile: profile(requireTlsOutsideTailnet: true, allowInsecureHttpInTailnet: false)
        )

        #expect(violation == .insecureTailnetTransportBlocked(host: "100.101.102.103"))
    }

    @Test func evaluatesStoredCredentialPolicy() {
        let creds = ServerCredentials(
            host: "example.com",
            port: 7749,
            token: "sk_test",
            name: "test",
            requireTlsOutsideTailnet: true,
            allowInsecureHttpInTailnet: true,
            requirePinnedServerIdentity: true
        )

        let violation = ConnectionSecurityPolicy.evaluate(credentials: creds)
        #expect(violation == .insecurePublicTransportBlocked(host: "example.com"))
    }
}
