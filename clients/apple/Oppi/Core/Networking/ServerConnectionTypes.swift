import Foundation

// MARK: - Fork Types

struct ForkMessage: Equatable, Sendable {
    let entryId: String
    let text: String
}

// MARK: - Session Tree Types

struct SessionTreeNodeSnapshot: Equatable, Sendable {
    let id: String
    let parentId: String?
    let type: String
    let timestamp: String
    let depth: Int
    let isLeafPath: Bool
    let defaultVisible: Bool
    let matchesFilter: Bool
    let role: String?
    let textPreview: String?
    let label: String?

    init(
        id: String,
        parentId: String?,
        type: String,
        timestamp: String,
        depth: Int,
        isLeafPath: Bool,
        defaultVisible: Bool = true,
        matchesFilter: Bool? = nil,
        role: String?,
        textPreview: String?,
        label: String?
    ) {
        self.id = id
        self.parentId = parentId
        self.type = type
        self.timestamp = timestamp
        self.depth = depth
        self.isLeafPath = isLeafPath
        self.defaultVisible = defaultVisible
        self.matchesFilter = matchesFilter ?? defaultVisible
        self.role = role
        self.textPreview = textPreview
        self.label = label
    }
}

struct SessionTreeSnapshot: Equatable, Sendable {
    let leafId: String?
    let nodes: [SessionTreeNodeSnapshot]
}

struct NavigateTreeSummaryEntrySnapshot: Equatable, Sendable {
    let id: String
}

struct NavigateTreeResult: Equatable, Sendable {
    let editorText: String?
    let cancelled: Bool
    let aborted: Bool?
    let summaryEntry: NavigateTreeSummaryEntrySnapshot?
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
