#if DEBUG
import SwiftUI

// MARK: - Session Timeline Preview

struct SessionTimelinePreview: View {
    @State private var toolArgsStore = ToolArgsStore()
    @State private var gitStatusStore = GitStatusStore()
    @State private var lastTreeNavigationCapture = "none"

    private struct PreviewNavigationCaptureError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    private static let previewItems: [ChatItem] = {
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        return [
            .userMessage(
                id: "entry-user-1",
                text: "Plan rollout for timeline branch/fork UX on mobile.",
                images: [],
                timestamp: base
            ),
            .assistantMessage(
                id: "entry-assistant-1",
                text: "Got it. I can draft a migration plan and test checklist.",
                timestamp: base.addingTimeInterval(2)
            ),
            .toolCall(
                id: "entry-tool-1",
                tool: "edit",
                argsSummary: "path: clients/apple/Oppi/Features/Chat/Support/SessionOutlineView.swift",
                outputPreview: "",
                outputByteCount: 220,
                isError: false,
                isDone: true
            ),
            .systemEvent(
                id: "entry-system-1",
                message: "Context compacted (42100 tokens): preserved latest branch summary and task checklist"
            ),
            .userMessage(
                id: "entry-user-2",
                text: "Now move fork + branch controls into Session Timeline, not row long-press.",
                images: [],
                timestamp: base.addingTimeInterval(8)
            ),
            .assistantMessage(
                id: "entry-assistant-2",
                text: "Done. Branch and Fork are in one dock in Session Timeline view.",
                timestamp: base.addingTimeInterval(11)
            ),
        ]
    }()

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
            items: Self.previewItems,
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
            initialTreeSnapshot: Self.previewTreeSnapshot
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
        .environment(toolArgsStore)
        .environment(gitStatusStore)
        .onAppear {
            toolArgsStore.set(
                [
                    "path": .string("clients/apple/Oppi/Features/Chat/Support/SessionOutlineView.swift"),
                ],
                for: "entry-tool-1"
            )
        }
        .accessibilityIdentifier("screenshot.ready")
    }
}
#endif
