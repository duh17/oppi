import Foundation

struct FileSuggestion: Sendable, Equatable, Identifiable {
    let path: String
    let isDirectory: Bool
    /// Unicode scalar indices of matched characters for highlighting.
    var matchPositions: [Int] = []

    var id: String { path }

    var displayName: String {
        normalizedPath.split(separator: "/").last.map(String.init) ?? normalizedPath
    }

    var parentPath: String? {
        guard let lastSlash = normalizedPath.lastIndex(of: "/") else {
            return nil
        }
        return String(normalizedPath[normalizedPath.startIndex...lastSlash])
    }

    private var normalizedPath: String {
        guard isDirectory, path.hasSuffix("/") else {
            return path
        }
        return String(path.dropLast())
    }
}
