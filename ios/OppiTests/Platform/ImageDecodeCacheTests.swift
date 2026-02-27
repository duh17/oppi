import Testing
import UIKit

@testable import Oppi

@Suite("ImageDecodeCache")
struct ImageDecodeCacheTests {
    private let tinyPngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO5WkN0AAAAASUVORK5CYII="

    @Test("decode key includes suffix to avoid same-prefix collisions")
    func decodeKeyIncludesSuffix() {
        let prefix = String(repeating: "A", count: 64)
        let a = prefix + "1111111111111111"
        let b = prefix + "2222222222222222"

        let keyA = ImageDecodeCache.decodeKey(for: a, maxPixelSize: 1600)
        let keyB = ImageDecodeCache.decodeKey(for: b, maxPixelSize: 1600)

        #expect(keyA != keyB)
    }

    @Test("invalid base64 returns nil")
    func invalidBase64ReturnsNil() {
        let decoded = ImageDecodeCache.decode(base64: "not-base64-@@@", maxPixelSize: 1600)
        #expect(decoded == nil)
    }

    @Test("decode reuses cached UIImage for same key")
    func decodeReusesCache() {
        let first = ImageDecodeCache.decode(base64: tinyPngBase64, maxPixelSize: 64)
        let second = ImageDecodeCache.decode(base64: tinyPngBase64, maxPixelSize: 64)

        #expect(first != nil)
        #expect(second != nil)
        if let first, let second {
            #expect(first === second)
        }
    }
}
