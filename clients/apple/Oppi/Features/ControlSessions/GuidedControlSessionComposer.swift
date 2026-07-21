import SwiftUI

/// Quick Session-style intake for server-scoped Agent and Schedule control sessions.
///
/// The selected workspace is prompt context only. Control sessions intentionally
/// remain workspace-less so the Default Agent can inspect and mutate server-owned
/// definitions through its restricted `oppi` CLI tool.
struct GuidedControlSessionComposer: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(ServerConnection.self) private var connection
    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(SessionStore.self) private var sessionStore
    @Environment(ChatSessionState.self) private var chatState
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let domain: ControlSessionDomain
    let intent: ControlSessionIntent
    var targetId: String?
    var targetName: String?
    var initialRequest = ""
    var allowsEmptyRequest = false
    var placeholder: String
    var onWillNavigate: (() -> Void)?

    @State private var request = ""
    @State private var textBeforeRecording: String?
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var pendingRepoPointers: [PendingFileReference] = []
    @State private var selectedWorkspace: Workspace?
    @State private var selectedModelId: String? = AppPreferences.QuickSession.lastModelId
    @State private var thinkingLevel: ThinkingLevel = AppPreferences.QuickSession.lastThinkingLevel
    @State private var voiceInputManager: VoiceInputManager?
    @State private var streamingBehavior: StreamingBehavior = .followUp
    @State private var showModelPicker = false
    @State private var isInitialized = false
    @State private var isCreating = false
    @State private var error: String?

    private var effectiveModelId: String? {
        selectedModelId ?? selectedWorkspace?.defaultModel
    }

    private var isAvailable: Bool {
        apiClient != nil && connection.controlSessionsAvailable && selectedWorkspace != nil
    }

    private var stacksControls: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.themeRed)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("\(identifierPrefix).error")
            }

            ChatInputBar(
                text: $request,
                textBeforeRecording: $textBeforeRecording,
                pendingAttachments: $pendingAttachments,
                pendingRepoPointers: $pendingRepoPointers,
                isBusy: false,
                busyStreamingBehavior: $streamingBehavior,
                isSending: isCreating,
                placeholderOverride: resolvedPlaceholder,
                allowsEmptySubmit: allowsEmptyRequest,
                sendProgressText: nil,
                isStopping: false,
                voiceInputManager: ReleaseFeatures.voiceInputEnabled ? voiceInputManager : nil,
                onPrepareVoiceInput: prepareVoiceInput,
                showForceStop: false,
                isForceStopInFlight: false,
                slashCommands: [],
                fileSuggestions: [],
                onFileSuggestionQuery: nil,
                onSend: { Task { await createControlSession() } },
                onStop: {},
                onForceStop: {},
                onExpand: {},
                externalFocusRequestID: 0,
                appliesOuterPadding: true,
                alwaysShowActionRow: !stacksControls,
                allowsExpansion: false,
                allowsAttachments: false,
                showsAccessoryRow: !stacksControls,
                actionRow: {
                    if !stacksControls {
                        composerControls
                    }
                }
            )
            .disabled(!isAvailable || !isInitialized)

            if stacksControls {
                VStack(alignment: .leading, spacing: 6) {
                    workspacePicker
                    HStack(spacing: 6) {
                        sessionToolbar
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .padding(.top, 8)
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(currentModel: effectiveModelId, onSelect: selectModel)
        }
        .task { await initialize() }
    }

    @ViewBuilder
    private var composerControls: some View {
        workspacePicker
        sessionToolbar
    }

    private var sessionToolbar: some View {
        SessionToolbar(
            session: nil,
            modelOverride: effectiveModelId,
            thinkingLevel: thinkingLevel,
            onModelTap: { showModelPicker = true },
            onThinkingSelect: selectThinkingLevel
        )
    }

    private var workspacePicker: some View {
        Menu {
            ForEach(workspaceStore.workspaces) { workspace in
                Button {
                    selectWorkspace(workspace)
                } label: {
                    Label {
                        Text(workspace.name)
                    } icon: {
                        if workspace.id == selectedWorkspace?.id {
                            Image(systemName: "checkmark")
                        } else {
                            Image(systemName: "folder")
                        }
                    }
                }
                .accessibilityIdentifier("\(identifierPrefix).workspace.\(workspace.id)")
            }
        } label: {
            SessionWorkspacePillLabel(workspace: selectedWorkspace)
        }
        .accessibilityLabel(selectedWorkspace.map { "Workspace picker, current workspace \($0.name)" } ?? "Workspace picker")
        .accessibilityIdentifier("\(identifierPrefix).workspacePicker")
    }

    private var resolvedPlaceholder: String {
        guard apiClient != nil, connection.controlSessionsAvailable else {
            return "Connect to use guided \(domainTitle.lowercased()) setup"
        }
        guard selectedWorkspace != nil else { return "Choose a workspace first" }
        return placeholder
    }

    private var identifierPrefix: String {
        "guided.\(domain.rawValue).\(intent.rawValue)"
    }

    private var domainTitle: String {
        switch domain {
        case .agents: "Agent"
        case .schedules: "Schedule"
        case .workspaces: "Workspace"
        }
    }

    private func selectWorkspace(_ workspace: Workspace) {
        selectedWorkspace = workspace
        AppPreferences.QuickSession.saveWorkspaceId(workspace.id)
        error = nil
    }

    private func selectModel(_ model: ModelInfo) {
        let modelId = ModelSwitchPolicy.fullModelID(for: model)
        selectedModelId = modelId
        AppPreferences.QuickSession.saveModelId(modelId)
        AppPreferences.RecentModels.record(modelId)
    }

    private func selectThinkingLevel(_ level: ThinkingLevel) {
        thinkingLevel = level
        AppPreferences.QuickSession.saveThinkingLevel(level)
    }

    @MainActor
    private func initialize() async {
        guard !isInitialized else { return }
        request = initialRequest

        let workspaces = workspaceStore.workspaces
        if let preferred = AppPreferences.QuickSession.preferredWorkspaceSelection(
            in: workspaces.map { (id: $0.id, name: $0.name) }
        ) {
            selectedWorkspace = workspaces.first(where: { $0.id == preferred.id })
        }
        if selectedWorkspace == nil {
            selectedWorkspace = workspaces.first
        }

        if ReleaseFeatures.voiceInputEnabled {
            let manager = VoiceInputManager()
            configureVoiceInput(manager)
            voiceInputManager = manager
        }

        if let apiClient {
            await chatState.refreshModelCache(api: apiClient)
        }
        isInitialized = true
    }

    private func configureVoiceInput(_ manager: VoiceInputManager) {
        manager.setServerCredentials(connection.credentials)
        manager.setServerConnection(connection)
        manager.setPlaybackInterrupter(connection.audioPlayer)
    }

    private func prepareVoiceInput(_ manager: VoiceInputManager) async throws {
        configureVoiceInput(manager)
        manager.setServerDictationTarget(nil)
    }

    @MainActor
    private func createControlSession() async {
        guard let apiClient, let selectedWorkspace, !isCreating else { return }
        let cleanRequest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowsEmptyRequest || !cleanRequest.isEmpty else { return }

        isCreating = true
        defer { isCreating = false }

        do {
            let response = try await apiClient.createControlSession(.init(
                domain: domain,
                intent: intent,
                targetId: targetId,
                targetName: targetName,
                name: sessionName(request: cleanRequest),
                model: effectiveModelId,
                thinking: thinkingLevel,
                prompt: ControlSessionStarterPrompt.make(
                    domain: domain,
                    intent: intent,
                    targetId: targetId,
                    targetName: targetName,
                    workspaceId: selectedWorkspace.id,
                    workspaceName: selectedWorkspace.name,
                    userRequest: cleanRequest
                )
            ))
            guard response.prompted == true else {
                error = "Default Agent could not start. Your request is still here so you can try again."
                return
            }
            sessionStore.cacheSessionForNavigation(response.session)
            guard let serverId = connection.currentServerId ?? sessionStore.activeServerId else {
                error = "Could not open the new Oppi session"
                return
            }

            request = ""
            error = nil
            onWillNavigate?()
            await Task.yield()
            navigation.openWorkspaceSession(.init(
                serverId: serverId,
                sessionId: response.session.id,
                routeScope: .control
            ))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func sessionName(request: String) -> String {
        if intent == .revise {
            return "Revise \(targetName ?? domainTitle)"
        }
        let fallback = "Create \(domainTitle)"
        guard !request.isEmpty else { return fallback }
        return "\(domainTitle): \(String(request.prefix(48)))"
    }
}

struct GuidedControlSessionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let domain: ControlSessionDomain
    let intent: ControlSessionIntent
    var targetId: String?
    var targetName: String?
    var initialRequest = ""
    var allowsEmptyRequest = true
    var placeholder: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                title,
                systemImage: domain == .agents ? "person.crop.circle.badge.questionmark" : "calendar.badge.clock",
                description: Text("Describe the outcome you want. Default Agent will inspect the current definition and clarify anything ambiguous before changing it.")
            )
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .themedListSurface()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                GuidedControlSessionComposer(
                    domain: domain,
                    intent: intent,
                    targetId: targetId,
                    targetName: targetName,
                    initialRequest: initialRequest,
                    allowsEmptyRequest: allowsEmptyRequest,
                    placeholder: placeholder,
                    onWillNavigate: { dismiss() }
                )
            }
        }
    }

    private var title: String {
        let subject = targetName ?? (domain == .agents ? "Agent" : "Schedule")
        return intent == .create ? "Create \(subject)" : "Revise \(subject)"
    }
}

struct SessionWorkspacePillLabel: View {
    let workspace: Workspace?

    var body: some View {
        HStack(spacing: 4) {
            if let workspace {
                WorkspaceRuntimeIcon(workspace: workspace, size: 12, frameSize: 16)
            } else {
                Image(systemName: "folder")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.themeBlue)
                    .frame(width: 16, height: 16)
            }
            Text(workspace?.name ?? "Workspace")
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
