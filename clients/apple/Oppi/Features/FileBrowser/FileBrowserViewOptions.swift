import Foundation
import Observation

/// What a folder listing sorts by. Files.app's keys: tapping the chosen key
/// again flips its direction; a new key starts in its natural direction
/// (names and kinds A to Z, dates and sizes newest or largest first).
enum FileBrowserSortKey: String, CaseIterable, Codable, Sendable {
    case name
    case modified
    case size
    case kind

    var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .modified: String(localized: "Date Modified")
        case .size: String(localized: "Size")
        case .kind: String(localized: "Kind")
        }
    }

    var startsAscending: Bool {
        switch self {
        case .name, .kind: true
        case .modified, .size: false
        }
    }
}

/// How every file browser on this device lists a folder: the sort, whether
/// folders come first, and whether dot-files show. Search results keep their
/// relevance order (only listings sort), and hide dot-files too.
struct FileBrowserViewOptions: Codable, Equatable, Sendable {
    var sortKey: FileBrowserSortKey = .name
    var ascending = true
    var foldersFirst = true
    var showsHidden = true

    /// The chosen key flips direction; another key takes its own.
    mutating func choose(_ key: FileBrowserSortKey) {
        if key == sortKey {
            ascending.toggle()
        } else {
            sortKey = key
            ascending = key.startsAscending
        }
    }

    /// `entries` filtered and ordered for display. Ties fall back to the
    /// name, A to Z, so equal dates or sizes never shuffle between loads.
    /// Folders have no size, so a size sort lists them by name.
    func arranged(_ entries: [FileEntry]) -> [FileEntry] {
        let visible = showsHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
        let sorted = visible.sorted(by: precedes)
        guard foldersFirst else { return sorted }
        return sorted.filter(\.isDirectory) + sorted.filter { !$0.isDirectory }
    }

    /// Index paths a search may return: with hidden files off, none inside a
    /// dot-folder or named with a leading dot.
    func searchable(_ paths: [String]) -> [String] {
        guard !showsHidden else { return paths }
        return paths.filter { path in
            !path.split(separator: "/").contains { $0.hasPrefix(".") }
        }
    }

    private func precedes(_ lhs: FileEntry, _ rhs: FileEntry) -> Bool {
        let order = primaryOrder(lhs, rhs)
        if order != .orderedSame {
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        return Self.nameOrder(lhs, rhs) == .orderedAscending
    }

    private func primaryOrder(_ lhs: FileEntry, _ rhs: FileEntry) -> ComparisonResult {
        switch sortKey {
        case .name:
            return Self.nameOrder(lhs, rhs)
        case .modified:
            return Self.compare(lhs.modifiedAt, rhs.modifiedAt)
        case .size:
            // A folder's size is not its contents'; folders keep name order.
            if lhs.isDirectory || rhs.isDirectory {
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory ? .orderedAscending : .orderedDescending
                }
                return ascending ? Self.nameOrder(lhs, rhs) : Self.nameOrder(rhs, lhs)
            }
            return Self.compare(lhs.size, rhs.size)
        case .kind:
            let left = Self.kind(of: lhs)
            let right = Self.kind(of: rhs)
            if left.rank != right.rank { return Self.compare(left.rank, right.rank) }
            let order = left.ext.compare(right.ext)
            return order == .orderedSame ? Self.nameOrder(lhs, rhs) : order
        }
    }

    /// Finder order: case-insensitive, numbers by value (`file2` before `file10`).
    private static func nameOrder(_ lhs: FileEntry, _ rhs: FileEntry) -> ComparisonResult {
        lhs.name.localizedStandardCompare(rhs.name)
    }

    /// A folder sorts before every file kind, a file without an extension
    /// (`README`, `.env`) before those with one, then by extension.
    private static func kind(of entry: FileEntry) -> (rank: Int, ext: String) {
        if entry.isDirectory { return (0, "") }
        let name = entry.name.drop { $0 == "." }
        guard let dot = name.lastIndex(of: ".") else { return (1, "") }
        return (2, name[name.index(after: dot)...].lowercased())
    }

    private static func compare(_ lhs: Int, _ rhs: Int) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }
}

/// The device's one `FileBrowserViewOptions`, observed: a browser reads it in
/// `updateProperties()`, so a change made from any browser's menu re-sorts
/// every browser on screen.
@MainActor @Observable
final class FileBrowserViewOptionsStore {
    static let shared = FileBrowserViewOptionsStore()

    private(set) var options: FileBrowserViewOptions

    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "\(AppIdentifiers.subsystem).fileBrowser.viewOptions"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        options = Self.load(from: defaults)
    }

    private static func load(from defaults: UserDefaults) -> FileBrowserViewOptions {
        defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(FileBrowserViewOptions.self, from: $0) }
            ?? FileBrowserViewOptions()
    }

#if DEBUG
    /// Reads the options from defaults again (`HarnessLaunchReset`): the
    /// in-process reset clears defaults, and this copy was read from them once.
    func resetForTesting() {
        options = Self.load(from: defaults)
    }
#endif

    /// The chat Files panel's per-session Changed / All tab, gone with the
    /// Changed tab. Launch removes what an older build stored there.
    nonisolated static func removeRetiredPanelTabs(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: "\(AppIdentifiers.subsystem).chatFileBrowser.selectedTabsBySession")
    }

    func update(_ change: (inout FileBrowserViewOptions) -> Void) {
        var next = options
        change(&next)
        guard next != options else { return }
        options = next
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

/// Where a browser search looks: the whole checkout, or the folder on screen
/// and below it.
enum FileBrowserSearchScope: Int, Sendable {
    case everywhere = 0
    case folder = 1

    /// The scope bar's titles while a folder below the root is on screen;
    /// at the root both scopes are the same, so there is no bar.
    static func titles(folderName: String?) -> [String]? {
        guard let folderName else { return nil }
        return [String(localized: "Everywhere"), folderName]
    }

    /// The index paths a search in this scope ranks.
    func candidates(_ paths: [String], folder: String) -> [String] {
        guard self == .folder, !folder.isEmpty, folder != "/" else { return paths }
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return paths.filter { $0.hasPrefix(prefix) }
    }
}
