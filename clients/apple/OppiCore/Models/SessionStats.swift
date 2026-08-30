import Foundation

/// Token totals from `get_session_stats`. UIKit-free so iOS and Mac share one parse.
struct SessionTokenStats: Equatable, Sendable {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let total: Int

    /// Complete prompt volume billed or served from cache.
    var promptInput: Int { input + cacheRead + cacheWrite }

    /// Prompt volume that was not served from cache. Cache writes are uncached work.
    var uncachedInput: Int { input + cacheWrite }

    var cacheHitRate: Double? {
        guard promptInput > 0 else { return nil }
        return Double(cacheRead) / Double(promptInput)
    }
}

struct SessionCacheWasteSnapshot: Equatable, Sendable {
    let missedTokens: Int
    let missedCost: Double
    let missCount: Int
}

struct SessionModelUsageSnapshot: Equatable, Sendable, Identifiable {
    let provider: String?
    let model: String
    let tokens: Int
    let cost: Double

    var id: String { provider.map { "\($0)/\(model)" } ?? model }
}

struct ContextFileTokenSnapshot: Equatable, Sendable {
    let path: String
    let chars: Int
    let tokens: Int
}

struct SessionContextCompositionSnapshot: Equatable, Sendable {
    let piSystemPromptChars: Int
    let piSystemPromptTokens: Int
    let agentsChars: Int
    let agentsTokens: Int
    let agentsFiles: [ContextFileTokenSnapshot]
    let skillsListingChars: Int
    let skillsListingTokens: Int
}

struct SessionResourceSnapshot: Equatable, Sendable, Identifiable {
    let name: String
    let description: String?
    let path: String

    var id: String { path.isEmpty ? name : path }
}

struct SessionLoadedResourcesSnapshot: Equatable, Sendable {
    let skills: [SessionResourceSnapshot]
    let extensions: [SessionResourceSnapshot]
}

struct SessionStatsSnapshot: Equatable, Sendable {
    let tokens: SessionTokenStats
    let cost: Double
    let cacheWaste: SessionCacheWasteSnapshot?
    let modelBreakdown: [SessionModelUsageSnapshot]
    let contextComposition: SessionContextCompositionSnapshot?
    let loadedResources: SessionLoadedResourcesSnapshot?
}

extension SessionStatsSnapshot {
    /// Session-row totals when `get_session_stats` has not returned yet.
    static func fallback(from session: Session) -> SessionStatsSnapshot {
        let input = max(session.tokens.input, 0)
        let output = max(session.tokens.output, 0)
        let cacheRead = max(session.tokens.cacheRead ?? 0, 0)
        let cacheWrite = max(session.tokens.cacheWrite ?? 0, 0)
        return SessionStatsSnapshot(
            tokens: SessionTokenStats(
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                total: input + output + cacheRead + cacheWrite
            ),
            cost: max(session.cost, 0),
            cacheWaste: nil,
            modelBreakdown: [],
            contextComposition: nil,
            loadedResources: nil
        )
    }
}
