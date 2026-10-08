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
#endif
