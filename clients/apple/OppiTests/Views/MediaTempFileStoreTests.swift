import CryptoKit
import Foundation
import Testing
@testable import Oppi

@Suite("MediaTempFileStore")
struct MediaTempFileStoreTests {
    @Test("uses a stable SHA256-derived filename for cached media")
    func usesStableSHA256DerivedFilename() throws {
        let data = Data("inline-media-cache-test".utf8)
        let expectedDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        let url = try MediaTempFileStore.fileURL(for: data, preferredExtension: "mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(url.lastPathComponent == "media-\(expectedDigest).mp4")
        #expect(FileManager.default.fileExists(atPath: url.path))

        let secondURL = try MediaTempFileStore.fileURL(for: data, preferredExtension: "mp4")
        #expect(secondURL == url)
    }
}
