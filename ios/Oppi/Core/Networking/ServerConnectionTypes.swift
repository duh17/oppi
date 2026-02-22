import Foundation

// MARK: - Fork Types

struct ForkMessage: Equatable, Sendable {
    let entryId: String
    let text: String
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
