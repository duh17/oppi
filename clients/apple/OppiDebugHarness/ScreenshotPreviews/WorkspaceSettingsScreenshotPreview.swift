#if DEBUG
import SwiftUI

/// Real Workspace Settings surfaces with one fixture workspace and no network.
/// `SCREENSHOT_WORKSPACE_PAGE` picks the root (default, the UIKit
/// `WorkspaceSettingsViewController`) or a page: `details`, `skills`,
/// `extensions`. `SCREENSHOT_COLOR_SCHEME=dark|light` selects that theme.
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

    init() {
        let environment = ProcessInfo.processInfo.environment
        if environment["SCREENSHOT_COLOR_SCHEME"] == "light" {
            ScreenshotVolatileDefaults.applyTheme(.light)
        } else {
            ScreenshotVolatileDefaults.applyDarkTheme(environment["SCREENSHOT_COLOR_SCHEME"] == "dark")
        }
        themeStore = ThemeStore()
        let serverId = Self.serverId

        let workspace = Workspace(
            id: "preview-ws",
            name: "oppi-dev",
            description: "iOS app development workspace",
            icon: .symbol("hammer"),
            systemPrompt: "Prefer small, reversible changes.\nRun the focused tests before reporting done.\nKeep commit subjects under 72 characters.",
            hostMount: "~/workspace/oppi",
            gitStatusEnabled: true,
            createdAt: Date(),
            updatedAt: Date()
        )
        self.workspace = workspace

        let connection = ServerConnection()
        connection.setPreviewServerId(serverId)
        if environment["SCREENSHOT_WORKSPACE_PAGE"] == nil {
            // The root shows the Oppi bar only on a connection with an API
            // client. Its requests go to an unresolvable host and fail harmlessly.
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
            projectTrust: .trusted,
            sandboxMcpServers: []
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
        case "details":
            RouterPreviewControllerStack(root: root) {
                WorkspaceDetailsViewController(settings: model, connection: connection, root: root)
            }
        case "skills":
            RouterPreviewControllerStack(root: root) {
                WorkspaceSkillsViewController(model: model, connection: connection, root: root)
            }
        case "extensions":
            RouterPreviewControllerStack(root: root) {
                WorkspaceExtensionsViewController(model: model, root: root)
            }
        default:
            RouterPreviewControllerStack(root: root) {
                WorkspaceSettingsViewController(workspace: workspace, model: model, connection: connection, root: root)
            }
        }
    }
}
#endif
