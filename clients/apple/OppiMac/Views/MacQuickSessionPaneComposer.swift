import SwiftUI

/// Empty-pane Quick Session: Mac chat-input look plus workspace / worktree / Agent.
struct MacQuickSessionPaneComposer: View {
    let workspaces: [Workspace]
    let agents: [AgentDefinitionSummary]
    let state: MacQuickSessionPaneState
    let composerState: MacSessionComposerState
    var sessionFocus: FocusState<KeybindingFocus?>.Binding
    let centersInPane: Bool
    let activate: () -> Void
    var isActivePane = true
    let loadWorktrees: (String) async -> [WorkspaceWorktree]
    let launch: (MacQuickSessionLaunchAttempt) async -> Void

    @Environment(\.theme) private var theme
    @Environment(\.macTypographyRevision) private var typographyRevision
    @State private var isLaunching = false
    @State private var models: [ModelInfo] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?
    @State private var isModelPickerPresented = false
    private let actionVisualDiameter = MacComposerInputMetrics.actionDiameter

    var body: some View {
        let _ = typographyRevision
        VStack(alignment: .leading, spacing: 10) {
            workspaceControls
            composerCapsule
        }
        .padding(.horizontal, 12)
        .padding(.vertical, centersInPane ? 12 : 0)
        .padding(.bottom, centersInPane ? 0 : 10)
        .frame(maxWidth: MacTimelineProsePaint.currentColumnWidth)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: centersInPane ? .center : .bottom
        )
        .accessibilityIdentifier("mac.session.pane.quickSession")
        .task(id: state.workspaceId) {
            await refreshWorktrees()
        }
        .onAppear {
            if state.workspaceId == nil {
                state.workspaceId = workspaces.first?.id
            }
        }
        .task {
            await loadModels()
        }
        .sheet(isPresented: $isModelPickerPresented) {
            MacModelPickerSheet(
                models: models,
                currentModel: state.modelID,
                isLoading: isLoadingModels,
                error: modelLoadError,
                refresh: { await loadModels() },
                selectModel: { model in
                    state.modelID = MacModelSelection.fullModelID(for: model)
                }
            )
        }
        .onChange(of: compatibleWorkspaces.map(\.id)) { _, ids in
            if let workspaceId = state.workspaceId, ids.contains(workspaceId) {
                return
            }
            state.workspaceId = ids.first
        }
    }

    @ViewBuilder
    private var workspaceControls: some View {
        if QuickSessionWorktreePickerPolicy.shouldShowPicker(worktreeCount: state.worktreeListing.worktrees.count) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    workspacePicker
                    worktreePicker
                }
                VStack(alignment: .leading, spacing: 6) {
                    workspacePicker
                    worktreePicker
                }
            }
        } else {
            workspacePicker
        }
    }

    private var compatibleWorkspaces: [Workspace] {
        QuickSessionLaunchRouting.compatibleWorkspaces(
            for: selectedAgent?.launchConstraints,
            in: workspaces
        )
    }

    private var selectedAgent: AgentDefinitionSummary? {
        guard let agentId = state.agentId else { return nil }
        return agents.first(where: { $0.id == agentId })
    }

    private var canSubmit: Bool {
        !isLaunching && state.workspaceId != nil && (
            selectedAgent == nil || !composerState.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private var workspacePicker: some View {
        Menu {
            ForEach(compatibleWorkspaces, id: \.id) { workspace in
                Button(workspace.name) {
                    state.workspaceId = workspace.id
                    state.worktreeId = nil
                }
            }
        } label: {
            MacComposerChromePill(
                systemImage: "folder",
                text: compatibleWorkspaces.first(where: { $0.id == state.workspaceId })?.name ?? "Workspace",
                showChevron: true
            )
        }
        .menuStyle(.borderlessButton)
        .accessibilityIdentifier("mac.quickSession.workspace")
        .accessibilityLabel("Workspace")
    }

    private var worktreePicker: some View {
        Menu {
            ForEach(state.worktreeListing.worktrees, id: \.id) { worktree in
                Button(worktree.displayName) {
                    state.worktreeId = worktree.id
                }
            }
        } label: {
            MacComposerChromePill(
                systemImage: "arrow.triangle.branch",
                text: worktreeLabel,
                showChevron: true
            )
        }
        .menuStyle(.borderlessButton)
        .accessibilityIdentifier("mac.quickSession.worktree")
        .accessibilityLabel("Worktree")
    }

    private var resolvedWorktreeId: String {
        state.worktreeListing.launchWorktreeId(selectedId: state.worktreeId)
    }

    private var worktreeLabel: String {
        if let match = state.worktreeListing.worktrees.first(where: { $0.id == resolvedWorktreeId }) {
            return match.displayName
        }
        if let selected = state.worktreeId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selected.isEmpty,
           selected != WorkspaceWorktree.mainId {
            return selected
        }
        return "Main"
    }

    private var composerCapsule: some View {
        let inputFont = MacComposerInputMetrics.font
        return VStack(alignment: .leading, spacing: 0) {
            if let errorMessage = state.errorMessage ?? composerState.localError {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(theme.accent.red)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            if !composerState.pendingAttachments.isEmpty {
                MacPendingAttachmentStrip(
                    attachments: composerState.pendingAttachments,
                    remove: { id in composerState.pendingAttachments.removeAll { $0.id == id } }
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

            HStack(alignment: .bottom, spacing: 8) {
                dictationButton

                ZStack(alignment: .topLeading) {
                    if composerState.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Message")
                            .font(Font(inputFont))
                            .foregroundStyle(theme.text.tertiary)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    MacComposerInputView(
                        text: Bindable(composerState).draft,
                        isEnabled: !isLaunching,
                        accessibilityLabel: "Message",
                        textColor: NSColor(theme.text.primary),
                        font: inputFont,
                        keyboardOwnershipGeneration: composerState.keyboardOwnershipGeneration,
                        wantsKeyboardOwnership: composerState.wantsKeyboardOwnership,
                        onFocusChange: { focused in
                            composerState.isComposerFirstResponder = focused
                            if focused {
                                activate()
                                sessionFocus.wrappedValue = .composer
                            }
                        },
                        onPasteAttachments: { payload in
                            let result = MacComposerPasteboardParser.adding(
                                payload,
                                to: composerState.pendingAttachments
                            )
                            composerState.pendingAttachments = result.attachments
                        }
                    )
                    // Hug the fitted text height (sizeThatFits clamps it to
                    // 1...6 lines). A min/max frame instead grew to the cap
                    // whenever the overlay offered room: a tall empty capsule.
                    .fixedSize(horizontal: false, vertical: true)
                    .focused(sessionFocus, equals: .composer)
                    .accessibilityIdentifier("mac.composer.input")
                }
                .frame(minHeight: actionVisualDiameter)

                sendButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            GlassEffectContainer(spacing: 0) {
                HStack(spacing: 6) {
                    attachButton
                    agentPicker
                    Spacer(minLength: 8)
                    modelPickerButton
                    thinkingLevelMenu
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedSurface(
            .elevatedPanel,
            in: RoundedRectangle(cornerRadius: MacComposerInputMetrics.capsuleCornerRadius, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session composer")
        .onChange(of: composerState.dictation.composedDraft) { _, composed in
            if composerState.dictation.isLive {
                composerState.draft = composed
            }
        }
    }

    private var dictationButton: some View {
        MacComposerDictationButton(
            state: composerState.dictation.state,
            diameter: actionVisualDiameter,
            isEnabled: !isLaunching && composerState.dictation.state != .stopping,
            action: { Task { await toggleDictation() } }
        )
    }

    private func toggleDictation() async {
        composerState.localError = nil
        switch composerState.dictation.state {
        case .recording:
            await composerState.dictation.stop()
            composerState.draft = composerState.dictation.composedDraft
        case .requestingPermission, .connecting:
            await composerState.dictation.cancel()
            composerState.draft = composerState.dictation.composedDraft
        case .stopping:
            return
        case .idle, .error:
            guard let endpoint = MacDictationEndpoint.localOwner() else {
                composerState.localError = DictationComposerPolicy.unavailableMessage
                return
            }
            do {
                try await composerState.dictation.start(
                    baseText: composerState.draft,
                    endpoint: endpoint
                )
            } catch {
                composerState.localError = error.localizedDescription
            }
        }
    }

    private var selectedModel: ModelInfo? {
        ThinkingLevelMenuSource.model(for: state.modelID, in: models)
    }

    private var attachButton: some View {
        Button(action: chooseAttachments) {
            MacComposerChromePill(systemImage: "plus", text: nil)
        }
        .buttonStyle(.plain)
        .disabled(isLaunching)
        .accessibilityIdentifier("mac.composer.attach")
        .accessibilityLabel("Add attachment")
        .help("Attach files")
    }

    private var modelPickerButton: some View {
        Button {
            isModelPickerPresented = true
        } label: {
            let provider = MacComposerActionPaint.modelPillProviderKey(for: state.modelID)
            MacComposerChromePill(
                systemImage: provider == nil ? "cpu" : nil,
                text: MacModelSelection.shortDisplayName(for: state.modelID) ?? "Model",
                showChevron: true,
                chevronSystemImage: MacComposerActionPaint.modelChevronSystemImage
            ) {
                if let provider {
                    ProviderGlyph(
                        provider: provider,
                        size: MacComposerChromePill<EmptyView>.glyphSize,
                        color: theme.text.primary
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isLaunching)
        .accessibilityIdentifier("mac.composer.model")
        .accessibilityLabel("Model")
        .help("Choose model")
    }

    private var thinkingLevelMenu: some View {
        Menu {
            Picker("Thinking", selection: Bindable(state).thinkingLevel) {
                ForEach(ThinkingLevelMenuSource.levels(for: selectedModel)) { level in
                    Text(level.displayTitle).tag(level)
                }
            }
        } label: {
            MacComposerChromePill(
                systemImage: "sparkle",
                text: state.thinkingLevel.compactTitle,
                tint: theme.thinking.color(for: state.thinkingLevel)
            )
        }
        .menuStyle(.borderlessButton)
        .disabled(isLaunching)
        .accessibilityIdentifier("mac.composer.thinking")
        .accessibilityLabel("Thinking level")
        .help("Thinking level")
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.begin { response in
            guard response == .OK else { return }
            let result = MacComposerPasteboardParser.adding(
                MacComposerPasteboardPayload(fileURLs: panel.urls, images: []),
                to: composerState.pendingAttachments
            )
            composerState.pendingAttachments = result.attachments
        }
    }

    private func loadModels() async {
        guard let client = MacWorkspaceClient.localOwner() else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            models = try await client.listModels()
            modelLoadError = nil
        } catch {
            modelLoadError = error.localizedDescription
        }
    }

    private var agentPicker: some View {
        Menu {
            Button("Pi") {
                state.agentId = nil
            }
            ForEach(agents, id: \.id) { agent in
                Button(agent.name) {
                    state.agentId = agent.id
                }
            }
        } label: {
            MacComposerChromePill(
                systemImage: "person.crop.circle",
                text: selectedAgent?.name ?? "Agent",
                showChevron: true
            )
        }
        .menuStyle(.borderlessButton)
        .accessibilityIdentifier("mac.quickSession.agent")
        .accessibilityLabel("Agent")
    }

    private var sendButton: some View {
        Button {
            submit()
        } label: {
            ZStack {
                Circle().fill(sendFillColor)
                Circle().stroke(sendStrokeColor, lineWidth: 1)
                if isLaunching {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(theme.bg.primary)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(canSubmit ? theme.bg.primary : theme.text.tertiary)
                }
            }
            .frame(width: actionVisualDiameter, height: actionVisualDiameter)
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .modifier(MacQuickSessionCommandReturnShortcut(isActivePane: isActivePane))
        .accessibilityIdentifier("mac.composer.send")
        .accessibilityLabel(isLaunching ? "Sending" : "Send")
        .help("Send")
    }

    private var sendFillColor: Color {
        switch MacComposerActionPaint.sendFill(
            isSendInFlight: isLaunching,
            canSend: canSubmit,
            isBusy: false
        ) {
        case .accent: theme.accent.blue
        case .purple: theme.accent.purple
        case .disabled: theme.bg.highlight
        }
    }

    private var sendStrokeColor: Color {
        canSubmit ? sendFillColor : theme.text.tertiary.opacity(0.2)
    }

    private func submit() {
        let request = QuickSessionLaunchRequest(
            workspaceId: state.workspaceId,
            worktreeId: resolvedWorktreeId,
            agentId: state.agentId,
            prompt: composerState.draft,
            hasAttachments: !composerState.pendingAttachments.isEmpty,
            hasRepoReferences: false
        )
        switch state.launchAttempt(for: request) {
        case .failure(let error):
            state.errorMessage = error.errorDescription
        case .success(let attempt):
            state.errorMessage = nil
            isLaunching = true
            Task {
                await launch(attempt)
                isLaunching = false
            }
        }
    }

    private func refreshWorktrees() async {
        let workspaceId = state.workspaceId
        let generation = state.worktreeListing.beginLoad(workspaceId: workspaceId)
        guard let workspaceId else { return }
        let fetched = await loadWorktrees(workspaceId)
        if Task.isCancelled {
            return
        }
        state.worktreeListing.applySuccess(
            workspaceId: workspaceId,
            generation: generation,
            worktrees: fetched
        )
    }
}

private struct MacQuickSessionCommandReturnShortcut: ViewModifier {
    let isActivePane: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if MacComposerPaneKeyboardRouting.installsCommandReturn(isActivePane: isActivePane) {
            content.keyboardShortcut(.return, modifiers: .command)
        } else {
            content
        }
    }
}
