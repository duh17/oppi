#if DEBUG
import UIKit

/// Workspace Settings' Details page with one fixture workspace and no network.
/// `SCREENSHOT_COLOR_SCHEME=dark|light` selects that theme.
final class WorkspaceSettingsPreviewController: PreviewRootController {
    // The fixtures the page reads, held as long as the preview the way the
    // SwiftUI view's constants were. The app root itself is the base's.
    private let connection: ServerConnection
    private let workspace: Workspace
    private let model: WorkspaceSettingsModel

    private static let serverId = "preview-server"

    init() {
        let environment = ProcessInfo.processInfo.environment
        if environment["SCREENSHOT_COLOR_SCHEME"] == "light" {
            ScreenshotVolatileDefaults.applyTheme(.light)
        } else {
            ScreenshotVolatileDefaults.applyDarkTheme(environment["SCREENSHOT_COLOR_SCHEME"] == "dark")
        }
        let themeStore = ThemeStore()
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
        connection.workspaceStore.setActiveServer(serverId)
        connection.workspaceStore.workspacesByServer[serverId] = [workspace]
        self.connection = connection

        let root = AppRootEnvironment.preview(
            coordinator: ConnectionCoordinator(serverStore: ServerStore()),
            themeStore: themeStore
        )

        let model = WorkspaceSettingsModel.screenshotFixture(
            workspace: workspace,
            skills: [],
            extensions: [],
            projectTrust: .trusted,
            sandboxMcpServers: []
        )
        model.attach(connection: connection, workspace: workspace)
        self.model = model

        super.init(
            root: root,
            themeStore: themeStore,
            content: PreviewHost.screenStack(root: root) {
                WorkspaceDetailsViewController(settings: model, connection: connection, root: root)
            }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
#endif
