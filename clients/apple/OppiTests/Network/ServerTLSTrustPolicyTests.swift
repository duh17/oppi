import Foundation
import Testing
@testable import Oppi

@Suite("Server TLS trust policy")
struct ServerTLSTrustPolicyTests {
    @Test func httpsIsRequired() {
        #expect(ServerTLSTrustPolicy.requiresHTTPS(scheme: "https"))
        #expect(ServerTLSTrustPolicy.requiresHTTPS(scheme: "HTTPS"))
        #expect(!ServerTLSTrustPolicy.requiresHTTPS(scheme: "http"))
        #expect(!ServerTLSTrustPolicy.requiresHTTPS(scheme: nil))
    }

    @Test func configuredPinIsAuthoritativeForTailscaleHosts() {
        #expect(
            ServerTLSTrustPolicy.decision(
                pinnedLeafFingerprint: "sha256:pin",
                presentedFingerprint: "sha256:other",
                host: "mac-studio.tail123.ts.net"
            ) == .reject
        )
        #expect(
            ServerTLSTrustPolicy.decision(
                pinnedLeafFingerprint: "sha256:pin",
                presentedFingerprint: "sha256:pin",
                host: "mac-studio.tail123.ts.net"
            ) == .pinMatch
        )
    }

    @Test func noPinTailscaleUsesPublicCA() {
        #expect(
            ServerTLSTrustPolicy.decision(
                pinnedLeafFingerprint: nil,
                presentedFingerprint: "sha256:rotating",
                host: "mac-studio.tail123.ts.net"
            ) == .publicCAFallback
        )
    }

    @Test func noPinPublicDomainUsesPublicCA() {
        #expect(
            ServerTLSTrustPolicy.decision(
                pinnedLeafFingerprint: nil,
                presentedFingerprint: "sha256:public-leaf",
                host: "oppi.example.com"
            ) == .publicCAFallback
        )
        #expect(ServerTLSTrustPolicy.allowsPublicCATrustFallback(forHost: "oppi.example.com"))
        #expect(!ServerTLSTrustPolicy.allowsUnpinnedLANShortcut(forHost: "oppi.example.com"))
    }

    @Test func noPinIPAndLocalRejectPublicCA() {
        #expect(
            ServerTLSTrustPolicy.decision(
                pinnedLeafFingerprint: nil,
                presentedFingerprint: "sha256:leaf",
                host: "192.168.1.9"
            ) == .reject
        )
        #expect(
            ServerTLSTrustPolicy.decision(
                pinnedLeafFingerprint: nil,
                presentedFingerprint: "sha256:leaf",
                host: "mac.local"
            ) == .reject
        )
        #expect(!ServerTLSTrustPolicy.allowsPublicCATrustFallback(forHost: "192.168.1.9"))
        #expect(!ServerTLSTrustPolicy.allowsPublicCATrustFallback(forHost: "mac.local"))
    }
}
