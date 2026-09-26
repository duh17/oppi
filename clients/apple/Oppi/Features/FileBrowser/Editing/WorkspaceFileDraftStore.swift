import Foundation

/// Unsaved editor buffer for one workspace file. `baseEtag` is the disk tag the
/// buffer was last known to extend; recovery compares it with a fresh read.
struct WorkspaceFileDraft: Codable, Equatable, Sendable {
    let identity: WorkspaceFileEditIdentity
    var baseEtag: String
    var bytes: Data
    var updatedAt: Date
}

/// Protected on-disk drafts, one file per identity under Application Support.
/// Not UserDefaults. Files use `completeUnlessOpen` so a background checkpoint
/// can still be written after the device locks, but cannot be read while locked.
struct WorkspaceFileDraftStore: Sendable {
    enum LoadResult: Equatable {
        case none
        case draft(WorkspaceFileDraft)
        /// A draft file exists but cannot be read back. Never overwrite or
        /// delete it; move it aside with `quarantine`.
        case unreadable
    }

    let directory: URL

    static let shared: WorkspaceFileDraftStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return WorkspaceFileDraftStore(directory: base.appendingPathComponent("WorkspaceFileDrafts", isDirectory: true))
    }()

    func loadResult(_ identity: WorkspaceFileEditIdentity) -> LoadResult {
        let url = fileURL(for: identity)
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        guard let data = try? Data(contentsOf: url),
              let draft = try? JSONDecoder().decode(WorkspaceFileDraft.self, from: data),
              draft.identity == identity else {
            return .unreadable
        }
        return .draft(draft)
    }

    func load(_ identity: WorkspaceFileEditIdentity) -> WorkspaceFileDraft? {
        if case .draft(let draft) = loadResult(identity) { return draft }
        return nil
    }

    func save(_ draft: WorkspaceFileDraft) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
        )
        let data = try JSONEncoder().encode(draft)
        try data.write(to: fileURL(for: draft.identity), options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    func remove(_ identity: WorkspaceFileEditIdentity) {
        try? FileManager.default.removeItem(at: fileURL(for: identity))
    }

    /// Move a draft the editor cannot apply out of the live slot, so later
    /// checkpoints cannot overwrite it. The app never deletes quarantined files.
    @discardableResult
    func quarantine(_ identity: WorkspaceFileEditIdentity) -> Bool {
        let source = fileURL(for: identity)
        let stamp = Int(Date().timeIntervalSince1970 * 1_000)
        let target = directory.appendingPathComponent("\(identity.storageKey).\(stamp).unreadable", isDirectory: false)
        return (try? FileManager.default.moveItem(at: source, to: target)) != nil
    }

    func quarantinedFiles(for identity: WorkspaceFileEditIdentity) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix("\(identity.storageKey).") && $0.hasSuffix(".unreadable") }
            .map { directory.appendingPathComponent($0) }
    }

    func fileURL(for identity: WorkspaceFileEditIdentity) -> URL {
        directory.appendingPathComponent("\(identity.storageKey).draft", isDirectory: false)
    }
}
