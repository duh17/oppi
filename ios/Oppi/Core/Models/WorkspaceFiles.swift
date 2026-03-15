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
    var isFile: Bool { type == .file }

    /// Human-readable file size.
    var formattedSize: String {
        if isDirectory { return "" }
        if size < 1024 { return "\(size) B" }
        let kb = Double(size) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        return String(format: "%.1f MB", mb)
    }
}

enum FileEntryType: String, Decodable, Sendable, Equatable, Hashable {
    case file
    case directory
}

struct DirectoryListingResponse: Decodable, Sendable, Equatable {
    let path: String
    let entries: [FileEntry]
    let truncated: Bool
}

struct FileSearchResponse: Decodable, Sendable, Equatable {
    let query: String
    let entries: [FileEntry]
    let truncated: Bool
}
