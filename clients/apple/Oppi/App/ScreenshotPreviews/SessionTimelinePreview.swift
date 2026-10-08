#if DEBUG
import SwiftUI

// MARK: - Session Timeline Preview

struct SessionTimelinePreview: View {
    @State private var inspectionFixture = ToolInspectionPreviewFixture.makeReducer()
    @State private var gitStatusStore = GitStatusStore()
    @State private var lastTreeNavigationCapture = "none"

    private struct PreviewNavigationCaptureError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    private static let previewTreeSnapshot = SessionTreeSnapshot(
        leafId: "entry-6",
        nodes: [
            SessionTreeNodeSnapshot(
                id: "entry-1",
                parentId: nil,
                type: "message",
                timestamp: "2026-04-19T17:10:00.000Z",
                depth: 0,
                isLeafPath: true,
                role: "user",
                textPreview: "Plan rollout for timeline branch/fork UX on mobile.",
                label: nil
            ),
            SessionTreeNodeSnapshot(
                id: "entry-2",
                parentId: "entry-1",
                type: "message",
                timestamp: "2026-04-19T17:10:06.000Z",
                depth: 1,
                isLeafPath: true,
                role: "assistant",
                textPreview: "Drafted a migration plan and test checklist.",
                label: nil
            ),
            SessionTreeNodeSnapshot(
                id: "entry-3",
                parentId: "entry-2",
                type: "message",
                timestamp: "2026-04-19T17:10:12.000Z",
                depth: 2,
                isLeafPath: false,
                role: "user",
                textPreview: "Ship list mode first.",
                label: nil
            ),
            SessionTreeNodeSnapshot(
                id: "entry-4",
                parentId: "entry-3",
                type: "message",
                timestamp: "2026-04-19T17:10:18.000Z",
                depth: 3,
                isLeafPath: false,
                role: "assistant",
                textPreview: "List mode shipped.",
                label: nil
            ),
            SessionTreeNodeSnapshot(
                id: "entry-5",
                parentId: "entry-2",
                type: "message",
                timestamp: "2026-04-19T17:11:00.000Z",
                depth: 2,
                isLeafPath: true,
                role: "user",
                textPreview: "Actually add a tree tab in Session Timeline.",
                label: nil
            ),
            SessionTreeNodeSnapshot(
                id: "entry-6",
                parentId: "entry-5",
                type: "message",
                timestamp: "2026-04-19T17:11:08.000Z",
                depth: 3,
                isLeafPath: true,
                role: "assistant",
                textPreview: "Tree mode is live and searchable.",
                label: nil
            ),
        ]
    )

    var body: some View {
        SessionOutlineView(
            items: inspectionFixture.items,
            sessionId: "preview-session",
            workspaceId: "preview-workspace",
            onSelect: { _ in },
            onFork: { _ in },
            onNavigateTreeNode: { request in
                let mode: String
                if !request.summarize {
                    mode = "none"
                } else if request.customInstructions?.isEmpty == false {
                    mode = "custom"
                } else {
                    mode = "default"
                }

                let instructions = request.customInstructions ?? "-"
                let summary = "mode=\(mode) instructions=\(instructions)"
                await MainActor.run {
                    lastTreeNavigationCapture = summary
                }
                throw PreviewNavigationCaptureError(message: "Captured \(summary)")
            },
            initialTreeSnapshot: Self.previewTreeSnapshot,
            toolDetails: { inspectionFixture.toolDetailsStore.details(for: $0) }
        )
        .overlay(alignment: .bottomLeading) {
            Text("Last tree navigate: \(lastTreeNavigationCapture)")
                .font(.caption2.monospaced())
                .foregroundStyle(.themeComment)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.themeBgDark.opacity(0.9), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(10)
                .accessibilityIdentifier("session-timeline.last-navigation")
        }
        .environment(inspectionFixture.toolArgsStore)
        .environment(gitStatusStore)
        .accessibilityIdentifier("screenshot.ready")
    }
}

// MARK: - Wide Content Timeline Preview

/// The production timeline collection under ChatView's scaffold (expanded under
/// the top bar only) with full-width rows: a Mermaid diagram, long code lines,
/// and tool rows. Proves rows stop at the trailing safe-area edge when a
/// vertical rail occupies it (`SCREENSHOT_SCREEN=session-timeline-wide`,
/// `SCREENSHOT_ORIENTATION=landscape` on iPhone Duo).
struct SessionTimelineWideContentPreview: View {
    @State private var connection = ServerConnection()
    @State private var sessionManager = ChatSessionManager(sessionId: "wide-preview")
    @State private var scrollController = ChatScrollController()
    @State private var audioPlayer = AudioPlayerService()
    @State private var audioLifecycleCoordinator = AudioLifecycleCoordinator()
    @State private var seeded = false

    /// ChatView expands the timeline under the top bar only. `SCREENSHOT_TIMELINE_FULL_BLEED=1`
    /// also expands it under the side rail, to prove the collection insets its rows itself.
    private static var expandedEdges: Edge.Set {
        ProcessInfo.processInfo.environment["SCREENSHOT_TIMELINE_FULL_BLEED"] == "1" ? [.top, .horizontal] : .top
    }

    private static let assistantMarkdown = #"""
    The review pass found three layout problems. The flow, then the offending lines:

    ```mermaid
    flowchart LR
        Dispatch[Dispatch work] --> Review{Review passes?}
        Review -->|yes| Land[Fast-forward main]
        Review -->|no| Fix[Fix findings]
        Fix --> Dispatch
        Land --> Verify[Run the full proof matrix on the final commit]
    ```

    ```swift
    let identifierForTheTrailingEdgeProbe = "this line is deliberately far wider than any phone column so it reaches the trailing edge"
    ```
    """#

    var body: some View {
        NavigationStack {
            ChatTimelineView(
                sessionId: "wide-preview",
                serverId: nil,
                workspaceId: nil,
                isBusy: false,
                extensionWorkingState: nil,
                extensionHiddenThinkingLabel: nil,
                currentModel: nil,
                sessionContent: connection.sessionContent,
                iconAssetCache: nil,
                openDestination: nil,
                loadOlderPage: nil,
                scrollController: scrollController,
                sessionManager: sessionManager,
                audioLifecycleCoordinator: audioLifecycleCoordinator,
                onFork: { _ in },
                onOpenCurrentFile: { _ in },
                onBackSwipe: {},
                reviewCommentSelectionRouter: nil,
                topOverlap: 0,
                bottomOverlap: 0
            )
            .ignoresSafeArea(.container, edges: Self.expandedEdges)
            .navigationTitle("Wide content")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Files", systemImage: "folder") {}
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Outline", systemImage: "list.bullet") {}
                }
            }
        }
        .environment(sessionManager.reducer)
        .environment(sessionManager.reducer.toolOutputStore)
        .environment(sessionManager.reducer.toolArgsStore)
        .environment(audioPlayer)
        .task {
            guard !seeded else { return }
            seeded = true
            ScreenshotPreviewOrientation.applyRequested()
            seed(sessionManager.reducer)
        }
        .accessibilityIdentifier("screenshot.ready")
    }

    private func seed(_ reducer: TimelineReducer) {
        _ = reducer.appendUserMessage("Run the checks and show me the layout")
        reducer.processBatch([
            .agentStart(sessionId: "wide-preview"),
            .messageEnd(sessionId: "wide-preview", content: Self.assistantMarkdown),
            .toolStart(
                sessionId: "wide-preview",
                toolEventId: "wide-bash",
                tool: "bash",
                args: ["command": "swift test --filter ChatTimelineLayoutTests --parallel --enable-code-coverage --verbose"],
                display: .init(title: "Bash")
            ),
            .toolEnd(sessionId: "wide-preview", toolEventId: "wide-bash"),
            .agentEnd(sessionId: "wide-preview"),
        ])
    }
}
#endif
