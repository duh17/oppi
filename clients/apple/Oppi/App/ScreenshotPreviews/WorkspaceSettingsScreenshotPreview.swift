#if DEBUG
import SwiftUI

/// Real Workspace Settings surfaces with one fixture workspace and no network.
/// `SCREENSHOT_WORKSPACE_PAGE` picks the root (default) or a page: `details`,
/// `instructions`, `skills`, `extensions`, `mcp`, `network`.
/// `SCREENSHOT_WORKSPACE_RUNTIME=sandbox` renders a sandbox workspace instead of
/// a host workspace. `SCREENSHOT_COLOR_SCHEME=dark` selects the dark theme.
struct WorkspaceSettingsScreenshotPreview: View {
    private let connection: ServerConnection
    private let coordinator: ConnectionCoordinator
    private let workspace: Workspace
    private let model: WorkspaceSettingsModel
    @State private var navigation = AppNavigation()
    private let themeStore = ThemeStore()

    private static let serverId = "preview-server"

    private static let skills: [SkillInfo] = [
        SkillInfo(name: "agents-md", description: "Manage global and project AGENTS.md files for coding agents.", path: "/skills/agents-md"),
        SkillInfo(name: "audio-transcribe", description: "Transcribe local audio files or YouTube videos with Yuwp's canonical `yuwp-asr` CLI and helpers.", path: "/skills/audio-transcribe", enabled: false),
        SkillInfo(name: "autoresearch", description: "Set up and run an autonomous experiment loop for any optimization target.", path: "/skills/autoresearch"),
        SkillInfo(name: "clanker-farm", description: "Design and build CLI tools and skills optimized for both human and AI agent consumption.", path: "/skills/clanker-farm", enabled: false),
        SkillInfo(name: "deep-research", description: "Conduct safe, evidence-first web research with iterative search and citation verification.", path: "/skills/deep-research"),
        SkillInfo(name: "devdoc", description: "Look up third-party API docs, Apple docs, and RFC references.", path: "/skills/devdoc"),
    ]

    private static let extensions: [ExtensionInfo] = [
        ExtensionInfo(name: "oppi-ask", path: "oppi://built-in/ask", kind: "built-in", source: "oppi"),
        ExtensionInfo(name: "oppi-permissions", path: "oppi://built-in/permissions", kind: "built-in", source: "oppi"),
        ExtensionInfo(name: "workflow", path: "~/.pi/agent/extensions/workflow", kind: "file", source: "pi"),
        ExtensionInfo(name: "pi-sessions", path: "~/.pi/agent/extensions/pi-sessions", kind: "file", source: "pi"),
        ExtensionInfo(name: "simplify", path: "~/.pi/agent/extensions/simplify", kind: "file", source: "pi", enabled: false),
        ExtensionInfo(name: "todos", path: "~/.pi/agent/extensions/todos", kind: "file", source: "pi"),
    ]

    private static func mcpServer(
        name: String,
        config: McpServerConfig,
        state: String,
        enabled: Bool = true,
        error: String? = nil
    ) -> McpServerSummary {
        McpServerSummary(
            name: name,
            transport: config.url == nil ? "stdio" : "http",
            config: config,
            enabled: enabled,
            exposure: .codemode,
            state: state,
            tools: [],
            toolExposure: nil,
            error: error,
            supportsOAuth: false
        )
    }

    init() {
        let environment = ProcessInfo.processInfo.environment
        let isSandbox = environment["SCREENSHOT_WORKSPACE_RUNTIME"] == "sandbox"
        let serverId = Self.serverId

        var workspace = Workspace(
            id: "preview-ws",
            name: isSandbox ? "oppi-sandbox" : "oppi-dev",
            description: "iOS app development workspace",
            icon: .symbol(isSandbox ? "shippingbox" : "hammer"),
            systemPrompt: "Prefer small, reversible changes.\nRun the focused tests before reporting done.\nKeep commit subjects under 72 characters.",
            hostMount: isSandbox ? nil : "~/workspace/oppi",
            gitStatusEnabled: true,
            createdAt: Date(),
            updatedAt: Date()
        )
        if isSandbox {
            workspace.runtime = .sandbox
            workspace.sandboxConfig = SandboxConfig(
                allowedHosts: ["api.github.com", "registry.npmjs.org"],
                env: nil,
                mcpServers: ["github"]
            )
        }
        self.workspace = workspace

        let connection = ServerConnection()
        connection.setPreviewServerId(serverId)
        connection.workspaceStore.setActiveServer(serverId)
        connection.workspaceStore.workspacesByServer[serverId] = [workspace]
        self.connection = connection

        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        self.coordinator = coordinator

        let model = WorkspaceSettingsModel.screenshotFixture(
            workspace: workspace,
            skills: Self.skills,
            extensions: Self.extensions,
            projectTrust: isSandbox ? nil : .trusted,
            sandboxMcpServers: [
                Self.mcpServer(name: "github", config: McpServerConfig(url: "https://api.github.com/mcp"), state: "available"),
                Self.mcpServer(
                    name: "filesystem",
                    config: McpServerConfig(command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem"]),
                    state: "blocked",
                    error: "Its environment references host secrets."
                ),
                Self.mcpServer(
                    name: "docs",
                    config: McpServerConfig(url: "https://docs.example.com/mcp"),
                    state: "disabled",
                    enabled: false
                ),
            ]
        )
        model.attach(connection: connection, workspace: workspace)
        self.model = model

        if environment["SCREENSHOT_COLOR_SCHEME"] == "dark" {
            themeStore.mode = .manual
            themeStore.manualThemeID = .dark
        }
    }

    var body: some View {
        NavigationStack {
            page
        }
        .environment(coordinator)
        .environment(coordinator.serverStore)
        .withServerScopedEnvironment(connection)
        .environment(navigation)
        .environment(themeStore)
        .environment(\.theme, themeStore.appTheme)
        .environment(\.themeID, themeStore.activeThemeID)
        .tint(.themeBlue)
        .preferredColorScheme(themeStore.preferredColorScheme)
        .accessibilityIdentifier("screenshot.ready")
    }

    @ViewBuilder
    private var page: some View {
        switch ProcessInfo.processInfo.environment["SCREENSHOT_WORKSPACE_PAGE"] {
        case "details": WorkspaceDetailsPage(model: model)
        case "instructions": WorkspaceInstructionsPage(model: model)
        case "skills": WorkspaceSkillsPage(model: model)
        case "extensions": WorkspaceExtensionsPage(model: model)
        case "mcp":
            if workspace.runtime == .sandbox {
                WorkspaceSandboxMcpPage(model: model)
            } else {
                McpServersView(scopeId: workspace.id)
            }
        case "network": WorkspaceNetworkAccessPage(model: model)
        default: WorkspaceSettingsRootView(workspace: workspace, model: model)
        }
    }
}
#endif
