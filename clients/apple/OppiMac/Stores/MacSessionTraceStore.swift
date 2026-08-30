import Foundation
import OSLog

private let macSessionTraceLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "OppiMac",
    category: "MacSessionTraceStore"
)

enum MacSessionTraceStoreError: LocalizedError, Equatable {
    case commandRejected(String)

    var errorDescription: String? {
        switch self {
        case .commandRejected(let message):
            message
        }
    }
}

@MainActor @Observable
final class MacSessionTraceStore {
    private let messageQueueStore = MessageQueueStore()
    private let fallbackToolOutputStore = ToolOutputStore()
    private let fallbackToolArgsStore = ToolArgsStore()
    private let fallbackToolDetailsStore = ToolDetailsStore()
    private let reviewComments: ReviewCommentStore
    private let keybindingPreferences = KeybindingPreferenceStore()

    private var runtimeAdapter: MacChatSessionRuntimeAdapter?
    private var sessionManager: ChatSessionManager?
    private var sessionRuntimeTask: Task<Void, Never>?
    private var pendingCommandChanges: [String: MacSessionCommandPendingChange] = [:]
    private enum CommandAck {
        case expected
        case waiting(CheckedContinuation<Void, Error>)
        case finished(Result<Void, Error>)
    }

    private var pendingCommandAcks: [String: CommandAck] = [:]
    private var fileIndexWorkspaceId: String?
    private var fileIndexRequestId: String?
    private var sessionChangesRequestId: String?
    private var sessionDiffRequestId: String?
    private var sessionFilePreviewRequestId: String?
    private var sessionOutlineRequestId: String?
    private var fullToolOutputLoadsInFlight: Set<String> = []

    var _sendLiveMessageForTesting: ((ClientMessage) async throws -> Bool)?
    var _listModelsForTesting: (() async throws -> [ModelInfo])?
    var _commandAckTimeoutForTesting: Duration?
    var _sessionRuntimeInstallGateForTesting: (@MainActor () async -> Void)?

    private(set) var selectedTarget: MacSelectedSessionTarget?
    private(set) var session: Session?
    private(set) var isLoading = false
    private(set) var isSending = false
    private(set) var isPreparingAttachments = false
    private(set) var attachmentPreparationText: String?
    private(set) var isUpdatingThinkingLevel = false
    private(set) var isUpdatingModel = false
    private(set) var isLoadingModels = false
    private(set) var isLoadingFileIndex = false
    private(set) var isLoadingSessionChanges = false
    private(set) var isLoadingSessionDiff = false
    private(set) var isLoadingSessionFilePreview = false
    private(set) var isLoadingSessionOutline = false
    private(set) var isRefreshingQueue = false
    private(set) var isUpdatingQueue = false
    private(set) var isStreaming = false
    private(set) var isResumingSession = false
    private(set) var isStoppingTurn = false
    private(set) var availableModels: [ModelInfo] = []
    private(set) var fileIndexPaths: [String] = []
    private(set) var slashCommands: [SlashCommand] = []
    private(set) var isLoadingSlashCommands = false
    private(set) var slashCommandsError: String?
    private var slashCommandsCacheKey: String?
    private var slashCommandsRequestId: String?
    private(set) var sessionStats: SessionStatsSnapshot?
    private(set) var isLoadingSessionStats = false
    private(set) var sessionStatsError: String?
    private var sessionStatsRequestId: String?
    private(set) var sessionChangedFiles: [SessionChangedFile] = []
    private(set) var sessionChangedFileCount = 0
    private(set) var sessionChangedFilesOverflow = 0
    private(set) var selectedSessionDiff: WorkspaceReviewDiffResponse?
    private(set) var selectedSessionFilePreview: MacSessionFilePreview?
    private(set) var pendingAskRequests: [AskRequest] = []
    private(set) var extensionSurface = ExtensionSurfaceState()
    var busyStreamingBehavior: StreamingBehavior = .followUp
    /// Reads persisted mode for every key event so open timelines update live.
    var keybindingMode: KeybindingMode {
        get { keybindingPreferences.mode }
        set { keybindingPreferences.mode = newValue }
    }
    /// Composer is the safe default so unmodified letters are not consumed.
    var keybindingFocus: KeybindingFocus = .composer
    /// Session-owned tool-row selection. Clicking a row focuses the timeline.
    private(set) var selectedToolRowID: String?
    /// Session-owned expansion. Tool rows must not keep a local `@State`.
    private(set) var expandedToolRowIDs: Set<String> = []
    /// Wide document column beside the timeline. Nil means the column is closed.
    private(set) var openToolDocumentID: String?
    /// Full-session outline from `GET .../trace-outline`. Nil until loaded.
    private(set) var sessionOutline: SessionOutlineSnapshot?
    private(set) var sessionOutlineError: String?
    /// Timeline row the outline asked to reveal. The scroll view consumes it.
    private(set) var scrollTargetID: String?
    /// Selection waiting for a Mac comment sheet. Nil means no draft is open.
    private(set) var pendingReviewCommentDraft: MacReviewCommentDraft?
    private(set) var messageQueueError: String?
    private(set) var modelLoadError: String?
    private(set) var fileIndexError: String?
    private(set) var sessionChangesError: String?
    private(set) var sessionDiffError: String?
    private(set) var sessionFilePreviewError: String?
    private(set) var lastError: String?
    private(set) var resumeError: String?
    private(set) var lastLoadedAt: Date?

    var items: [ChatItem] { sessionManager?.reducer.items ?? [] }
    var toolOutputStore: ToolOutputStore {
        sessionManager?.reducer.toolOutputStore ?? fallbackToolOutputStore
    }
    var toolArgsStore: ToolArgsStore {
        sessionManager?.reducer.toolArgsStore ?? fallbackToolArgsStore
    }
    var toolDetailsStore: ToolDetailsStore {
        sessionManager?.reducer.toolDetailsStore ?? fallbackToolDetailsStore
    }
    func toolCallSegments(for id: String) -> [StyledSegment]? {
        sessionManager?.reducer.toolSegmentStore.callSegments(for: id)
    }
    func toolResultSegments(for id: String) -> [StyledSegment]? {
        sessionManager?.reducer.toolSegmentStore.resultSegments(for: id)
    }
    func toolStartTime(for id: String) -> Date? {
        sessionManager?.reducer.toolStartTime(for: id)
    }
    func toolElapsed(for id: String) -> Int? {
        sessionManager?.reducer.toolElapsed(for: id)
    }
    func isToolInterrupted(_ id: String) -> Bool {
        sessionManager?.reducer.isToolInterrupted(id) ?? false
    }
    var currentAskRequest: AskRequest? { pendingAskRequests.first }
    var messageQueue: MessageQueueState { messageQueueStore.queue(for: selectedTarget?.sessionId) }

    var showsMessageQueue: Bool {
        session?.status == .busy || !messageQueue.steering.isEmpty || !messageQueue.followUp.isEmpty
    }

    var thinkingLevel: ThinkingLevel {
        ThinkingLevel(sessionValue: session?.thinkingLevel)
    }

    var canSendMessage: Bool {
        guard !isSending, let session else { return false }
        switch session.status {
        case .starting, .ready, .busy:
            return true
        case .stopping, .stopped, .error:
            return false
        }
    }

    var stagedReviewComments: [ReviewComment] { reviewComments.stagedComments }
    var stagedReviewCommentCount: Int { reviewComments.stagedCount }
    var hasStagedReviewComments: Bool { stagedReviewCommentCount > 0 }

    init(reviewComments: ReviewCommentStore = ReviewCommentStore()) {
        self.reviewComments = reviewComments
    }

    #if DEBUG
    var _chatSessionManagerForTesting: ChatSessionManager? { sessionManager }
    var _runtimeAdapterForTesting: MacChatSessionRuntimeAdapter? { runtimeAdapter }
    var _sessionRuntimeLoopRunningForTesting: Bool { sessionRuntimeTask != nil }

    func installSessionRuntimeForTesting(client: MacWorkspaceClient) async {
        guard let selectedTarget else { return }
        await installSessionRuntime(target: selectedTarget, client: client)
    }

    func loadSelectedFromLocalConfigForTesting(client: MacWorkspaceClient) async {
        guard let selectedTarget else { return }
        await loadSelectedSession(target: selectedTarget, client: client)
    }

    func startSessionRuntimeLoopForTesting() {
        startSessionRuntimeLoop()
    }

    func ensureFocusedStreamConnectingForTesting() {
        ensureFocusedStreamConnecting()
    }
    #endif

    func select(_ target: MacSelectedSessionTarget) {
        guard selectedTarget != target else { return }
        tearDownRuntime()
        resetTimelineKeybindingState()
        selectedTarget = target
        session = target.summary.session
        isLoading = false
        isResumingSession = false
        resetSessionOperationState()
        lastError = nil
        resumeError = nil
        failPendingCommandAcks(MacSessionTraceStoreError.commandRejected("Session selection changed."))
        fullToolOutputLoadsInFlight = []
        pendingCommandChanges = [:]
        pendingAskRequests = []
        extensionSurface = ExtensionSurfaceState()
        messageQueueError = nil
        fileIndexError = nil
        sessionChangesError = nil
        sessionDiffError = nil
        sessionFilePreviewError = nil
        sessionChangedFiles = []
        sessionChangedFileCount = 0
        sessionChangedFilesOverflow = 0
        selectedSessionDiff = nil
        selectedSessionFilePreview = nil
        if fileIndexWorkspaceId != target.workspaceId {
            fileIndexRequestId = nil
            isLoadingFileIndex = false
            fileIndexWorkspaceId = nil
            fileIndexPaths = []
        }
        resetSlashCommands()
        resetSessionStats()
        resetSessionOutline()
        messageQueueStore.clear(sessionId: target.sessionId)
        pendingReviewCommentDraft = nil
        loadReviewComments()
    }

    func clearSelection() {
        tearDownRuntime()
        resetTimelineKeybindingState()
        let previousSessionId = selectedTarget?.sessionId
        selectedTarget = nil
        session = nil
        isLoading = false
        isResumingSession = false
        resetSessionOperationState()
        lastError = nil
        resumeError = nil
        failPendingCommandAcks(MacSessionTraceStoreError.commandRejected("Session selection cleared."))
        fullToolOutputLoadsInFlight = []
        pendingCommandChanges = [:]
        pendingAskRequests = []
        extensionSurface = ExtensionSurfaceState()
        messageQueueError = nil
        fileIndexWorkspaceId = nil
        fileIndexRequestId = nil
        isLoadingFileIndex = false
        fileIndexPaths = []
        fileIndexError = nil
        resetSlashCommands()
        resetSessionStats()
        resetSessionOutline()
        sessionChangesError = nil
        sessionDiffError = nil
        sessionFilePreviewError = nil
        sessionChangedFiles = []
        sessionChangedFileCount = 0
        sessionChangedFilesOverflow = 0
        selectedSessionDiff = nil
        selectedSessionFilePreview = nil
        if let previousSessionId {
            messageQueueStore.clear(sessionId: previousSessionId)
        }
        pendingReviewCommentDraft = nil
        reviewComments.clearLoadedScope()
    }

    func isToolRowExpanded(_ id: String) -> Bool {
        expandedToolRowIDs.contains(id)
    }

    func selectToolRow(_ id: String) {
        var state = timelineKeybindingState
        MacTimelineKeybinding.selectToolRow(id, in: &state)
        applyTimelineKeybindingState(state)
    }

    func setToolRowExpanded(_ id: String, expanded: Bool) {
        if expanded {
            expandedToolRowIDs.insert(id)
        } else {
            expandedToolRowIDs.remove(id)
        }
    }

    func closeToolDocument() {
        var state = timelineKeybindingState
        MacTimelineKeybinding.apply(.closeViewer, to: &state, toolRowIDs: [])
        applyTimelineKeybindingState(state)
    }

    func loadReviewComments() {
        guard let selectedTarget else {
            reviewComments.clearLoadedScope()
            return
        }
        reviewComments.load(workspaceId: selectedTarget.workspaceId, sessionId: selectedTarget.sessionId)
    }

    func beginReviewCommentDraft(_ draft: MacReviewCommentDraft) {
        pendingReviewCommentDraft = draft
    }

    func cancelReviewCommentDraft() {
        pendingReviewCommentDraft = nil
    }

    @discardableResult
    func saveReviewComment(body: String, draft: MacReviewCommentDraft? = nil) -> String? {
        guard let selectedTarget else {
            return "Review comments are unavailable for this session."
        }
        guard let resolved = draft ?? pendingReviewCommentDraft else {
            return "Select text before adding a review comment."
        }
        do {
            _ = try reviewComments.create(
                workspaceId: selectedTarget.workspaceId,
                sessionId: selectedTarget.sessionId,
                body: body,
                reference: resolved.reference
            )
            if pendingReviewCommentDraft == resolved {
                pendingReviewCommentDraft = nil
            }
            lastError = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func updateReviewComment(_ comment: ReviewComment, body: String) -> String? {
        do {
            _ = try reviewComments.updateBody(commentId: comment.id, body: body)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func deleteReviewComment(_ comment: ReviewComment) {
        reviewComments.delete(commentId: comment.id)
    }

    @discardableResult
    func applyKeybinding(
        _ chord: KeybindingChord,
        toolRowIDs: [String]? = nil
    ) -> KeybindingAction? {
        var state = timelineKeybindingState
        let action = MacTimelineKeybinding.apply(
            chord: chord,
            mode: keybindingMode,
            to: &state,
            toolRowIDs: toolRowIDs ?? MacTimelineKeybinding.toolRowIDs(in: items)
        )
        applyTimelineKeybindingState(state)
        return action
    }

    private var timelineKeybindingState: MacTimelineKeybinding.State {
        MacTimelineKeybinding.State(
            selectedToolRowID: selectedToolRowID,
            expandedToolRowIDs: expandedToolRowIDs,
            focus: keybindingFocus,
            openToolDocumentID: openToolDocumentID
        )
    }

    private func applyTimelineKeybindingState(_ state: MacTimelineKeybinding.State) {
        selectedToolRowID = state.selectedToolRowID
        expandedToolRowIDs = state.expandedToolRowIDs
        keybindingFocus = state.focus
        openToolDocumentID = state.openToolDocumentID
    }

    private func resetTimelineKeybindingState() {
        selectedToolRowID = nil
        expandedToolRowIDs = []
        keybindingFocus = .composer
        openToolDocumentID = nil
    }

    /// A selected session owns these in-flight flags. Reset them immediately
    /// when focus moves so a suspended operation from the previous session
    /// cannot disable controls in the newly selected composer.
    private func resetSessionOperationState() {
        isSending = false
        isPreparingAttachments = false
        attachmentPreparationText = nil
        isUpdatingThinkingLevel = false
        isUpdatingModel = false
        isRefreshingQueue = false
        isUpdatingQueue = false
        isStoppingTurn = false
        isLoadingSessionChanges = false
        isLoadingSessionDiff = false
        isLoadingSessionFilePreview = false
        isLoadingSessionOutline = false
        sessionChangesRequestId = nil
        sessionDiffRequestId = nil
        sessionFilePreviewRequestId = nil
        sessionOutlineRequestId = nil
    }

    func loadSelectedFromLocalConfig() async {
        guard let selectedTarget else { return }
        guard let client = MacWorkspaceClient.localOwner() else {
            lastError = "Local server config is not initialized yet."
            return
        }
        await loadSelectedSession(target: selectedTarget, client: client)
    }

    private func loadSelectedSession(target: MacSelectedSessionTarget, client: MacWorkspaceClient) async {
        isLoading = true
        lastError = nil
        await installSessionRuntime(target: target, client: client, restart: true)
        guard shouldContinueLoad(for: target) else { return }
        startSessionRuntimeLoop()
        guard shouldContinueLoad(for: target) else { return }
        await loadSessionChanges(target: target, client: client)
        guard shouldContinueLoad(for: target) else { return }
        if shouldRefreshLiveQueue {
            await refreshQueue(target: target, client: client)
            guard shouldContinueLoad(for: target) else { return }
        }
        await loadAvailableModels(client: client)
    }

    func load(target: MacSelectedSessionTarget, client: MacWorkspaceClient) async {
        select(target)
        isLoading = true
        lastError = nil
        await installSessionRuntime(target: target, client: client)
        guard shouldContinueLoad(for: target) else { return }
        // Reusing a manager: canceling `sessionRuntimeTask` without bumping
        // `connectionGeneration` closes the replacement stream.
        if sessionRuntimeTask == nil {
            startSessionRuntimeLoop()
        }
        guard shouldContinueLoad(for: target) else { return }
        let didLoad = await sessionManager?.forceHistoryReload() ?? false
        guard shouldContinueLoad(for: target) else { return }
        if didLoad {
            lastLoadedAt = Date()
        } else {
            lastError = lastError ?? "Failed to load session history."
        }
        isLoading = false
        guard shouldContinueLoad(for: target) else { return }
        await loadAvailableModels(client: client)
    }

    @discardableResult
    func sendPromptFromLocalConfig(_ text: String, attachments: [MacPendingAttachment] = []) async -> Bool {
        guard let selectedTarget else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!trimmed.isEmpty || !attachments.isEmpty || hasStagedReviewComments), canSendMessage else {
            return false
        }

        guard let client = MacWorkspaceClient.localOwner() else {
            lastError = "Local server config is not initialized yet."
            return false
        }

        return await sendPrompt(
            trimmed,
            attachments: attachments,
            target: selectedTarget,
            client: client
        )
    }

    /// Abort the current turn only. Never escalate to `stopSession`.
    func stopTurnFromLocalConfig() async {
        guard let selectedTarget else { return }
        guard let client = MacWorkspaceClient.localOwner() else {
            lastError = "Local server config is not initialized yet."
            return
        }
        await stopTurn(target: selectedTarget, client: client)
    }

    func stopTurn(target: MacSelectedSessionTarget, client: MacWorkspaceClient) async {
        guard !isStoppingTurn else { return }
        await installSessionRuntime(target: target, client: client)
        guard selectedTarget == target, !Task.isCancelled else { return }
        isStoppingTurn = true
        lastError = nil
        defer {
            if selectedTarget == target {
                isStoppingTurn = false
            }
        }
        let requestId = UUID().uuidString
        do {
            try await sendSessionCommand(
                .stop(requestId: requestId),
                target: target,
                requestId: requestId
            )
        } catch {
            guard selectedTarget == target, !Task.isCancelled else { return }
            lastError = error.localizedDescription
            macSessionTraceLogger.warning("Turn stop failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func resumeSessionFromLocalConfig() async {
        guard let selectedTarget else { return }
        guard let client = MacWorkspaceClient.localOwner() else {
            let message = "Local server config is not initialized yet."
            resumeError = message
            return
        }
        await resumeSession(target: selectedTarget, client: client)
    }

    func resumeSession(target: MacSelectedSessionTarget, client: MacWorkspaceClient) async {
        guard selectedTarget == target,
              session?.status == .stopped,
              !isResumingSession else { return }

        isResumingSession = true
        resumeError = nil
        defer {
            if selectedTarget == target {
                isResumingSession = false
            }
        }

        do {
            let updated = try await client.resumeSession(
                scope: target.routeScope,
                sessionId: target.sessionId
            )
            guard selectedTarget == target, !Task.isCancelled else { return }
            session = updated
            resumeError = nil
            runtimeAdapter?.upsert(updated)
            if let sessionManager {
                sessionManager.reconnect()
            } else {
                await installSessionRuntime(target: target, client: client)
                startSessionRuntimeLoop()
            }
        } catch {
            guard selectedTarget == target, !Task.isCancelled else { return }
            let message = "Resume failed: \(error.localizedDescription)"
            resumeError = message
            macSessionTraceLogger.warning(
                "Session resume failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func loadAvailableModelsFromLocalConfig() async {
        guard let client = MacWorkspaceClient.localOwner() else {
            modelLoadError = "Local server config is not initialized yet."
            return
        }

        await loadAvailableModels(client: client)
    }

    func loadAvailableModels(client: MacWorkspaceClient) async {
        isLoadingModels = true
        modelLoadError = nil
        do {
            if let listModels = _listModelsForTesting {
                availableModels = try await listModels()
            } else {
                availableModels = try await client.listModels()
            }
        } catch {
            macSessionTraceLogger.warning("Model list load failed: \(error.localizedDescription, privacy: .public)")
            modelLoadError = error.localizedDescription
        }
        isLoadingModels = false
    }

    func loadFileIndexFromLocalConfig() async {
        guard let selectedTarget else { return }
        if fileIndexWorkspaceId == selectedTarget.workspaceId, !fileIndexPaths.isEmpty { return }
        guard let client = MacWorkspaceClient.localOwner() else {
            fileIndexError = "Local server config is not initialized yet."
            return
        }

        await loadFileIndex(
            workspaceId: selectedTarget.workspaceId,
            client: client
        )
    }

    func loadFileIndex(workspaceId: String, client: MacWorkspaceClient) async {
        guard selectedTarget?.workspaceId == workspaceId else { return }
        let requestId = UUID().uuidString
        fileIndexRequestId = requestId
        isLoadingFileIndex = true
        fileIndexError = nil
        defer {
            if fileIndexRequestId == requestId {
                fileIndexRequestId = nil
                isLoadingFileIndex = false
            }
        }
        do {
            let response = try await client.fetchFileIndex(workspaceId: workspaceId)
            guard selectedTarget?.workspaceId == workspaceId,
                  fileIndexRequestId == requestId,
                  !Task.isCancelled else { return }
            fileIndexWorkspaceId = workspaceId
            fileIndexPaths = response.paths
        } catch {
            guard selectedTarget?.workspaceId == workspaceId,
                  fileIndexRequestId == requestId,
                  !Task.isCancelled else { return }
            macSessionTraceLogger.warning("File index load failed: \(error.localizedDescription, privacy: .public)")
            fileIndexError = error.localizedDescription
        }
    }

    func loadSlashCommandsFromLocalConfig() async {
        guard let selectedTarget, let session else { return }
        let cacheKey = slashCommandCacheKey(for: session, workspaceId: selectedTarget.workspaceId)
        if slashCommandsCacheKey == cacheKey, !slashCommands.isEmpty {
            return
        }
        guard !isLoadingSlashCommands else { return }

        isLoadingSlashCommands = true
        slashCommandsError = nil
        let requestId = UUID().uuidString
        slashCommandsRequestId = requestId
        do {
            try await sendSessionCommand(
                .getCommands(requestId: requestId),
                target: selectedTarget
            )
        } catch {
            guard self.selectedTarget == selectedTarget,
                  slashCommandsRequestId == requestId,
                  !Task.isCancelled else { return }
            slashCommandsRequestId = nil
            isLoadingSlashCommands = false
            slashCommandsError = error.localizedDescription
            macSessionTraceLogger.warning(
                "Slash command load failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func loadSessionStatsFromLocalConfig() async {
        guard let selectedTarget, session != nil else { return }
        guard !isLoadingSessionStats else { return }

        isLoadingSessionStats = true
        sessionStatsError = nil
        let requestId = UUID().uuidString
        sessionStatsRequestId = requestId
        do {
            try await sendSessionCommand(
                .getSessionStats(requestId: requestId),
                target: selectedTarget
            )
        } catch {
            guard self.selectedTarget == selectedTarget,
                  sessionStatsRequestId == requestId,
                  !Task.isCancelled else { return }
            sessionStatsRequestId = nil
            isLoadingSessionStats = false
            sessionStatsError = error.localizedDescription
            macSessionTraceLogger.warning(
                "Session stats load failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func loadSessionChangesFromLocalConfig() async {
        guard let selectedTarget else { return }
        guard let client = MacWorkspaceClient.localOwner() else {
            sessionChangesError = "Local server config is not initialized yet."
            return
        }

        await loadSessionChanges(
            target: selectedTarget,
            client: client
        )
    }

    func loadSessionChanges(target: MacSelectedSessionTarget, client: MacWorkspaceClient) async {
        guard selectedTarget == target else { return }
        guard target.routeScope != .control else {
            sessionChangedFiles = []
            sessionChangedFileCount = 0
            sessionChangedFilesOverflow = 0
            sessionChangesError = nil
            return
        }
        let requestId = UUID().uuidString
        sessionChangesRequestId = requestId
        isLoadingSessionChanges = true
        sessionChangesError = nil
        defer {
            if sessionChangesRequestId == requestId {
                sessionChangesRequestId = nil
                isLoadingSessionChanges = false
            }
        }
        do {
            let response = try await client.listSessionChanges(
                workspaceId: target.workspaceId,
                sessionId: target.sessionId
            )
            guard selectedTarget == target,
                  sessionChangesRequestId == requestId,
                  !Task.isCancelled else { return }
            sessionChangedFiles = response.files
            sessionChangedFileCount = response.changedFileCount
            sessionChangedFilesOverflow = response.changedFilesOverflow
        } catch {
            guard selectedTarget == target,
                  sessionChangesRequestId == requestId,
                  !Task.isCancelled else { return }
            macSessionTraceLogger.warning("Session changes load failed: \(error.localizedDescription, privacy: .public)")
            sessionChangesError = error.localizedDescription
        }
    }

    func loadSessionOutlineFromLocalConfig() async {
        guard let selectedTarget else { return }
        guard let client = MacWorkspaceClient.localOwner() else {
            sessionOutlineError = "Local server config is not initialized yet."
            return
        }
        await loadSessionOutline(target: selectedTarget, client: client)
    }

    func loadSessionOutline(target: MacSelectedSessionTarget, client: MacWorkspaceClient) async {
        guard selectedTarget == target else { return }
        let requestId = UUID().uuidString
        sessionOutlineRequestId = requestId
        isLoadingSessionOutline = true
        sessionOutlineError = nil
        defer {
            if sessionOutlineRequestId == requestId {
                sessionOutlineRequestId = nil
                isLoadingSessionOutline = false
            }
        }
        do {
            let outline = try await client.getSessionTraceOutline(
                scope: target.routeScope,
                sessionId: target.sessionId
            )
            guard selectedTarget == target,
                  sessionOutlineRequestId == requestId,
                  !Task.isCancelled else { return }
            sessionOutline = outline
        } catch {
            guard selectedTarget == target,
                  sessionOutlineRequestId == requestId,
                  !Task.isCancelled else { return }
            macSessionTraceLogger.warning(
                "Session outline load failed: \(error.localizedDescription, privacy: .public)"
            )
            sessionOutlineError = error.localizedDescription
        }
    }

    func jumpToOutlineEntry(_ id: String) async {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !items.contains(where: { $0.id == trimmed }) {
            _ = await sessionManager?.loadTracePageAround(entryId: trimmed)
        }
        scrollTargetID = trimmed
    }

    func clearScrollTarget() {
        scrollTargetID = nil
    }

    private func resetSessionOutline() {
        sessionOutlineRequestId = nil
        sessionOutline = nil
        sessionOutlineError = nil
        isLoadingSessionOutline = false
        scrollTargetID = nil
    }

    func loadSessionDiffFromLocalConfig(path: String) async {
        guard let selectedTarget else { return }
        guard let client = MacWorkspaceClient.localOwner() else {
            sessionDiffError = "Local server config is not initialized yet."
            return
        }

        await loadSessionDiff(
            path: path,
            target: selectedTarget,
            client: client
        )
    }

    func loadSessionDiff(path: String, target: MacSelectedSessionTarget, client: MacWorkspaceClient) async {
        guard selectedTarget == target else { return }
        let requestId = UUID().uuidString
        sessionDiffRequestId = requestId
        isLoadingSessionDiff = true
        sessionDiffError = nil
        defer {
            if sessionDiffRequestId == requestId {
                sessionDiffRequestId = nil
                isLoadingSessionDiff = false
            }
        }
        do {
            let diff = try await client.getSessionDiff(
                workspaceId: target.workspaceId,
                sessionId: target.sessionId,
                path: path
            )
            guard selectedTarget == target,
                  sessionDiffRequestId == requestId,
                  !Task.isCancelled else { return }
            selectedSessionDiff = diff
        } catch {
            guard selectedTarget == target,
                  sessionDiffRequestId == requestId,
                  !Task.isCancelled else { return }
            macSessionTraceLogger.warning("Session diff load failed: \(error.localizedDescription, privacy: .public)")
            sessionDiffError = error.localizedDescription
        }
    }

    func clearSessionDiff() {
        sessionDiffRequestId = nil
        isLoadingSessionDiff = false
        selectedSessionDiff = nil
        sessionDiffError = nil
    }

    func loadSessionFilePreviewFromLocalConfig(path: String) async {
        guard let selectedTarget else { return }
        guard let client = MacWorkspaceClient.localOwner() else {
            sessionFilePreviewError = "Local server config is not initialized yet."
            return
        }

        await loadSessionFilePreview(
            path: path,
            target: selectedTarget,
            client: client
        )
    }

    func loadSessionFilePreview(path: String, target: MacSelectedSessionTarget, client: MacWorkspaceClient) async {
        guard selectedTarget == target else { return }
        let requestId = UUID().uuidString
        sessionFilePreviewRequestId = requestId
        isLoadingSessionFilePreview = true
        sessionFilePreviewError = nil
        defer {
            if sessionFilePreviewRequestId == requestId {
                sessionFilePreviewRequestId = nil
                isLoadingSessionFilePreview = false
            }
        }
        do {
            let data = try await client.getSessionRawFileData(
                workspaceId: target.workspaceId,
                sessionId: target.sessionId,
                path: path
            )
            guard selectedTarget == target,
                  sessionFilePreviewRequestId == requestId,
                  !Task.isCancelled else { return }
            selectedSessionFilePreview = MacSessionFilePreview(path: path, data: data)
        } catch {
            guard selectedTarget == target,
                  sessionFilePreviewRequestId == requestId,
                  !Task.isCancelled else { return }
            macSessionTraceLogger.warning("Session file preview load failed: \(error.localizedDescription, privacy: .public)")
            sessionFilePreviewError = error.localizedDescription
        }
    }

    func clearSessionFilePreview() {
        sessionFilePreviewRequestId = nil
        isLoadingSessionFilePreview = false
        selectedSessionFilePreview = nil
        sessionFilePreviewError = nil
    }

    func loadFullToolOutputIfNeeded(itemID: String) async {
        guard let selectedTarget else { return }
        guard let client = MacWorkspaceClient.localOwner() else { return }
        await loadFullToolOutputIfNeeded(
            itemID: itemID,
            target: selectedTarget,
            client: client
        )
    }

    func loadFullToolOutputIfNeeded(
        itemID: String,
        target: MacSelectedSessionTarget,
        client: MacWorkspaceClient
    ) async {
        guard !itemID.isEmpty else { return }
        guard selectedTarget == target else { return }
        guard !toolOutputStore.hasCompleteOutput(for: itemID) else { return }
        guard fullToolOutputLoadsInFlight.insert(itemID).inserted else { return }
        defer { fullToolOutputLoadsInFlight.remove(itemID) }

        do {
            guard let output = try await client.getFullToolOutput(
                scope: target.routeScope,
                sessionId: target.sessionId,
                toolCallId: itemID
            ) else {
                return
            }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard selectedTarget == target else { return }
            guard !toolOutputStore.hasCompleteOutput(for: itemID) else { return }
            toolOutputStore.replace(output, for: itemID, previewOnly: false)
        } catch {
            macSessionTraceLogger.debug(
                "Full tool output fetch failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func refreshQueueFromLocalConfig() async {
        guard let selectedTarget else { return }
        guard let client = MacWorkspaceClient.localOwner() else {
            messageQueueError = "Local server config is not initialized yet."
            return
        }

        await refreshQueue(
            target: selectedTarget,
            client: client
        )
    }

    func applyQueueMutationFromLocalConfig(_ request: MacMessageQueueMutationRequest) async throws {
        guard let selectedTarget else { return }
        guard let client = MacWorkspaceClient.localOwner() else {
            let message = "Local server config is not initialized yet."
            messageQueueError = message
            throw MacSessionTraceStoreError.commandRejected(message)
        }

        try await applyQueueMutation(
            request,
            target: selectedTarget,
            client: client
        )
    }

    func refreshQueue(target: MacSelectedSessionTarget, client: MacWorkspaceClient) async {
        await installSessionRuntime(target: target, client: client)
        guard selectedTarget == target, !Task.isCancelled else { return }
        guard shouldRefreshLiveQueue else { return }
        isRefreshingQueue = true
        messageQueueError = nil
        defer {
            if selectedTarget == target {
                isRefreshingQueue = false
            }
        }
        do {
            let requestId = UUID().uuidString
            try await sendSessionCommand(
                .getQueue(requestId: requestId),
                target: target,
                requestId: requestId,
                awaitResult: true
            )
        } catch {
            guard selectedTarget == target, !Task.isCancelled else { return }
            macSessionTraceLogger.debug("Queue refresh failed: \(error.localizedDescription, privacy: .public)")
            messageQueueError = error.localizedDescription
        }
    }

    func applyQueueMutation(
        _ request: MacMessageQueueMutationRequest,
        target: MacSelectedSessionTarget,
        client: MacWorkspaceClient
    ) async throws {
        guard selectedTarget == target, !Task.isCancelled else {
            throw MacSessionTraceStoreError.commandRejected("Session selection changed.")
        }
        isUpdatingQueue = true
        messageQueueError = nil
        defer {
            if selectedTarget == target {
                isUpdatingQueue = false
            }
        }

        await installSessionRuntime(target: target, client: client)
        guard selectedTarget == target, !Task.isCancelled else {
            throw MacSessionTraceStoreError.commandRejected("Session selection changed.")
        }
        do {
            let requestId = UUID().uuidString
            try await sendSessionCommand(
                .setQueue(
                    baseVersion: request.baseVersion,
                    steering: request.steering,
                    followUp: request.followUp,
                    requestId: requestId
                ),
                target: target,
                requestId: requestId,
                awaitResult: true
            )
        } catch {
            let mutationError = error
            guard selectedTarget == target, !Task.isCancelled else {
                throw mutationError
            }

            var surfacedError: Error = mutationError
            do {
                // A rejected compare-and-swap means the editor's base snapshot
                // may be stale. Re-read before returning the rejection so the
                // subsequent optimistic rollback converges on server state.
                let reconciliationRequestId = UUID().uuidString
                try await sendSessionCommand(
                    .getQueue(requestId: reconciliationRequestId),
                    target: target,
                    requestId: reconciliationRequestId,
                    awaitResult: true
                )
            } catch {
                if selectedTarget == target, !Task.isCancelled {
                    surfacedError = MacSessionTraceStoreError.commandRejected(
                        "\(mutationError.localizedDescription) Queue refresh failed: \(error.localizedDescription)"
                    )
                    macSessionTraceLogger.warning(
                        "Queue reconciliation failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            if selectedTarget == target, !Task.isCancelled {
                messageQueueError = surfacedError.localizedDescription
            }
            throw surfacedError
        }
    }

    @discardableResult
    func sendPrompt(
        _ text: String,
        attachments pendingAttachments: [MacPendingAttachment] = [],
        target: MacSelectedSessionTarget,
        client: MacWorkspaceClient
    ) async -> Bool {
        guard selectedTarget == target, !Task.isCancelled else { return false }
        await installSessionRuntime(target: target, client: client)
        guard let operationManager = runtimeManager(for: target) else { return false }
        let requestID = UUID().uuidString
        let stagedCommentIds = reviewComments.stagedComments.map(\.id)
        let stagedWorkspaceId = target.workspaceId
        let stagedSessionId = target.sessionId
        let textWithComments = reviewComments.appendReviewBlock(to: text)
        let uploadedAttachments: [ChatAttachmentRef]
        do {
            uploadedAttachments = try await uploadPendingAttachments(
                pendingAttachments,
                requestID: requestID,
                target: target,
                client: client,
                boundManager: operationManager
            )
        } catch {
            guard isCurrentRuntime(operationManager, for: target) else { return false }
            operationManager.reducer.appendSystemEvent("Attachment upload failed: \(error.localizedDescription)")
            macSessionTraceLogger.warning("Attachment upload failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            return false
        }
        guard isCurrentRuntime(operationManager, for: target) else { return false }

        let isBusy = session?.status.isRunning == true
        let streamingBehavior = busyStreamingBehavior
        let messageText = MacAttachmentDisplayFormatter.appendAttachedFilesBlock(
            to: textWithComments,
            attachments: uploadedAttachments
        )
        let optimisticID = isBusy ? nil : operationManager.reducer.appendUserMessage(messageText)
        let queuedKind: MessageQueueKind? = isBusy
            ? (streamingBehavior == .steer ? .steer : .followUp)
            : nil
        let optimisticQueueItem: MessageQueueItem?
        if let queuedKind {
            optimisticQueueItem = messageQueueStore.enqueueOptimisticItem(
                for: target.sessionId,
                kind: queuedKind,
                message: messageText,
                attachments: uploadedAttachments.isEmpty ? nil : uploadedAttachments,
                id: requestID
            )
        } else {
            optimisticQueueItem = nil
        }

        isSending = true
        lastError = nil
        defer {
            if isCurrentRuntime(operationManager, for: target) {
                isSending = false
            }
        }
        do {
            let attachments = uploadedAttachments.isEmpty ? nil : uploadedAttachments
            let message: ClientMessage
            if isBusy {
                switch streamingBehavior {
                case .steer:
                    message = .steer(message: textWithComments, attachments: attachments, requestId: requestID, clientTurnId: requestID)
                case .followUp:
                    message = .followUp(message: textWithComments, attachments: attachments, requestId: requestID, clientTurnId: requestID)
                }
            } else {
                message = .prompt(message: textWithComments, attachments: attachments, requestId: requestID)
            }
            try await sendSessionCommand(message, target: target)
        } catch {
            if let optimisticID {
                operationManager.reducer.removeItem(id: optimisticID)
            }
            if let queuedKind, let optimisticQueueItem {
                messageQueueStore.removeQueuedItem(
                    for: target.sessionId,
                    kind: queuedKind,
                    id: optimisticQueueItem.id,
                    messageFallback: messageText
                )
            }
            if isCurrentRuntime(operationManager, for: target) {
                operationManager.reducer.appendSystemEvent("Send failed: \(error.localizedDescription)")
                macSessionTraceLogger.warning("Session command send failed: \(error.localizedDescription, privacy: .public)")
                lastError = error.localizedDescription
            }
            return false
        }

        if selectedTarget?.workspaceId == stagedWorkspaceId,
           selectedTarget?.sessionId == stagedSessionId,
           isCurrentRuntime(operationManager, for: target) {
            reviewComments.clearSent(ids: stagedCommentIds)
        }
        return true
    }

    private func uploadPendingAttachments(
        _ attachments: [MacPendingAttachment],
        requestID: String,
        target: MacSelectedSessionTarget,
        client: MacWorkspaceClient,
        boundManager: ChatSessionManager
    ) async throws -> [ChatAttachmentRef] {
        guard !attachments.isEmpty else { return [] }
        guard isCurrentRuntime(boundManager, for: target) else {
            throw MacSessionTraceStoreError.commandRejected("Session selection changed.")
        }

        isPreparingAttachments = true
        attachmentPreparationText = "Uploading attachments…"
        defer {
            if isCurrentRuntime(boundManager, for: target) {
                isPreparingAttachments = false
                attachmentPreparationText = nil
            }
        }

        var uploaded: [ChatAttachmentRef] = []
        for (index, attachment) in attachments.enumerated() {
            guard isCurrentRuntime(boundManager, for: target) else {
                throw MacSessionTraceStoreError.commandRejected("Session selection changed.")
            }
            attachmentPreparationText = "Uploading attachment \(index + 1) of \(attachments.count)…"
            let upload = try await client.createSessionAttachmentUpload(
                scope: target.routeScope,
                sessionId: target.sessionId,
                name: attachment.displayName,
                mimeType: attachment.mimeType,
                sizeBytes: attachment.sizeBytes
            )
            guard isCurrentRuntime(boundManager, for: target) else {
                throw MacSessionTraceStoreError.commandRejected("Session selection changed.")
            }
            let data = try Data(contentsOf: attachment.url)
            let ref = try await client.uploadSessionAttachmentContent(
                scope: target.routeScope,
                sessionId: target.sessionId,
                attachmentId: upload.uploadId,
                data: data,
                contentType: attachment.mimeType
            )
            guard isCurrentRuntime(boundManager, for: target) else {
                throw MacSessionTraceStoreError.commandRejected("Session selection changed.")
            }
            uploaded.append(ref)
            macSessionTraceLogger.debug(
                "Uploaded attachment for request \(requestID, privacy: .public): \(attachment.displayName, privacy: .public)"
            )
        }
        return uploaded
    }

    func setThinkingLevelFromLocalConfig(_ level: ThinkingLevel, persist: Bool = false) async {
        guard let selectedTarget, canSendMessage else { return }
        guard let client = MacWorkspaceClient.localOwner() else {
            lastError = "Local server config is not initialized yet."
            return
        }

        await setThinkingLevel(
            level,
            target: selectedTarget,
            client: client,
            persist: persist
        )
    }

    func setModelFromLocalConfig(_ model: ModelInfo, persist: Bool = false) async {
        guard let selectedTarget, canSendMessage else { return }
        guard let client = MacWorkspaceClient.localOwner() else {
            lastError = "Local server config is not initialized yet."
            return
        }

        await setModel(
            model,
            target: selectedTarget,
            client: client,
            persist: persist
        )
    }

    func setThinkingLevel(
        _ level: ThinkingLevel,
        target: MacSelectedSessionTarget,
        client: MacWorkspaceClient,
        persist: Bool = false
    ) async {
        guard selectedTarget == target, !Task.isCancelled else { return }
        if persist, session?.supportsPersistingDefaults == false {
            lastError = SessionRuntimeKind.persistUnsupportedMessage
            sessionManager?.reducer.appendSystemEvent(SessionRuntimeKind.persistUnsupportedMessage)
            return
        }
        guard persist || thinkingLevel != level else { return }
        await installSessionRuntime(target: target, client: client)
        guard let operationManager = runtimeManager(for: target) else { return }
        let previousLevel = session?.thinkingLevel
        let optimisticLevel = level.rawValue
        let requestId = UUID().uuidString
        session?.thinkingLevel = optimisticLevel
        pendingCommandChanges[requestId] = .thinking(previous: previousLevel, optimistic: optimisticLevel)
        isUpdatingThinkingLevel = true
        lastError = nil
        defer {
            if isCurrentRuntime(operationManager, for: target) {
                isUpdatingThinkingLevel = false
            }
        }
        do {
            try await sendSessionCommand(
                .setThinkingLevel(
                    level: level,
                    requestId: requestId,
                    persist: persist ? true : nil
                ),
                target: target,
                requestId: requestId
            )
        } catch {
            if isCurrentRuntime(operationManager, for: target),
               pendingCommandChanges.removeValue(forKey: requestId) != nil {
                session?.thinkingLevel = previousLevel
                operationManager.reducer.appendSystemEvent("Thinking level update failed: \(error.localizedDescription)")
                lastError = error.localizedDescription
            }
            macSessionTraceLogger.warning("Thinking level update failed: \(error.localizedDescription, privacy: .public)")
            return
        }
    }

    func applyServerMessageForTesting(_ message: ServerMessage, target: MacSelectedSessionTarget) {
        applyLiveRuntimeMessage(message, sessionId: target.sessionId)
    }

    func setModel(
        _ model: ModelInfo,
        target: MacSelectedSessionTarget,
        client: MacWorkspaceClient,
        persist: Bool = false
    ) async {
        guard selectedTarget == target, !Task.isCancelled else { return }
        if persist, session?.supportsPersistingDefaults == false {
            lastError = SessionRuntimeKind.persistUnsupportedMessage
            sessionManager?.reducer.appendSystemEvent(SessionRuntimeKind.persistUnsupportedMessage)
            return
        }
        guard persist || !MacModelSelection.isCurrent(model: model, currentModel: session?.model) else { return }
        await installSessionRuntime(target: target, client: client)
        guard let operationManager = runtimeManager(for: target) else { return }
        let previousModel = session?.model
        let optimisticModel = MacModelSelection.fullModelID(for: model)
        let requestId = UUID().uuidString
        session?.model = optimisticModel
        pendingCommandChanges[requestId] = .model(previous: previousModel, optimistic: optimisticModel)
        isUpdatingModel = true
        lastError = nil
        defer {
            if isCurrentRuntime(operationManager, for: target) {
                isUpdatingModel = false
            }
        }
        do {
            try await sendSessionCommand(
                .setModel(
                    provider: model.provider,
                    modelId: MacModelSelection.commandModelID(for: model),
                    requestId: requestId,
                    persist: persist ? true : nil
                ),
                target: target,
                requestId: requestId,
                awaitResult: persist
            )
        } catch {
            if isCurrentRuntime(operationManager, for: target),
               pendingCommandChanges.removeValue(forKey: requestId) != nil {
                session?.model = previousModel
                operationManager.reducer.appendSystemEvent("Model update failed: \(error.localizedDescription)")
                lastError = error.localizedDescription
            }
            macSessionTraceLogger.warning("Model update failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        if persist {
            guard isCurrentRuntime(operationManager, for: target) else { return }
            availableModels = MacModelSelection.markingDefault(availableModels, as: model)
            await loadAvailableModels(client: client)
        }
    }

    func submitAskResponseFromLocalConfig(request: AskRequest, draft: MacAskResponseDraft) async {
        guard let selectedTarget else { return }
        guard let client = MacWorkspaceClient.localOwner() else {
            lastError = "Local server config is not initialized yet."
            return
        }

        await sendAskResponse(
            request: request,
            message: MacAskResponseEncoder.responseMessage(request: request, draft: draft),
            target: selectedTarget,
            client: client
        )
    }

    func ignoreAskRequestFromLocalConfig(_ request: AskRequest) async {
        guard let selectedTarget else { return }
        guard let client = MacWorkspaceClient.localOwner() else {
            lastError = "Local server config is not initialized yet."
            return
        }

        await sendAskResponse(
            request: request,
            message: .extensionUIResponse(id: request.id, cancelled: true),
            target: selectedTarget,
            client: client
        )
    }

    private func sendAskResponse(
        request: AskRequest,
        message: ClientMessage,
        target: MacSelectedSessionTarget,
        client: MacWorkspaceClient
    ) async {
        guard selectedTarget == target, !Task.isCancelled else { return }
        await installSessionRuntime(target: target, client: client)
        guard let operationManager = runtimeManager(for: target) else { return }
        lastError = nil
        do {
            try await sendSessionCommand(message, target: target)
            guard isCurrentRuntime(operationManager, for: target) else { return }
            removeAskRequest(id: request.id)
            if pendingAskRequests.isEmpty {
                MacAttentionNotificationService.shared.cancelAskNotification(sessionId: target.sessionId)
            }
        } catch {
            macSessionTraceLogger.warning("Ask response failed: \(error.localizedDescription, privacy: .public)")
            if isCurrentRuntime(operationManager, for: target) {
                operationManager.reducer.appendSystemEvent("Ask response failed: \(error.localizedDescription)")
                lastError = error.localizedDescription
            }
        }
    }

    func applyLiveRuntimeMessage(_ message: ServerMessage, sessionId: String) {
        guard let selectedTarget, selectedTarget.sessionId == sessionId else { return }
        applyAskEffects(from: message, target: selectedTarget)
        applyExtensionSurfaceEffects(from: message, target: selectedTarget)
        applyQueueEffects(from: message, target: selectedTarget)
        applySlashCommandResult(from: message)
        applySessionStatsResult(from: message)
        _ = applyPendingCommandResult(from: message)
    }

    /// Live session snapshot from adapter `upsert`. Runtime writer of `session`
    /// besides optimistic command mutations on this store.
    func applyLiveRuntimeSession(_ session: Session) {
        guard selectedTarget?.sessionId == session.id else { return }
        self.session = session
        if isLoading {
            isLoading = false
            lastLoadedAt = Date()
        }
    }

    func applyLiveRuntimeStreamAvailability(_ isStreaming: Bool) {
        self.isStreaming = isStreaming
    }

    func noteHistoryLoadFailed() {
        guard isLoading else { return }
        lastError = lastError ?? "Failed to load session history."
        isLoading = false
    }

    private func shouldContinueLoad(for target: MacSelectedSessionTarget) -> Bool {
        guard selectedTarget == target else { return false }
        guard !Task.isCancelled else {
            isLoading = false
            return false
        }
        return true
    }

    private func runtimeManager(
        for target: MacSelectedSessionTarget
    ) -> ChatSessionManager? {
        guard selectedTarget == target,
              !Task.isCancelled,
              let sessionManager,
              sessionManager.sessionId == target.sessionId else {
            return nil
        }
        return sessionManager
    }

    private func isCurrentRuntime(
        _ manager: ChatSessionManager,
        for target: MacSelectedSessionTarget
    ) -> Bool {
        runtimeManager(for: target) === manager
    }

    private func installSessionRuntime(
        target: MacSelectedSessionTarget,
        client: MacWorkspaceClient,
        restart: Bool = false
    ) async {
        guard selectedTarget == target, !Task.isCancelled else { return }
        if !restart,
           sessionManager?.sessionId == target.sessionId,
           runtimeAdapter != nil {
            return
        }

        tearDownRuntime()
        if let gate = _sessionRuntimeInstallGateForTesting {
            await gate()
            guard selectedTarget == target, !Task.isCancelled else { return }
        }
        let token = await client.ownerToken()
        guard selectedTarget == target, !Task.isCancelled else { return }
        let adapter = MacChatSessionRuntimeAdapter(client: client, token: token)
        if let session, session.id == target.sessionId {
            adapter.upsert(session)
        } else {
            adapter.upsert(target.summary.session)
        }
        adapter.setActiveSessionId(target.sessionId)
        adapter.liveSessionOwner = self
        runtimeAdapter = adapter
        let manager = ChatSessionManager(
            sessionId: target.sessionId,
            workspaceIdHint: target.routeScope.workspaceId,
            routeScope: target.routeScope,
            adapter: adapter
        )
        manager.onReconnect = { [weak self] in
            self?.startSessionRuntimeLoop()
        }
        sessionManager = manager
    }

    private func startSessionRuntimeLoop() {
        sessionRuntimeTask?.cancel()
        guard let manager = sessionManager else { return }
        sessionRuntimeTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            await manager.connect()
        }
    }

    private func tearDownRuntime() {
        sessionRuntimeTask?.cancel()
        sessionRuntimeTask = nil
        sessionManager?.onReconnect = nil
        sessionManager?.cleanup()
        sessionManager = nil
        runtimeAdapter?.liveSessionOwner = nil
        runtimeAdapter?.close()
        runtimeAdapter = nil
        isStreaming = false
        failPendingCommandAcks(MacSessionTraceStoreError.commandRejected("Live session stream ended."))
    }

    private var shouldRefreshLiveQueue: Bool {
        FocusedSessionConnectionPolicy.actionAfterHistoryRefresh(for: session?.status) == .openStream
    }

    private func ensureFocusedStreamConnecting() {
        guard let manager = sessionManager else { return }
        let hasRuntimeTask = sessionRuntimeTask != nil
        switch manager.entryState {
        case .loadingCache, .awaitingConnected, .streaming:
            // Already connecting or live. Reconnect would reset the reducer
            // and wipe an optimistic send.
            if !hasRuntimeTask {
                startSessionRuntimeLoop()
            }
        case .idle, .disconnected, .stopped:
            if hasRuntimeTask {
                manager.reconnect()
            } else {
                startSessionRuntimeLoop()
            }
        }
    }

    private func sendSessionCommand(
        _ message: ClientMessage,
        target: MacSelectedSessionTarget,
        requestId: String? = nil,
        awaitResult: Bool = false
    ) async throws {
        guard selectedTarget == target, !Task.isCancelled else {
            throw MacSessionTraceStoreError.commandRejected("Session selection changed.")
        }
        // Bind one manager before the first suspension. Re-reading the store's
        // global manager after a session switch can redirect an old command to
        // the newly focused session.
        let boundManager = sessionManager
        if _sendLiveMessageForTesting == nil {
            guard let boundManager,
                  boundManager.sessionId == target.sessionId else {
                throw ChatSessionFocusedStreamBindError.timedOut
            }
            ensureFocusedStreamConnecting()
            let timeout = _commandAckTimeoutForTesting ?? ChatSessionManager.focusedStreamBindTimeout
            try await boundManager.waitUntilStreaming(timeout: timeout)
            guard selectedTarget == target,
                  !Task.isCancelled,
                  sessionManager === boundManager else {
                throw MacSessionTraceStoreError.commandRejected("Session selection changed.")
            }
        }

        if awaitResult, let requestId {
            // Mark this request before send can yield. Unrelated command_result
            // IDs are not buffered.
            pendingCommandAcks[requestId] = .expected
            async let acknowledged: Void = waitForCommandResult(requestId: requestId)
            do {
                try await sendLiveMessage(
                    message,
                    target: target,
                    boundManager: boundManager
                )
                try await acknowledged
            } catch {
                abandonCommandAck(requestId: requestId)
                _ = try? await acknowledged
                throw error
            }
            return
        }

        try await sendLiveMessage(
            message,
            target: target,
            boundManager: boundManager
        )
    }

    private func sendLiveMessage(
        _ message: ClientMessage,
        target: MacSelectedSessionTarget,
        boundManager: ChatSessionManager?
    ) async throws {
        guard selectedTarget == target, !Task.isCancelled else {
            throw MacSessionTraceStoreError.commandRejected("Session selection changed.")
        }
        if let sendLiveMessage = _sendLiveMessageForTesting {
            let sent = try await sendLiveMessage(message)
            guard sent else {
                throw ChatSessionFocusedStreamBindError.timedOut
            }
            return
        }
        guard let boundManager,
              sessionManager === boundManager,
              boundManager.sessionId == target.sessionId else {
            throw ChatSessionFocusedStreamBindError.timedOut
        }
        // Even if selection changes while send suspends, this port remains the
        // one bound to `target`; it can fail, but it cannot become session B.
        try await boundManager.focusedStreamPort.send(message)
    }

    private func waitForCommandResult(requestId: String) async throws {
        if case .finished(let result) = pendingCommandAcks.removeValue(forKey: requestId) {
            try result.get()
            return
        }

        let timeout = _commandAckTimeoutForTesting ?? ChatSessionManager.focusedStreamBindTimeout
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if case .finished(let result) = pendingCommandAcks.removeValue(forKey: requestId) {
                continuation.resume(with: result)
                return
            }
            pendingCommandAcks[requestId] = .waiting(continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self else { return }
                guard case .waiting(let pending) = self.pendingCommandAcks.removeValue(forKey: requestId) else {
                    return
                }
                pending.resume(throwing: MacSessionTraceStoreError.commandRejected("Command timed out."))
            }
        }
    }

    private func completeCommandAck(requestId: String, error: Error?) {
        let result: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
        switch pendingCommandAcks.removeValue(forKey: requestId) {
        case .waiting(let continuation):
            continuation.resume(with: result)
        case .expected:
            pendingCommandAcks[requestId] = .finished(result)
        case .finished, nil:
            break
        }
    }

    private func abandonCommandAck(requestId: String) {
        switch pendingCommandAcks.removeValue(forKey: requestId) {
        case .waiting(let continuation):
            continuation.resume()
        case .expected, .finished, nil:
            break
        }
    }

    private func failPendingCommandAcks(_ error: Error) {
        let pending = pendingCommandAcks
        pendingCommandAcks = [:]
        for (_, ack) in pending {
            if case .waiting(let continuation) = ack {
                continuation.resume(throwing: error)
            }
        }
    }

    private func applyExtensionSurfaceEffects(from message: ServerMessage, target: MacSelectedSessionTarget) {
        if case .extensionUINotification(let notification) = message {
            ExtensionSurfaceReducer.apply(notification, to: &extensionSurface)
        }

        let cleanup = ServerMessageEffects.cleanupEffects(
            for: message,
            routedSessionId: target.sessionId,
            isFocusedSession: true
        )
        for sessionId in cleanup.clearExtensionSurfaceSessionIds where sessionId == target.sessionId {
            extensionSurface = ExtensionSurfaceState()
        }
    }

    private func applyAskEffects(from message: ServerMessage, target: MacSelectedSessionTarget) {
        if case .extensionUIRequest(let request) = message,
           request.sessionId == target.sessionId,
           let ask = request.askRequest {
            upsertAskRequest(ask)
            MacAttentionNotificationService.shared.notifyAskIfNeeded(ask)
        }

        let cleanup = ServerMessageEffects.cleanupEffects(
            for: message,
            routedSessionId: target.sessionId,
            isFocusedSession: true
        )
        var didClearSession = false
        for sessionId in cleanup.clearAskSessionIds where sessionId == target.sessionId {
            pendingAskRequests = []
            didClearSession = true
        }
        var didRemoveRequest = false
        for requestId in cleanup.clearAskRequestIds {
            if pendingAskRequests.contains(where: { $0.id == requestId }) {
                didRemoveRequest = true
            }
            removeAskRequest(id: requestId)
        }
        if didClearSession || (didRemoveRequest && pendingAskRequests.isEmpty) {
            MacAttentionNotificationService.shared.cancelAskNotification(sessionId: target.sessionId)
        } else if didRemoveRequest, let nextAsk = pendingAskRequests.first {
            MacAttentionNotificationService.shared.notifyAskIfNeeded(nextAsk)
        }
    }

    private func upsertAskRequest(_ request: AskRequest) {
        if let index = pendingAskRequests.firstIndex(where: { $0.id == request.id }) {
            pendingAskRequests[index] = request
        } else {
            pendingAskRequests.append(request)
        }
    }

    private func removeAskRequest(id: String) {
        pendingAskRequests.removeAll { $0.id == id }
    }

    private func applyQueueEffects(from message: ServerMessage, target: MacSelectedSessionTarget) {
        applyQueueEffects(ServerMessageEffects.queueEffects(for: message), sessionId: target.sessionId)

        if case .commandResult(let command, _, let success, let data, let error) = message {
            applyQueueEffects(
                ServerMessageEffects.queueEffectsForCommandResult(
                    command: command,
                    success: success,
                    data: data
                ),
                sessionId: target.sessionId
            )
            if !success, command == "get_queue" || command == "set_queue" {
                messageQueueError = error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? error
                    : "\(command) failed"
            }
        }

        let cleanup = ServerMessageEffects.cleanupEffects(
            for: message,
            routedSessionId: target.sessionId,
            isFocusedSession: true
        )
        for sessionId in cleanup.clearMessageQueueSessionIds where sessionId == target.sessionId {
            messageQueueStore.clear(sessionId: sessionId)
        }
    }

    private func applyQueueEffects(_ effects: ServerMessageQueueEffects, sessionId: String) {
        if let queue = effects.applyQueueState {
            messageQueueStore.apply(queue, for: sessionId)
        }
        if let started = effects.queueItemStarted {
            messageQueueStore.applyQueueItemStarted(
                for: sessionId,
                kind: started.kind,
                item: started.item,
                queueVersion: started.queueVersion
            )
        }
    }

    private func applySlashCommandResult(from message: ServerMessage) {
        guard case .commandResult(let command, let requestId, let success, let data, let error) = message,
              command == "get_commands" else {
            return
        }
        if let expected = slashCommandsRequestId, let requestId, requestId != expected {
            return
        }

        slashCommandsRequestId = nil
        isLoadingSlashCommands = false
        guard success else {
            slashCommandsError = error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? error
                : "get_commands failed"
            return
        }

        slashCommandsError = nil
        slashCommands = Self.parseSlashCommands(from: data)
        if let session, let selectedTarget {
            slashCommandsCacheKey = slashCommandCacheKey(for: session, workspaceId: selectedTarget.workspaceId)
        }
    }

    private func resetSlashCommands() {
        slashCommands = []
        slashCommandsError = nil
        slashCommandsCacheKey = nil
        slashCommandsRequestId = nil
        isLoadingSlashCommands = false
    }

    private func applySessionStatsResult(from message: ServerMessage) {
        guard case .commandResult(let command, let requestId, let success, let data, let error) = message,
              command == "get_session_stats" else {
            return
        }
        if let expected = sessionStatsRequestId, let requestId, requestId != expected {
            return
        }

        sessionStatsRequestId = nil
        isLoadingSessionStats = false
        guard success else {
            sessionStatsError = error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? error
                : "get_session_stats failed"
            return
        }

        sessionStatsError = nil
        sessionStats = SessionStatsParser.parse(data)
        if sessionStats == nil {
            sessionStatsError = "Session usage is not available yet."
        }
    }

    private func resetSessionStats() {
        sessionStats = nil
        sessionStatsError = nil
        sessionStatsRequestId = nil
        isLoadingSessionStats = false
    }

    private func slashCommandCacheKey(for session: Session, workspaceId: String) -> String {
        "\(session.id)|\(session.workspaceId ?? workspaceId)"
    }

    private static func parseSlashCommands(from data: JSONValue?) -> [SlashCommand] {
        guard let commandValues = data?.objectValue?["commands"]?.arrayValue else {
            return []
        }

        var deduped: [String: SlashCommand] = [:]
        for value in commandValues {
            guard let command = SlashCommand(value) else { continue }
            let key = command.name.lowercased()
            if deduped[key] == nil {
                deduped[key] = command
            }
        }

        return deduped.values.sorted { lhs, rhs in
            let lhsName = lhs.name.lowercased()
            let rhsName = rhs.name.lowercased()
            if lhsName == rhsName {
                return lhs.source.sortRank < rhs.source.sortRank
            }
            return lhsName < rhsName
        }
    }

    private func applyPendingCommandResult(from message: ServerMessage) -> String? {
        guard case .commandResult(let command, let requestId, let success, _, let error) = message,
              let requestId else {
            return nil
        }

        let failure: String?
        if success {
            failure = nil
        } else {
            failure = error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? error ?? "\(command) failed"
                : "\(command) failed"
        }

        if let pending = pendingCommandChanges.removeValue(forKey: requestId), let failure {
            pending.rollbackIfStillOptimistic(session: &session)
            sessionManager?.reducer.appendSystemEvent("\(pending.displayName) update failed: \(failure)")
            lastError = failure
        }

        completeCommandAck(
            requestId: requestId,
            error: failure.map(MacSessionTraceStoreError.commandRejected)
        )
        return failure
    }

    #if DEBUG
    static func _shouldOpenFocusedStreamForTesting(_ status: SessionStatus) -> Bool {
        FocusedSessionConnectionPolicy.actionAfterHistoryRefresh(for: status) == .openStream
    }
    #endif
}
