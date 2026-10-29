import Testing
import Foundation
@testable import Oppi

@Suite("TLSPinning")
struct TLSPinningTests {

    @Test("a cancel is a load cancellation in every form it arrives in")
    func loadCancellationCoversEveryCancelForm() {
        let cancels: [any Error] = [
            CancellationError(),
            URLError(.cancelled),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
        ]
        for error in cancels {
            #expect(error.isLoadCancellation, "\(error)")
        }
    }

    @Test("a bare NSURLErrorCancelled NSError bridges to URLError.cancelled")
    func bareNSErrorBridgesToURLErrorCancelled() {
        // The shared rule only checks `URLError.cancelled`; it matches the
        // NSError form because of this bridging.
        let bare: any Error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        #expect((bare as? URLError)?.code == .cancelled)
    }

    @Test("other failures, including a rejected certificate, are not cancellations")
    func loadCancellationRejectsRealFailures() {
        let failures: [any Error] = [
            URLError(.timedOut),
            URLError(.serverCertificateUntrusted),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
            NSError(domain: NSCocoaErrorDomain, code: NSURLErrorCancelled),
            APIError.server(status: 500, message: "boom"),
        ]
        for error in failures {
            #expect(!error.isLoadCancellation, "\(error)")
        }
    }

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
