#if DEBUG
import SwiftUI

// MARK: - Configuration

enum ScreenshotPreviewConfig {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--screenshot-preview")
    }

    static var screen: String {
        ProcessInfo.processInfo.environment["SCREENSHOT_SCREEN"] ?? "workspace-edit"
    }
}

// MARK: - Root Preview View

/// Launches a standalone screen with mock data for screenshot capture in UI tests.
struct ScreenshotPreviewView: View {
    var body: some View {
        switch ScreenshotPreviewConfig.screen {
        case "workspace-edit":
            WorkspaceEditPreview()
        default:
            Text("Unknown screen: \(ScreenshotPreviewConfig.screen)")
        }
    }
}

// MARK: - Workspace Edit Preview

private struct WorkspaceEditPreview: View {
    @State private var connection = ServerConnection()

    private static let mockSkills: [SkillInfo] = [
        SkillInfo(name: "search", description: "Private web search via SearXNG for research and documentation.", path: "/skills/search"),
        SkillInfo(name: "web-fetch", description: "Fetch and extract readable content from web pages.", path: "/skills/web-fetch"),
        SkillInfo(name: "web-browser", description: "Web browser automation via Chrome DevTools Protocol.", path: "/skills/web-browser"),
        SkillInfo(name: "tmux", description: "Spawn and control tmux panes for interactive CLIs.", path: "/skills/tmux"),
        SkillInfo(name: "sentry", description: "Fetch and analyze Sentry issues, events, and logs.", path: "/skills/sentry"),
        SkillInfo(name: "youtube-transcript", description: "Fetch YouTube video transcripts for summarization.", path: "/skills/youtube-transcript"),
        SkillInfo(name: "audio-transcribe", description: "Transcribe and summarize audio files using MLX Qwen-ASR.", path: "/skills/audio-transcribe"),
        SkillInfo(name: "pi-remote-session", description: "Look up and inspect pi-remote sessions and traces.", path: "/skills/pi-remote-session"),
    ]

    private static let mockWorkspace = Workspace(
        id: "preview-ws",
        name: "oppi-dev",
        description: "iOS app development workspace",
        icon: "hammer",
        skills: ["search", "web-fetch", "web-browser", "tmux", "sentry"],
        systemPrompt: nil,
        hostMount: "~/workspace/oppi",
        memoryEnabled: true,
        memoryNamespace: "oppi",
        extensions: nil,
        gitStatusEnabled: true,
        defaultModel: nil,
        createdAt: Date(),
        updatedAt: Date()
    )

    var body: some View {
        NavigationStack {
            WorkspaceEditView(workspace: Self.mockWorkspace)
        }
        .environment(connection)
        .onAppear {
            let serverId = "preview-server"
            connection.workspaceStore.skillsByServer[serverId] = Self.mockSkills
            connection.workspaceStore.workspacesByServer[serverId] = [Self.mockWorkspace]
            // Set the active server ID so the view can find its data.
            connection.setPreviewServerId(serverId)
        }
        .accessibilityIdentifier("screenshot.ready")
    }
}
#endif
