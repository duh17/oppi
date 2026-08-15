import OSLog
import SwiftUI
import UIKit

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "QuickSession")

func quickSessionText(_ existingText: String, appending incomingText: String?) -> String {
    guard let incomingText = incomingText?.trimmingCharacters(in: .whitespacesAndNewlines),
          !incomingText.isEmpty else { return existingText }
    if existingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return incomingText
    }
    return existingText + "\n" + incomingText
}

struct QuickSessionOverlayLayout {
    static let minimumTopClearance: CGFloat = 12

    struct Viewport: Equatable {
        let height: CGFloat
        let requiresScrolling: Bool
    }

    static func stacksActionControls(for dynamicTypeSize: DynamicTypeSize) -> Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    static func viewport(contentHeight: CGFloat, availableHeight: CGFloat) -> Viewport {
        let safeAvailableHeight = availableHeight.isFinite ? max(0, availableHeight) : 0
        let maximumHeight = max(0, floor(safeAvailableHeight - minimumTopClearance))

        // Geometry is initially unknown. Give the content a bounded measurement
        // viewport; the next layout pass shrinks it to its fitted height.
        guard contentHeight.isFinite, contentHeight > 0 else {
            return Viewport(height: maximumHeight, requiresScrolling: false)
        }

        let safeContentHeight = ceil(contentHeight)
        return Viewport(
            height: min(safeContentHeight, maximumHeight),
            requiresScrolling: safeContentHeight > maximumHeight
        )
    }
}

private struct AgentQuickSessionSubmitKey: Equatable {
    let serverId: String
    let workspaceId: String
    let agentId: String
    let prompt: String
    let attachmentIds: [String]
    let modelId: String?
    let thinkingLevel: ThinkingLevel?
}

private struct AgentQuickSessionSubmitAttempt {
    let key: AgentQuickSessionSubmitKey
    let launchIdempotencyKey: String
    let clientTurnId: String
    var sessionId: String?
    var uploadedAttachments: [ChatAttachmentRef]?
}

private struct QuickSessionSlashCommandLoadKey: Equatable {
    let serverId: String?
    let workspaceId: String?
    let apiClientIdentifier: ObjectIdentifier?
}

private enum QuickSessionSlashCommandLoadResult: Sendable {
    case promptTemplates([SlashCommand])
    case skills([SlashCommand])
    case promptTemplateFailure(String)
    case skillFailure(String)
}

/// Compact sheet for starting a new session.
///
/// Presented from Oppi, the Control widget, App Intents, or saved share intake.
/// The sheet stays focused on one task: pick workspace (and optionally Agent),
/// compose the first message, then create and navigate to the new session.
///
/// **Flow**: Pick workspace/Agent → compose message → send → session created →
/// navigate to ChatView. Plain Pi uses workspace session create + optional
/// auto-send. A selected Agent uses `launchAgentSession` so definition defaults apply.
struct QuickSessionSheet: View {
    let onDismiss: () -> Void

    @Environment(ChatSessionState.self) private var chatState
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.composerDraftStore) private var composerDraftStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var text = ""
    @State private var composerTextBeforeRecording: String?
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var pendingRepoPointers: [PendingFileReference] = []
    @State private var promptTemplateSlashCommands: [SlashCommand] = []
    @State private var skillSlashCommands: [SlashCommand] = []
    @State private var slashCommandLoadGeneration: UInt64 = 0
    @State private var selectedWorkspace: Workspace?
    @State private var selectedWorkspaceSelectionSource = "unknown"
    @State private var selectedServerId: String?
    @State private var selectedModelId: String? = AppPreferences.QuickSession.lastModelId
    @State private var thinkingLevel: ThinkingLevel = AppPreferences.QuickSession.lastThinkingLevel
    /// `nil` = plain Pi. Remembered last Agent is restored after agents load.
    @State private var selectedAgentId: String?
    @State private var availableAgents: [AgentDefinitionSummary] = []
    @State private var isLoadingAgents = false
    @State private var agentLoadGeneration: UInt64 = 0
    @State private var shouldRememberAgentSelection = true
    /// When an Agent is selected, model/thinking only apply if the user sets them.
    @State private var agentModelOverride: String?
    @State private var agentThinkingOverride: ThinkingLevel?
    @State private var showModelPicker = false
    @State private var showExpandedComposer = false
    @State private var isInitialized = false
    @State private var isCreating = false
    @State private var agentSubmitAttempt: AgentQuickSessionSubmitAttempt?
    @State private var error: String?
    @State private var launchFailure: AgentLaunchFailureResponse?
    @State private var voiceInputManager: VoiceInputManager?
    @State private var busyStreamingBehavior: StreamingBehavior = .followUp
    @State private var composerFocusRequestID = 0
    @State private var showWorkspacePicker = false
    @State private var showAgentPicker = false
    @State private var measuredComposerHeight: CGFloat = 0
    @State private var measuredAccessibilityActionHeight: CGFloat = 0
    @State private var keyboardFrame: CGRect = .null

    /// All workspaces across all connected servers.
    private var rawServerWorkspaces: [(serverId: String, workspace: Workspace)] {
        coordinator.connections.flatMap { serverId, conn in
            conn.workspaceStore.workspaces.map { (serverId: serverId, workspace: $0) }
        }
    }

    private var effectiveLaunchConstraints: AgentLaunchConstraints? {
        guard let recovery = launchFailure?.recovery,
              recovery.allowedWorkspaceIds != nil || recovery.requiredRuntime != nil else {
            return selectedAgent?.launchConstraints
        }
        return AgentLaunchConstraints(
            allowedWorkspaceIds: recovery.allowedWorkspaceIds,
            requiredRuntime: recovery.requiredRuntime
        )
    }

    private var allServerWorkspaces: [(serverId: String, workspace: Workspace)] {
        guard let constraints = effectiveLaunchConstraints else { return rawServerWorkspaces }
        return rawServerWorkspaces.filter { entry in
            entry.serverId == selectedServerId && constraints.allows(entry.workspace)
        }
    }

    private var workspacePickerSections: [QuickSessionWorkspacePickerSection] {
        let grouped = Dictionary(grouping: allServerWorkspaces, by: \.serverId)
        return grouped.keys.sorted().map { serverId in
            QuickSessionWorkspacePickerSection(
                id: serverId,
                name: coordinator.serverStore.server(for: serverId)?.name ?? serverId,
                workspaces: (grouped[serverId] ?? []).map(\.workspace),
                iconAssetCache: coordinator.connection(for: serverId)?.iconAssetCache
            )
        }
    }

    /// Display model: last or current explicit selection wins, then the workspace default.
    /// Session creation sends only the last/current explicit selection; server-side
    /// resolution applies workspace defaults and Pi settings centrally.
    /// With an Agent selected, only an explicit post-selection override is shown/sent.
    private var effectiveModelId: String? {
        if selectedAgentId != nil {
            return agentModelOverride
        }
        return selectedModelId ?? selectedWorkspace?.defaultModel
    }

    private var effectiveThinkingLevel: ThinkingLevel {
        if selectedAgentId != nil {
            return agentThinkingOverride ?? .medium
        }
        return thinkingLevel
    }

    private var selectedAgent: AgentDefinitionSummary? {
        guard let selectedAgentId else { return nil }
        return availableAgents.first(where: { $0.id == selectedAgentId })
    }

    private var selectedServerIconAssetCache: IconAssetCache? {
        selectedServerConnection()?.iconAssetCache
    }

    private var slashCommands: [SlashCommand] {
        promptTemplateSlashCommands + skillSlashCommands
    }

    private var slashCommandLoadKey: QuickSessionSlashCommandLoadKey {
        let apiClient = selectedServerId.flatMap {
            coordinator.connection(for: $0)?.apiClient
        }
        return QuickSessionSlashCommandLoadKey(
            serverId: selectedServerId,
            workspaceId: selectedWorkspace?.id,
            apiClientIdentifier: apiClient.map(ObjectIdentifier.init)
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let rootFrame = proxy.frame(in: .global)
            let keyboardOverlap = keyboardFrame.isNull
                ? 0
                : max(0, rootFrame.intersection(keyboardFrame).height)
            let accessibilityActionHeight = stacksActionControls
                ? measuredAccessibilityActionHeight
                : 0
            let viewport = QuickSessionOverlayLayout.viewport(
                contentHeight: measuredComposerHeight,
                availableHeight: proxy.size.height - keyboardOverlap - accessibilityActionHeight
            )

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                ScrollView(.vertical) {
                    composerContent
                        .onGeometryChange(for: CGFloat.self) { contentProxy in
                            contentProxy.size.height
                        } action: { height in
                            let normalizedHeight = height.isFinite ? ceil(max(0, height)) : 0
                            if measuredComposerHeight != normalizedHeight {
                                measuredComposerHeight = normalizedHeight
                            }
                        }
                }
                .scrollDisabled(!viewport.requiresScrolling)
                .scrollIndicators(viewport.requiresScrolling ? .automatic : .hidden)
                .scrollDismissesKeyboard(.never)
                .frame(maxWidth: .infinity)
                .frame(height: viewport.height, alignment: .bottom)
                .accessibilityIdentifier("quickSession.viewport")

                if stacksActionControls {
                    accessibilityActionControls
                        .onGeometryChange(for: CGFloat.self) { controlsProxy in
                            controlsProxy.size.height
                        } action: { height in
                            let normalizedHeight = height.isFinite ? ceil(max(0, height)) : 0
                            if measuredAccessibilityActionHeight != normalizedHeight {
                                measuredAccessibilityActionHeight = normalizedHeight
                            }
                        }
                }
            }
            .padding(.bottom, keyboardOverlap)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(.clear)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) {
            notification in
            keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .null
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardFrame = .null
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(
                currentModel: effectiveModelId,
                onSelect: selectModel
            )
        }
        .fullScreenCover(isPresented: $showExpandedComposer) {
            ExpandedComposerView(
                text: $text,
                textBeforeRecording: $composerTextBeforeRecording,
                pendingAttachments: $pendingAttachments,
                pendingRepoPointers: $pendingRepoPointers,
                isBusy: false,
                busyStreamingBehavior: .followUp,
                slashCommands: slashCommands,
                fileSuggestions: [],
                onFileSuggestionQuery: nil,
                session: nil,
                modelOverride: effectiveModelId,
                thinkingLevel: effectiveThinkingLevel,
                voiceInputManager: ReleaseFeatures.voiceInputEnabled ? voiceInputManager : nil,
                onPrepareVoiceInput: prepareVoiceInputForSelectedServer,
                onSend: handleSend,
                onModelTap: { showModelPicker = true },
                onThinkingSelect: selectThinkingLevel,
                allowsEmptySubmit: selectedAgentId == nil
            )
        }
        .task {
            await setupInitialState()
        }
        .task(id: slashCommandLoadKey) {
            await loadSlashCommands(for: slashCommandLoadKey)
        }
        .onChange(of: selectedServerId) { _, _ in
            configureVoiceInputForSelectedServer()
            guard isInitialized else { return }
            Task { await loadAgentsForSelectedServer() }
        }
        .onChange(of: text) { _, newValue in
            composerDraftStore?.setQuickSessionDraftText(newValue)
        }
    }

    private var composerContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.themeRed)
                        .fixedSize(horizontal: false, vertical: true)

                    if launchFailure?.recovery.actions.contains(.chooseWorkspace) == true {
                        Button("Choose Compatible Workspace") {
                            showWorkspacePicker = true
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    if launchFailure?.recovery.actions.contains(.editAgent) == true
                        || (selectedAgent != nil && allServerWorkspaces.isEmpty) {
                        Button("Open Agents") {
                            onDismiss()
                            navigation.openWorkspaceUtility(.agents)
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.themeRed.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            // Only the Agent picker is detached above the input capsule.
            // Workspace/model/thinking stay in the composer action row.
            agentPickerPill
                .padding(.horizontal, 16)

            ChatInputBar(
                text: $text,
                textBeforeRecording: $composerTextBeforeRecording,
                pendingAttachments: $pendingAttachments,
                pendingRepoPointers: $pendingRepoPointers,
                isBusy: false,
                busyStreamingBehavior: $busyStreamingBehavior,
                isSending: isCreating,
                allowsEmptySubmit: selectedAgentId == nil,
                sendProgressText: nil,
                isStopping: false,
                voiceInputManager: ReleaseFeatures.voiceInputEnabled ? voiceInputManager : nil,
                onPrepareVoiceInput: prepareVoiceInputForSelectedServer,
                showForceStop: false,
                isForceStopInFlight: false,
                slashCommands: slashCommands,
                fileSuggestions: [],
                onFileSuggestionQuery: nil,
                onSend: handleSend,
                onStop: {},
                onForceStop: {},
                onExpand: { showExpandedComposer = true },
                externalFocusRequestID: composerFocusRequestID,
                appliesOuterPadding: true,
                alwaysShowActionRow: true,
                actionRow: {
                    quickSessionActionControls
                }
            )
        }
        .padding(.top, 6)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(!isInitialized)
    }

    private var stacksActionControls: Bool {
        QuickSessionOverlayLayout.stacksActionControls(for: dynamicTypeSize)
    }

    @ViewBuilder
    private var quickSessionActionControls: some View {
        if !stacksActionControls {
            workspaceNavBarItem
            sessionToolbar
        }
    }

    private var accessibilityActionControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            workspaceNavBarItem

            HStack(spacing: 6) {
                sessionToolbar
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var sessionToolbar: some View {
        SessionToolbar(
            session: nil,
            modelOverride: effectiveModelId,
            thinkingLevel: effectiveThinkingLevel,
            onModelTap: { showModelPicker = true },
            onThinkingSelect: selectThinkingLevel
        )
    }

    private func selectModel(_ model: ModelInfo) {
        let modelId = ModelSwitchPolicy.fullModelID(for: model)
        if selectedAgentId != nil {
            agentModelOverride = modelId
        } else {
            selectedModelId = modelId
            AppPreferences.QuickSession.saveModelId(modelId)
        }
        AppPreferences.RecentModels.record(modelId)
    }

    private func selectThinkingLevel(_ level: ThinkingLevel) {
        if selectedAgentId != nil {
            agentThinkingOverride = level
        } else {
            thinkingLevel = level
            AppPreferences.QuickSession.saveThinkingLevel(level)
        }
    }

    // MARK: - Agent Picker

    private var agentPickerPill: some View {
        Button {
            showAgentPicker.toggle()
        } label: {
            QuickSessionAgentPillLabel(agent: selectedAgent)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showAgentPicker, arrowEdge: .bottom) {
            QuickSessionAgentPicker(
                agents: availableAgents,
                selectedAgentId: selectedAgentId,
                isLoading: isLoadingAgents,
                iconAssetCache: selectedServerIconAssetCache,
                onSelect: selectAgent
            )
            .presentationCompactAdaptation(.popover)
            .presentationBackground(Color.themeSurfaceFill(.popover))
        }
        .accessibilityLabel(
            selectedAgent.map { "Agent picker, current agent \($0.name)" }
                ?? "Agent picker, Pi with no agent"
        )
        .accessibilityIdentifier("quickSession.agentPicker")
    }

    private func selectAgent(_ agentId: String?) {
        selectedAgentId = agentId
        agentModelOverride = nil
        agentThinkingOverride = nil
        shouldRememberAgentSelection = true
        showAgentPicker = false
        error = nil
        launchFailure = nil
        AppPreferences.QuickSession.saveAgentId(agentId)
        requireExplicitCompatibleWorkspaceIfNeeded()
    }

    private func requireExplicitCompatibleWorkspaceIfNeeded() {
        guard let constraints = effectiveLaunchConstraints else { return }
        if let selectedWorkspace, constraints.allows(selectedWorkspace) { return }
        selectedWorkspace = nil
        selectedWorkspaceSelectionSource = "agent_constraint_required"
        error = "Choose a workspace compatible with \(selectedAgent?.name ?? "this Agent")."
        showWorkspacePicker = true
    }

    // MARK: - Workspace Picker

    /// Compact workspace picker for the action row — icon + name with a custom popover.
    private var workspaceNavBarItem: some View {
        Button {
            showWorkspacePicker.toggle()
        } label: {
            SessionWorkspacePillLabel(workspace: selectedWorkspace)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showWorkspacePicker, arrowEdge: .bottom) {
            QuickSessionWorkspacePicker(
                sections: workspacePickerSections,
                showsSectionHeaders: workspacePickerSections.count > 1,
                selectedWorkspaceId: selectedWorkspace?.id,
                selectedServerId: selectedServerId,
                onSelect: selectWorkspace,
                emptyMessage: selectedAgent == nil
                    ? "Pair or refresh a server, then try again."
                    : "\(selectedAgent?.name ?? "This Agent") requires a compatible workspace. Edit the Agent or add one, then try again."
            )
            .presentationCompactAdaptation(.popover)
            .presentationBackground(Color.themeSurfaceFill(.popover))
        }
        .accessibilityLabel(selectedWorkspace.map { "Workspace picker, current workspace \($0.name)" } ?? "Workspace picker")
        .accessibilityIdentifier("quickSession.workspacePicker")
    }

    private func selectWorkspace(_ workspace: Workspace, serverId: String) {
        if selectedServerId != serverId {
            selectedAgentId = nil
            agentModelOverride = nil
            agentThinkingOverride = nil
            shouldRememberAgentSelection = true
        }
        selectedWorkspace = workspace
        selectedWorkspaceSelectionSource = "manual"
        selectedServerId = serverId
        showWorkspacePicker = false
        error = nil
        launchFailure = nil
        configureVoiceInputForSelectedServer()
        AppPreferences.QuickSession.saveWorkspaceId(workspace.id)
    }

    // MARK: - Actions

    private func setupInitialState() async {
        if let composerDraftStore {
            await composerDraftStore.load()
            text = composerDraftStore.quickSessionDraftText
        }

        let launchContext = navigation.pendingQuickSessionLaunchContext
        navigation.pendingQuickSessionLaunchContext = nil
        shouldRememberAgentSelection = launchContext == nil

        // Select workspace: requested Agent server, then last used > explicit default > first available.
        // Prefer constraint-filtered lists when an Agent is already known.
        let baseWorkspaces = launchContext.map { context in
            rawServerWorkspaces.filter { $0.serverId == context.serverId }
        } ?? rawServerWorkspaces
        let all = baseWorkspaces
        if let preferred = AppPreferences.QuickSession.preferredWorkspaceSelection(
            in: all.map { (id: $0.workspace.id, name: $0.workspace.name) }
        ), let match = all.first(where: { $0.workspace.id == preferred.id }) {
            selectedWorkspace = match.workspace
            selectedWorkspaceSelectionSource = preferred.source
            selectedServerId = match.serverId
        } else if let first = all.first {
            selectedWorkspace = first.workspace
            selectedWorkspaceSelectionSource = "first_available"
            selectedServerId = first.serverId
        } else if let launchContext {
            selectedServerId = launchContext.serverId
        } else {
            selectedServerId = coordinator.activeServerId
        }

        // Initialize voice input
        if ReleaseFeatures.voiceInputEnabled {
            let manager = VoiceInputManager()
            voiceInputManager = manager
            configureVoiceInputForSelectedServer(manager)
        }

        await loadAgentsForSelectedServer(requestedAgentId: launchContext?.agentId)

        if let pendingPayload = QuickSessionTrigger.shared.consumePendingPayload() {
            applyInitialPayload(pendingPayload)
        }
        isInitialized = true

        // Auto-focus the text input for typing, then move assistive focus to
        // that same composer instead of the overlay's dismiss control.
        composerFocusRequestID += 1
        await moveAccessibilityFocusToComposer()

        // Ensure model cache is fresh for the selected server.
        if let api = selectedServerConnection()?.apiClient {
            await chatState.refreshModelCache(api: api)
        }

        await drainPendingDictationCleanupQueue()
    }

    private func moveAccessibilityFocusToComposer() async {
        // The UIKit text view is mounted by ChatInputBar. Yield twice so both
        // the external keyboard-focus request and SwiftUI accessibility tree
        // have applied before posting the modal screen change.
        await Task.yield()
        await Task.yield()

        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        // An intent can open Quick Session over an existing chat composer.
        // SwiftUI appends overlays later in the hosting hierarchy, so choose
        // the last matching text view rather than the obscured background one.
        guard let composer = windows.flatMap({
            $0.quickSessionDescendants(accessibilityIdentifier: "chat.input")
        }).last else {
            return
        }
        UIAccessibility.post(notification: .screenChanged, argument: composer)
    }

    private func applyInitialPayload(_ payload: QuickSessionInitialPayload) {
        appendInitialText(payload.text)
        for attachment in payload.attachments {
            appendInitialAttachment(
                name: attachment.name,
                data: attachment.data,
                mimeType: attachment.mimeType
            )
        }
    }

    private func appendInitialText(_ value: String?) {
        text = quickSessionText(text, appending: value)
    }

    private func appendInitialAttachment(name: String, data: Data, mimeType: String) {
        if mimeType.hasPrefix("image/"), let image = UIImage(data: data) {
            pendingAttachments.append(PendingImage.from(data: data, mimeType: mimeType, image: image).pendingAttachment)
        } else {
            pendingAttachments.append(PendingAttachment.localFile(
                name: name,
                data: data,
                mimeType: mimeType
            ))
        }
    }

    private func configureVoiceInputForSelectedServer(_ manager: VoiceInputManager? = nil) {
        guard let manager = manager ?? voiceInputManager else { return }
        guard let targetConnection = selectedServerConnection() else { return }
        manager.setServerCredentials(targetConnection.credentials)
        manager.setServerConnection(targetConnection)
        manager.setPlaybackInterrupter(targetConnection.audioPlayer)
    }

    private func prepareVoiceInputForSelectedServer(_ manager: VoiceInputManager) async throws {
        configureVoiceInputForSelectedServer(manager)

        // Remote dictation is server-bound: connect directly to `/dictation/stream`.
        // No workspace session, no capability preflight, no legacy audio target.
        manager.setServerDictationTarget(nil)
    }

    private func loadSlashCommands(for key: QuickSessionSlashCommandLoadKey) async {
        slashCommandLoadGeneration &+= 1
        let generation = slashCommandLoadGeneration
        promptTemplateSlashCommands = []
        skillSlashCommands = []

        guard let serverId = key.serverId,
              let workspaceId = key.workspaceId,
              let apiClientIdentifier = key.apiClientIdentifier,
              key == slashCommandLoadKey,
              let api = coordinator.connection(for: serverId)?.apiClient,
              ObjectIdentifier(api) == apiClientIdentifier else {
            return
        }

        await withTaskGroup(of: QuickSessionSlashCommandLoadResult.self) { group in
            group.addTask {
                do {
                    let options = try await api.getWorkspaceQuickActions(workspaceId: workspaceId).actions
                    return .promptTemplates(SlashCommand.promptTemplates(from: options))
                } catch {
                    return .promptTemplateFailure(error.localizedDescription)
                }
            }
            group.addTask {
                do {
                    let skills = try await api.listSkills(workspaceId: workspaceId)
                    return .skills(SlashCommand.skills(from: skills))
                } catch {
                    return .skillFailure(error.localizedDescription)
                }
            }

            for await result in group {
                guard !Task.isCancelled,
                      generation == slashCommandLoadGeneration,
                      key == slashCommandLoadKey else {
                    group.cancelAll()
                    return
                }

                switch result {
                case .promptTemplates(let commands):
                    promptTemplateSlashCommands = commands
                case .skills(let commands):
                    skillSlashCommands = commands
                case .promptTemplateFailure(let message):
                    logger.warning("Failed to load prompt templates for quick session: \(message, privacy: .public)")
                case .skillFailure(let message):
                    logger.warning("Failed to load skills for quick session: \(message, privacy: .public)")
                }
            }
        }
    }

    private func selectedServerConnection() -> ServerConnection? {
        if let selectedServerId {
            return coordinator.connection(for: selectedServerId)
        }
        return coordinator.activeConnection
    }

    private func drainPendingDictationCleanupQueue() async {
        for cleanup in AppPreferences.QuickSession.pendingDictationCleanups {
            await attemptPendingDictationCleanup(cleanup)
        }
    }

    private func attemptPendingDictationCleanup(
        _ cleanup: AppPreferences.QuickSession.PendingDictationCleanup
    ) async {
        guard let connection = coordinator.connection(for: cleanup.serverId),
              let api = connection.apiClient else {
            return
        }

        do {
            try await api.deleteWorkspaceSession(
                workspaceId: cleanup.workspaceId,
                sessionId: cleanup.sessionId
            )
            connection.sessionStore.remove(id: cleanup.sessionId)
            await TimelineCache.shared.removeTrace(cleanup.sessionId, serverId: cleanup.serverId)
            AppPreferences.QuickSession.removePendingDictationCleanup(cleanup)
        } catch let apiError as APIError {
            if case .server(let status, _) = apiError, status == 404 {
                connection.sessionStore.remove(id: cleanup.sessionId)
                await TimelineCache.shared.removeTrace(cleanup.sessionId, serverId: cleanup.serverId)
                AppPreferences.QuickSession.removePendingDictationCleanup(cleanup)
            } else {
                logger.warning("Failed to delete queued quick dictation session \(cleanup.sessionId, privacy: .public): \(apiError.localizedDescription, privacy: .public)")
            }
        } catch {
            logger.warning("Failed to delete queued quick dictation session \(cleanup.sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadAgentsForSelectedServer(requestedAgentId: String? = nil) async {
        guard let targetServerId = selectedServerId ?? coordinator.activeServerId else {
            availableAgents = []
            selectedAgentId = nil
            return
        }
        if selectedServerId == nil { selectedServerId = targetServerId }
        agentLoadGeneration &+= 1
        let generation = agentLoadGeneration
        isLoadingAgents = true

        guard let connection = coordinator.connection(for: targetServerId),
              let api = connection.apiClient else {
            if generation == agentLoadGeneration, selectedServerId == targetServerId {
                availableAgents = []
                selectedAgentId = nil
                isLoadingAgents = false
            }
            return
        }

        do {
            let agents = try await api.listAgents()
                .filter { $0.status == .active }
                .sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            guard generation == agentLoadGeneration, selectedServerId == targetServerId else {
                return
            }
            availableAgents = agents
            if let requestedAgentId {
                if agents.contains(where: { $0.id == requestedAgentId }) {
                    selectedAgentId = requestedAgentId
                } else {
                    selectedAgentId = nil
                    error = "This Agent is no longer available on the selected server."
                }
            } else {
                selectedAgentId = QuickSessionLaunchRouting.preferredAgentId(
                    lastAgentId: AppPreferences.QuickSession.lastAgentId,
                    availableAgentIds: agents.map(\.id)
                )
            }
            agentModelOverride = nil
            agentThinkingOverride = nil
            requireExplicitCompatibleWorkspaceIfNeeded()
            isLoadingAgents = false
        } catch {
            guard generation == agentLoadGeneration, selectedServerId == targetServerId else {
                return
            }
            logger.warning("Failed to load agents for quick session: \(error.localizedDescription, privacy: .public)")
            availableAgents = []
            selectedAgentId = nil
            if requestedAgentId != nil {
                self.error = "Could not load this Agent: \(error.localizedDescription)"
            }
            isLoadingAgents = false
        }
    }

    private func handleSend() {
        guard !isCreating else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let transportText = PendingFileReference.appendReferenceBlock(
            to: trimmed,
            files: pendingRepoPointers
        )
        let launchDecision = QuickSessionLaunchRouting.plan(
            for: QuickSessionLaunchRequest(
                workspaceId: selectedWorkspace?.id,
                agentId: selectedAgentId,
                prompt: transportText,
                hasAttachments: !pendingAttachments.isEmpty,
                hasRepoReferences: !pendingRepoPointers.isEmpty
            )
        )

        let plan: QuickSessionLaunchPlan
        switch launchDecision {
        case .success(let resolved):
            plan = resolved
        case .failure(let validationError):
            error = validationError.localizedDescription
            return
        }

        guard let workspace = selectedWorkspace, workspace.id == plan.workspaceId else {
            error = QuickSessionLaunchValidationError.missingWorkspace.localizedDescription
            return
        }

        let modelId = selectedAgentId == nil ? selectedModelId : agentModelOverride
        let thinking = thinkingLevel
        let agentThinking = agentThinkingOverride
        let submittedDraftRevision = composerDraftStore?
            .setQuickSessionDraftText(text)?
            .revision

        isCreating = true
        error = nil

        let telemetryStartedAtMs = ChatSessionTelemetry.nowMs()
        let telemetryTags = [
            "source": "sheet",
            "selection": selectedWorkspaceSelectionSource,
            "has_message": trimmed.isEmpty ? "0" : "1",
            "has_attachments": pendingAttachments.isEmpty ? "0" : "1",
            "has_repo_refs": pendingRepoPointers.isEmpty ? "0" : "1",
            "has_model": modelId == nil ? "0" : "1",
            "has_agent": selectedAgentId == nil ? "0" : "1",
        ]

        // Capture references before dismiss invalidates environment
        let nav = navigation
        let serverId = selectedServerId ?? coordinator.activeServerId ?? "default"
        let attachments = pendingAttachments

        Task { @MainActor in
            do {
                // Use the correct server's API client
                guard let targetConnection = coordinator.connection(for: serverId),
                      let api = targetConnection.apiClient else {
                    throw QuickSessionError.noConnection
                }

                var session: Session
                let autoSendMessage: String?
                let autoSendAttachments: [PendingAttachment]?

                switch plan.mode {
                case .plainPi:
                    // Create session without prompt — we'll send through WebSocket
                    let response = try await api.createWorkspaceSession(
                        workspaceId: workspace.id,
                        model: modelId,
                        thinking: thinking.rawValue
                    )
                    session = response.session
                    autoSendMessage = plan.shouldAutoSend ? transportText : nil
                    autoSendAttachments = plan.shouldAutoSend ? attachments : nil
                    AppPreferences.QuickSession.saveModelId(modelId)
                    AppPreferences.QuickSession.saveThinkingLevel(thinking)

                case .agent(let agentId):
                    // Keep stable launch and turn IDs until authoritative delivery is
                    // confirmed. Retrying an ambiguous HTTP failure must resume the same
                    // Agent session rather than create and prompt a second one.
                    let submitKey = AgentQuickSessionSubmitKey(
                        serverId: serverId,
                        workspaceId: workspace.id,
                        agentId: agentId,
                        prompt: plan.prompt,
                        attachmentIds: attachments.map(\.id),
                        modelId: modelId,
                        thinkingLevel: agentThinking
                    )
                    var attempt: AgentQuickSessionSubmitAttempt
                    if let pending = agentSubmitAttempt, pending.key == submitKey {
                        attempt = pending
                    } else {
                        let attemptId = UUID().uuidString
                        attempt = AgentQuickSessionSubmitAttempt(
                            key: submitKey,
                            launchIdempotencyKey: "ios-agent-launch-\(attemptId)",
                            clientTurnId: "quick-agent-\(attemptId)"
                        )
                        agentSubmitAttempt = attempt
                    }

                    let launchedSessionId: String
                    if let pendingSessionId = attempt.sessionId {
                        launchedSessionId = pendingSessionId
                    } else {
                        do {
                            let response = try await api.launchAgentSession(
                                agentId: agentId,
                                prompt: nil,
                                workspaceId: workspace.id,
                                model: modelId,
                                thinkingLevel: agentThinking,
                                idempotencyKey: attempt.launchIdempotencyKey
                            )
                            // Create-only launch: prompt is sent after attachment upload.
                            // Reject non-accepted receipts and missing sessions.
                            guard response.receipt.accepted, let launched = response.session else {
                                throw QuickSessionError.agentLaunchFailed(
                                    response.receipt.promptError
                                        ?? response.receipt.reason
                                        ?? "The Agent did not start. Review its configuration and try again."
                                )
                            }
                            launchedSessionId = launched.id
                            attempt.sessionId = launched.id
                            agentSubmitAttempt = attempt
                        } catch let failure as AgentLaunchFailureResponse {
                            launchFailure = failure
                            throw QuickSessionError.agentLaunchFailed(failure.localizedDescription)
                        }
                    }

                    let scope = SessionRouteScope.workspace(workspace.id)
                    session = try await api.resumeWorkspaceSession(
                        workspaceId: workspace.id,
                        sessionId: launchedSessionId
                    )
                    let uploaded: [ChatAttachmentRef]
                    if let pendingUploads = attempt.uploadedAttachments {
                        uploaded = pendingUploads
                    } else {
                        uploaded = try await PendingAttachmentUploader.upload(
                            attachments,
                            api: api,
                            scope: scope,
                            sessionId: launchedSessionId
                        )
                        attempt.uploadedAttachments = uploaded
                        agentSubmitAttempt = attempt
                    }
                    try await api.sendWorkspaceSessionCommand(
                        workspaceId: workspace.id,
                        sessionId: launchedSessionId,
                        message: .prompt(
                            message: plan.prompt,
                            attachments: uploaded.isEmpty ? nil : uploaded,
                            requestId: attempt.clientTurnId,
                            clientTurnId: attempt.clientTurnId
                        )
                    )
                    session = try await api.getSession(scope: scope, sessionId: launchedSessionId).session
                    agentSubmitAttempt = nil
                    autoSendMessage = nil
                    autoSendAttachments = nil
                }

                // Upsert into the target server's session store — not the
                // environment's store (which belongs to the currently active
                // server and may differ for cross-server quick sessions).
                targetConnection.sessionStore.upsert(session)

                AppPreferences.QuickSession.saveWorkspaceId(workspace.id)
                if shouldRememberAgentSelection {
                    AppPreferences.QuickSession.saveAgentId(selectedAgentId)
                }
                ChatSessionTelemetry.recordTimingMetric(
                    .quickSessionCreateMs,
                    durationMs: max(0, ChatSessionTelemetry.nowMs() - telemetryStartedAtMs),
                    workspaceId: workspace.id,
                    tags: telemetryTags.merging(["status": "ok"]) { _, new in new }
                )
                logger.notice("Quick session created: \(session.id, privacy: .public) in workspace \(workspace.name, privacy: .public)")

                // Single atomic write — ContentView.onDismiss unpacks.
                nav.pendingQuickSessionNav = QuickSessionNav(
                    target: WorkspaceNavTarget(serverId: serverId, workspace: workspace),
                    sessionId: session.id,
                    autoSendMessage: autoSendMessage,
                    autoSendAttachments: autoSendAttachments
                )

                composerDraftStore?.clearQuickSessionDraft(ifRevision: submittedDraftRevision)
                onDismiss()
            } catch {
                if let failure = error as? AgentLaunchFailureResponse {
                    launchFailure = failure
                }
                let errorKind = ChatSessionTelemetry.metricErrorKind(for: error)
                ChatSessionTelemetry.recordTimingMetric(
                    .quickSessionCreateMs,
                    durationMs: max(0, ChatSessionTelemetry.nowMs() - telemetryStartedAtMs),
                    workspaceId: workspace.id,
                    tags: telemetryTags.merging([
                        "status": "error",
                        "error_kind": errorKind,
                    ]) { _, new in new }
                )
                ChatSessionTelemetry.recordCountMetric(
                    .quickSessionError,
                    workspaceId: workspace.id,
                    tags: [
                        "source": "sheet",
                        "selection": selectedWorkspaceSelectionSource,
                        "error_kind": errorKind,
                    ]
                )
                self.error = error.localizedDescription
                isCreating = false
                logger.error("Quick session creation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Agent picker (detached above input)

private struct QuickSessionAgentPillLabel: View {
    let agent: AgentDefinitionSummary?

    var body: some View {
        HStack(spacing: 4) {
            if let agent {
                AgentIconView(value: agent.icon, size: 12, frameSize: 16)
            } else {
                CurrentAssistantAvatarPreview(
                    sessionId: "quick-session-agent-pill",
                    size: 16
                )
            }
            Text(agent?.name ?? "Pi")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.themeFg)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.themeComment)
        }
        .frame(minHeight: 17)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .glassEffect(.regular, in: Capsule())
        .frame(minHeight: ComposerInputMetrics.controlDiameter)
        .contentShape(Rectangle())
    }
}

private struct QuickSessionAgentPicker: View {
    let agents: [AgentDefinitionSummary]
    let selectedAgentId: String?
    let isLoading: Bool
    let iconAssetCache: IconAssetCache?
    let onSelect: (String?) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                agentRow(
                    id: nil,
                    title: "Pi",
                    subtitle: nil,
                    icon: nil,
                    usesPiAvatar: true,
                    isSelected: selectedAgentId == nil
                )

                if isLoading && agents.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading agents…")
                            .font(.subheadline)
                            .foregroundStyle(.themeComment)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                } else if agents.isEmpty {
                    Text("No saved Agents on this server.")
                        .font(.subheadline)
                        .foregroundStyle(.themeComment)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                } else {
                    ForEach(agents) { agent in
                        agentRow(
                            id: agent.id,
                            title: agent.name,
                            subtitle: agent.description,
                            icon: agent.icon,
                            usesPiAvatar: false,
                            isSelected: selectedAgentId == agent.id
                        )
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .frame(minWidth: 260, idealWidth: 280, maxHeight: 320)
    }

    private func agentRow(
        id: String?,
        title: String,
        subtitle: String?,
        icon: IconChoice?,
        usesPiAvatar: Bool,
        isSelected: Bool
    ) -> some View {
        Button {
            onSelect(id)
        } label: {
            HStack(spacing: 10) {
                if usesPiAvatar {
                    CurrentAssistantAvatarPreview(
                        sessionId: "quick-session-agent-picker-pi",
                        size: 22
                    )
                } else if let icon {
                    AgentIconView(
                        value: icon,
                        size: 16,
                        frameSize: 22,
                        assetCache: iconAssetCache
                    )
                } else {
                    Image(systemName: "person.crop.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeComment)
                        .frame(width: 22, height: 22)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.themeBlue)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(id.map { "quickSession.agent.\($0)" } ?? "quickSession.agent.pi")
    }
}

private struct QuickSessionWorkspacePickerSection: Identifiable {
    let id: String
    let name: String
    let workspaces: [Workspace]
    let iconAssetCache: IconAssetCache?
}

private struct QuickSessionWorkspacePicker: View {
    let sections: [QuickSessionWorkspacePickerSection]
    let showsSectionHeaders: Bool
    let selectedWorkspaceId: String?
    let selectedServerId: String?
    let onSelect: (Workspace, String) -> Void
    let emptyMessage: String

    private var hasWorkspaces: Bool {
        sections.contains { !$0.workspaces.isEmpty }
    }

    var body: some View {
        Group {
            if hasWorkspaces {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections.indices, id: \.self) { index in
                            let section = sections[index]
                            if !section.workspaces.isEmpty {
                                if showsSectionHeaders {
                                    if index > 0 {
                                        Divider()
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 6)
                                    }

                                    Text(section.name)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.themeComment)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 16)
                                        .padding(.top, index == 0 ? 8 : 0)
                                        .padding(.bottom, 4)
                                }

                                ForEach(section.workspaces) { workspace in
                                    Button {
                                        onSelect(workspace, section.id)
                                    } label: {
                                        QuickSessionWorkspacePickerRow(
                                            workspace: workspace,
                                            isSelected: isSelected(workspace, serverId: section.id),
                                            iconAssetCache: section.iconAssetCache
                                        )
                                    }
                                    .buttonStyle(QuickSessionWorkspacePickerRowButtonStyle())
                                    .accessibilityLabel(workspace.name)
                                    .accessibilityValue(isSelected(workspace, serverId: section.id) ? "Selected" : "")
                                    .accessibilityIdentifier("quickSession.workspace.\(workspace.name)")
                                }
                            }
                        }
                    }
                    .padding(.top, showsSectionHeaders ? 0 : 8)
                    .padding(.bottom, 8)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("No workspaces available", systemImage: "folder.badge.questionmark")
                        .font(.body.weight(.semibold))
                    Text(emptyMessage)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
        }
        .frame(width: 320)
        .frame(maxHeight: 430)
    }

    private func isSelected(_ workspace: Workspace, serverId: String) -> Bool {
        guard workspace.id == selectedWorkspaceId else { return false }
        guard let selectedServerId else { return true }
        return selectedServerId == serverId
    }
}

private struct QuickSessionWorkspacePickerRow: View {
    let workspace: Workspace
    let isSelected: Bool
    let iconAssetCache: IconAssetCache?

    var body: some View {
        HStack(spacing: 12) {
            WorkspaceRuntimeIcon(
                workspace: workspace,
                size: 18,
                frameSize: 30,
                assetCache: iconAssetCache
            )
                .frame(width: 30, height: 30)

            Text(workspace.name)
                .font(.body)
                .foregroundStyle(.themeFg)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.themeBlue)
                    .frame(width: 18, height: 18)
            } else {
                Color.clear
                    .frame(width: 18, height: 18)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .padding(.horizontal, 12)
        .background(
            isSelected ? Color.themeBlue.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct QuickSessionWorkspacePickerRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                if configuration.isPressed {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.themeFg.opacity(0.06))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                }
            }
    }
}

private extension UIView {
    func quickSessionDescendants(accessibilityIdentifier identifier: String) -> [UIView] {
        let currentMatch = accessibilityIdentifier == identifier ? [self] : []
        return currentMatch + subviews.flatMap {
            $0.quickSessionDescendants(accessibilityIdentifier: identifier)
        }
    }
}

enum QuickSessionError: LocalizedError {
    case noConnection
    case noWorkspace
    case agentLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .noConnection: return "Server is offline"
        case .noWorkspace: return "Choose a workspace first."
        case .agentLaunchFailed(let reason): return reason
        }
    }
}

// MARK: - Urgency scoring (extracted for testability)

/// Urgency score for session sorting — higher = more urgent.
///
/// Priority order: asks (20) > error (15) > busy/starting/stopping (10) > ready (5) > stopped (0).
/// Used by session list surfaces to rank active sessions before recent ones.
func quickSessionUrgencyScore(
    status: SessionStatus,
    hasAsk: Bool
) -> Int {
    if hasAsk { return 20 }
    switch status {
    case .error: return 15
    case .busy, .starting, .stopping: return 10
    case .ready: return 5
    case .stopped: return 0
    }
}

/// Sort sessions by urgency (descending), then by last activity (descending).
///
/// Each session's urgency is determined by `quickSessionUrgencyScore`.
/// Callers provide closures to resolve ask state per session so sorting stays
/// decoupled from store types.
func quickSessionSorted(
    _ sessions: [Session],
    hasAsk: (String) -> Bool
) -> [Session] {
    sessions.sorted { lhs, rhs in
        let lhsScore = quickSessionUrgencyScore(
            status: lhs.status,
            hasAsk: hasAsk(lhs.id)
        )
        let rhsScore = quickSessionUrgencyScore(
            status: rhs.status,
            hasAsk: hasAsk(rhs.id)
        )
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        return lhs.lastActivity > rhs.lastActivity
    }
}
