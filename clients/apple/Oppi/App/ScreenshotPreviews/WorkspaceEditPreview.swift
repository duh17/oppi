#if DEBUG
import SwiftUI

// MARK: - Workspace Edit Preview

struct WorkspaceEditPreview: View {
    @State private var connection = Self.makePreviewConnection()

    private static let mockSkills: [SkillInfo] = [
        SkillInfo(name: "agents-md", description: "Manage global and project AGENTS.md files for coding agents.", path: "/skills/agents-md"),
        SkillInfo(name: "audio-transcribe", description: "Transcribe local audio files or YouTube videos with Yuwp's canonical `yuwp-asr` CLI and helpers.", path: "/skills/audio-transcribe"),
        SkillInfo(name: "autoresearch", description: "Set up and run an autonomous experiment loop for any optimization target.", path: "/skills/autoresearch"),
        SkillInfo(name: "clanker-farm", description: "Design and build CLI tools and skills optimized for both human and AI agent consumption.", path: "/skills/clanker-farm"),
        SkillInfo(name: "deep-research", description: "Conduct safe, evidence-first web research with iterative search and citation verification.", path: "/skills/deep-research"),
        SkillInfo(name: "devdoc", description: "Look up third-party API docs, Apple docs, and RFC references.", path: "/skills/devdoc"),
    ]

    private static let mockExtensions: [ExtensionInfo] = [
        ExtensionInfo(name: "workflow", path: "~/.pi/agent/extensions/workflow", kind: "file", source: "pi"),
        ExtensionInfo(name: "index", path: "~/.pi/agent/git/index", kind: "file", source: "pi"),
        ExtensionInfo(name: "pi-sessions", path: "~/.pi/agent/extensions/pi-sessions", kind: "file", source: "pi"),
        ExtensionInfo(name: "simplify", path: "~/.pi/agent/extensions/simplify", kind: "file", source: "pi"),
        ExtensionInfo(name: "theme-builder", path: "~/.pi/agent/extensions/theme-builder", kind: "file", source: "pi"),
        ExtensionInfo(name: "todos", path: "~/.pi/agent/extensions/todos", kind: "file", source: "pi"),
    ]

    private static let mockWorkspace = Workspace(
        id: "preview-ws",
        name: "oppi-dev",
        description: "iOS app development workspace",
        icon: .symbol("hammer"),
        systemPrompt: nil,
        hostMount: "~/workspace/oppi",
        gitStatusEnabled: true,
        createdAt: Date(),
        updatedAt: Date()
    )

    var body: some View {
        NavigationStack {
            WorkspaceEditView(
                workspace: Self.mockWorkspace,
                previewAvailableExtensions: Self.mockExtensions
            )
        }
        .environment(connection)
        .environment(connection.workspaceStore)
        .environment(\.apiClient, connection.apiClient)
        .accessibilityIdentifier("screenshot.ready")
    }

    private static func makePreviewConnection() -> ServerConnection {
        let connection = ServerConnection()
        let serverId = "preview-server"
        connection.workspaceStore.skillsByServer[serverId] = Self.mockSkills
        connection.workspaceStore.workspacesByServer[serverId] = [Self.mockWorkspace]
        connection.setPreviewServerId(serverId)
        return connection
    }
}
#endif
