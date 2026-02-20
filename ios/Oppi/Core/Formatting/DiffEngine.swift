import Foundation

// MARK: - DiffLine

struct DiffLine: Sendable {
    let kind: Kind
    let text: String

    enum Kind: Sendable {
        case context
        case added
        case removed

        var prefix: String {
            switch self {
            case .context: return " "
            case .added: return "+"
            case .removed: return "-"
            }
        }
    }
}

// MARK: - DiffEngine

/// Line-level LCS diff algorithm.
///
/// Uses classic O(n*m) dynamic programming. Fine for Edit tool changes
/// which are typically 1-50 lines.
enum DiffEngine {

    /// Maximum DP cell count before we fall back to a linear diff.
    ///
    /// LCS is O(n*m); this guard prevents UI stalls on very large edits.
    private static let maxLcsCells = 250_000

    /// Compute a unified diff between old and new text.
    static func compute(old: String, new: String) -> [DiffLine] {
        let oldTrimmed = splitLines(old)
        let newTrimmed = splitLines(new)

        let cellCount = oldTrimmed.count * newTrimmed.count
        if cellCount > maxLcsCells {
            return fallbackDiff(old: oldTrimmed, new: newTrimmed)
        }

        return lcs(old: oldTrimmed, new: newTrimmed)
    }

    /// Format diff lines as unified diff text.
    static func formatUnified(_ lines: [DiffLine]) -> String {
        lines.map { line in
            switch line.kind {
            case .context: return "  \(line.text)"
            case .added: return "+ \(line.text)"
            case .removed: return "- \(line.text)"
            }
        }.joined(separator: "\n")
    }

    /// Count added and removed lines.
    static func stats(_ lines: [DiffLine]) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for line in lines {
            switch line.kind {
            case .added: added += 1
            case .removed: removed += 1
            case .context: break
            }
        }
        return (added, removed)
    }

    // MARK: - LCS Algorithm

    private static func lcs(old: [String], new: [String]) -> [DiffLine] {
        let m = old.count
        let n = new.count

        // Edge cases
        if m == 0, n == 0 { return [] }
        if m == 0 { return new.map { DiffLine(kind: .added, text: $0) } }
        if n == 0 { return old.map { DiffLine(kind: .removed, text: $0) } }

        // Build LCS table
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0..<m {
            for j in 0..<n {
                if old[i] == new[j] {
                    dp[i + 1][j + 1] = dp[i][j] + 1
                } else {
                    dp[i + 1][j + 1] = max(dp[i][j + 1], dp[i + 1][j])
                }
            }
        }

        // Backtrace to produce diff
        var result: [DiffLine] = []
        var i = m, j = n

        while i > 0 || j > 0 {
            if i > 0, j > 0, old[i - 1] == new[j - 1] {
                result.append(DiffLine(kind: .context, text: old[i - 1]))
                i -= 1; j -= 1
            } else if j > 0, i == 0 || dp[i][j - 1] >= dp[i - 1][j] {
                result.append(DiffLine(kind: .added, text: new[j - 1]))
                j -= 1
            } else {
                result.append(DiffLine(kind: .removed, text: old[i - 1]))
                i -= 1
            }
        }

        return result.reversed()
    }

    /// Linear-time fallback used when LCS would be too expensive.
    private static func fallbackDiff(old: [String], new: [String]) -> [DiffLine] {
        var lines: [DiffLine] = []
        lines.reserveCapacity(old.count + new.count)

        for line in old {
            lines.append(DiffLine(kind: .removed, text: line))
        }
        for line in new {
            lines.append(DiffLine(kind: .added, text: line))
        }

        return lines
    }

    /// Split text into lines, handling empty strings and trailing newlines.
    private static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Trailing newline produces a spurious empty last element — trim it
        if lines.count > 1, lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }
}
