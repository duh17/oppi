import Foundation

@MainActor
final class ChatTimelineControllerContext {
    var sessionId = ""
    var workspaceId: String?
    var onFork: ((String) -> Void)?
    var onShowEarlier: (() -> Void)?
    weak var scrollController: ChatScrollController?
    var reducer: TimelineReducer?
    var toolOutputStore: ToolOutputStore?
    var toolArgsStore: ToolArgsStore?
    var toolSegmentStore: ToolSegmentStore?
    var toolDetailsStore: ToolDetailsStore?
    var connection: ServerConnection?
    var currentModel: String?
    var currentThemeID: ThemeID = .dark
    var selectedTextPiRouter: SelectedTextPiActionRouter?
    var piQuickActionStore: PiQuickActionStore?

    func didChangeSessionScope(for configuration: ChatTimelineCollectionHost.Configuration) -> Bool {
        sessionId != configuration.sessionId || workspaceId != configuration.workspaceId
    }

    func apply(configuration: ChatTimelineCollectionHost.Configuration) {
        sessionId = configuration.sessionId
        workspaceId = configuration.workspaceId
        onFork = configuration.onFork
        onShowEarlier = configuration.onShowEarlier
        scrollController = configuration.scrollController
        reducer = configuration.reducer
        toolOutputStore = configuration.toolOutputStore
        toolArgsStore = configuration.toolArgsStore
        toolSegmentStore = configuration.toolSegmentStore
        toolDetailsStore = configuration.toolDetailsStore
        connection = configuration.connection
        currentModel = configuration.currentModel
        currentThemeID = configuration.themeID
        selectedTextPiRouter = configuration.selectedTextPiRouter
        piQuickActionStore = configuration.piQuickActionStore
    }
}
