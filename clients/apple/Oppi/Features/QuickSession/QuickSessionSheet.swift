import OSLog
import SwiftUI
import UIKit

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "QuickSession")

/// Compact sheet for starting a new agent session.
///
/// Presented by the Action Button / Control Center / Spotlight via
/// `StartQuickSessionIntent`. The sheet stays focused on one task: pick a
/// workspace, compose the first message, then create and navigate to the new
/// session. Active and recent sessions live under each workspace.
///
/// **Flow**: Pick workspace → compose message → send → session created →
/// navigate to ChatView.
struct QuickSessionSheet: View {
    let onContentHeightChange: (CGFloat) -> Void

    @Environment(ChatSessionState.self) private var chatState
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var composerTextBeforeRecording: String?
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var pendingRepoPointers: [PendingFileReference] = []
    @State private var selectedWorkspace: Workspace?
    @State private var selectedWorkspaceSelectionSource = "unknown"
    @State private var selectedServerId: String?
    @State private var selectedModelId: String? = AppPreferences.QuickSession.lastModelId
    @State private var thinkingLevel: ThinkingLevel = AppPreferences.QuickSession.lastThinkingLevel
    @State private var showModelPicker = false
    @State private var showExpandedComposer = false
    @State private var isCreating = false
    @State private var error: String?
    @State private var voiceInputManager: VoiceInputManager?
    @State private var busyStreamingBehavior: StreamingBehavior = .followUp
    @State private var composerFocusRequestID = 0
    @State private var showWorkspacePicker = false

    /// All workspaces across all connected servers.
    private var allServerWorkspaces: [(serverId: String, workspace: Workspace)] {
        coordinator.connections.flatMap { serverId, conn in
            conn.workspaceStore.workspaces.map { (serverId: serverId, workspace: $0) }
        }
    }

    private var workspacePickerSections: [QuickSessionWorkspacePickerSection] {
        let grouped = Dictionary(grouping: allServerWorkspaces, by: \.serverId)
        return grouped.keys.sorted().map { serverId in
            QuickSessionWorkspacePickerSection(
                id: serverId,
                name: coordinator.serverStore.server(for: serverId)?.name ?? serverId,
                workspaces: (grouped[serverId] ?? []).map(\.workspace)
            )
        }
    }

    /// Display model: last or current explicit selection wins, then the workspace default.
    /// Session creation sends only the last/current explicit selection; server-side
    /// resolution applies workspace defaults and Pi settings centrally.
    private var effectiveModelId: String? {
        selectedModelId ?? selectedWorkspace?.defaultModel
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            composerContent
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .background(.clear)
        .presentationBackground(.clear)
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
                slashCommands: [],
                fileSuggestions: [],
                onFileSuggestionQuery: nil,
                session: nil,
                modelOverride: effectiveModelId,
                thinkingLevel: thinkingLevel,
                voiceInputManager: ReleaseFeatures.voiceInputEnabled ? voiceInputManager : nil,
                onPrepareVoiceInput: prepareVoiceInputForSelectedServer,
                onSend: handleSend,
                onModelTap: { showModelPicker = true },
                onThinkingSelect: selectThinkingLevel,
                allowsEmptySubmit: true
            )
        }
        .task {
            await setupInitialState()
        }
        .onChange(of: selectedServerId) { _, _ in
            configureVoiceInputForSelectedServer()
        }
    }

    private var composerContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.themeRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.themeRed.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            ChatInputBar(
                text: $text,
                textBeforeRecording: $composerTextBeforeRecording,
                pendingAttachments: $pendingAttachments,
                pendingRepoPointers: $pendingRepoPointers,
                isBusy: false,
                busyStreamingBehavior: $busyStreamingBehavior,
                isSending: isCreating,
                allowsEmptySubmit: true,
                sendProgressText: nil,
                isStopping: false,
                voiceInputManager: ReleaseFeatures.voiceInputEnabled ? voiceInputManager : nil,
                onPrepareVoiceInput: prepareVoiceInputForSelectedServer,
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
                appliesOuterPadding: true,
                alwaysShowActionRow: true,
                actionRow: {
                    workspaceNavBarItem
                    SessionToolbar(
                        session: nil,
                        modelOverride: effectiveModelId,
                        thinkingLevel: thinkingLevel,
                        onModelTap: { showModelPicker = true },
                        onThinkingSelect: selectThinkingLevel
                    )
                }
            )
        }
        .padding(.top, 6)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            onContentHeightChange(height)
        }
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

    // MARK: - Workspace Picker

    /// Compact workspace picker for the action row — icon + name with a custom popover.
    private var workspaceNavBarItem: some View {
        Button {
            showWorkspacePicker.toggle()
        } label: {
            HStack(spacing: 4) {
                if let selectedWorkspace {
                    WorkspaceRuntimeIcon(workspace: selectedWorkspace, size: 12, frameSize: 16)
                } else {
                    Image(systemName: "folder")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.themeBlue)
                        .frame(width: 16, height: 16)
                }
                Text(selectedWorkspace?.name ?? "Workspace")
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
        .buttonStyle(.plain)
        .popover(isPresented: $showWorkspacePicker, arrowEdge: .bottom) {
            QuickSessionWorkspacePicker(
                sections: workspacePickerSections,
                showsSectionHeaders: workspacePickerSections.count > 1,
                selectedWorkspaceId: selectedWorkspace?.id,
                selectedServerId: selectedServerId,
                onSelect: selectWorkspace
            )
            .presentationCompactAdaptation(.popover)
            .presentationBackground(.regularMaterial)
        }
        .accessibilityLabel(selectedWorkspace.map { "Workspace picker, current workspace \($0.name)" } ?? "Workspace picker")
    }

    private func selectWorkspace(_ workspace: Workspace, serverId: String) {
        selectedWorkspace = workspace
        selectedWorkspaceSelectionSource = "manual"
        selectedServerId = serverId
        showWorkspacePicker = false
        error = nil
        configureVoiceInputForSelectedServer()
        AppPreferences.QuickSession.saveWorkspaceId(workspace.id)
    }

    // MARK: - Actions

    private func setupInitialState() async {
        await drainPendingDictationCleanupQueue()

        // Select workspace: last used > explicit default > first available.
        let all = allServerWorkspaces
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
        }

        // Initialize voice input
        if ReleaseFeatures.voiceInputEnabled {
            let manager = VoiceInputManager()
            voiceInputManager = manager
            configureVoiceInputForSelectedServer(manager)
        }

        if let sharedPayload = QuickSessionTrigger.shared.consumePendingSharePayload() {
            applySharedPayload(sharedPayload)
        }

        // Auto-focus the text input
        composerFocusRequestID += 1

        // Ensure model cache is fresh for the selected server.
        if let api = selectedServerConnection().apiClient {
            await chatState.refreshModelCache(api: api)
        }
    }

    private func applySharedPayload(_ payload: ShareQuickSessionPayload) {
        defer { ShareQuickSessionPayload.removePayloadFiles(id: payload.id) }

        if let sharedText = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines), !sharedText.isEmpty {
            text = sharedText
        }

        for file in payload.files {
            guard let inboxURL = ShareQuickSessionPayload.inboxURL else { continue }
            let url = inboxURL.appendingPathComponent(file.relativePath, isDirectory: false)
            guard let data = try? Data(contentsOf: url) else { continue }

            if file.mimeType.hasPrefix("image/"), let image = UIImage(data: data) {
                pendingAttachments.append(PendingImage.from(data: data, mimeType: file.mimeType, image: image).pendingAttachment)
            } else {
                pendingAttachments.append(PendingAttachment.localFile(
                    name: file.name,
                    data: data,
                    mimeType: file.mimeType
                ))
            }
        }
    }

    private func configureVoiceInputForSelectedServer(_ manager: VoiceInputManager? = nil) {
        guard let manager = manager ?? voiceInputManager else { return }
        let targetConnection = selectedServerConnection()
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

    private func selectedServerConnection() -> ServerConnection {
        if let selectedServerId,
           let connection = coordinator.connection(for: selectedServerId) {
            return connection
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
            await TimelineCache.shared.removeTrace(cleanup.sessionId)
            AppPreferences.QuickSession.removePendingDictationCleanup(cleanup)
        } catch let apiError as APIError {
            if case .server(let status, _) = apiError, status == 404 {
                connection.sessionStore.remove(id: cleanup.sessionId)
                await TimelineCache.shared.removeTrace(cleanup.sessionId)
                AppPreferences.QuickSession.removePendingDictationCleanup(cleanup)
            } else {
                logger.warning("Failed to delete queued quick dictation session \(cleanup.sessionId, privacy: .public): \(apiError.localizedDescription, privacy: .public)")
            }
        } catch {
            logger.warning("Failed to delete queued quick dictation session \(cleanup.sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleSend() {
        guard !isCreating else { return }
        guard let workspace = selectedWorkspace else {
            error = "Choose a workspace first."
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let transportText = PendingFileReference.appendReferenceBlock(
            to: trimmed,
            files: pendingRepoPointers
        )
        let modelId = selectedModelId
        let thinking = thinkingLevel

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
        ]

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
                    model: modelId,
                    thinking: thinking.rawValue
                )
                let session = response.session
                // Upsert into the target server's session store — not the
                // environment's store (which belongs to the currently active
                // server and may differ for cross-server quick sessions).
                targetConnection.sessionStore.upsert(session)

                // Save defaults for next time. Model persists from the last/current
                // explicit selection; workspace defaults are displayed but not sent
                // as client overrides.
                AppPreferences.QuickSession.saveWorkspaceId(workspace.id)
                AppPreferences.QuickSession.saveModelId(modelId)
                AppPreferences.QuickSession.saveThinkingLevel(thinking)
                ChatSessionTelemetry.recordTimingMetric(
                    .quickSessionCreateMs,
                    durationMs: max(0, ChatSessionTelemetry.nowMs() - telemetryStartedAtMs),
                    workspaceId: workspace.id,
                    tags: telemetryTags.merging(["status": "ok"]) { _, new in new }
                )
                logger.notice("Quick session created: \(session.id, privacy: .public) in workspace \(workspace.name, privacy: .public)")

                // Single atomic write — ContentView.onDismiss unpacks.
                let shouldAutoSend = !transportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
                nav.pendingQuickSessionNav = QuickSessionNav(
                    target: WorkspaceNavTarget(serverId: serverId, workspace: workspace),
                    sessionId: session.id,
                    autoSendMessage: shouldAutoSend ? transportText : nil,
                    autoSendAttachments: shouldAutoSend ? pendingAttachments : nil
                )

                dismiss()
            } catch {
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

private struct QuickSessionWorkspacePickerSection: Identifiable {
    let id: String
    let name: String
    let workspaces: [Workspace]
}

private struct QuickSessionWorkspacePicker: View {
    let sections: [QuickSessionWorkspacePickerSection]
    let showsSectionHeaders: Bool
    let selectedWorkspaceId: String?
    let selectedServerId: String?
    let onSelect: (Workspace, String) -> Void

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
                                            isSelected: isSelected(workspace, serverId: section.id)
                                        )
                                    }
                                    .buttonStyle(QuickSessionWorkspacePickerRowButtonStyle())
                                    .accessibilityLabel(workspace.name)
                                    .accessibilityValue(isSelected(workspace, serverId: section.id) ? "Selected" : "")
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
                    Text("Pair or refresh a server, then try again.")
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

    var body: some View {
        HStack(spacing: 12) {
            WorkspaceRuntimeIcon(workspace: workspace, size: 18, frameSize: 30)
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

enum QuickSessionError: LocalizedError {
    case noConnection
    case noWorkspace

    var errorDescription: String? {
        switch self {
        case .noConnection: return "Server is offline"
        case .noWorkspace: return "Choose a workspace first."
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
