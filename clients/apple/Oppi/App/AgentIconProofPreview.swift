#if DEBUG
import SwiftUI

/// Deterministic UI proof for the Agent icon journey.
///
/// The picker, validation model, icon renderer, session row, and chat empty-state
/// identity are production components. Persistence and session launch stop at
/// this preview's in-memory boundary so the focused UI test needs no server.
struct AgentIconProofPreview: View {
    private enum Destination: Hashable {
        case detail
        case sessions
        case agentChat
    }

    let failsFirstSave: Bool

    @State private var agent = Self.makeAgent(icon: .defaultValue, version: 1)
    @State private var isShowingPicker = false
    @State private var saveAttemptCount = 0
    @State private var themeStore = ThemeStore()
    @Environment(\.colorScheme) private var colorScheme

    init(failsFirstSave: Bool = false) {
        self.failsFirstSave = failsFirstSave
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Agents") {
                    NavigationLink(value: Destination.detail) {
                        HStack(spacing: 12) {
                            AgentIconView(value: agent.definition.icon, size: 22, frameSize: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(agent.name)
                                    .font(.headline)
                                Text(iconSummary)
                                    .font(.caption)
                                    .foregroundStyle(.themeComment)
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityValue(iconSummary)
                    .accessibilityIdentifier("agent.proof.agentRow")
                }
            }
            .navigationTitle("Agents")
            .navigationBarTitleDisplayMode(.inline)
            .themedListSurface()
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .detail:
                    detailView
                case .sessions:
                    sessionsView
                case .agentChat:
                    agentChatView
                }
            }
        }
        .environment(\.theme, themeStore.appTheme)
        .environment(\.themeID, themeStore.activeThemeID)
        .tint(.themeBlue)
        .preferredColorScheme(themeStore.preferredColorScheme)
        .onAppear(perform: syncSystemColorScheme)
        .onChange(of: colorScheme) { _, _ in
            syncSystemColorScheme()
        }
        .accessibilityIdentifier("screenshot.ready")
    }

    private func syncSystemColorScheme() {
        themeStore.updateSystemColorScheme(colorScheme)
    }

    private var detailView: some View {
        List {
            Section("Definition") {
                Button {
                    isShowingPicker = true
                } label: {
                    HStack(spacing: 12) {
                        Text("Icon")
                            .foregroundStyle(.themeComment)
                        Spacer(minLength: 12)
                        AgentIconView(value: agent.definition.icon, size: 24, frameSize: 32)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.themeComment)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Icon")
                .accessibilityValue(iconSummary)
                .accessibilityIdentifier("agent.proof.detail.icon")

                LabeledContent("Name", value: agent.name)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Description")
                        .font(.subheadline)
                        .foregroundStyle(.themeComment)
                    Text(agent.definition.description ?? "")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                LabeledContent("Status", value: "Active")
                LabeledContent("Version", value: "v\(agent.version)")
            }

            if let instructions = agent.definition.instructions {
                Section(instructions.mode == .append ? "Append System Prompt" : "Replace System Prompt") {
                    Text(instructions.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section("Pi Session Defaults") {
                LabeledContent("Model", value: agent.definition.sessionDefaults?.model ?? "Server default")
                LabeledContent(
                    "Thinking Level",
                    value: agent.definition.sessionDefaults?.thinkingLevel?.rawValue ?? "Default"
                )
                if let noTools = agent.definition.sessionDefaults?.noTools {
                    LabeledContent("Tools", value: noTools.displayName)
                        .accessibilityIdentifier("agent.proof.tools.noTools")
                }
                if let allowed = agent.definition.sessionDefaults?.tools, !allowed.isEmpty {
                    toolList("Allowed Tools", values: allowed)
                }
                if let excluded = agent.definition.sessionDefaults?.excludeTools, !excluded.isEmpty {
                    toolList("Excluded Tools", values: excluded)
                }
            }

            Section("Start") {
                NavigationLink(value: Destination.sessions) {
                    Label("Start Session with Agent", systemImage: "play.circle.fill")
                }
                .accessibilityIdentifier("agent.proof.launch")
            }
        }
        .navigationTitle(agent.name)
        .navigationBarTitleDisplayMode(.inline)
        .themedListSurface()
        .sheet(isPresented: $isShowingPicker) {
            AgentIconPickerView(
                agent: agent,
                saveOperation: { icon in
                    saveAttemptCount += 1
                    if failsFirstSave && saveAttemptCount == 1 {
                        throw AgentIconProofSaveError.unavailable
                    }
                    return Self.makeAgent(icon: icon, version: agent.version + 1)
                },
                onSaved: { updated in
                    agent = updated
                }
            )
        }
    }

    private var sessionsView: some View {
        List {
            Section("Agent Session") {
                NavigationLink(value: Destination.agentChat) {
                    SessionRow(session: agentSession)
                        .accessibilityElement(children: .combine)
                }
                .accessibilityIdentifier("agent.proof.session.agent")
            }

            Section("Ordinary Session") {
                SessionRow(session: ordinarySession)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("agent.proof.session.ordinary")
            }
        }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .themedListSurface()
    }

    private var agentChatView: some View {
        VStack(spacing: 20) {
            HStack(spacing: 8) {
                AgentIconView(
                    value: agent.definition.icon,
                    size: 20,
                    frameSize: 24,
                    isDecorative: false,
                    visualScale: ChatAgentIconStyle.compactVisualScale
                )
                Text(agentSession.displayTitle)
                    .font(.headline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("agent.proof.chat.titleIdentity")

            GroupBox("Agent session empty state") {
                ChatEmptyState(
                    sessionId: agentSession.id,
                    agentId: agent.id,
                    agentIcon: agent.definition.icon
                )
                .frame(height: 150)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("agent.proof.chat.agentIdentity")

            GroupBox("Ordinary session comparison") {
                ChatEmptyState(sessionId: ordinarySession.id)
                    .frame(height: 96)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Ordinary session uses the global assistant avatar")
            .accessibilityIdentifier("agent.proof.chat.ordinaryIdentity")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.themeBg.ignoresSafeArea())
        .navigationTitle("Agent Session")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toolList(_ title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.themeComment)
            Text(values.joined(separator: ", "))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var iconSummary: String {
        AgentIconPickerView.description(agent.definition.icon)
    }

    private var agentSession: Session {
        Self.makeSession(
            id: "agent-proof-session",
            name: "Icon Journey",
            launch: SessionLaunchMetadata(agentId: agent.id, agentIcon: agent.definition.icon)
        )
    }

    private var ordinarySession: Session {
        Self.makeSession(id: "ordinary-proof-session", name: "Ordinary Session", launch: nil)
    }

    private static func makeAgent(icon: IconChoice, version: Int) -> StoredAgentDefinition {
        StoredAgentDefinition(
            id: "agent-icon-proof",
            name: "Design Reviewer",
            icon: icon,
            description: "Reviews product presentation and checks interface hierarchy, alignment, and platform fit.",
            status: .active,
            version: version,
            definition: AgentDefinition(
                name: "Design Reviewer",
                icon: icon,
                description: "Reviews product presentation and checks interface hierarchy, alignment, and platform fit.",
                instructions: AgentInstructions(
                    mode: .append,
                    text: "Review the interface as a product designer. Prioritize hierarchy, alignment, and native platform conventions."
                ),
                sessionDefaults: AgentSessionDefaults(
                    model: "gpt-5.6-terra",
                    thinkingLevel: .medium,
                    tools: ["read", "bash"],
                    excludeTools: ["browser"],
                    noTools: .builtin
                )
            ),
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: Double(version)),
            archivedAt: nil
        )
    }

    private static func makeSession(
        id: String,
        name: String,
        launch: SessionLaunchMetadata?
    ) -> Session {
        let now = Date()
        return Session(
            id: id,
            workspaceId: "agent-icon-proof-workspace",
            workspaceName: "Proof Workspace",
            name: name,
            status: .ready,
            createdAt: now,
            lastActivity: now,
            model: "omlx/proof-model",
            messageCount: 0,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0,
            contextTokens: nil,
            contextWindow: nil,
            firstMessage: nil,
            lastMessage: nil,
            thinkingLevel: nil,
            launch: launch
        )
    }
}

private enum AgentIconProofSaveError: LocalizedError {
    case unavailable

    var errorDescription: String? { "Preview server is unavailable" }
}

/// Isolated assistant-avatar sheet proof. It keeps persistence outside the
/// fixture so Cancel can prove that an invalid draft never changes the avatar.
struct AssistantAvatarPickerProofPreview: View {
    @State private var avatar: AssistantAvatar = .piText
    @State private var isShowingPicker = false

    var body: some View {
        NavigationStack {
            List {
                Button("Change Assistant Avatar") {
                    isShowingPicker = true
                }
                .accessibilityIdentifier("assistant.avatarProof.open")

                LabeledContent("Saved Avatar", value: avatar.accessibilityDescription)
                    .accessibilityIdentifier("assistant.avatarProof.saved")
            }
            .navigationTitle("Assistant Avatar Proof")
            .sheet(isPresented: $isShowingPicker) {
                AvatarPickerView(avatar: $avatar)
            }
        }
        .accessibilityIdentifier("screenshot.ready")
    }
}
#endif
