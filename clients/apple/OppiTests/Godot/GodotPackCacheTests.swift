import CryptoKit
import Foundation
import Testing
@testable import Oppi

/// The pack cache: two panes wanting one pack at once share one download
/// (two would write one partial file together), and pruning never removes a
/// pack the engine has mounted.
@MainActor
@Suite("GodotPackCache")
struct GodotPackCacheTests {
    @MainActor
    private final class Downloads {
        var count = 0
    }

    private func sample() throws -> Data {
        try Data(contentsOf: try #require(TestFixtures.bundle.url(forResource: "godot-sample", withExtension: "pck")))
    }

    private func release(_ pack: Data) -> GodotRelease {
        let sha = SHA256.hash(data: pack).map { String(format: "%02x", $0) }.joined()
        return GodotRelease(
            v: 1, seq: 1, createdAt: 0, origin: "discovery", engine: GodotEngine(name: "godot", version: "4.7"),
            packs: [GodotPack(sha256: sha, size: pack.count, format: .pck)], entry: nil, reload: .scene, label: nil
        )
    }

    @Test func twoPanesWantingOnePackShareOneDownload() async throws {
        let pack = try sample()
        let slot = GodotSlot(serverId: "sha256:test", project: "cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: GodotFolders.packs(for: slot)) }
        let downloads = Downloads()
        let download: @MainActor (String, URL) async throws -> Void = { _, file in
            downloads.count += 1
            try await Task.sleep(for: .milliseconds(100))
            try pack.write(to: file)
        }
        let release = release(pack)
        let first = Task { try await GodotPackCache.packs(of: release, slot: slot, download: download) }
        let second = Task { try await GodotPackCache.packs(of: release, slot: slot, download: download) }
        let (a, b) = (try await first.value, try await second.value)
        #expect(downloads.count == 1)
        #expect(a.map(\.url) == b.map(\.url))
        #expect(a.first?.index.files["project.binary"] != nil, "Both read the whole pack")
    }

    @Test func pruningKeepsMountedPacks() async throws {
        let pack = try sample()
        let slot = GodotSlot(serverId: "sha256:test", project: "prune-\(UUID().uuidString)")
        let folder = GodotFolders.packs(for: slot)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Older packs than the cache keeps, the oldest of them mounted.
        let old = (0..<(GodotPackCache.keptPacks + 2)).map { folder.appending(path: "old\($0).pck") }
        for (age, file) in old.enumerated() {
            try Data([1]).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(-1000 + age))], ofItemAtPath: file.path)
        }
        GodotPackCache.pin([old[0]])
        _ = try await GodotPackCache.packs(of: release(pack), slot: slot) { _, file in try pack.write(to: file) }
        #expect(FileManager.default.fileExists(atPath: old[0].path), "The mounted pack stays")
        #expect(!FileManager.default.fileExists(atPath: old[1].path), "The oldest unmounted pack goes")
        #expect(FileManager.default.fileExists(atPath: old.last?.path ?? ""), "The newest old packs stay")
    }
}
