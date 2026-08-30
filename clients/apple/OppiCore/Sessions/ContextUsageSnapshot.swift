import Foundation

/// Context fill from the session row. Chip chrome uses this before stats load.
struct ContextUsageSnapshot: Sendable, Equatable {
    let tokens: Int?
    let window: Int?

    var progress: Double? {
        guard let tokens, let window, window > 0 else { return nil }
        return min(max(Double(tokens) / Double(window), 0), 1)
    }

    var percentText: String {
        guard let progress else { return "Unknown" }
        return String(format: "%.1f%%", progress * 100)
    }

    var usageText: String {
        guard let window, window > 0 else { return "Unknown" }
        guard let tokens else { return "— / \(SessionFormatting.tokenCount(window))" }
        return "\(SessionFormatting.tokenCount(tokens)) / \(SessionFormatting.tokenCount(window))"
    }

    var usedTokens: Int { max(tokens ?? 0, 0) }

    var windowTokens: Int { max(window ?? 0, 0) }

    var remainingTokens: Int { max(windowTokens - usedTokens, 0) }

    var accessibilityLabel: String {
        guard let window, window > 0 else {
            return "Context usage unavailable"
        }
        guard let tokens else {
            return "Context usage unknown out of \(window) tokens"
        }
        let percent = Int(((Double(tokens) / Double(window)) * 100).rounded())
        return "Context usage \(percent) percent, \(tokens) of \(window) tokens"
    }
}

enum SessionContextUsagePresentation {
    static func snapshot(for session: Session?) -> ContextUsageSnapshot {
        ContextUsageSnapshot(
            tokens: session?.contextTokens,
            window: session?.contextWindow
        )
    }

    /// Toolbar chip copy. Prefer session tokens; "Context" only when nothing is known.
    static func toolbarTitle(_ snapshot: ContextUsageSnapshot) -> String {
        if snapshot.tokens == nil && snapshot.windowTokens == 0 {
            return "Context"
        }
        return snapshot.usageText
    }
}
