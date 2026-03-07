import CryptoKit
import Testing
import Foundation
@testable import Oppi

@Suite("TLSPinning")
struct TLSPinningTests {

    // MARK: - certFingerprint(for:)

    @Test("certFingerprint returns sha256: prefix")
    func certFingerprintPrefix() {
        let data = Data("arbitrary cert bytes".utf8)
        let fp = PinnedServerTrustDelegate.certFingerprint(for: data)
        #expect(fp.hasPrefix("sha256:"))
    }

    @Test("certFingerprint suffix uses base64url alphabet only")
    func certFingerprintBase64URLAlphabet() {
        let data = Data("arbitrary cert bytes".utf8)
        let fp = PinnedServerTrustDelegate.certFingerprint(for: data)
        let suffix = String(fp.dropFirst("sha256:".count))
        #expect(!suffix.isEmpty)
        // base64url uses A-Z, a-z, 0-9, -, _ (no +, /, or =)
        let validChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        #expect(suffix.unicodeScalars.allSatisfy { validChars.contains($0) })
        #expect(!suffix.contains("+"))
        #expect(!suffix.contains("/"))
        #expect(!suffix.contains("="))
    }

    @Test("certFingerprint is deterministic for same input")
    func certFingerprintDeterministic() {
        let data = Data("deterministic test".utf8)
        let fp1 = PinnedServerTrustDelegate.certFingerprint(for: data)
        let fp2 = PinnedServerTrustDelegate.certFingerprint(for: data)
        #expect(fp1 == fp2)
    }

    @Test("certFingerprint produces different values for different inputs")
    func certFingerprintDistinct() {
        let fp1 = PinnedServerTrustDelegate.certFingerprint(for: Data("cert-a".utf8))
        let fp2 = PinnedServerTrustDelegate.certFingerprint(for: Data("cert-b".utf8))
        #expect(fp1 != fp2)
    }

    @Test("certFingerprint matches independent SHA256 computation")
    func certFingerprintMatchesSHA256() {
        let data = Data("self-signed cert DER content".utf8)
        let digest = Data(SHA256.hash(data: data))
        let expected = "sha256:\(digest.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""))"
        let actual = PinnedServerTrustDelegate.certFingerprint(for: data)
        #expect(actual == expected)
    }

    @Test("certFingerprint handles empty data")
    func certFingerprintEmptyData() {
        let fp = PinnedServerTrustDelegate.certFingerprint(for: Data())
        // SHA256 of empty string is a known value; just verify format
        #expect(fp.hasPrefix("sha256:"))
        let suffix = String(fp.dropFirst("sha256:".count))
        #expect(!suffix.isEmpty)
    }

    // MARK: - PinnedServerTrustDelegate init

    @Test("delegate initialises without crashing when fingerprint is nil")
    func delegateInitNilFingerprint() {
        _ = PinnedServerTrustDelegate(pinnedLeafFingerprint: nil)
    }

    @Test("delegate initialises without crashing for valid fingerprint")
    func delegateInitValidFingerprint() {
        let data = Data("sample cert".utf8)
        let fp = PinnedServerTrustDelegate.certFingerprint(for: data)
        _ = PinnedServerTrustDelegate(pinnedLeafFingerprint: fp)
    }

    @Test("delegate initialises without crashing for whitespace-only fingerprint")
    func delegateInitWhitespaceFingerprint() {
        // Whitespace-only should be treated as nil (no pinning)
        _ = PinnedServerTrustDelegate(pinnedLeafFingerprint: "   ")
    }
}
