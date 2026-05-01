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
/// When active sessions exist across any workspace/server, they are shown
/// above the composer grouped by workspace — tap to navigate.
///
/// **Flow**: Pick workspace → compose message → send → session created →
/// navigate to ChatView.
struct QuickSessionSheet: View {
    @Environment(ChatSessionState.self) private var chatState
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var composerTextBeforeRecording: String?
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var pendingRepoPointers: [PendingFileReference] = []
    @State private var selectedWorkspace: Workspace?
    @State private var selectedServerId: String?
    @State private var selectedModelId: String?
    @State private var thinkingLevel: ThinkingLevel = .medium
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

    /// Effective model: explicit selection only. If nil, Pi settings choose.
    private var effectiveModelId: String? {
        selectedModelId
    }

    /// Whether multiple servers are connected (affects section headers).
    private var hasMultipleServers: Bool {
        coordinator.connections.count > 1
    }

    /// Active sessions across all servers, grouped by workspace.
    ///
    /// "Active" = busy, starting, stopping, ready, or error.
    /// Stopped sessions are excluded.
    private var activeSessionsByWorkspace: [(workspace: Workspace, serverId: String, sessions: [Session])] {
        var groups: [(workspace: Workspace, serverId: String, sessions: [Session])] = []
        var seen: Set<String> = []

        for (serverId, conn) in coordinator.connections {
            let sessions = conn.sessionStore.sessions.filter { session in
                switch session.status {
                case .busy, .starting, .stopping, .ready, .error: return true
                case .stopped: return false
                }
            }

            let byWorkspace = Dictionary(grouping: sessions) { $0.workspaceId ?? "" }
            for (wsId, wsSessions) in byWorkspace {
                guard !seen.contains(wsId) else { continue }
                seen.insert(wsId)

                guard let ws = conn.workspaceStore.workspaces.first(where: { $0.id == wsId }) else {
                    continue
                }

                let sorted = quickSessionSorted(
                    wsSessions,
                    hasPermission: { !conn.permissionStore.pending(for: $0).isEmpty },
                    hasAsk: { conn.askRequestStore.hasPending(for: $0) }
                )

                groups.append((workspace: ws, serverId: serverId, sessions: sorted))
            }
        }

        return groups.sorted { lhs, rhs in
            let lhsMax = lhs.sessions.map { session in
                coordinator.connections[lhs.serverId].map { sessionUrgencyScore(session, connection: $0) } ?? 0
            }.max() ?? 0
            let rhsMax = rhs.sessions.map { session in
                coordinator.connections[rhs.serverId].map { sessionUrgencyScore(session, connection: $0) } ?? 0
            }.max() ?? 0
            if lhsMax != rhsMax { return lhsMax > rhsMax }
            return lhs.workspace.name < rhs.workspace.name
        }
    }

    /// Urgency score for sorting — higher = more urgent.
    private func sessionUrgencyScore(_ session: Session, connection conn: ServerConnection) -> Int {
        quickSessionUrgencyScore(
            status: session.status,
            hasPermission: !conn.permissionStore.pending(for: session.id).isEmpty,
            hasAsk: conn.askRequestStore.hasPending(for: session.id)
        )
    }

    /// Whether there are active sessions to display.
    var hasActiveSessions: Bool {
        !activeSessionsByWorkspace.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if !activeSessionsByWorkspace.isEmpty {
                activeSessionsList
                Divider()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }

            ChatInputBar(
            text: $text,
            textBeforeRecording: $composerTextBeforeRecording,
            pendingAttachments: $pendingAttachments,
            pendingRepoPointers: $pendingRepoPointers,
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
                    }
                )
            }
        )
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 4)
        }
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
                textBeforeRecording: $composerTextBeforeRecording,
                pendingAttachments: $pendingAttachments,
                pendingRepoPointers: $pendingRepoPointers,
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
                }
            )
        }
        .task {
            await setupInitialState()
        }
    }

    // MARK: - Active Sessions List

    /// Scrollable list of active sessions grouped by workspace.
    private var activeSessionsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(activeSessionsByWorkspace, id: \.workspace.id) { group in
                    workspaceSessionSection(
                        workspace: group.workspace,
                        serverId: group.serverId,
                        sessions: group.sessions
                    )
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(maxHeight: 400)
    }

    /// Section header + session rows for one workspace.
    @ViewBuilder
    private func workspaceSessionSection(
        workspace: Workspace,
        serverId: String,
        sessions: [Session]
    ) -> some View {
        HStack(spacing: 6) {
            if let icon = workspace.icon {
                Text(icon)
                    .font(.caption)
            }
            Text(workspace.name.uppercased())
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.themeComment)
                .tracking(0.8)

            if hasMultipleServers {
                let serverName = coordinator.serverStore.server(for: serverId)?.name
                    ?? String(serverId.prefix(8))
                Text(serverName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.themeComment)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.themeComment.opacity(0.1), in: Capsule())
            }

            Spacer()
        }
        .padding(.top, 16)
        .padding(.bottom, 6)

        let conn = coordinator.connections[serverId]
        ForEach(sessions) { session in
            Button {
                navigateToSession(session, serverId: serverId, workspace: workspace)
            } label: {
                activeSessionRow(for: session, connection: conn)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
        }
    }

    /// Build a SessionRow with activity data from the owning connection.
    private func activeSessionRow(for session: Session, connection conn: ServerConnection?) -> some View {
        let permissions = conn?.permissionStore.pending(for: session.id) ?? []
        let pendingCount = permissions.count
        let askPending = conn?.askRequestStore.hasPending(for: session.id) == true ? 1 : 0
        let activity = conn?.activityStore.lastActivity(for: session.id)
        let ask = conn?.askRequestStore.pending(for: session.id)

        let summary = SessionActivitySummary.text(
            session: session,
            pendingCount: pendingCount,
            pendingPermissions: permissions,
            pendingAsk: ask,
            activity: activity
        )

        return SessionRow(
            session: session,
            pendingCount: pendingCount,
            pendingAskCount: askPending,
            activitySummary: summary
        )
    }

    /// Dismiss sheet and navigate to a specific session.
    private func navigateToSession(
        _ session: Session,
        serverId: String,
        workspace: Workspace
    ) {
        let nav = navigation
        nav.pendingQuickSessionNav = QuickSessionNav(
            target: WorkspaceNavTarget(serverId: serverId, workspace: workspace),
            sessionId: session.id
        )
        dismiss()
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
            AppPreferences.QuickSession.saveWorkspaceId(workspace.id)
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
        // Select workspace: last used > explicit default > first available.
        let all = allServerWorkspaces
        let preferredId = AppPreferences.QuickSession.preferredWorkspaceId(
            in: all.map { (id: $0.workspace.id, name: $0.workspace.name) }
        )
        if let preferredId, let match = all.first(where: { $0.workspace.id == preferredId }) {
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
        let transportText = PendingFileReference.appendReferenceBlock(
            to: trimmed,
            files: pendingRepoPointers
        )
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
                AppPreferences.QuickSession.saveWorkspaceId(workspace.id)
                logger.notice("Quick session created: \(session.id, privacy: .public) in workspace \(workspace.name, privacy: .public)")

                // Single atomic write — ContentView.onDismiss unpacks.
                nav.pendingQuickSessionNav = QuickSessionNav(
                    target: WorkspaceNavTarget(serverId: serverId, workspace: workspace),
                    sessionId: session.id,
                    autoSendMessage: transportText,
                    autoSendAttachments: pendingAttachments
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

// MARK: - Urgency scoring (extracted for testability)

/// Urgency score for session sorting — higher = more urgent.
///
/// Priority order: permissions (30) > asks (20) > error (15) > busy/starting/stopping (10) > ready (5) > stopped (0).
/// Used by `QuickSessionSheet.activeSessionsByWorkspace` to rank sessions and workspace groups.
func quickSessionUrgencyScore(
    status: SessionStatus,
    hasPermission: Bool,
    hasAsk: Bool
) -> Int {
    if hasPermission { return 30 }
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
/// Callers provide closures to resolve permission/ask state per session
/// so sorting stays decoupled from store types.
func quickSessionSorted(
    _ sessions: [Session],
    hasPermission: (String) -> Bool,
    hasAsk: (String) -> Bool
) -> [Session] {
    sessions.sorted { lhs, rhs in
        let lhsScore = quickSessionUrgencyScore(
            status: lhs.status,
            hasPermission: hasPermission(lhs.id),
            hasAsk: hasAsk(lhs.id)
        )
        let rhsScore = quickSessionUrgencyScore(
            status: rhs.status,
            hasPermission: hasPermission(rhs.id),
            hasAsk: hasAsk(rhs.id)
        )
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        return lhs.lastActivity > rhs.lastActivity
    }
}
