import OSLog
import PhotosUI
import SwiftUI

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "QuickSession")

/// Compact sheet for starting a new agent session.
///
/// Presented by the Action Button / Control Center / Spotlight via
/// `StartQuickSessionIntent`. Mirrors the `ChatInputBar` aesthetic:
/// glass capsule composer with mic, images, model and thinking pills.
///
/// **Flow**: Pick workspace → compose message → send → session created →
/// navigate to ChatView.
struct QuickSessionSheet: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(SessionStore.self) private var sessionStore
    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(ChatSessionState.self) private var chatState
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var text = ""
    @State private var pendingImages: [PendingImage] = []
    @State private var selectedWorkspace: Workspace?
    @State private var selectedServerId: String?
    @State private var selectedModelId: String?
    @State private var thinkingLevel: ThinkingLevel = QuickSessionDefaults.lastThinkingLevel
    @State private var showModelPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var isCreating = false
    @State private var error: String?
    @State private var voiceInputManager: VoiceInputManager?
    @State private var textBeforeRecording: String?
    @State private var suppressKeyboard = false
    @State private var keyboardLanguage: String?
    @State private var focusRequestID = 0

    /// All workspaces across all connected servers.
    private var allServerWorkspaces: [(serverId: String, workspace: Workspace)] {
        coordinator.connections.flatMap { serverId, conn in
            conn.workspaceStore.workspaces.map { (serverId: serverId, workspace: $0) }
        }
    }

    private var canSend: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImages = !pendingImages.isEmpty
        return (hasText || hasImages) && selectedWorkspace != nil && !isCreating
    }

    private var modelDisplay: String {
        guard let modelId = effectiveModelId else { return "default" }
        return shortModelName(modelId)
    }

    private var modelProvider: String {
        guard let modelId = effectiveModelId else { return "" }
        return providerFromModel(modelId) ?? ""
    }

    /// Effective model: explicit selection > workspace default > last used.
    private var effectiveModelId: String? {
        selectedModelId
            ?? selectedWorkspace?.defaultModel
            ?? QuickSessionDefaults.lastModelId
    }

    private var thinkingTint: Color {
        theme.thinking.color(for: thinkingLevel)
    }

    private static let thinkingOptions: [ThinkingLevel] = [.off, .minimal, .low, .medium, .high, .xhigh]

    private var thinkingLabel: String {
        switch thinkingLevel {
        case .off: return "off"
        case .minimal: return "min"
        case .low: return "low"
        case .medium: return "med"
        case .high: return "high"
        case .xhigh: return "max"
        }
    }

    var body: some View {
        composerCapsule
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
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(
                onCapture: { image in
                    addCapturedImage(image)
                    showCamera = false
                },
                onCancel: { showCamera = false }
            )
            .ignoresSafeArea()
        }
        .task {
            await setupInitialState()
        }
        .onChange(of: photoSelection) { _, items in
            loadSelectedPhotos(items)
        }
        .onChange(of: voiceInputManager?.currentTranscript) { _, newTranscript in
            guard let prefix = textBeforeRecording, let transcript = newTranscript else { return }
            text = prefix + transcript
        }
    }

    // MARK: - Workspace Nav Bar Item

    /// Compact workspace picker for the nav bar — icon only with menu.
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
                        .font(.system(size: 11))
                } else {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(.themeBlue)
                }
                Text(selectedWorkspace?.name ?? "Workspace")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
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

    // MARK: - Composer

    private var composerCapsule: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !pendingImages.isEmpty {
                imageStrip
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }

            HStack(alignment: .bottom, spacing: 6) {
                if ReleaseFeatures.voiceInputEnabled, let manager = voiceInputManager {
                    micButton(manager: manager)
                        .fixedSize()
                }

                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text("What do you need?")
                            .font(.body)
                            .foregroundStyle(.themeComment)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }

                    PastableTextView(
                        text: $text,
                        placeholder: "",
                        font: .preferredFont(forTextStyle: .body),
                        textColor: UIColor(Color.themeFg),
                        tintColor: UIColor(Color.themeBlue),
                        maxLines: 6,
                        autocorrectionEnabled: true,
                        onPasteImages: handlePastedImages,
                        onCommandEnter: handleSend,
                        onAlternateEnter: handleSend,
                        onOverflowChange: nil,
                        onLineCountChange: nil,
                        onFocusChange: nil,
                        onDictationStateChange: nil,
                        focusRequestID: focusRequestID,
                        blurRequestID: 0,
                        dictationRequestID: 0,
                        suppressKeyboard: suppressKeyboard,
                        allowKeyboardRestoreOnTap: true,
                        onKeyboardRestoreRequest: handleKeyboardRestore,
                        accessibilityIdentifier: "quickSession.input",
                        keyboardLanguage: $keyboardLanguage
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                sendButton
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            // Action row
            HStack(spacing: 6) {
                workspaceNavBarItem

                attachButton

                Spacer()

                Button { showModelPicker = true } label: {
                    HStack(spacing: 3) {
                        ProviderIcon(provider: modelProvider)
                            .frame(width: 11, height: 11)
                        Text(modelDisplay)
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .frame(minHeight: 17)
                    .foregroundStyle(.themeFg)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .glassEffect(.regular, in: Capsule())
                }
                .buttonStyle(.plain)

                Menu {
                    ForEach(Self.thinkingOptions, id: \.rawValue) { level in
                        Button {
                            thinkingLevel = level
                            QuickSessionDefaults.saveThinkingLevel(level)
                        } label: {
                            if level == thinkingLevel {
                                Label(thinkingMenuTitle(for: level), systemImage: "checkmark")
                            } else {
                                Text(thinkingMenuTitle(for: level))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 11, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                        Text(thinkingLabel)
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .frame(minHeight: 17)
                    .foregroundStyle(thinkingTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .glassEffect(.regular, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .padding(.bottom, 7)
        }
        .frame(minHeight: 38)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var attachButton: some View {
        Menu {
            Button {
                showPhotoPicker = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }
            Button {
                showCamera = true
            } label: {
                Label("Camera", systemImage: "camera")
            }
        } label: {
            Image(systemName: "plus")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.themeFg)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: Capsule())
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoSelection,
            maxSelectionCount: 5,
            matching: .images
        )
    }

    @ViewBuilder
    private var sendButton: some View {
        Button(action: handleSend) {
            ZStack {
                Circle().fill(canSend ? Color.themeBlue : Color.themeBgHighlight)
                Circle().stroke(
                    canSend ? Color.themeBlue.opacity(0.9) : Color.themeComment.opacity(0.35),
                    lineWidth: 1
                )
                if isCreating {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(canSend ? .white : .themeComment)
                }
            }
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityIdentifier("quickSession.send")
    }

    private func micButton(manager: VoiceInputManager) -> some View {
        let isRecording = manager.isRecording
        let isPreparing = manager.isPreparing
        let isProcessing = manager.isProcessing

        return Button {
            Task {
                switch manager.state {
                case .recording:
                    await manager.stopRecording()
                    textBeforeRecording = nil
                case .preparingModel:
                    await manager.cancelRecording()
                    textBeforeRecording = nil
                    suppressKeyboard = false
                case .idle:
                    let current = text
                    if current.isEmpty || current.hasSuffix(" ") || current.hasSuffix("\n") {
                        textBeforeRecording = current
                    } else {
                        textBeforeRecording = current + " "
                    }
                    suppressKeyboard = true
                    focusRequestID += 1
                    do {
                        try await manager.startRecording(
                            keyboardLanguage: keyboardLanguage,
                            source: "quick_session_mic"
                        )
                    } catch {
                        textBeforeRecording = nil
                        suppressKeyboard = false
                    }
                case .processing, .error:
                    break
                }
            }
        } label: {
            MicButtonLabel(
                isRecording: isRecording,
                isProcessing: isPreparing || isProcessing,
                audioLevel: manager.audioLevel,
                languageLabel: manager.activeLanguageLabel,
                accentColor: .themeBlue,
                engineBadge: micEngineBadge(for: manager),
                diameter: 32
            )
        }
        .buttonStyle(.plain)
        .disabled(isProcessing)
        .accessibilityIdentifier("quickSession.mic")
    }

    private var imageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingImages) { pending in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: pending.thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.themeComment.opacity(0.3), lineWidth: 1)
                            )
                        Button {
                            pendingImages.removeAll { $0.id == pending.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.white)
                                .background(Circle().fill(.black.opacity(0.6)))
                        }
                        .offset(x: 4, y: -4)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func setupInitialState() async {
        // Select workspace: last used > first available
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

        // Pre-fill with pending draft (e.g. from file browser π action)
        if let draft = navigation.pendingQuickSessionDraft {
            text = draft
            navigation.pendingQuickSessionDraft = nil
        }

        // Auto-focus the text input
        focusRequestID += 1

        // Ensure model cache is fresh
        await connection.refreshModelCache()
    }

    private func handleSend() {
        guard canSend, let workspace = selectedWorkspace else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        let modelId = effectiveModelId
        let thinking = thinkingLevel

        // Stop any active recording before sending
        if let manager = voiceInputManager, manager.isRecording || manager.isPreparing {
            textBeforeRecording = nil
            Task {
                if manager.isRecording {
                    await manager.stopRecording()
                } else {
                    await manager.cancelRecording()
                }
            }
        }

        isCreating = true
        error = nil

        // Capture references before dismiss invalidates environment
        let nav = navigation
        let serverId = selectedServerId ?? connection.currentServerId ?? "default"

        Task { @MainActor in
            do {
                // Use the correct server's API client
                let targetConnection = coordinator.connection(for: serverId) ?? connection
                guard let api = targetConnection.apiClient else {
                    throw QuickSessionError.noConnection
                }

                // Create session without prompt — we'll send through WebSocket
                let response = try await api.createWorkspaceSession(
                    workspaceId: workspace.id,
                    model: modelId
                )
                let session = response.session
                sessionStore.upsert(session)

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

                // Stage navigation — ContentView's onDismiss will execute the two-step push
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

    private func handleKeyboardRestore() {
        suppressKeyboard = false
        textBeforeRecording = nil
        if let manager = voiceInputManager, manager.isRecording || manager.isPreparing {
            Task {
                if manager.isRecording {
                    await manager.stopRecording()
                } else {
                    await manager.cancelRecording()
                }
            }
        }
    }

    private func handlePastedImages(_ images: [UIImage]) {
        for image in images {
            DispatchQueue.global(qos: .userInitiated).async {
                let pending = PendingImage.from(image)
                DispatchQueue.main.async {
                    pendingImages.append(pending)
                }
            }
        }
    }

    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) {
        for item in items {
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                guard let uiImage = UIImage(data: data) else { return }
                let pending = PendingImage.from(uiImage)
                await MainActor.run { pendingImages.append(pending) }
            }
        }
        photoSelection = []
    }

    private func addCapturedImage(_ image: UIImage) {
        DispatchQueue.global(qos: .userInitiated).async {
            let pending = PendingImage.from(image)
            DispatchQueue.main.async {
                pendingImages.append(pending)
            }
        }
    }

    private func micEngineBadge(for manager: VoiceInputManager) -> MicButtonLabel.EngineBadge {
        switch manager.routeIndicator {
        case .auto: return .auto
        case .onDevice: return .onDevice
        case .remote: return .remote
        }
    }

    private func thinkingMenuTitle(for level: ThinkingLevel) -> String {
        switch level {
        case .off: return "Off"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Max"
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
