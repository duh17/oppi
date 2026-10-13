import Testing
import Foundation
@testable import Oppi

@Suite("TLSPinning")
struct TLSPinningTests {

    @Test("sha256 fingerprint is url-safe, unpadded base64 of the digest")
    func sha256FingerprintKnownValue() {
        // SHA-256("") in standard base64 is "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=".
        #expect(Data().sha256Fingerprint == "sha256:47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU")
    }

    @Test("public CA fallback is allowed for Tailscale hostnames")
    func publicCAFallbackAllowedForTailscaleHosts() {
        #expect(PinnedServerTrustDelegate.allowsPublicCATrustFallback(forHost: "mac-studio.tail123.ts.net"))
        #expect(PinnedServerTrustDelegate.allowsPublicCATrustFallback(forHost: "NODE.beta.tailscale.net"))
    }

    @Test("configured pin remains authoritative for Tailscale hostnames")
    func publicCAFallbackRejectsPinnedTailscaleHost() {
        #expect(!PinnedServerTrustDelegate.allowsPublicCATrustFallback(
            forHost: "mac-studio.tail123.ts.net",
            pinnedLeafFingerprint: "sha256:stable-pin"
        ))
    }

    @Test("public CA fallback is not allowed for IPs or .local hosts")
    func publicCAFallbackRejectsNonPublicHosts() {
        #expect(!PinnedServerTrustDelegate.allowsPublicCATrustFallback(forHost: "192.168.68.66"))
        #expect(!PinnedServerTrustDelegate.allowsPublicCATrustFallback(forHost: "mac.local"))
        #expect(PinnedServerTrustDelegate.allowsPublicCATrustFallback(forHost: "example.com"))
        #expect(PinnedServerTrustDelegate.allowsPublicCATrustFallback(forHost: "evil-ts.net.example.com"))
        #expect(!ServerTLSTrustPolicy.isTailscaleHostname("evil-ts.net.example.com"))
    }
}
