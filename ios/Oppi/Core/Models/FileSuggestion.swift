import Foundation

struct FileSuggestion: Sendable, Equatable, Identifiable {
    let path: String
    let isDirectory: Bool

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

struct FileSuggestionResult: Sendable, Equatable {
    let items: [FileSuggestion]
    let truncated: Bool

    static func from(_ data: JSONValue?) -> Self? {
        guard case .object(let object) = data else {
            return nil
        }

        let truncated = object["truncated"]?.boolValue ?? false

        guard case .array(let rawItems) = object["items"] else {
            return Self(items: [], truncated: truncated)
        }

        let items = rawItems.compactMap(FileSuggestion.from)
        return Self(items: items, truncated: truncated)
    }
}

private extension FileSuggestion {
    static func from(_ value: JSONValue) -> Self? {
        guard case .object(let object) = value,
              case .string(let path) = object["path"],
              case .bool(let isDirectory) = object["isDirectory"] else {
            return nil
        }

        return Self(path: path, isDirectory: isDirectory)
    }
}
