import Foundation

// MARK: - Fork Types

struct ForkMessage: Equatable, Sendable {
    let entryId: String
    let text: String
}

// MARK: - Session Stats Types

struct SessionTokenStats: Equatable, Sendable {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let total: Int
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
}

struct SessionStatsSnapshot: Equatable, Sendable {
    let tokens: SessionTokenStats
    let cost: Double
    let contextComposition: SessionContextCompositionSnapshot?
}

// MARK: - Error Types

enum ForkRequestError: LocalizedError, Equatable {
    case turnInProgress
    case noForkableMessages
    case entryNotForkable

    var errorDescription: String? {
        switch self {
        case .turnInProgress:
            return "Wait for this turn to finish before forking."
        case .noForkableMessages:
            return "No user messages available for forking yet."
        case .entryNotForkable:
            return "That message cannot be forked. Pick a user message from history."
        }
    }
}
