import Foundation

protocol OppiMacAPIClient: Sendable {
    func health() async throws -> Bool
    func me() async throws -> User
    func listWorkspaces() async throws -> [Workspace]
    func createWorkspace(_ request: CreateWorkspaceRequest) async throws -> Workspace
    func updateWorkspace(id: String, _ request: UpdateWorkspaceRequest) async throws -> Workspace
    func deleteWorkspace(id: String) async throws
    func listSkills() async throws -> [SkillInfo]
    func getSkillDetail(name: String) async throws -> SkillDetail
    func getSkillFile(name: String, path: String) async throws -> String
    func listWorkspaceSessions(workspaceId: String) async throws -> [Session]
    func getWorkspaceGraph(
        workspaceId: String,
        sessionId: String?,
        includeEntryGraph: Bool,
        entrySessionId: String?,
        includePaths: Bool
    ) async throws -> WorkspaceGraphResponse
    func createWorkspaceSession(workspaceId: String, name: String?, model: String?) async throws -> Session
    func resumeWorkspaceSession(workspaceId: String, sessionId: String) async throws -> Session
    func getWorkspaceSession(
        workspaceId: String,
        sessionId: String,
        traceView: APIClient.SessionTraceView
    ) async throws -> (session: Session, trace: [TraceEvent])
    func stopWorkspaceSession(workspaceId: String, sessionId: String) async throws -> Session
    func deleteWorkspaceSession(workspaceId: String, sessionId: String) async throws
}

extension APIClient: OppiMacAPIClient {}

@MainActor
protocol OppiMacStreamingClient: AnyObject {
    var status: WebSocketClient.Status { get }
    func connect(sessionId: String, workspaceId: String) -> AsyncStream<ServerMessage>
    func send(_ message: ClientMessage) async throws
    func disconnect()
}

extension WebSocketClient: OppiMacStreamingClient {}

@MainActor @Observable
final class OppiMacStore {
    struct ConnectionDraft: Codable, Equatable {
        var host: String = "localhost"
        var port: String = "7749"
        var token: String = ""
        var name: String = "Chen"
    }

    enum FocusColumn: String, Sendable {
        case sessions
        case timeline
        case inspector
    }

    struct DisplayPreferences: Codable, Equatable {
        var timelineTextScale: Double = 1.15
    }

    private static let connectionDraftDefaultsKey = "dev.chenda.OppiMac.connectionDraft"
    private static let displayPreferencesDefaultsKey = "dev.chenda.OppiMac.displayPreferences"

    private static let timelineInitialRenderWindow = 240
    private static let timelineRenderWindowStep = 200

    var draft: ConnectionDraft
    var timelineTextScale: Double = DisplayPreferences().timelineTextScale

    var isConnecting = false
    var isConnected = false

    var isLoadingWorkspaces = false
    var isLoadingSessions = false
    var isLoadingTimeline = false

    var isStreamConnecting = false
    var isStreamConnected = false

    var currentUserName: String?

    var workspaces: [Workspace] = []
    var selectedWorkspaceID: String?

    var skills: [SkillInfo] = []
    var selectedSkillName: String?
    var selectedSkillDetail: SkillDetail?
    var selectedSkillFilePath: String?
    var selectedSkillFileContent: String = ""

    var isLoadingSkills = false
    var isLoadingSkillDetail = false
    var isLoadingSkillFile = false

    var sessions: [Session] = []
    var selectedSessionID: String?

    var selectedWorkspaceSessionGraph: WorkspaceGraphResponse.SessionGraph?
    var selectedWorkspaceGraphGeneratedAt: Date?
    var isLoadingWorkspaceGraph = false

    var timelineItems: [ReviewTimelineItem] = []
    var selectedTimelineItemID: String?

    var timelineSearchQuery: String = ""
    var selectedKinds: Set<ReviewTimelineKind> = Set(ReviewTimelineKind.allCases)
    var timelineRenderWindow: Int = 240

    var pendingPermissions: [PermissionRequest] = []

    var composerText: String = ""
    var isSendingPrompt = false

    var lastErrorMessage: String?
    var requestedFocusColumn: FocusColumn?
    private(set) var composerFocusRequestID = 0

    private let userDefaults: UserDefaults
    private let apiClientFactory: (URL, String) -> any OppiMacAPIClient
    private let streamingClientFactory: (ServerCredentials) -> any OppiMacStreamingClient

    private var credentials: ServerCredentials?
    private var apiClient: (any OppiMacAPIClient)?

    private var streamingClient: (any OppiMacStreamingClient)?
    private var streamTask: Task<Void, Never>?
    private var streamWorkspaceID: String?
    private var streamSessionID: String?

    private var liveAssistantItemID: String?
    private var liveAssistantText = ""
    private var liveAssistantTimestamp: Date?

    private var liveThinkingItemID: String?
    private var liveThinkingText = ""
    private var liveThinkingTimestamp: Date?

    private var currentToolCallKey: String?
    private var liveToolOutputByCallKey: [String: String] = [:]
    private var liveToolOutputErrorByCallKey: [String: Bool] = [:]
    private var syntheticToolCallCounter = 0

    init(
        userDefaults: UserDefaults = .standard,
        apiClientFactory: @escaping (URL, String) -> any OppiMacAPIClient = { baseURL, token in
            APIClient(baseURL: baseURL, token: token)
        },
        streamingClientFactory: @escaping (ServerCredentials) -> any OppiMacStreamingClient = { credentials in
            WebSocketClient(credentials: credentials)
        }
    ) {
        self.userDefaults = userDefaults
        self.apiClientFactory = apiClientFactory
        self.streamingClientFactory = streamingClientFactory

        if let data = userDefaults.data(forKey: Self.connectionDraftDefaultsKey),
           let persisted = try? JSONDecoder().decode(ConnectionDraft.self, from: data) {
            draft = persisted
        } else {
            draft = ConnectionDraft()
        }

        if let data = userDefaults.data(forKey: Self.displayPreferencesDefaultsKey),
           let persisted = try? JSONDecoder().decode(DisplayPreferences.self, from: data) {
            timelineTextScale = Self.clampedTextScale(persisted.timelineTextScale)
        }
    }

    var selectedWorkspace: Workspace? {
        guard let selectedWorkspaceID else { return nil }
        return workspaces.first { $0.id == selectedWorkspaceID }
    }

    var selectedSession: Session? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    var selectedWorkspaceSessionTree: [OppiMacSessionTreeNode] {
        OppiMacSessionTreeBuilder.build(
            sessions: sessions,
            graph: selectedWorkspaceSessionGraph
        )
    }

    var selectedTimelineItem: ReviewTimelineItem? {
        guard let selectedTimelineItemID else { return nil }
        return timelineItems.first { $0.id == selectedTimelineItemID }
    }

    var selectedSessionPendingPermissions: [PermissionRequest] {
        guard let selectedSessionID else { return [] }
        return pendingPermissions.filter { $0.sessionId == selectedSessionID }
    }

    var filteredTimelineItems: [ReviewTimelineItem] {
        timelineItems.filter { item in
            guard selectedKinds.contains(item.kind) else { return false }
            return ReviewTimelineBuilder.matches(item, query: timelineSearchQuery)
        }
    }

    var renderedTimelineItems: [ReviewTimelineItem] {
        let filtered = filteredTimelineItems

        guard shouldApplyTimelineWindow else {
            return filtered
        }

        guard filtered.count > timelineRenderWindow else {
            return filtered
        }

        if let selectedTimelineItemID,
           let selectedIndex = filtered.firstIndex(where: { $0.id == selectedTimelineItemID }) {
            let defaultWindowStart = filtered.count - timelineRenderWindow
            if selectedIndex < defaultWindowStart {
                let windowEnd = selectedIndex
                let windowStart = max(0, windowEnd - timelineRenderWindow + 1)
                return Array(filtered[windowStart...windowEnd])
            }
        }

        return Array(filtered.suffix(timelineRenderWindow))
    }

    var hiddenTimelineItemCount: Int {
        max(0, filteredTimelineItems.count - renderedTimelineItems.count)
    }

    private var shouldApplyTimelineWindow: Bool {
        timelineSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func requestFocus(_ column: FocusColumn) {
        requestedFocusColumn = column
    }

    func requestComposerFocus() {
        composerFocusRequestID &+= 1
    }

    func increaseTimelineTextScale() {
        setTimelineTextScale(timelineTextScale + 0.05)
    }

    func decreaseTimelineTextScale() {
        setTimelineTextScale(timelineTextScale - 0.05)
    }

    func resetTimelineTextScale() {
        setTimelineTextScale(DisplayPreferences().timelineTextScale)
    }

    func setTimelineTextScale(_ value: Double) {
        let clamped = Self.clampedTextScale(value)
        guard abs(clamped - timelineTextScale) > 0.0001 else { return }

        timelineTextScale = clamped
        persistDisplayPreferences()
    }

    func toggleKind(_ kind: ReviewTimelineKind) {
        if selectedKinds.contains(kind) {
            if selectedKinds.count > 1 {
                selectedKinds.remove(kind)
            }
        } else {
            selectedKinds.insert(kind)
        }
    }

    func showEarlierTimelineItems() {
        let total = filteredTimelineItems.count
        guard shouldApplyTimelineWindow else {
            return
        }

        guard total > timelineRenderWindow else {
            return
        }

        timelineRenderWindow = min(total, timelineRenderWindow + Self.timelineRenderWindowStep)
    }

    func resetTimelineRenderWindow() {
        timelineRenderWindow = Self.timelineInitialRenderWindow
    }

    func connect() async {
        lastErrorMessage = nil

        let host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = draft.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !host.isEmpty else {
            lastErrorMessage = "Host is required."
            return
        }

        guard !token.isEmpty else {
            lastErrorMessage = "Token is required."
            return
        }

        guard let port = Int(draft.port), (1...65_535).contains(port) else {
            lastErrorMessage = "Port must be a valid number between 1 and 65535."
            return
        }

        let credentials = ServerCredentials(host: host, port: port, token: token, name: name.isEmpty ? "Mac" : name)

        if let violation = ConnectionSecurityPolicy.evaluate(credentials: credentials) {
            lastErrorMessage = violation.localizedDescription
            return
        }

        guard let baseURL = credentials.baseURL else {
            lastErrorMessage = "Invalid host or port."
            return
        }

        isConnecting = true
        defer { isConnecting = false }

        let api = apiClientFactory(baseURL, credentials.token)

        do {
            let healthy = try await api.health()
            guard healthy else {
                throw APIError.server(status: 503, message: "Server health check failed")
            }

            let user = try await api.me()

            self.credentials = credentials
            self.apiClient = api
            self.currentUserName = user.name
            self.isConnected = true

            persistDraft()

            await refreshSessions()
            requestFocus(.sessions)
        } catch {
            self.credentials = nil
            self.apiClient = nil
            self.currentUserName = nil
            self.isConnected = false
            self.lastErrorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        disconnectStream(clearPermissions: true)

        credentials = nil
        apiClient = nil

        isConnected = false
        isLoadingWorkspaces = false
        isLoadingSessions = false
        isLoadingTimeline = false

        currentUserName = nil

        workspaces = []
        selectedWorkspaceID = nil

        skills = []
        selectedSkillName = nil
        selectedSkillDetail = nil
        selectedSkillFilePath = nil
        selectedSkillFileContent = ""
        isLoadingSkills = false
        isLoadingSkillDetail = false
        isLoadingSkillFile = false

        sessions = []
        selectedSessionID = nil
        selectedWorkspaceSessionGraph = nil
        selectedWorkspaceGraphGeneratedAt = nil
        isLoadingWorkspaceGraph = false

        clearTimelineSelection()
        composerText = ""
        isSendingPrompt = false
    }

    func refreshSessions() async {
        guard let apiClient else {
            return
        }

        isLoadingWorkspaces = true
        defer { isLoadingWorkspaces = false }

        do {
            let fetchedWorkspaces = try await apiClient.listWorkspaces().sorted(by: Self.workspaceSort)
            workspaces = fetchedWorkspaces

            if let selectedWorkspaceID,
               !fetchedWorkspaces.contains(where: { $0.id == selectedWorkspaceID }) {
                self.selectedWorkspaceID = nil
            }

            if self.selectedWorkspaceID == nil {
                self.selectedWorkspaceID = fetchedWorkspaces.first?.id
            }

            await refreshSessionsForSelectedWorkspace()
        } catch {
            sessions = []
            selectedSessionID = nil
            selectedWorkspaceSessionGraph = nil
            selectedWorkspaceGraphGeneratedAt = nil
            isLoadingWorkspaceGraph = false
            clearTimelineSelection()
            pendingPermissions = []
            lastErrorMessage = error.localizedDescription
        }
    }

    func createWorkspace(
        name: String,
        description: String?,
        runtime: String,
        policyPreset: String
    ) async {
        guard let apiClient else {
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            lastErrorMessage = "Workspace name is required."
            return
        }

        let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = CreateWorkspaceRequest(
            name: trimmedName,
            description: trimmedDescription?.isEmpty == false ? trimmedDescription : nil,
            icon: nil,
            skills: [],
            runtime: runtime,
            policyPreset: policyPreset
        )

        do {
            let created = try await apiClient.createWorkspace(request)
            upsertWorkspace(created)

            selectedWorkspaceID = created.id
            selectedSessionID = nil
            selectedWorkspaceSessionGraph = nil
            selectedWorkspaceGraphGeneratedAt = nil
            isLoadingWorkspaceGraph = false

            disconnectStream(clearPermissions: true)
            clearTimelineSelection()

            await refreshSessionsForSelectedWorkspace()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func updateSelectedWorkspace(
        name: String,
        description: String?,
        runtime: String,
        policyPreset: String
    ) async {
        guard let apiClient,
              let workspace = selectedWorkspace else {
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            lastErrorMessage = "Workspace name is required."
            return
        }

        let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = UpdateWorkspaceRequest(
            name: trimmedName,
            description: trimmedDescription?.isEmpty == false ? trimmedDescription : nil,
            runtime: runtime,
            policyPreset: policyPreset
        )

        do {
            let updated = try await apiClient.updateWorkspace(id: workspace.id, request)
            upsertWorkspace(updated)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func deleteSelectedWorkspace() async {
        guard let apiClient,
              let selectedWorkspaceID else {
            return
        }

        do {
            try await apiClient.deleteWorkspace(id: selectedWorkspaceID)

            workspaces.removeAll { $0.id == selectedWorkspaceID }
            workspaces.sort(by: Self.workspaceSort)

            sessions = []
            selectedSessionID = nil
            selectedWorkspaceSessionGraph = nil
            selectedWorkspaceGraphGeneratedAt = nil
            isLoadingWorkspaceGraph = false

            disconnectStream(clearPermissions: true)
            clearTimelineSelection()

            self.selectedWorkspaceID = workspaces.first?.id
            await refreshSessionsForSelectedWorkspace()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func loadSkills() async {
        guard let apiClient else {
            return
        }

        isLoadingSkills = true
        defer { isLoadingSkills = false }

        do {
            let fetched = try await apiClient.listSkills().sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            skills = fetched

            if let selectedSkillName,
               !fetched.contains(where: { $0.name == selectedSkillName }) {
                self.selectedSkillName = nil
            }

            if self.selectedSkillName == nil {
                self.selectedSkillName = fetched.first?.name
            }

            if let selectedSkillName {
                await loadSkillDetail(name: selectedSkillName)
            } else {
                selectedSkillDetail = nil
                selectedSkillFilePath = nil
                selectedSkillFileContent = ""
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func selectSkill(_ skillName: String?) async {
        guard selectedSkillName != skillName else { return }
        selectedSkillName = skillName

        guard let skillName else {
            selectedSkillDetail = nil
            selectedSkillFilePath = nil
            selectedSkillFileContent = ""
            return
        }

        await loadSkillDetail(name: skillName)
    }

    func selectSkillFile(_ path: String?) async {
        guard let selectedSkillName else {
            return
        }

        guard let path, path != "SKILL.md" else {
            selectedSkillFilePath = nil
            selectedSkillFileContent = selectedSkillDetail?.content ?? ""
            return
        }

        guard let apiClient else {
            return
        }

        isLoadingSkillFile = true
        defer { isLoadingSkillFile = false }

        do {
            let content = try await apiClient.getSkillFile(name: selectedSkillName, path: path)
            selectedSkillFilePath = path
            selectedSkillFileContent = content
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func selectWorkspace(_ workspaceID: String?) async {
        guard selectedWorkspaceID != workspaceID else { return }

        selectedWorkspaceID = workspaceID
        selectedSessionID = nil
        selectedWorkspaceSessionGraph = nil
        selectedWorkspaceGraphGeneratedAt = nil
        isLoadingWorkspaceGraph = false

        disconnectStream(clearPermissions: true)
        clearTimelineSelection()

        await refreshSessionsForSelectedWorkspace()
    }

    func loadTimelineForCurrentSelection() async {
        guard let workspaceID = selectedWorkspaceID,
              let selectedSessionID else {
            disconnectStream(clearPermissions: true)
            clearTimelineSelection()
            selectedWorkspaceSessionGraph = nil
            selectedWorkspaceGraphGeneratedAt = nil
            isLoadingWorkspaceGraph = false
            return
        }

        await loadTimeline(workspaceID: workspaceID, sessionID: selectedSessionID)
    }

    func createSessionInSelectedWorkspace(name: String? = nil) async {
        guard let apiClient,
              let workspaceID = selectedWorkspaceID else {
            return
        }

        do {
            let created = try await apiClient.createWorkspaceSession(
                workspaceId: workspaceID,
                name: name,
                model: nil
            )

            upsertSession(created)
            selectedSessionID = created.id
            await loadTimeline(workspaceID: workspaceID, sessionID: created.id)
            await refreshWorkspaceSessionGraph(workspaceID: workspaceID, anchorSessionID: created.id)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func stopSelectedSession() async {
        guard let apiClient,
              let session = selectedSession,
              let workspaceID = session.workspaceId ?? selectedWorkspaceID else {
            return
        }

        do {
            let updated = try await apiClient.stopWorkspaceSession(
                workspaceId: workspaceID,
                sessionId: session.id
            )

            upsertSession(updated)
            await refreshSessionsForSelectedWorkspace()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func resumeSelectedSession() async {
        guard let apiClient,
              let session = selectedSession,
              let workspaceID = session.workspaceId ?? selectedWorkspaceID else {
            return
        }

        do {
            let updated = try await apiClient.resumeWorkspaceSession(
                workspaceId: workspaceID,
                sessionId: session.id
            )

            upsertSession(updated)
            selectedSessionID = updated.id
            await loadTimeline(workspaceID: workspaceID, sessionID: updated.id)
            await refreshWorkspaceSessionGraph(workspaceID: workspaceID, anchorSessionID: updated.id)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func deleteSelectedSession() async {
        guard let apiClient,
              let session = selectedSession,
              let workspaceID = session.workspaceId ?? selectedWorkspaceID else {
            return
        }

        do {
            try await apiClient.deleteWorkspaceSession(
                workspaceId: workspaceID,
                sessionId: session.id
            )

            sessions.removeAll { $0.id == session.id }
            pendingPermissions.removeAll { $0.sessionId == session.id }

            selectedSessionID = sessions.first?.id

            if let selectedSessionID {
                await loadTimeline(workspaceID: workspaceID, sessionID: selectedSessionID)
                await refreshWorkspaceSessionGraph(workspaceID: workspaceID, anchorSessionID: selectedSessionID)
            } else {
                disconnectStream(clearPermissions: true)
                clearTimelineSelection()
                selectedWorkspaceSessionGraph = nil
                selectedWorkspaceGraphGeneratedAt = nil
                isLoadingWorkspaceGraph = false
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func sendPromptFromComposer() async {
        guard let streamingClient else {
            lastErrorMessage = "Live stream not connected."
            return
        }

        let message = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }

        isSendingPrompt = true
        defer { isSendingPrompt = false }

        do {
            try await streamingClient.send(.prompt(message: message, images: nil, streamingBehavior: nil, requestId: nil, clientTurnId: nil))
            composerText = ""
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func sendStopTurn() async {
        guard let streamingClient else {
            lastErrorMessage = "Live stream not connected."
            return
        }

        do {
            try await streamingClient.send(.stop())
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func respondToPermission(id: String, action: PermissionAction) async {
        guard let streamingClient else {
            lastErrorMessage = "Live stream not connected."
            return
        }

        do {
            try await streamingClient.send(.permissionResponse(id: id, action: action))
            pendingPermissions.removeAll { $0.id == id }

            let result = action == .allow ? "Allowed" : "Denied"
            appendSystemEvent("\(result) permission \(id)")
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func approveFirstPendingPermission() async {
        guard let first = selectedSessionPendingPermissions.first else { return }
        await respondToPermission(id: first.id, action: .allow)
    }

    func denyFirstPendingPermission() async {
        guard let first = selectedSessionPendingPermissions.first else { return }
        await respondToPermission(id: first.id, action: .deny)
    }

    // MARK: - Testing seams

    func _setStreamingClientForTesting(
        _ client: any OppiMacStreamingClient,
        workspaceID: String,
        sessionID: String
    ) {
        disconnectStream(clearPermissions: false)
        streamingClient = client
        streamWorkspaceID = workspaceID
        streamSessionID = sessionID
        isStreamConnecting = false
        isStreamConnected = true
    }

    func _handleStreamMessageForTesting(
        _ message: ServerMessage,
        workspaceID: String,
        sessionID: String
    ) {
        handleStreamMessage(message, workspaceID: workspaceID, sessionID: sessionID)
    }

    // MARK: - Private

    private func loadSkillDetail(name: String) async {
        guard let apiClient else {
            return
        }

        isLoadingSkillDetail = true
        defer { isLoadingSkillDetail = false }

        do {
            let detail = try await apiClient.getSkillDetail(name: name)
            selectedSkillName = detail.skill.name
            selectedSkillDetail = detail
            selectedSkillFilePath = nil
            selectedSkillFileContent = detail.content
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func refreshSessionsForSelectedWorkspace() async {
        guard let apiClient else {
            return
        }

        guard let workspaceID = selectedWorkspaceID else {
            sessions = []
            selectedSessionID = nil
            selectedWorkspaceSessionGraph = nil
            selectedWorkspaceGraphGeneratedAt = nil
            isLoadingWorkspaceGraph = false
            disconnectStream(clearPermissions: true)
            clearTimelineSelection()
            return
        }

        isLoadingSessions = true
        defer { isLoadingSessions = false }

        do {
            let fetchedSessions = try await apiClient
                .listWorkspaceSessions(workspaceId: workspaceID)
                .sorted { $0.lastActivity > $1.lastActivity }

            sessions = fetchedSessions

            if let selectedSessionID,
               !fetchedSessions.contains(where: { $0.id == selectedSessionID }) {
                self.selectedSessionID = nil
            }

            if self.selectedSessionID == nil {
                self.selectedSessionID = fetchedSessions.first?.id
            }

            if let selectedSessionID {
                await loadTimeline(workspaceID: workspaceID, sessionID: selectedSessionID)
                await refreshWorkspaceSessionGraph(
                    workspaceID: workspaceID,
                    anchorSessionID: selectedSessionID
                )
            } else {
                disconnectStream(clearPermissions: true)
                clearTimelineSelection()
                selectedWorkspaceSessionGraph = nil
                selectedWorkspaceGraphGeneratedAt = nil
                isLoadingWorkspaceGraph = false
            }
        } catch {
            sessions = []
            selectedSessionID = nil
            selectedWorkspaceSessionGraph = nil
            selectedWorkspaceGraphGeneratedAt = nil
            isLoadingWorkspaceGraph = false
            disconnectStream(clearPermissions: true)
            clearTimelineSelection()
            lastErrorMessage = error.localizedDescription
        }
    }

    private func refreshWorkspaceSessionGraph(
        workspaceID: String,
        anchorSessionID: String?
    ) async {
        guard let apiClient else {
            return
        }

        guard selectedWorkspaceID == workspaceID else {
            return
        }

        isLoadingWorkspaceGraph = true
        defer { isLoadingWorkspaceGraph = false }

        do {
            let response = try await apiClient.getWorkspaceGraph(
                workspaceId: workspaceID,
                sessionId: anchorSessionID,
                includeEntryGraph: false,
                entrySessionId: nil,
                includePaths: false
            )

            guard selectedWorkspaceID == workspaceID else {
                return
            }

            selectedWorkspaceSessionGraph = response.sessionGraph
            selectedWorkspaceGraphGeneratedAt = response.generatedAt
        } catch {
            guard selectedWorkspaceID == workspaceID else {
                return
            }

            // Keep existing graph on transient failure.
            if selectedWorkspaceSessionGraph == nil {
                selectedWorkspaceGraphGeneratedAt = nil
            }
        }
    }

    private func loadTimeline(workspaceID: String, sessionID: String) async {
        guard let apiClient else {
            return
        }

        if streamWorkspaceID != workspaceID || streamSessionID != sessionID {
            disconnectStream(clearPermissions: true)
        }

        isLoadingTimeline = true
        defer { isLoadingTimeline = false }

        do {
            let (session, trace) = try await apiClient.getWorkspaceSession(
                workspaceId: workspaceID,
                sessionId: sessionID,
                traceView: .full
            )

            upsertSession(session)

            resetTimelineRenderWindow()
            timelineItems = ReviewTimelineBuilder.build(from: trace)
            selectedTimelineItemID = timelineItems.last?.id

            clearLiveBuffers()
            connectStreamIfNeeded(workspaceID: workspaceID, sessionID: sessionID)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func connectStreamIfNeeded(workspaceID: String, sessionID: String) {
        guard let credentials else {
            return
        }

        if streamWorkspaceID == workspaceID,
           streamSessionID == sessionID,
           streamTask != nil {
            return
        }

        disconnectStream(clearPermissions: true)

        let client = streamingClientFactory(credentials)
        streamingClient = client
        streamWorkspaceID = workspaceID
        streamSessionID = sessionID
        isStreamConnecting = true
        isStreamConnected = false

        let stream = client.connect(sessionId: sessionID, workspaceId: workspaceID)

        streamTask = Task { [weak self] in
            guard let self else { return }

            for await message in stream {
                self.handleStreamMessage(message, workspaceID: workspaceID, sessionID: sessionID)
            }

            self.handleStreamTermination(workspaceID: workspaceID, sessionID: sessionID)
        }
    }

    private func disconnectStream(clearPermissions: Bool) {
        streamTask?.cancel()
        streamTask = nil

        streamingClient?.disconnect()
        streamingClient = nil

        streamWorkspaceID = nil
        streamSessionID = nil

        isStreamConnecting = false
        isStreamConnected = false

        clearLiveBuffers()

        if clearPermissions {
            pendingPermissions = []
        }
    }

    private func handleStreamTermination(workspaceID: String, sessionID: String) {
        guard streamWorkspaceID == workspaceID,
              streamSessionID == sessionID else {
            return
        }

        streamTask = nil
        streamingClient = nil

        isStreamConnecting = false
        isStreamConnected = false
    }

    private func handleStreamMessage(_ message: ServerMessage, workspaceID: String, sessionID: String) {
        guard selectedWorkspaceID == workspaceID,
              selectedSessionID == sessionID else {
            return
        }

        isStreamConnecting = false
        isStreamConnected = true

        switch message {
        case .connected(let session), .state(let session):
            upsertSession(session)

        case .agentStart:
            appendSystemEvent("Agent started")

        case .agentEnd:
            finalizeAssistantMessage(with: nil)
            finalizeThinkingMessage()
            appendSystemEvent("Agent finished")

        case .textDelta(let delta):
            appendAssistantDelta(delta)

        case .messageEnd(let role, let content):
            if role == "assistant" {
                finalizeAssistantMessage(with: content)
            }

        case .thinkingDelta(let delta):
            appendThinkingDelta(delta)

        case .toolStart(let tool, let args, let toolCallId):
            handleToolStart(tool: tool, args: args, toolCallId: toolCallId)

        case .toolOutput(let output, let isError, let toolCallId):
            handleToolOutput(output: output, isError: isError, toolCallId: toolCallId)

        case .toolEnd(_, let toolCallId):
            if let key = toolCallId?.nonEmpty {
                currentToolCallKey = key
            }

        case .permissionRequest(let request):
            if !pendingPermissions.contains(where: { $0.id == request.id }) {
                pendingPermissions.append(request)
                pendingPermissions.sort { $0.timeoutAt < $1.timeoutAt }
            }

        case .permissionExpired(let id, _), .permissionCancelled(let id):
            pendingPermissions.removeAll { $0.id == id }

        case .stopRequested(_, let reason):
            appendSystemEvent(reason ?? "Stop requested")

        case .stopConfirmed(_, let reason):
            appendSystemEvent(reason ?? "Stop confirmed")

        case .stopFailed(_, let reason):
            appendSystemEvent("Stop failed: \(reason)")

        case .sessionEnded(let reason):
            appendSystemEvent("Session ended: \(reason)")
            if var selectedSession {
                selectedSession.status = .stopped
                selectedSession.lastActivity = Date()
                upsertSession(selectedSession)
            }

        case .error(let error, _, _):
            appendSystemEvent("Error: \(error)")

        case .compactionStart(let reason):
            appendCompactionEvent("Compaction started: \(reason)")

        case .compactionEnd(let aborted, let willRetry, let summary, _):
            if aborted {
                appendCompactionEvent("Compaction aborted")
            } else if willRetry {
                appendCompactionEvent("Compaction completed, retrying")
            } else {
                appendCompactionEvent(summary ?? "Compaction completed")
            }

        case .retryStart(let attempt, let maxAttempts, _, let errorMessage):
            appendSystemEvent("Retry \(attempt)/\(maxAttempts): \(errorMessage)")

        case .retryEnd(let success, _, let finalError):
            if success {
                appendSystemEvent("Retry succeeded")
            } else if let finalError {
                appendSystemEvent("Retry failed: \(finalError)")
            }

        case .rpcResult(let command, _, let success, _, let error):
            if !success {
                appendSystemEvent("\(command) failed: \(error ?? "unknown")")
            }

        case .extensionUIRequest,
             .extensionUINotification,
             .turnAck,
             .unknown:
            break
        }
    }

    private func appendAssistantDelta(_ delta: String) {
        guard !delta.isEmpty else { return }

        let itemID: String
        if let liveAssistantItemID {
            itemID = liveAssistantItemID
        } else {
            itemID = "ws-assistant-\(UUID().uuidString)"
            liveAssistantItemID = itemID
            liveAssistantTimestamp = Date()
        }

        liveAssistantText += delta

        let item = ReviewTimelineItem(
            id: itemID,
            kind: .assistant,
            timestamp: liveAssistantTimestamp ?? Date(),
            title: "Assistant (live)",
            preview: previewText(liveAssistantText),
            detail: liveAssistantText,
            metadata: [
                "source": "ws",
                "streaming": "true",
            ]
        )

        upsertTimelineItem(item)
    }

    private func finalizeAssistantMessage(with content: String?) {
        let finalText: String
        if let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finalText = content
        } else {
            finalText = liveAssistantText
        }

        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            liveAssistantItemID = nil
            liveAssistantText = ""
            liveAssistantTimestamp = nil
            return
        }

        let itemID = liveAssistantItemID ?? "ws-assistant-\(UUID().uuidString)"
        let timestamp = liveAssistantTimestamp ?? Date()

        let item = ReviewTimelineItem(
            id: itemID,
            kind: .assistant,
            timestamp: timestamp,
            title: "Assistant",
            preview: previewText(finalText),
            detail: finalText,
            metadata: ["source": "ws"]
        )

        upsertTimelineItem(item)

        liveAssistantItemID = nil
        liveAssistantText = ""
        liveAssistantTimestamp = nil
    }

    private func appendThinkingDelta(_ delta: String) {
        guard !delta.isEmpty else { return }

        let itemID: String
        if let liveThinkingItemID {
            itemID = liveThinkingItemID
        } else {
            itemID = "ws-thinking-\(UUID().uuidString)"
            liveThinkingItemID = itemID
            liveThinkingTimestamp = Date()
        }

        liveThinkingText += delta

        let item = ReviewTimelineItem(
            id: itemID,
            kind: .thinking,
            timestamp: liveThinkingTimestamp ?? Date(),
            title: "Thinking (live)",
            preview: previewText(liveThinkingText),
            detail: liveThinkingText,
            metadata: [
                "source": "ws",
                "streaming": "true",
            ]
        )

        upsertTimelineItem(item)
    }

    private func finalizeThinkingMessage() {
        guard let itemID = liveThinkingItemID else { return }

        let text = liveThinkingText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            liveThinkingItemID = nil
            liveThinkingText = ""
            liveThinkingTimestamp = nil
            return
        }

        let item = ReviewTimelineItem(
            id: itemID,
            kind: .thinking,
            timestamp: liveThinkingTimestamp ?? Date(),
            title: "Thinking",
            preview: previewText(text),
            detail: text,
            metadata: ["source": "ws"]
        )

        upsertTimelineItem(item)

        liveThinkingItemID = nil
        liveThinkingText = ""
        liveThinkingTimestamp = nil
    }

    private func handleToolStart(tool: String, args: [String: JSONValue], toolCallId: String?) {
        let callKey = resolveToolCallKey(toolCallId)
        currentToolCallKey = callKey

        let argsSummary: String
        if args.isEmpty {
            argsSummary = "No arguments"
        } else {
            argsSummary = args
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.summary(maxLength: 60))" }
                .joined(separator: ", ")
        }

        let detail = prettyPrintedJSON(args) ?? argsSummary

        let item = ReviewTimelineItem(
            id: "ws-tool-call-\(callKey)",
            kind: .toolCall,
            timestamp: Date(),
            title: "Tool call: \(tool)",
            preview: previewText(argsSummary),
            detail: detail,
            metadata: [
                "source": "ws",
                "tool": tool,
                "tool_call_id": callKey,
            ]
        )

        upsertTimelineItem(item)
    }

    private func handleToolOutput(output: String, isError: Bool, toolCallId: String?) {
        let callKey = resolveToolCallKey(toolCallId)

        let existing = liveToolOutputByCallKey[callKey] ?? ""
        let combined = existing + output
        liveToolOutputByCallKey[callKey] = combined
        liveToolOutputErrorByCallKey[callKey] = (liveToolOutputErrorByCallKey[callKey] ?? false) || isError

        let hasError = liveToolOutputErrorByCallKey[callKey] ?? false

        let item = ReviewTimelineItem(
            id: "ws-tool-output-\(callKey)",
            kind: .toolResult,
            timestamp: Date(),
            title: hasError ? "Tool output (error)" : "Tool output",
            preview: previewText(combined),
            detail: combined,
            metadata: [
                "source": "ws",
                "tool_call_id": callKey,
                "is_error": hasError ? "true" : "false",
            ]
        )

        upsertTimelineItem(item)
    }

    private func resolveToolCallKey(_ toolCallId: String?) -> String {
        if let id = toolCallId?.nonEmpty {
            return id
        }

        if let currentToolCallKey {
            return currentToolCallKey
        }

        syntheticToolCallCounter += 1
        return "synthetic-\(syntheticToolCallCounter)"
    }

    private func appendSystemEvent(_ message: String) {
        let item = ReviewTimelineItem(
            id: "ws-system-\(UUID().uuidString)",
            kind: .system,
            timestamp: Date(),
            title: "System",
            preview: previewText(message),
            detail: message,
            metadata: ["source": "ws"]
        )

        timelineItems.append(item)
        selectedTimelineItemID = item.id
    }

    private func appendCompactionEvent(_ message: String) {
        let item = ReviewTimelineItem(
            id: "ws-compaction-\(UUID().uuidString)",
            kind: .compaction,
            timestamp: Date(),
            title: "Compaction",
            preview: previewText(message),
            detail: message,
            metadata: ["source": "ws"]
        )

        timelineItems.append(item)
        selectedTimelineItemID = item.id
    }

    private func upsertTimelineItem(_ item: ReviewTimelineItem) {
        if let index = timelineItems.firstIndex(where: { $0.id == item.id }) {
            timelineItems[index] = item
        } else {
            timelineItems.append(item)
        }

        selectedTimelineItemID = item.id
    }

    private func upsertWorkspace(_ workspace: Workspace) {
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace
        } else {
            workspaces.append(workspace)
        }

        workspaces.sort(by: Self.workspaceSort)
    }

    private func upsertSession(_ session: Session) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }

        sessions.sort { $0.lastActivity > $1.lastActivity }
    }

    private func clearTimelineSelection() {
        timelineItems = []
        selectedTimelineItemID = nil
        resetTimelineRenderWindow()
    }

    private func clearLiveBuffers() {
        liveAssistantItemID = nil
        liveAssistantText = ""
        liveAssistantTimestamp = nil

        liveThinkingItemID = nil
        liveThinkingText = ""
        liveThinkingTimestamp = nil

        currentToolCallKey = nil
        liveToolOutputByCallKey = [:]
        liveToolOutputErrorByCallKey = [:]
        syntheticToolCallCounter = 0
    }

    private func persistDraft() {
        guard let data = try? JSONEncoder().encode(draft) else {
            return
        }

        userDefaults.set(data, forKey: Self.connectionDraftDefaultsKey)
    }

    private func persistDisplayPreferences() {
        let prefs = DisplayPreferences(timelineTextScale: timelineTextScale)
        guard let data = try? JSONEncoder().encode(prefs) else {
            return
        }

        userDefaults.set(data, forKey: Self.displayPreferencesDefaultsKey)
    }

    private static func clampedTextScale(_ value: Double) -> Double {
        min(max(value, 0.95), 1.55)
    }

    private static func workspaceSort(lhs: Workspace, rhs: Workspace) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func previewText(_ text: String, limit: Int = 220) -> String {
        let normalized = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if normalized.isEmpty {
            return "(empty)"
        }

        if normalized.count <= limit {
            return normalized
        }

        return String(normalized.prefix(limit - 1)) + "…"
    }

    private func prettyPrintedJSON(_ value: [String: JSONValue]) -> String? {
        guard !value.isEmpty,
              let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8)
        else {
            return nil
        }

        return text
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
