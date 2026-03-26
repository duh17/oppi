/// Models for the workspace file browser API.
///
/// Mirrors `FileEntry`, `DirectoryListingResponse`, and `FileSearchResponse`
/// from `server/src/types.ts`.

struct FileEntry: Decodable, Sendable, Equatable, Identifiable, Hashable {
    let name: String
    let type: FileEntryType
    let size: Int
    let modifiedAt: Int
    /// Workspace-relative path (present in search results).
    let path: String?

    var id: String { path ?? name }

    var isDirectory: Bool { type == .directory }
    // periphery:ignore
    var isFile: Bool { type == .file }

    /// Human-readable file size.
    var formattedSize: String {
        if isDirectory { return "" }
        return SessionFormatting.byteCount(size)
    }
}

enum FileEntryType: String, Decodable, Sendable, Equatable, Hashable {
    case file
    case directory
}

struct DirectoryListingResponse: Decodable, Sendable, Equatable {
    let path: String
    let entries: [FileEntry]
    /// Total entries in the directory (before pagination, after filtering).
    let total: Int
    let truncated: Bool

    /// Whether there are more entries beyond the current page.
    var hasMore: Bool { entries.count < total }
}

// periphery:ignore
struct FileSearchResponse: Decodable, Sendable, Equatable {
    let query: String
    let entries: [FileEntry]
    let truncated: Bool
}

/// Flat file index for client-side fuzzy search.
/// Mirrors `FileIndexResponse` from `server/src/types.ts`.
struct FileIndexResponse: Decodable, Sendable, Equatable {
    let paths: [String]
    let truncated: Bool
}
