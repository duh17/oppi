import SwiftUI

enum MacQuickSessionPaneLayoutPolicy {
    static let maximumSurfaceWidth: CGFloat = 640
}

/// Empty-pane Quick Session: Mac chat-input look plus workspace / worktree / Agent.
struct MacQuickSessionPaneComposer: View {
    let workspaces: [Workspace]
    let agents: [AgentDefinitionSummary]
    let state: MacQuickSessionPaneState
    let composerState: MacSessionComposerState
    var sessionFocus: FocusState<KeybindingFocus?>.Binding
    let centersInPane: Bool
    let activate: () -> Void
    let loadWorktrees: (String) async -> [WorkspaceWorktree]
    let launch: (MacQuickSessionLaunchAttempt) async -> Void

    @Environment(\.theme) private var theme
    @State private var worktrees: [WorkspaceWorktree] = []
    @State private var isLaunching = false
    private let actionVisualDiameter: CGFloat = 32

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            workspaceControls
            composerCapsule
        }
        .padding(.horizontal, 12)
        .padding(.vertical, centersInPane ? 12 : 0)
        .padding(.bottom, centersInPane ? 0 : 10)
        .frame(maxWidth: MacQuickSessionPaneLayoutPolicy.maximumSurfaceWidth)
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
        .onChange(of: compatibleWorkspaces.map(\.id)) { _, ids in
            if let workspaceId = state.workspaceId, ids.contains(workspaceId) {
                return
            }
            state.workspaceId = ids.first
        }
    }

    @ViewBuilder
    private var workspaceControls: some View {
        if QuickSessionWorktreePickerPolicy.shouldShowPicker(worktreeCount: worktrees.count) {
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
            ForEach(worktrees, id: \.id) { worktree in
                Button(worktree.displayName) {
                    state.worktreeId = worktree.id
                }
            }
        } label: {
            MacComposerChromePill(
                systemImage: "arrow.triangle.branch",
                text: worktrees.first(where: { $0.id == resolvedWorktreeId })?.displayName ?? "Main",
                showChevron: true
            )
        }
        .menuStyle(.borderlessButton)
        .accessibilityIdentifier("mac.quickSession.worktree")
        .accessibilityLabel("Worktree")
    }

    private var resolvedWorktreeId: String {
        QuickSessionWorktreePickerPolicy.resolvedWorktreeId(
            selectedId: state.worktreeId,
            worktrees: worktrees
        )
    }

    private var composerCapsule: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let errorMessage = state.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(theme.accent.red)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .leading) {
                    if composerState.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Message")
                            .foregroundStyle(theme.text.tertiary)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    MacComposerInputView(
                        text: Bindable(composerState).draft,
                        isEnabled: !isLaunching,
                        accessibilityLabel: "Message",
                        textColor: NSColor(theme.text.primary),
                        keyboardOwnershipGeneration: composerState.keyboardOwnershipGeneration,
                        wantsKeyboardOwnership: composerState.wantsKeyboardOwnership,
                        onFocusChange: { focused in
                            composerState.isComposerFirstResponder = focused
                            if focused {
                                activate()
                                sessionFocus.wrappedValue = .composer
                            }
                        },
                        onPasteAttachments: { _ in }
                    )
                    .frame(
                        minHeight: MacComposerInputMetrics.minimumHeight,
                        maxHeight: MacComposerInputMetrics.maximumHeight
                    )
                    .focused(sessionFocus, equals: .composer)
                    .accessibilityIdentifier("mac.composer.input")
                }

                sendButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            HStack {
                agentPicker
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedSurface(
            .elevatedPanel,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session composer")
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
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(canSubmit ? theme.bg.primary : theme.text.tertiary)
                }
            }
            .frame(width: actionVisualDiameter, height: actionVisualDiameter)
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .keyboardShortcut(.return, modifiers: .command)
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
            hasAttachments: false,
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
        guard let workspaceId = state.workspaceId else {
            worktrees = []
            return
        }
        worktrees = await loadWorktrees(workspaceId)
        state.worktreeId = QuickSessionWorktreePickerPolicy.resolvedWorktreeId(
            selectedId: state.worktreeId,
            worktrees: worktrees
        )
    }
}
