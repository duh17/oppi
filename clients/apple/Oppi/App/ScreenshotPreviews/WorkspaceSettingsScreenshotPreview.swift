#if DEBUG
import SwiftUI

/// Real Workspace Settings surfaces with one fixture workspace and no network.
/// `SCREENSHOT_WORKSPACE_PAGE` picks the root (default, the UIKit
/// `WorkspaceSettingsViewController`) or a page: `details`, `instructions`,
/// `skills`, `extensions`, `mcp`, `network`.
/// `SCREENSHOT_WORKSPACE_RUNTIME=sandbox` renders a sandbox workspace instead of
/// a host workspace. `SCREENSHOT_COLOR_SCHEME=dark` selects the dark theme.
struct WorkspaceSettingsScreenshotPreview: View {
    private let connection: ServerConnection
    private let root: AppRootEnvironment
    private let workspace: Workspace
    private let model: WorkspaceSettingsModel
    private let themeStore: ThemeStore

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
        ScreenshotVolatileDefaults.applyDarkTheme(environment["SCREENSHOT_COLOR_SCHEME"] == "dark")
        themeStore = ThemeStore()
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
        if environment["SCREENSHOT_WORKSPACE_PAGE"] == nil {
            // The root shows Edit with Oppi only on a connection with an API
            // client. Nothing sends a request: the fixture URL is never read.
            connection.setPreviewAPIClient(APIClient(baseURL: URL(string: "https://preview.invalid") ?? URL(fileURLWithPath: "/"), token: "sk_preview"))
        }
        connection.workspaceStore.setActiveServer(serverId)
        connection.workspaceStore.workspacesByServer[serverId] = [workspace]
        self.connection = connection

        root = .preview(coordinator: ConnectionCoordinator(serverStore: ServerStore()), themeStore: themeStore)

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
    }

    var body: some View {
        content
            .ignoresSafeArea()
            .appRootEnvironment(root)
            .publishesAppRootToWindow(root)
            .preferredColorScheme(themeStore.preferredColorScheme)
            .accessibilityIdentifier("screenshot.ready")
    }

    @ViewBuilder
    private var content: some View {
        switch ProcessInfo.processInfo.environment["SCREENSHOT_WORKSPACE_PAGE"] {
        case "details": leaf { WorkspaceDetailsPage(model: model) }
        case "instructions": leaf { WorkspaceInstructionsPage(model: model) }
        case "skills": leaf { WorkspaceSkillsPage(model: model) }
        case "extensions": leaf { WorkspaceExtensionsPage(model: model) }
        case "mcp":
            leaf {
                if workspace.runtime == .sandbox {
                    WorkspaceSandboxMcpPage(model: model)
                } else {
                    McpServersView(scopeId: workspace.id)
                }
            }
        case "network": leaf { WorkspaceNetworkAccessPage(model: model) }
        default:
            RouterPreviewControllerStack(root: root) {
                WorkspaceSettingsViewController(workspace: workspace, model: model, connection: connection, root: root)
            }
        }
    }

    /// A pushed SwiftUI page as the root of a router stack.
    private func leaf<Page: View>(@ViewBuilder _ page: @escaping () -> Page) -> some View {
        RouterPreviewStack(root: root) { page().withServerScopedEnvironment(connection) }
    }
}
#endif
