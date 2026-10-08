#if DEBUG
import SwiftUI

/// Production sheets and editors whose toolbar items must read on the iPhone
/// Duo vertical rail. Each case renders the real view with in-memory fixtures;
/// there is no server behind them.
enum RailToolbarScreenshotPreview {
    static let screens: Set<String> = [
        "rail-agent-edit",
        "rail-workspace-create",
        "rail-commit-detail",
        "rail-file-viewer",
        "rail-file-editor",
        "rail-ssh-hosts",
        "rail-onboarding-manual",
        "rail-roles",
        "rail-session-inbox",
        "rail-workspace-detail",
    ]
}

struct RailToolbarScreenshotPreviewView: View {
    let screen: String
    @State private var connection: ServerConnection = {
        let connection = ServerConnection()
        connection.setPreviewServerId("preview-server")
        return connection
    }()
    @State private var coordinator = ConnectionCoordinator(serverStore: ServerStore())
    @State private var navigation = AppNavigation()
    @State private var themeStore = ThemeStore()
    @State private var showsPreview = false

    var body: some View {
        content
            .environment(connection)
            .environment(connection.workspaceStore)
            .environment(connection.sessionStore)
            .environment(coordinator)
            .environment(coordinator.serverStore)
            .environment(navigation)
            .environment(themeStore)
            .accessibilityIdentifier("screenshot.ready")
            .onAppear { ScreenshotPreviewOrientation.applyRequested() }
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case "rail-agent-edit":
            AgentNativeEditView(agent: Self.agent, onSaved: { _ in })
        case "rail-workspace-create":
            WorkspaceCreateView(
                server: HostSwitcherPreviewData.server,
                prefillName: "oppi",
                prefillPath: "/Users/chen/workspace/oppi"
            )
        case "rail-commit-detail":
            NavigationStack {
                CommitDetailView(
                    workspaceId: "preview-workspace",
                    commit: GitCommitSummary(sha: "d30b40337", message: "fix: keep wiki file icons out of links", date: "2026-10-07")
                )
            }
        case "rail-file-viewer":
            NavigationStack {
                Color.themeBg
                    .ignoresSafeArea()
                    .navigationTitle("AGENTS.md")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(String(localized: "Edit"), systemImage: "pencil") {}
                        }
                    }
            }
        case "rail-file-editor":
            NavigationStack {
                Color.themeBg
                    .ignoresSafeArea()
                    .navigationTitle("AGENTS.md")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        WorkspaceFileEditToolbar(status: .saved, isShowingPreview: $showsPreview, onDone: {})
                    }
            }
        case "rail-ssh-hosts":
            NavigationStack { SSHTerminalHostListView() }
        case "rail-onboarding-manual":
            ManualEntryView { _ in }
        case "rail-session-inbox":
            RailSessionListScreenshotPreview(surface: .inbox)
        case "rail-workspace-detail":
            RailSessionListScreenshotPreview(surface: .workspaceDetail)
        case "rail-roles":
            NavigationStack {
                Color.themeBg
                    .ignoresSafeArea()
                    .navigationTitle("Roles")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button(role: .cancel) {} }
                        ToolbarItem(placement: .confirmationAction) { Button(role: .confirm) {} }
                        ToolbarItem(placement: .topBarTrailing) { Button(role: .close) {} }
                        if #available(iOS 27.0, *) {
                            ToolbarOverflowMenu { Button("Archive", systemImage: "archivebox") {} }
                        }
                    }
            }
        default:
            Text("Unknown rail screen \(screen)")
        }
    }

    private static let agent = StoredAgentDefinition(
        id: "agent-rail-preview",
        name: "Design Reviewer",
        icon: .defaultValue,
        description: "Reviews product presentation and checks interface hierarchy.",
        status: .active,
        version: 1,
        definition: AgentDefinition(
            name: "Design Reviewer",
            icon: .defaultValue,
            description: "Reviews product presentation and checks interface hierarchy.",
            instructions: AgentInstructions(mode: .append, text: "Review the interface as a product designer."),
            sessionDefaults: AgentSessionDefaults(model: "gpt-5.6-terra", thinkingLevel: .medium)
        ),
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1),
        archivedAt: nil
    )
}

/// Production All Sessions and workspace-detail chrome, with in-memory
/// sessions so the rail can be captured without a paired server.
private struct RailSessionListScreenshotPreview: View {
    enum Surface {
        case inbox
        case workspaceDetail
    }

    let surface: Surface
    @State private var coordinator: ConnectionCoordinator
    @State private var navigation = AppNavigation()
    @State private var path = NavigationPath()

    init(surface: Surface) {
        self.surface = surface
        _coordinator = State(initialValue: Self.makeCoordinator())
        if surface == .workspaceDetail {
            var path = NavigationPath()
            path.append("detail")
            _path = State(initialValue: path)
        }
    }

    var body: some View {
        content
            .environment(coordinator)
            .environment(coordinator.serverStore)
            .withServerScopedEnvironment(coordinator.activeConnection)
            .environment(navigation)
            .environment(ThemeStore())
    }

    @ViewBuilder
    private var content: some View {
        switch surface {
        case .inbox:
            NavigationStack {
                SessionInboxView(onOpenSidebar: {})
            }
        case .workspaceDetail:
            NavigationStack(path: $path) {
                Color.clear
                    .navigationTitle("All Sessions")
                    .navigationDestination(for: String.self) { _ in
                        WorkspaceDetailView(workspace: Self.workspace)
                            .withServerScopedEnvironment(coordinator.activeConnection)
                    }
            }
        }
    }

    private static let server = pairedServer()
    private static let workspace = Workspace(
        id: "oppi",
        name: "oppi",
        description: "Preview workspace",
        icon: .symbol("iphone.and.arrow.forward"),
        systemPrompt: nil,
        hostMount: "~/workspace/oppi",
        gitStatusEnabled: false,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    private static func makeCoordinator() -> ConnectionCoordinator {
        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        coordinator.serverStore.replaceServersForPreview([server])
        guard coordinator.switchToServer(server),
              let connection = coordinator.connection(for: server.id) else { return coordinator }
        connection.workspaceStore.upsert(workspace, serverId: server.id)
        connection.sessionStore.switchServer(to: server.id)
        connection.sessionStore.sessions = [
            session(id: "rail-1", name: "Fill the Duo side rail", status: .busy, minutesAgo: 2),
            session(id: "rail-2", name: "Keep Message on the phone bar", status: .ready, minutesAgo: 18),
        ]
        return coordinator
    }

    private static func pairedServer() -> PairedServer {
        guard let server = PairedServer(from: ServerCredentials(
            host: "mac-studio.local",
            port: 7749,
            token: "sk_preview",
            name: "mac-studio",
            scheme: .https,
            serverFingerprint: "sha256:rail-inbox-preview",
            tlsCertFingerprint: "sha256:rail-inbox-preview-leaf"
        )) else {
            preconditionFailure("rail inbox preview server")
        }
        return server
    }

    private static func session(
        id: String,
        name: String,
        status: SessionStatus,
        minutesAgo: Double
    ) -> Session {
        let lastActivity = Date().addingTimeInterval(-minutesAgo * 60)
        return Session(
            id: id,
            workspaceId: workspace.id,
            workspaceName: workspace.name,
            name: name,
            status: status,
            createdAt: lastActivity.addingTimeInterval(-600),
            lastActivity: lastActivity,
            model: "anthropic/claude-opus-5-5",
            messageCount: 4,
            tokens: TokenUsage(input: 8_000, output: 1_200),
            cost: 0.18
        )
    }
}
#endif
