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
}
