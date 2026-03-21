import OSLog
import SwiftUI

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "QuickSession")

/// Compact sheet for starting a new agent session.
///
/// Presented by the Action Button / Control Center / Spotlight via
/// `StartQuickSessionIntent`. Uses `ChatInputBar` with workspace picker,
/// model and thinking pills to compose and send the initial prompt.
/// Supports expanding to `ExpandedComposerView` for long-form input.
///
/// **Flow**: Pick workspace → compose message → send → session created →
/// navigate to ChatView.
struct QuickSessionSheet: View {
    @Environment(ChatSessionState.self) private var chatState
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var pendingImages: [PendingImage] = []
    @State private var pendingFiles: [PendingFileReference] = []
    @State private var selectedWorkspace: Workspace?
    @State private var selectedServerId: String?
    @State private var selectedModelId: String?
    @State private var thinkingLevel: ThinkingLevel = QuickSessionDefaults.lastThinkingLevel
    @State private var showModelPicker = false
    @State private var showExpandedComposer = false
    @State private var isCreating = false
    @State private var error: String?
    @State private var voiceInputManager: VoiceInputManager?
    @State private var busyStreamingBehavior: StreamingBehavior = .followUp
    @State private var composerFocusRequestID = 0

    /// All workspaces across all connected servers.
    private var allServerWorkspaces: [(serverId: String, workspace: Workspace)] {
        coordinator.connections.flatMap { serverId, conn in
            conn.workspaceStore.workspaces.map { (serverId: serverId, workspace: $0) }
        }
    }

    /// Effective model: explicit selection > workspace default > last used.
    private var effectiveModelId: String? {
        selectedModelId
            ?? selectedWorkspace?.defaultModel
            ?? QuickSessionDefaults.lastModelId
    }

    var body: some View {
        ChatInputBar(
            text: $text,
            pendingImages: $pendingImages,
            pendingFiles: $pendingFiles,
            isBusy: false,
            busyStreamingBehavior: $busyStreamingBehavior,
            isSending: isCreating,
            sendProgressText: nil,
            isStopping: false,
            voiceInputManager: ReleaseFeatures.voiceInputEnabled ? voiceInputManager : nil,
            showForceStop: false,
            isForceStopInFlight: false,
            slashCommands: [],
            fileSuggestions: [],
            onFileSuggestionQuery: nil,
            onSend: handleSend,
            onStop: {},
            onForceStop: {},
            onExpand: { showExpandedComposer = true },
            externalFocusRequestID: composerFocusRequestID,
            appliesOuterPadding: false,
            alwaysShowActionRow: true,
            actionRow: {
                workspaceNavBarItem
                SessionToolbar(
                    session: nil,
                    modelOverride: effectiveModelId,
                    thinkingLevel: thinkingLevel,
                    onModelTap: { showModelPicker = true },
                    onThinkingSelect: { level in
                        thinkingLevel = level
                        QuickSessionDefaults.saveThinkingLevel(level)
                    }
                )
            }
        )
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .background(.clear)
        .presentationBackground(.clear)
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(
                currentModel: effectiveModelId,
                onSelect: { model in
                    selectedModelId = ModelSwitchPolicy.fullModelID(for: model)
                }
            )
        }
        .fullScreenCover(isPresented: $showExpandedComposer) {
            ExpandedComposerView(
                text: $text,
                pendingImages: $pendingImages,
                pendingFiles: $pendingFiles,
                isBusy: false,
                busyStreamingBehavior: .followUp,
                slashCommands: [],
                fileSuggestions: [],
                onFileSuggestionQuery: nil,
                session: nil,
                modelOverride: effectiveModelId,
                thinkingLevel: thinkingLevel,
                voiceInputManager: ReleaseFeatures.voiceInputEnabled ? voiceInputManager : nil,
                onSend: handleSend,
                onModelTap: { showModelPicker = true },
                onThinkingSelect: { level in
                    thinkingLevel = level
                    QuickSessionDefaults.saveThinkingLevel(level)
                }
            )
        }
        .task {
            await setupInitialState()
        }
    }

    // MARK: - Workspace Picker

    /// Compact workspace picker for the action row — icon + name with menu.
    private var workspaceNavBarItem: some View {
        Menu {
            let grouped = Dictionary(grouping: allServerWorkspaces, by: \.serverId)
            let serverIds = grouped.keys.sorted()
            ForEach(serverIds, id: \.self) { serverId in
                let items = grouped[serverId] ?? []
                let serverName = coordinator.serverStore.server(for: serverId)?.name ?? serverId
                if serverIds.count > 1 {
                    Section(serverName) {
                        ForEach(items, id: \.workspace.id) { item in
                            workspaceMenuButton(item.workspace, serverId: item.serverId)
                        }
                    }
                } else {
                    ForEach(items, id: \.workspace.id) { item in
                        workspaceMenuButton(item.workspace, serverId: item.serverId)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                if let icon = selectedWorkspace?.icon {
                    Text(icon)
                        .font(.appCaptionLight)
                } else {
                    Image(systemName: "folder")
                        .font(.appChipLight)
                        .foregroundStyle(.themeBlue)
                }
                Text(selectedWorkspace?.name ?? "Workspace")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.appBadgeCount)
                    .foregroundStyle(.themeComment)
            }
            .frame(minHeight: 17)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.themeComment.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Workspace picker")
    }

    private func workspaceMenuButton(_ workspace: Workspace, serverId: String) -> some View {
        Button {
            selectedWorkspace = workspace
            selectedServerId = serverId
            QuickSessionDefaults.saveWorkspaceId(workspace.id)
        } label: {
            Label {
                Text(workspace.name)
            } icon: {
                if workspace.id == selectedWorkspace?.id {
                    Image(systemName: "checkmark")
                } else if let icon = workspace.icon {
                    Text(icon)
                }
            }
        }
    }

    // MARK: - Actions

    private func setupInitialState() async {
        // Select workspace: last used > first available across all servers
        let lastId = QuickSessionDefaults.lastWorkspaceId
        let all = allServerWorkspaces
        if let lastId, let match = all.first(where: { $0.workspace.id == lastId }) {
            selectedWorkspace = match.workspace
            selectedServerId = match.serverId
        } else if let first = all.first {
            selectedWorkspace = first.workspace
            selectedServerId = first.serverId
        }

        // Initialize voice input
        if ReleaseFeatures.voiceInputEnabled {
            voiceInputManager = VoiceInputManager()
        }

        // Pre-fill with pending draft (e.g. from file browser pi action)
        if let draft = navigation.pendingQuickSessionDraft {
            text = draft
            navigation.pendingQuickSessionDraft = nil
        }

        // Auto-focus the text input
        composerFocusRequestID += 1

        // Ensure model cache is fresh
        if let api = coordinator.activeConnection.apiClient {
            await chatState.refreshModelCache(api: api)
        }
    }

    private func handleSend() {
        guard let workspace = selectedWorkspace, !isCreating else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        let modelId = effectiveModelId
        let thinking = thinkingLevel

        isCreating = true
        error = nil

        // Capture references before dismiss invalidates environment
        let nav = navigation
        let serverId = selectedServerId ?? coordinator.activeServerId ?? "default"

        Task { @MainActor in
            do {
                // Use the correct server's API client
                let targetConnection = coordinator.connection(for: serverId) ?? coordinator.activeConnection
                guard let api = targetConnection.apiClient else {
                    throw QuickSessionError.noConnection
                }

                // Create session without prompt — we'll send through WebSocket
                let response = try await api.createWorkspaceSession(
                    workspaceId: workspace.id,
                    model: modelId
                )
                let session = response.session
                // Upsert into the target server's session store — not the
                // environment's store (which belongs to the currently active
                // server and may differ for cross-server quick sessions).
                targetConnection.sessionStore.upsert(session)

                // Save defaults for next time
                QuickSessionDefaults.saveWorkspaceId(workspace.id)
                if let modelId {
                    QuickSessionDefaults.saveModelId(modelId)
                }
                QuickSessionDefaults.saveThinkingLevel(thinking)

                // Store pending message + images for auto-send in ChatView
                nav.pendingQuickSessionMessage = trimmed
                nav.pendingQuickSessionImages = images.isEmpty ? nil : images

                logger.notice("Quick session created: \(session.id, privacy: .public) in workspace \(workspace.name, privacy: .public)")

                // Stage navigation — ContentView's onDismiss pushes the workspace,
                // WorkspaceDetailView consumes the session ID on appear.
                nav.pendingQuickSessionNav = QuickSessionNav(
                    target: WorkspaceNavTarget(serverId: serverId, workspace: workspace),
                    sessionId: session.id
                )

                dismiss()
            } catch {
                self.error = error.localizedDescription
                isCreating = false
                logger.error("Quick session creation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

enum QuickSessionError: LocalizedError {
    case noConnection

    var errorDescription: String? {
        switch self {
        case .noConnection: return "Server is offline"
        }
    }
}
