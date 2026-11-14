import CryptoKit
import Foundation

/// A project's packs on this device, by SHA-256 (design §10): a pack comes
/// only from its paired server, is checked against the hash and size the
/// release names before anything reads it, and its file table must hold no
/// native code. A pack already here is never fetched again; two panes that
/// want one pack at once share one download (`downloads`); a project keeps
/// the packs of its last few releases, and never loses one the engine has
/// mounted (`pin`).
@MainActor
enum GodotPackCache {
    enum Failure: LocalizedError, Equatable {
        case mismatch
        case unreadable(GodotPackIndex.ReadError)

        var errorDescription: String? {
            switch self {
            case .mismatch:
                String(localized: "The build that arrived doesn’t match the one the server published.")
            case .unreadable(.encrypted):
                String(localized: "The build is encrypted, so Oppi can’t check what it runs.")
            case .unreadable(.sparseBundle):
                String(localized: "The build is a sparse bundle. Export it as one .pck file.")
            case .unreadable:
                String(localized: "The build isn’t a Godot pack Oppi can read.")
            }
        }
    }

    /// Packs kept per project, beyond the current release's.
    static let keptPacks = 6

    /// Downloads in flight, by destination file. A second download of one
    /// file would write the same `.part` file at the same time.
    private static var downloads: [URL: Task<Void, any Error>] = [:]
    /// Packs the engine has mounted this launch: it reads them for as long as
    /// it runs, so pruning leaves them.
    private static var mounted: Set<URL> = []

    /// The engine mounted `packs`.
    static func pin(_ packs: [URL]) {
        mounted.formUnion(packs.map(\.standardizedFileURL))
    }

    /// The release's packs on disk with their file tables, fetched as needed.
    static func packs(
        of release: GodotRelease, slot: GodotSlot, link: GodotLinkClient
    ) async throws -> [(url: URL, index: GodotPackIndex)] {
        try await packs(of: release, slot: slot) { sha, file in
            try await link.packDownload(project: slot.project, sha256: sha).run(to: file) { _ in }
        }
    }

    /// `download(sha256, file)` fetches one pack into `file`.
    static func packs(
        of release: GodotRelease, slot: GodotSlot, download: @escaping @MainActor (String, URL) async throws -> Void
    ) async throws -> [(url: URL, index: GodotPackIndex)] {
        let folder = GodotFolders.packs(for: slot)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var result: [(URL, GodotPackIndex)] = []
        for pack in release.packs {
            let sha = pack.sha256.lowercased()
            guard sha.count == 64, sha.allSatisfy(\.isHexDigit) else { throw Failure.mismatch }
            let file = folder.appending(path: "\(sha).\(pack.format == .zip ? "zip" : "pck")")
            if !(try await isIntact(file, sha256: sha, size: Int64(pack.size))) {
                try await fetch(file) { try await download(sha, file) }
                guard try await isIntact(file, sha256: sha, size: Int64(pack.size)) else {
                    try? FileManager.default.removeItem(at: file)
                    throw Failure.mismatch
                }
            }
            do {
                result.append((file, try GodotPackIndex(contentsOf: file)))
            } catch let error as GodotPackIndex.ReadError {
                throw Failure.unreadable(error)
            }
            // Touched, so pruning keeps the packs in use longest.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        }
        prune(folder, keeping: Set(result.map(\.0)))
        return result
    }

    /// Runs `download` for `file`, or waits for the one already running.
    private static func fetch(_ file: URL, download: @escaping @MainActor () async throws -> Void) async throws {
        let key = file.standardizedFileURL
        if let running = downloads[key] { return try await running.value }
        let task = Task { try await download() }
        downloads[key] = task
        defer { downloads[key] = nil }
        try await task.value
    }

    /// Whether `file` exists with the expected size and hash. A known pack
    /// is hashed again each time: the cache folder is the app's, but a game
    /// pack is code and the check costs little next to a download.
    private static func isIntact(_ file: URL, sha256: String, size: Int64) async throws -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              (attributes[.size] as? NSNumber)?.int64Value == size else { return false }
        return try await Self.sha256(of: file) == sha256
    }

    static func sha256(of file: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    /// Drops the oldest packs past `keptPacks`, never one in `keeping`.
    private static func prune(_ folder: URL, keeping: Set<URL>) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        let kept = Set(keeping.map(\.standardizedFileURL)).union(mounted).union(downloads.keys)
        let others = files
            .filter { !kept.contains($0.standardizedFileURL) && ["pck", "zip"].contains($0.pathExtension) }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
        for file in others.dropFirst(keptPacks) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
