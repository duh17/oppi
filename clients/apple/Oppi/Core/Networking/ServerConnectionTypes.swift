import Foundation

// MARK: - Fork Types

struct ForkMessage: Equatable, Sendable {
    let entryId: String
    let text: String
}

// MARK: - Session Tree Types

enum SessionTreeFilterMode: String, CaseIterable, Sendable {
    case standard = "default"
    case noTools = "no-tools"
    case userOnly = "user-only"
    case labeledOnly = "labeled-only"
    case all = "all"

    var title: String {
        switch self {
        case .standard: return "Default"
        case .noTools: return "No Tools"
        case .userOnly: return "Users"
        case .labeledOnly: return "Labeled"
        case .all: return "All"
        }
    }
}

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
    let contextComposition: SessionContextCompositionSnapshot?
    let loadedResources: SessionLoadedResourcesSnapshot?
}

// MARK: - Extension UI Surface

struct ExtensionWidgetState: Equatable, Sendable {
    let key: String
    var lines: [String]
    var placement: String?
    var order: Int = 0
}

struct ExtensionNativeSurfaceState: Equatable, Sendable, Identifiable {
    let key: String
    let surface: ExtensionUINativeSurface
    var placement: String?
    var order: Int = 0

    var id: String { surface.id }

    var hasVisibleContent: Bool {
        surface.hasVisibleContent
    }
}

struct ExtensionWorkingState: Equatable, Sendable {
    var message: String?
    var visible: Bool = true
    var indicator: ExtensionUIWorkingIndicator?

    var isDefault: Bool {
        (message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && visible
            && indicator == nil
    }
}

struct ExtensionSurfaceState: Equatable, Sendable {
    var title: String?
    var statuses: [String: String]
    var widgets: [String: ExtensionWidgetState]
    var nativeSurfaces: [String: ExtensionNativeSurfaceState]
    var widgetOrderCursor: Int
    var working: ExtensionWorkingState?
    var hiddenThinkingLabel: String?
    var toolsExpanded: Bool?

    init(
        title: String? = nil,
        statuses: [String: String] = [:],
        widgets: [String: ExtensionWidgetState] = [:],
        nativeSurfaces: [String: ExtensionNativeSurfaceState] = [:],
        widgetOrderCursor: Int = 0,
        working: ExtensionWorkingState? = nil,
        hiddenThinkingLabel: String? = nil,
        toolsExpanded: Bool? = nil
    ) {
        self.title = title
        self.statuses = statuses
        self.widgets = widgets
        self.nativeSurfaces = nativeSurfaces
        self.widgetOrderCursor = widgetOrderCursor
        self.working = working
        self.hiddenThinkingLabel = hiddenThinkingLabel
        self.toolsExpanded = toolsExpanded
    }

    var hasVisibleContent: Bool {
        let hasTitle = !(title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasStatuses = !statuses.isEmpty
        let hasWidgets = widgets.values.contains { !$0.lines.isEmpty }
        let hasNativeSurfaces = nativeSurfaces.values.contains { $0.hasVisibleContent }
        return hasTitle || hasStatuses || hasWidgets || hasNativeSurfaces
    }

    var hasRetainedContent: Bool {
        hasVisibleContent
            || working?.isDefault == false
            || !(hiddenThinkingLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || toolsExpanded != nil
    }

    mutating func nextWidgetOrder() -> Int {
        widgetOrderCursor += 1
        return widgetOrderCursor
    }
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
