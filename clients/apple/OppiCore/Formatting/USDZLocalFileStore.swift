import Foundation

/// Retains downloaded `.usdz` bytes on disk until every consumer releases them.
///
/// Inline and full-screen viewers share one file. RealityKit loading stays in
/// the platform UI layer; this store is Foundation-only.
actor USDZLocalFileStore {
    static let shared = USDZLocalFileStore()

    struct Handle: Sendable, Equatable {
        let key: String
        let url: URL
    }

    private struct Entry {
        var url: URL
        var retainCount: Int
    }

    private var entries: [String: Entry] = [:]

    static func cacheKey(
        kind: ResourceReferenceKind,
        workspaceID: String?,
        sessionID: String?,
        worktreeID: String?,
        path: String
    ) -> String {
        [
            kind.rawValue,
            workspaceID ?? "",
            sessionID ?? "",
            worktreeID ?? "",
            path,
        ].joined(separator: "|")
    }

    func store(key: String, data: Data) throws -> Handle {
        if var existing = entries[key] {
            existing.retainCount += 1
            try data.write(to: existing.url, options: .atomic)
            entries[key] = existing
            return Handle(key: key, url: existing.url)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oppi-usdz-\(UUID().uuidString).usdz", isDirectory: false)
        try data.write(to: url, options: .atomic)
        entries[key] = Entry(url: url, retainCount: 1)
        return Handle(key: key, url: url)
    }

    func retain(_ handle: Handle) {
        guard var existing = entries[handle.key], existing.url == handle.url else { return }
        existing.retainCount += 1
        entries[handle.key] = existing
    }

    func release(_ handle: Handle) {
        guard var existing = entries[handle.key], existing.url == handle.url else { return }
        existing.retainCount -= 1
        if existing.retainCount <= 0 {
            try? FileManager.default.removeItem(at: existing.url)
            entries[handle.key] = nil
        } else {
            entries[handle.key] = existing
        }
    }

#if DEBUG
    func debugRetainCount(for key: String) -> Int? {
        entries[key]?.retainCount
    }

    func debugURL(for key: String) -> URL? {
        entries[key]?.url
    }
#endif
}
