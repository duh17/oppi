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
    private let reducer = TimelineReducer(environment: .none)
    private let messageQueueStore = MessageQueueStore()

    private var liveURLSession: URLSession?
    private var liveWebSocket: URLSessionWebSocketTask?
    private var liveStreamTask: Task<Void, Never>?
    private var pendingCommandChanges: [String: MacSessionCommandPendingChange] = [:]
    private var fileIndexWorkspaceId: String?

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
    private(set) var isRefreshingQueue = false
    private(set) var isUpdatingQueue = false
    private(set) var isStreaming = false
    private(set) var availableModels: [ModelInfo] = []
    private(set) var fileIndexPaths: [String] = []
    private(set) var sessionChangedFiles: [SessionChangedFile] = []
    private(set) var sessionChangedFileCount = 0
    private(set) var sessionChangedFilesOverflow = 0
    private(set) var selectedSessionDiff: WorkspaceReviewDiffResponse?
    private(set) var selectedSessionFilePreview: MacSessionFilePreview?
    private(set) var pendingAskRequests: [AskRequest] = []
    var busyStreamingBehavior: StreamingBehavior = .followUp
    private(set) var messageQueueError: String?
    private(set) var modelLoadError: String?
    private(set) var fileIndexError: String?
    private(set) var sessionChangesError: String?
    private(set) var sessionDiffError: String?
    private(set) var sessionFilePreviewError: String?
    private(set) var lastError: String?
    private(set) var lastLoadedAt: Date?

    var items: [ChatItem] { reducer.items }
    var currentAskRequest: AskRequest? { pendingAskRequests.first }
    var messageQueue: MessageQueueState { messageQueueStore.queue(for: selectedTarget?.sessionId) }

    var showsMessageQueue: Bool {
        session?.status == .busy || !messageQueue.steering.isEmpty || !messageQueue.followUp.isEmpty
    }

    var thinkingLevel: MacComposerThinkingLevel {
        MacComposerThinkingLevel(sessionValue: session?.thinkingLevel)
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

    func select(_ target: MacSelectedSessionTarget) {
        guard selectedTarget != target else { return }
        stopLiveStream()
        selectedTarget = target
        session = target.summary.session
        lastError = nil
        pendingCommandChanges = [:]
        pendingAskRequests = []
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
            fileIndexWorkspaceId = nil
            fileIndexPaths = []
        }
        messageQueueStore.clear(sessionId: target.sessionId)
        reducer.reset()
    }

    func clearSelection() {
        stopLiveStream()
        let previousSessionId = selectedTarget?.sessionId
        selectedTarget = nil
        session = nil
        lastError = nil
        pendingCommandChanges = [:]
        pendingAskRequests = []
        messageQueueError = nil
        fileIndexWorkspaceId = nil
        fileIndexPaths = []
        fileIndexError = nil
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
        reducer.reset()
    }

    func loadSelectedFromLocalConfig() async {
        guard let selectedTarget else { return }
        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir),
              let baseURL = MacServerLifecycle.defaultBaseURL else {
            lastError = "Local server config is not initialized yet."
            return
        }

        let target = selectedTarget
        let client = MacWorkspaceClient(baseURL: baseURL, token: token)
        await load(target: target, client: client)
        guard self.selectedTarget == target, !Task.isCancelled else { return }
        await loadSessionChanges(target: target, client: client)
        guard self.selectedTarget == target, !Task.isCancelled else { return }
        await refreshQueue(target: target, client: client)
        guard self.selectedTarget == target, !Task.isCancelled else { return }
        startLiveStream(target: target, baseURL: baseURL, token: token)
    }

    func load(target: MacSelectedSessionTarget, client: MacWorkspaceClient) async {
        select(target)
        isLoading = true
        lastError = nil
        do {
            let page = try await client.getWorkspaceSessionTracePage(
                workspaceId: target.workspaceId,
                sessionId: target.sessionId
            )
            guard selectedTarget == target, !Task.isCancelled else {
                isLoading = false
                return
            }
            session = page.session
            reducer.loadSession(
                Self.timelineTrace(from: page.trace, session: page.session),
                preserveOrphans: false
            )
            if !page.session.status.isRunning {
                reducer.finalizeTerminalArtifactsAsInterrupted()
            }
            lastLoadedAt = Date()
        } catch {
            macSessionTraceLogger.warning("Session trace load failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    @discardableResult
    func sendPromptFromLocalConfig(_ text: String, attachments: [MacPendingAttachment] = []) async -> Bool {
        guard let selectedTarget else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!trimmed.isEmpty || !attachments.isEmpty), canSendMessage else { return false }

        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir),
              let baseURL = MacServerLifecycle.defaultBaseURL else {
            lastError = "Local server config is not initialized yet."
            return false
        }

        return await sendPrompt(
            trimmed,
            attachments: attachments,
            target: selectedTarget,
            client: MacWorkspaceClient(baseURL: baseURL, token: token)
        )
    }

    func loadAvailableModelsFromLocalConfig() async {
        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir),
              let baseURL = MacServerLifecycle.defaultBaseURL else {
            modelLoadError = "Local server config is not initialized yet."
            return
        }

        await loadAvailableModels(client: MacWorkspaceClient(baseURL: baseURL, token: token))
    }

    func loadAvailableModels(client: MacWorkspaceClient) async {
        isLoadingModels = true
        modelLoadError = nil
        do {
            availableModels = try await client.listModels()
        } catch {
            macSessionTraceLogger.warning("Model list load failed: \(error.localizedDescription, privacy: .public)")
            modelLoadError = error.localizedDescription
        }
        isLoadingModels = false
    }

    func loadFileIndexFromLocalConfig() async {
        guard let selectedTarget else { return }
        if fileIndexWorkspaceId == selectedTarget.workspaceId, !fileIndexPaths.isEmpty { return }
        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir),
              let baseURL = MacServerLifecycle.defaultBaseURL else {
            fileIndexError = "Local server config is not initialized yet."
            return
        }

        await loadFileIndex(
            workspaceId: selectedTarget.workspaceId,
            client: MacWorkspaceClient(baseURL: baseURL, token: token)
        )
    }

    func loadFileIndex(workspaceId: String, client: MacWorkspaceClient) async {
        isLoadingFileIndex = true
        fileIndexError = nil
        defer { isLoadingFileIndex = false }
        do {
            let response = try await client.fetchFileIndex(workspaceId: workspaceId)
            guard selectedTarget?.workspaceId == workspaceId, !Task.isCancelled else { return }
            fileIndexWorkspaceId = workspaceId
            fileIndexPaths = response.paths
        } catch {
            macSessionTraceLogger.warning("File index load failed: \(error.localizedDescription, privacy: .public)")
            fileIndexError = error.localizedDescription
        }
    }

    func loadSessionChangesFromLocalConfig() async {
        guard let selectedTarget else { return }
        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir),
              let baseURL = MacServerLifecycle.defaultBaseURL else {
            sessionChangesError = "Local server config is not initialized yet."
            return
        }

        await loadSessionChanges(
            target: selectedTarget,
            client: MacWorkspaceClient(baseURL: baseURL, token: token)
        )
    }

    func loadSessionChanges(target: MacSelectedSessionTarget, client: MacWorkspaceClient) async {
        isLoadingSessionChanges = true
        sessionChangesError = nil
        defer { isLoadingSessionChanges = false }
        do {
            let response = try await client.listSessionChanges(
                workspaceId: target.workspaceId,
                sessionId: target.sessionId
            )
            guard selectedTarget == target, !Task.isCancelled else { return }
            sessionChangedFiles = response.files
            sessionChangedFileCount = response.changedFileCount
            sessionChangedFilesOverflow = response.changedFilesOverflow
        } catch {
            macSessionTraceLogger.warning("Session changes load failed: \(error.localizedDescription, privacy: .public)")
            sessionChangesError = error.localizedDescription
        }
    }

    func loadSessionDiffFromLocalConfig(path: String) async {
        guard let selectedTarget else { return }
        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir),
              let baseURL = MacServerLifecycle.defaultBaseURL else {
            sessionDiffError = "Local server config is not initialized yet."
            return
        }

        await loadSessionDiff(
            path: path,
            target: selectedTarget,
            client: MacWorkspaceClient(baseURL: baseURL, token: token)
        )
    }

    func loadSessionDiff(path: String, target: MacSelectedSessionTarget, client: MacWorkspaceClient) async {
        isLoadingSessionDiff = true
        sessionDiffError = nil
        defer { isLoadingSessionDiff = false }
        do {
            let diff = try await client.getSessionDiff(
                workspaceId: target.workspaceId,
                sessionId: target.sessionId,
                path: path
            )
            guard selectedTarget == target, !Task.isCancelled else { return }
            selectedSessionDiff = diff
        } catch {
            macSessionTraceLogger.warning("Session diff load failed: \(error.localizedDescription, privacy: .public)")
            sessionDiffError = error.localizedDescription
        }
    }

    func clearSessionDiff() {
        selectedSessionDiff = nil
        sessionDiffError = nil
    }

    func loadSessionFilePreviewFromLocalConfig(path: String) async {
        guard let selectedTarget else { return }
        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir),
              let baseURL = MacServerLifecycle.defaultBaseURL else {
            sessionFilePreviewError = "Local server config is not initialized yet."
            return
        }

        await loadSessionFilePreview(
            path: path,
            target: selectedTarget,
            client: MacWorkspaceClient(baseURL: baseURL, token: token)
        )
    }

    func loadSessionFilePreview(path: String, target: MacSelectedSessionTarget, client: MacWorkspaceClient) async {
        isLoadingSessionFilePreview = true
        sessionFilePreviewError = nil
        defer { isLoadingSessionFilePreview = false }
        do {
            let data = try await client.getSessionRawFileData(
                workspaceId: target.workspaceId,
                sessionId: target.sessionId,
                path: path
            )
            guard selectedTarget == target, !Task.isCancelled else { return }
            selectedSessionFilePreview = MacSessionFilePreview(path: path, data: data)
        } catch {
            macSessionTraceLogger.warning("Session file preview load failed: \(error.localizedDescription, privacy: .public)")
            sessionFilePreviewError = error.localizedDescription
        }
    }

    func clearSessionFilePreview() {
        selectedSessionFilePreview = nil
        sessionFilePreviewError = nil
    }

    func refreshQueueFromLocalConfig() async {
        guard let selectedTarget else { return }
        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir),
              let baseURL = MacServerLifecycle.defaultBaseURL else {
            messageQueueError = "Local server config is not initialized yet."
            return
        }

        await refreshQueue(
            target: selectedTarget,
            client: MacWorkspaceClient(baseURL: baseURL, token: token)
        )
    }

    func applyQueueMutationFromLocalConfig(_ request: MacMessageQueueMutationRequest) async throws {
        guard let selectedTarget else { return }
        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir),
              let baseURL = MacServerLifecycle.defaultBaseURL else {
            let message = "Local server config is not initialized yet."
            messageQueueError = message
            throw MacSessionTraceStoreError.commandRejected(message)
        }

        try await applyQueueMutation(
            request,
            target: selectedTarget,
            client: MacWorkspaceClient(baseURL: baseURL, token: token)
        )
    }

    func refreshQueue(target: MacSelectedSessionTarget, client: MacWorkspaceClient) async {
        isRefreshingQueue = true
        messageQueueError = nil
        do {
            let requestId = UUID().uuidString
            _ = try await sendSessionCommand(
                .getQueue(requestId: requestId),
                target: target,
                client: client,
                requestId: requestId
            )
        } catch {
            macSessionTraceLogger.debug("Queue refresh failed: \(error.localizedDescription, privacy: .public)")
            messageQueueError = error.localizedDescription
        }
        isRefreshingQueue = false
    }

    func applyQueueMutation(
        _ request: MacMessageQueueMutationRequest,
        target: MacSelectedSessionTarget,
        client: MacWorkspaceClient
    ) async throws {
        isUpdatingQueue = true
        messageQueueError = nil
        defer { isUpdatingQueue = false }

        do {
            let requestId = UUID().uuidString
            _ = try await sendSessionCommand(
                .setQueue(
                    baseVersion: request.baseVersion,
                    steering: request.steering,
                    followUp: request.followUp,
                    requestId: requestId
                ),
                target: target,
                client: client,
                requestId: requestId
            )
        } catch {
            messageQueueError = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    func sendPrompt(
        _ text: String,
        attachments pendingAttachments: [MacPendingAttachment] = [],
        target: MacSelectedSessionTarget,
        client: MacWorkspaceClient
    ) async -> Bool {
        let isBusy = session?.status.isRunning == true
        let requestID = UUID().uuidString
        let uploadedAttachments: [ChatAttachmentRef]
        do {
            uploadedAttachments = try await uploadPendingAttachments(
                pendingAttachments,
                requestID: requestID,
                target: target,
                client: client
            )
        } catch {
            reducer.appendSystemEvent("Attachment upload failed: \(error.localizedDescription)")
            macSessionTraceLogger.warning("Attachment upload failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            return false
        }

        let messageText = MacAttachmentDisplayFormatter.appendAttachedFilesBlock(
            to: text,
            attachments: uploadedAttachments
        )
        let optimisticID = isBusy ? nil : reducer.appendUserMessage(messageText)
        let queuedKind: MessageQueueKind? = isBusy
            ? (busyStreamingBehavior == .steer ? .steer : .followUp)
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
        let sentOverStream: Bool
        do {
            let attachments = uploadedAttachments.isEmpty ? nil : uploadedAttachments
            let message: ClientMessage
            if isBusy {
                switch busyStreamingBehavior {
                case .steer:
                    message = .steer(message: text, attachments: attachments, requestId: requestID, clientTurnId: requestID)
                case .followUp:
                    message = .followUp(message: text, attachments: attachments, requestId: requestID, clientTurnId: requestID)
                }
            } else {
                message = .prompt(message: text, attachments: attachments, requestId: requestID)
            }
            sentOverStream = try await sendSessionCommand(message, target: target, client: client)
        } catch {
            if let optimisticID {
                reducer.removeItem(id: optimisticID)
            }
            if let queuedKind, let optimisticQueueItem {
                messageQueueStore.removeQueuedItem(
                    for: target.sessionId,
                    kind: queuedKind,
                    id: optimisticQueueItem.id,
                    messageFallback: messageText
                )
            }
            reducer.appendSystemEvent("Send failed: \(error.localizedDescription)")
            macSessionTraceLogger.warning("Session command send failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            isSending = false
            return false
        }

        isSending = false
        if !sentOverStream {
            if isBusy {
                await refreshQueue(target: target, client: client)
            } else {
                await load(target: target, client: client)
            }
        }
        return true
    }

    private func uploadPendingAttachments(
        _ attachments: [MacPendingAttachment],
        requestID: String,
        target: MacSelectedSessionTarget,
        client: MacWorkspaceClient
    ) async throws -> [ChatAttachmentRef] {
        guard !attachments.isEmpty else { return [] }

        isPreparingAttachments = true
        attachmentPreparationText = "Uploading attachments…"
        defer {
            isPreparingAttachments = false
            attachmentPreparationText = nil
        }

        var uploaded: [ChatAttachmentRef] = []
        for (index, attachment) in attachments.enumerated() {
            attachmentPreparationText = "Uploading attachment \(index + 1) of \(attachments.count)…"
            let upload = try await client.createSessionAttachmentUpload(
                workspaceId: target.workspaceId,
                sessionId: target.sessionId,
                name: attachment.displayName,
                mimeType: attachment.mimeType,
                sizeBytes: attachment.sizeBytes
            )
            let data = try Data(contentsOf: attachment.url)
            let ref = try await client.uploadSessionAttachmentContent(
                workspaceId: target.workspaceId,
                sessionId: target.sessionId,
                attachmentId: upload.uploadId,
                data: data,
                contentType: attachment.mimeType
            )
            uploaded.append(ref)
            macSessionTraceLogger.debug(
                "Uploaded attachment for request \(requestID, privacy: .public): \(attachment.displayName, privacy: .public)"
            )
        }
        return uploaded
    }

    func setThinkingLevelFromLocalConfig(_ level: MacComposerThinkingLevel) async {
        guard let selectedTarget, canSendMessage else { return }
        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir),
              let baseURL = MacServerLifecycle.defaultBaseURL else {
            lastError = "Local server config is not initialized yet."
            return
        }

        await setThinkingLevel(
            level,
            target: selectedTarget,
            client: MacWorkspaceClient(baseURL: baseURL, token: token)
        )
    }

    func setModelFromLocalConfig(_ model: ModelInfo) async {
        guard let selectedTarget, canSendMessage else { return }
        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir),
              let baseURL = MacServerLifecycle.defaultBaseURL else {
            lastError = "Local server config is not initialized yet."
            return
        }

        await setModel(
            model,
            target: selectedTarget,
            client: MacWorkspaceClient(baseURL: baseURL, token: token)
        )
    }

    func setThinkingLevel(
        _ level: MacComposerThinkingLevel,
        target: MacSelectedSessionTarget,
        client: MacWorkspaceClient
    ) async {
        guard thinkingLevel != level else { return }
        let previousLevel = session?.thinkingLevel
        let optimisticLevel = level.rawValue
        let requestId = UUID().uuidString
        session?.thinkingLevel = optimisticLevel
        pendingCommandChanges[requestId] = .thinking(previous: previousLevel, optimistic: optimisticLevel)
        isUpdatingThinkingLevel = true
        lastError = nil
        let sentOverStream: Bool
        do {
            sentOverStream = try await sendSessionCommand(
                .setThinkingLevel(level: level.protocolLevel, requestId: requestId),
                target: target,
                client: client,
                requestId: requestId
            )
        } catch {
            pendingCommandChanges[requestId] = nil
            if !(error is MacSessionTraceStoreError) {
                session?.thinkingLevel = previousLevel
                reducer.appendSystemEvent("Thinking level update failed: \(error.localizedDescription)")
                lastError = error.localizedDescription
            }
            macSessionTraceLogger.warning("Thinking level update failed: \(error.localizedDescription, privacy: .public)")
            isUpdatingThinkingLevel = false
            return
        }

        isUpdatingThinkingLevel = false
        if !sentOverStream {
            await load(target: target, client: client)
        }
    }

    func applyServerMessageForTesting(_ message: ServerMessage, target: MacSelectedSessionTarget) {
        applySessionProjection(from: message, target: target)
        applyAskEffects(from: message, target: target)
        applyQueueEffects(from: message, target: target)
    }

    func setModel(
        _ model: ModelInfo,
        target: MacSelectedSessionTarget,
        client: MacWorkspaceClient
    ) async {
        guard !MacModelSelection.isCurrent(model: model, currentModel: session?.model) else { return }
        let previousModel = session?.model
        let optimisticModel = MacModelSelection.fullModelID(for: model)
        let requestId = UUID().uuidString
        session?.model = optimisticModel
        pendingCommandChanges[requestId] = .model(previous: previousModel, optimistic: optimisticModel)
        isUpdatingModel = true
        lastError = nil
        let sentOverStream: Bool
        do {
            sentOverStream = try await sendSessionCommand(
                .setModel(
                    provider: model.provider,
                    modelId: MacModelSelection.commandModelID(for: model),
                    requestId: requestId
                ),
                target: target,
                client: client,
                requestId: requestId
            )
        } catch {
            pendingCommandChanges[requestId] = nil
            if !(error is MacSessionTraceStoreError) {
                session?.model = previousModel
                reducer.appendSystemEvent("Model update failed: \(error.localizedDescription)")
                lastError = error.localizedDescription
            }
            macSessionTraceLogger.warning("Model update failed: \(error.localizedDescription, privacy: .public)")
            isUpdatingModel = false
            return
        }

        isUpdatingModel = false
        if !sentOverStream {
            await load(target: target, client: client)
        }
    }

    func submitAskResponseFromLocalConfig(request: AskRequest, draft: MacAskResponseDraft) async {
        guard let selectedTarget else { return }
        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir),
              let baseURL = MacServerLifecycle.defaultBaseURL else {
            lastError = "Local server config is not initialized yet."
            return
        }

        await sendAskResponse(
            request: request,
            message: MacAskResponseEncoder.responseMessage(request: request, draft: draft),
            target: selectedTarget,
            client: MacWorkspaceClient(baseURL: baseURL, token: token)
        )
    }

    func ignoreAskRequestFromLocalConfig(_ request: AskRequest) async {
        guard let selectedTarget else { return }
        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir),
              let baseURL = MacServerLifecycle.defaultBaseURL else {
            lastError = "Local server config is not initialized yet."
            return
        }

        await sendAskResponse(
            request: request,
            message: .extensionUIResponse(id: request.id, cancelled: true),
            target: selectedTarget,
            client: MacWorkspaceClient(baseURL: baseURL, token: token)
        )
    }

    private func sendAskResponse(
        request: AskRequest,
        message: ClientMessage,
        target: MacSelectedSessionTarget,
        client: MacWorkspaceClient
    ) async {
        lastError = nil
        do {
            _ = try await sendSessionCommand(message, target: target, client: client)
            removeAskRequest(id: request.id)
        } catch {
            macSessionTraceLogger.warning("Ask response failed: \(error.localizedDescription, privacy: .public)")
            reducer.appendSystemEvent("Ask response failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    private func startLiveStream(target: MacSelectedSessionTarget, baseURL: URL, token: String) {
        stopLiveStream()
        guard let streamURL = Self.makeStreamURL(baseURL: baseURL, target: target) else {
            lastError = "Invalid session stream URL."
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        let urlSession = URLSession(
            configuration: config,
            delegate: LocalServerTrustDelegate(),
            delegateQueue: nil
        )
        var request = URLRequest(url: streamURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let webSocket = urlSession.webSocketTask(with: request)
        liveURLSession = urlSession
        liveWebSocket = webSocket
        isStreaming = true
        webSocket.resume()

        liveStreamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.receiveLiveStream(webSocket: webSocket, target: target)
        }
    }

    private func receiveLiveStream(webSocket: URLSessionWebSocketTask, target: MacSelectedSessionTarget) async {
        while !Task.isCancelled {
            do {
                let message = try await webSocket.receive()
                let text: String
                switch message {
                case .string(let value):
                    text = value
                case .data(let data):
                    text = String(data: data, encoding: .utf8) ?? ""
                @unknown default:
                    continue
                }

                guard selectedTarget == target else { break }
                let streamMessage = try StreamMessage.decode(from: text)
                applySessionProjection(from: streamMessage.message, target: target)
                applyAskEffects(from: streamMessage.message, target: target)
                applyQueueEffects(from: streamMessage.message, target: target)
                _ = applyPendingCommandResult(from: streamMessage.message)
                let events = ServerMessageEffects.timelineEvents(
                    for: streamMessage.message,
                    sessionId: target.sessionId
                )
                if !events.isEmpty {
                    reducer.processBatch(events)
                }
            } catch {
                if !Task.isCancelled, selectedTarget == target {
                    macSessionTraceLogger.debug("Session live stream ended: \(error.localizedDescription, privacy: .public)")
                }
                break
            }
        }

        if liveWebSocket === webSocket {
            liveWebSocket = nil
            liveURLSession = nil
            isStreaming = false
        }
    }

    private func stopLiveStream() {
        liveStreamTask?.cancel()
        liveStreamTask = nil
        liveWebSocket?.cancel(with: .goingAway, reason: nil)
        liveWebSocket = nil
        liveURLSession = nil
        isStreaming = false
    }

    private func sendSessionCommand(
        _ message: ClientMessage,
        target: MacSelectedSessionTarget,
        client: MacWorkspaceClient,
        requestId: String? = nil
    ) async throws -> Bool {
        let sentOverStream = try await sendLiveMessageIfConnected(message)
        if !sentOverStream {
            let messages = try await client.sendWorkspaceSessionCommand(
                workspaceId: target.workspaceId,
                sessionId: target.sessionId,
                message: message
            )
            try processCommandResponseMessages(messages, target: target, requestId: requestId)
        }
        return sentOverStream
    }

    private func sendLiveMessageIfConnected(_ message: ClientMessage) async throws -> Bool {
        guard let webSocket = liveWebSocket, isStreaming else { return false }
        try await webSocket.send(.string(message.jsonString()))
        return true
    }

    private func processCommandResponseMessages(
        _ messages: [ServerMessage],
        target: MacSelectedSessionTarget,
        requestId: String?
    ) throws {
        var matchedFailure: String?
        for message in messages {
            applySessionProjection(from: message, target: target)
            applyAskEffects(from: message, target: target)
            applyQueueEffects(from: message, target: target)
            if let failure = applyCommandResultFailure(from: message, requestId: requestId) {
                matchedFailure = failure
            }
        }
        if let matchedFailure, requestId != nil {
            throw MacSessionTraceStoreError.commandRejected(matchedFailure)
        }
    }

    private func applySessionProjection(from message: ServerMessage, target: MacSelectedSessionTarget) {
        switch message {
        case .connected(let session) where session.id == target.sessionId:
            self.session = session
        case .state(let session) where session.id == target.sessionId:
            self.session = session
            if !session.status.isRunning {
                reducer.finalizeTerminalArtifactsAsInterrupted()
            }
        case .sessionSummary(let summary) where summary.id == target.sessionId:
            session = summary.session
            if !summary.status.isRunning {
                reducer.finalizeTerminalArtifactsAsInterrupted()
            }
        default:
            break
        }
    }

    private func applyAskEffects(from message: ServerMessage, target: MacSelectedSessionTarget) {
        if case .extensionUIRequest(let request) = message,
           let ask = Self.makeAskRequest(from: request, target: target) {
            upsertAskRequest(ask)
        }

        let cleanup = ServerMessageEffects.cleanupEffects(
            for: message,
            routedSessionId: target.sessionId,
            isFocusedSession: true
        )
        for sessionId in cleanup.clearAskSessionIds where sessionId == target.sessionId {
            pendingAskRequests = []
        }
        for requestId in cleanup.clearAskRequestIds {
            removeAskRequest(id: requestId)
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

    private static func makeAskRequest(
        from request: ExtensionUIRequest,
        target: MacSelectedSessionTarget
    ) -> AskRequest? {
        guard request.sessionId == target.sessionId else { return nil }

        switch request.method {
        case "ask":
            guard let questions = request.askQuestions, !questions.isEmpty else { return nil }
            return AskRequest(
                id: request.id,
                sessionId: request.sessionId,
                questions: questions,
                allowCustom: request.allowCustom ?? true,
                timeout: request.timeout,
                workspaceId: request.workspaceId ?? target.workspaceId
            )

        case "select":
            guard let options = request.options, !options.isEmpty else { return nil }
            return AskRequest(
                id: request.id,
                sessionId: request.sessionId,
                questions: [
                    AskQuestion(
                        id: MacAskResponseEncoder.inlineQuestionId,
                        question: Self.inlinePrompt(from: request, fallback: "Choose an option"),
                        options: options.map { AskOption(value: $0, label: $0) },
                        multiSelect: false
                    ),
                ],
                allowCustom: false,
                timeout: request.timeout,
                workspaceId: request.workspaceId ?? target.workspaceId,
                responseEncoding: .extensionSelect
            )

        case "confirm":
            return AskRequest(
                id: request.id,
                sessionId: request.sessionId,
                questions: [
                    AskQuestion(
                        id: MacAskResponseEncoder.inlineQuestionId,
                        question: Self.inlinePrompt(from: request, fallback: "Confirm this action?"),
                        options: [
                            AskOption(value: MacAskResponseEncoder.confirmValue, label: "Confirm"),
                            AskOption(value: MacAskResponseEncoder.cancelValue, label: "Cancel"),
                        ],
                        multiSelect: false
                    ),
                ],
                allowCustom: false,
                timeout: request.timeout,
                workspaceId: request.workspaceId ?? target.workspaceId,
                responseEncoding: .extensionConfirm
            )

        case "input":
            return AskRequest(
                id: request.id,
                sessionId: request.sessionId,
                questions: [
                    AskQuestion(
                        id: MacAskResponseEncoder.inlineQuestionId,
                        question: Self.inlinePrompt(from: request, fallback: "Enter a response"),
                        options: [],
                        multiSelect: false
                    ),
                ],
                allowCustom: true,
                timeout: request.timeout,
                workspaceId: request.workspaceId ?? target.workspaceId,
                customPlaceholder: request.placeholder,
                responseEncoding: .extensionInput
            )

        default:
            return nil
        }
    }

    private static func inlinePrompt(from request: ExtensionUIRequest, fallback: String) -> String {
        let prompt = [request.title, request.message]
            .compactMap { value -> String? in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: "\n\n")
        return prompt.isEmpty ? fallback : prompt
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

    private func applyCommandResultFailure(from message: ServerMessage, requestId: String?) -> String? {
        if let pendingFailure = applyPendingCommandResult(from: message) {
            return pendingFailure
        }

        guard case .commandResult(let command, let resultRequestId, let success, _, let error) = message,
              !success,
              let requestId,
              resultRequestId == requestId else {
            return nil
        }

        return error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? error ?? "\(command) failed"
            : "\(command) failed"
    }

    private func applyPendingCommandResult(from message: ServerMessage) -> String? {
        guard case .commandResult(let command, let requestId, let success, _, let error) = message,
              let requestId,
              let pending = pendingCommandChanges.removeValue(forKey: requestId) else {
            return nil
        }

        guard !success else { return nil }

        let message = error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? error ?? "\(command) failed"
            : "\(command) failed"
        pending.rollbackIfStillOptimistic(session: &session)
        reducer.appendSystemEvent("\(pending.displayName) update failed: \(message)")
        lastError = message
        return message
    }

    private static func makeStreamURL(baseURL: URL, target: MacSelectedSessionTarget) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components.path = "/workspaces/\(target.workspaceId)/sessions/\(target.sessionId)/stream"
        components.queryItems = nil
        return components.url
    }

    private static func timelineTrace(from trace: [TraceEvent], session: Session) -> [TraceEvent] {
        if !trace.isEmpty { return trace }
        guard let firstMessage = session.firstMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !firstMessage.isEmpty else {
            return trace
        }
        return [
            TraceEvent(
                id: "session-\(session.id)-first-message-fallback",
                type: .user,
                timestamp: ISO8601DateFormatter().string(from: session.createdAt),
                text: firstMessage
            )
        ]
    }
}
