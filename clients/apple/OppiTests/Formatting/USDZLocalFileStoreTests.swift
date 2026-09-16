import Foundation
import Testing
@testable import Oppi

@Suite("USDZ local file store")
struct USDZLocalFileStoreTests {
    @Test func retainKeepsFileUntilLastRelease() async throws {
        let store = USDZLocalFileStore()
        let data = Data("usdz-bytes".utf8)
        let first = try await store.store(key: "scene", data: data)
        #expect(FileManager.default.fileExists(atPath: first.url.path))
        await store.retain(first)
        #expect(await store.debugRetainCount(for: "scene") == 2)
        await store.release(first)
        #expect(FileManager.default.fileExists(atPath: first.url.path))
        await store.release(first)
        #expect(await store.debugRetainCount(for: "scene") == nil)
        #expect(!FileManager.default.fileExists(atPath: first.url.path))
    }
}
