import Foundation

/// Where a person left a book: which spine document, which top-level block of
/// it, and how far into that block.
///
/// The block ordinal is a line in the chapter's Markdown, so it resolves to the
/// same paragraph after the text size changes; a scroll offset alone would
/// drift. The offset is where the block's top was, in points, and is clamped by
/// the reader on restore.
struct EPUBReadingPosition: Equatable, Sendable {
    /// Archive path of the spine document (`chapters[i].href`).
    let chapterHref: String
    let blockOrdinal: Int
    let offsetPoints: Double
}

/// Reading positions, keyed by the book's identity, in the same shape as
/// `AudioResumeStore`: a small bounded dictionary in preferences, oldest out.
struct EPUBReadingPositionStore {
    static let maximumEntries = 200
    static let preferenceKey = "\(AppIdentifiers.subsystem).epub.readingPositions"

    var defaults: UserDefaults = .standard

    /// A stable key for one book: the server it came from, where the viewer
    /// read it (a workspace, a session, or the host), and the path it read.
    /// Two books at one path in two workspaces are two different books.
    static func key(serverId: String?, origin: String, path: String) -> String {
        "\(serverId ?? "-")|\(origin)|\(path)"
    }

    func position(for key: String) -> EPUBReadingPosition? {
        guard let entry = entries()[key] else { return nil }
        return EPUBReadingPosition(
            chapterHref: entry.href,
            blockOrdinal: entry.block,
            offsetPoints: entry.offset
        )
    }

    func save(_ position: EPUBReadingPosition, for key: String, now: Date = Date()) {
        guard position.blockOrdinal >= 0, position.offsetPoints.isFinite else { return }
        var all = entries()
        all[key] = Entry(
            href: position.chapterHref,
            block: position.blockOrdinal,
            offset: position.offsetPoints,
            at: now.timeIntervalSince1970
        )
        if all.count > Self.maximumEntries {
            let oldest = all.sorted { $0.value.at < $1.value.at }
                .prefix(all.count - Self.maximumEntries)
                .map(\.key)
            for key in oldest { all.removeValue(forKey: key) }
        }
        persist(all)
    }

    func clear(_ key: String) {
        var all = entries()
        guard all.removeValue(forKey: key) != nil else { return }
        persist(all)
    }

    private struct Entry: Codable {
        let href: String
        let block: Int
        let offset: Double
        let at: Double
    }

    private func entries() -> [String: Entry] {
        guard let data = defaults.data(forKey: Self.preferenceKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func persist(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.preferenceKey)
    }
}
