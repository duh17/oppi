import Foundation

@MainActor
final class ChatTimelineControllerContext {
    var sessionId = ""
    var serverId: String?
    var workspaceId: String?
    var agentId: String?
    var agentIcon: IconChoice?
    var routeScope: SessionRouteScope?
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
    var extensionWorkingState: ExtensionWorkingState?
    var extensionHiddenThinkingLabel: String?
    var audioLifecycleCoordinator: AudioLifecycleCoordinator?
    let interactionContext = TimelineInteractionContext()

    func didChangeSessionScope(for configuration: ChatTimelineCollectionHost.Configuration) -> Bool {
        sessionId != configuration.sessionId
            || serverId != configuration.serverId
            || workspaceId != configuration.workspaceId
            || routeScope != configuration.routeScope
    }

    func didChangeAgentPresentation(
        for configuration: ChatTimelineCollectionHost.Configuration
    ) -> Bool {
        agentId != configuration.agentId || agentIcon != configuration.agentIcon
    }

    func apply(configuration: ChatTimelineCollectionHost.Configuration) {
        sessionId = configuration.sessionId
        serverId = configuration.serverId
        workspaceId = configuration.workspaceId
        agentId = configuration.agentId
        agentIcon = configuration.agentIcon
        routeScope = configuration.routeScope
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
        extensionWorkingState = configuration.extensionWorkingState
        extensionHiddenThinkingLabel = configuration.extensionHiddenThinkingLabel
        audioLifecycleCoordinator = configuration.audioLifecycleCoordinator
        interactionContext.reviewCommentSelectionRouter = configuration.reviewCommentSelectionRouter
        interactionContext.sessionId = configuration.sessionId
    }
}
