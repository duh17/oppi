import Foundation

/// Where a person left a book: which spine document, which top-level block of
/// it, and how far into that block.
///
/// The block ordinal is a line in the chapter's Markdown, so it resolves to the
/// same paragraph after the text size changes; a scroll offset alone would
/// drift. The distance into the block counts in `unit`: the scrolling chapter
/// measures points down the block, the pages count characters into it, and
/// either converts the other's distance through the block it names.
struct EPUBReadingPosition: Equatable, Sendable {
    /// What `offset` counts inside the block.
    enum Unit: String, Codable, Sendable {
        /// Points down the block, as the scrolling chapter measures it.
        case points
        /// Characters into the block, as a page break can cut it.
        case characters
    }

    /// Archive path of the spine document (`chapters[i].href`).
    let chapterHref: String
    let blockOrdinal: Int
    let offset: Double
    let unit: Unit

    init(chapterHref: String, blockOrdinal: Int, offset: Double = 0, unit: Unit = .points) {
        self.chapterHref = chapterHref
        self.blockOrdinal = blockOrdinal
        self.offset = offset
        self.unit = unit
    }
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
            offset: entry.offset,
            // An entry written before the unit was stored carries points: the
            // scrolling chapter is what wrote them.
            unit: entry.unit ?? .points
        )
    }

    func save(_ position: EPUBReadingPosition, for key: String, now: Date = Date()) {
        guard position.blockOrdinal >= 0, position.offset.isFinite else { return }
        var all = entries()
        all[key] = Entry(
            href: position.chapterHref,
            block: position.blockOrdinal,
            offset: position.offset,
            unit: position.unit,
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
        /// Absent from entries an older build wrote, which always meant points.
        let unit: EPUBReadingPosition.Unit?
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
