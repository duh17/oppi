import Foundation

/// Display-only stash location. Compact rows keep the shortest trailing path
/// that distinguishes this comment's file from other distinct files in the
/// current stash, plus the line range. Complete location stays available for
/// accessibility and the editor.
enum ReviewCommentStashLocation {
    static func completeText(for comment: ReviewComment) -> String {
        locationText(for: comment, displayedPath: comment.reference.displayPath)
    }

    static func compactText(for comment: ReviewComment, among comments: [ReviewComment]) -> String {
        let displayedPath: String?
        if let path = comment.reference.displayPath, !path.isEmpty {
            displayedPath = uniqueTrailingPath(path, among: distinctDisplayPaths(in: comments))
        } else {
            displayedPath = nil
        }
        return locationText(for: comment, displayedPath: displayedPath)
    }

    private static func locationText(for comment: ReviewComment, displayedPath: String?) -> String {
        if let displayedPath, !displayedPath.isEmpty {
            return displayedPath + lineRangeSuffix(comment.reference)
        }
        if let label = comment.reference.label, !label.isEmpty {
            return label
        }
        return sourceText(comment.reference.source)
    }

    private static func distinctDisplayPaths(in comments: [ReviewComment]) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for comment in comments {
            guard let path = comment.reference.displayPath, !path.isEmpty else { continue }
            if seen.insert(path).inserted {
                paths.append(path)
            }
        }
        return paths
    }

    private static func uniqueTrailingPath(_ path: String, among paths: [String]) -> String {
        let components = pathComponents(path)
        guard !components.isEmpty else { return path }
        let others = paths.filter { $0 != path }
        for count in 1...components.count {
            let suffix = components.suffix(count).joined(separator: "/")
            let collides = others.contains { other in
                trailing(other, count: count) == suffix
            }
            if !collides {
                return suffix
            }
        }
        return path
    }

    private static func trailing(_ path: String, count: Int) -> String {
        let components = pathComponents(path)
        guard !components.isEmpty else { return "" }
        let take = min(count, components.count)
        return components.suffix(take).joined(separator: "/")
    }

    private static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func lineRangeSuffix(_ reference: ReviewCommentReference) -> String {
        guard let startLine = reference.startLine else { return "" }
        var text = ":\(startLine)"
        if let endLine = reference.endLine, endLine != startLine {
            text += "-\(endLine)"
        }
        return text
    }

    private static func sourceText(_ source: ReviewCommentReferenceSource) -> String {
        switch source {
        case .gitDiff: return "Diff"
        case .file: return "File"
        case .timelineText: return "Timeline"
        case .toolOutput: return "Tool output"
        case .terminalOutput: return "Terminal"
        case .image: return "Image"
        case .unknown: return "Review comment"
        }
    }
}
