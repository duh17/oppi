import Foundation

extension String {
    /// Shorten absolute paths for display: /Users/foo/workspace → ~/workspace
    var shortenedPath: String {
        if hasPrefix("/Users/") {
            let parts = split(separator: "/", maxSplits: 3)
            if parts.count > 2 {
                return "~/" + parts.dropFirst(2).joined(separator: "/")
            }
        }
        return self
    }

    /// Convert a path into a workspace-relative path suitable for workspace/session file APIs.
    ///
    /// - Relative inputs stay relative (with leading `./` trimmed).
    /// - Absolute inputs are relativized against `hostMount` when they live inside that workspace.
    /// - Paths outside the workspace return `nil`.
    func workspaceRelativePath(hostMount: String?) -> String? {
        var normalized = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        normalized = normalized.replacingOccurrences(of: "\\", with: "/")
        while normalized.hasPrefix("./") {
            normalized.removeFirst(2)
        }

        if !normalized.hasPrefix("/") && !normalized.hasPrefix("~") {
            return normalized.isEmpty ? nil : normalized
        }

        guard let hostMount, !hostMount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let expandedRoot = NSString(string: hostMount).expandingTildeInPath
        let expandedPath = NSString(string: normalized).expandingTildeInPath
        let rootPath = URL(fileURLWithPath: expandedRoot).standardizedFileURL.path
        let absolutePath = URL(fileURLWithPath: expandedPath).standardizedFileURL.path

        guard absolutePath == rootPath || absolutePath.hasPrefix(rootPath + "/") else {
            return nil
        }

        let relative = String(absolutePath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? nil : relative
    }

    var lastPathComponentForDisplay: String {
        let normalized = normalizedDisplayPath
        guard !normalized.isEmpty else { return normalized }
        let components = normalized.split(separator: "/")
        return components.last.map(String.init) ?? normalized
    }

    var parentPathForDisplay: String? {
        let normalized = normalizedDisplayPath
        guard !normalized.isEmpty else { return nil }
        let components = normalized.split(separator: "/")
        guard components.count > 1 else { return nil }
        return components.dropLast().joined(separator: "/")
    }

    // periphery:ignore
    func localizedTreePathCompare(to other: String) -> ComparisonResult {
        let lhsComponents = normalizedTreePathComponents
        let rhsComponents = other.normalizedTreePathComponents
        let sharedCount = min(lhsComponents.count, rhsComponents.count)

        for index in 0..<sharedCount {
            let result = lhsComponents[index].localizedCaseInsensitiveCompare(rhsComponents[index])
            if result != .orderedSame {
                return result
            }
        }

        if lhsComponents.count == rhsComponents.count {
            return .orderedSame
        }

        return lhsComponents.count < rhsComponents.count ? .orderedAscending : .orderedDescending
    }

    private var normalizedDisplayPath: String {
        var normalized = shortenedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    // periphery:ignore
    private var normalizedTreePathComponents: [String] {
        var normalized = trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasPrefix("./") {
            normalized.removeFirst(2)
        }
        normalized = normalized.replacingOccurrences(of: "\\", with: "/")
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized.split(separator: "/").map(String.init)
    }
}
