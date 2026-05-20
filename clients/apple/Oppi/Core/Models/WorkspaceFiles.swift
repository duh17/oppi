import Foundation

/// Models for the workspace file browser API.
///
/// Mirrors `FileEntry`, `DirectoryListingResponse`, and `FileIndexResponse`
/// from `server/src/types.ts`.

struct FileEntry: Codable, Sendable, Equatable, Identifiable, Hashable {
    let name: String
    let type: FileEntryType
    let size: Int
    let modifiedAt: Int
    /// Workspace-relative path when the caller needs full context.
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

    /// Relative modification time (e.g. "2m ago", "yesterday").
    var relativeModifiedTime: String {
        let date = Date(timeIntervalSince1970: Double(modifiedAt) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Whether the file was modified within the last 5 minutes.
    var isRecentlyModified: Bool {
        let date = Date(timeIntervalSince1970: Double(modifiedAt) / 1000)
        return Date().timeIntervalSince(date) < 300
    }
}

enum FileEntryType: String, Codable, Sendable, Equatable, Hashable {
    case file
    case directory
}

struct DirectoryListingResponse: Codable, Sendable, Equatable {
    let path: String
    let entries: [FileEntry]
    let truncated: Bool
}

/// Flat file index for client-side fuzzy search.
/// Mirrors `FileIndexResponse` from `server/src/types.ts`.
struct FileIndexResponse: Decodable, Sendable, Equatable {
    let paths: [String]
    let truncated: Bool
}
