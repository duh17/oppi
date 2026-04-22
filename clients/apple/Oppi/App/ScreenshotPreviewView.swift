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
        case "session-timeline":
            SessionTimelinePreview()
        case "share-redaction-report":
            ShareRedactionReportPreview()
        case "share-redaction-settings":
            ShareRedactionSettingsPreview()
        case "live-activity-working":
            LiveActivityPreviewScreen(
                title: "Live Activity — Working",
                state: .workingPreview,
                isStale: false
            )
        case "live-activity-approval":
            LiveActivityPreviewScreen(
                title: "Live Activity — Approval",
                state: .approvalPreview,
                isStale: false
            )
        case "live-activity-stale-approval":
            LiveActivityPreviewScreen(
                title: "Live Activity — Stale Approval",
                state: .approvalPreview,
                isStale: true
            )
        case "live-activity-done":
            LiveActivityPreviewScreen(
                title: "Live Activity — Done",
                state: .donePreview,
                isStale: false
            )
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
        .environment(connection.workspaceStore)
        .environment(\.apiClient, connection.apiClient)
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

// MARK: - Session Timeline Preview

private struct SessionTimelinePreview: View {
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

    private static let previewChangedFiles: [String] = [
        "clients/apple/Oppi/Features/Chat/Support/SessionOutlineView.swift",
        "clients/apple/Oppi/Features/Chat/ChatView.swift",
        "server/src/session-commands.ts",
    ]

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
            changedFiles: Self.previewChangedFiles,
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

// MARK: - Share Redaction Report Preview

private struct ShareRedactionReportPreview: View {
    private let reportLines = [
        "Share URL: https://pi.dev/session/#abc123",
        "Gist: https://gist.github.com/demo-user/abc123",
        "Redaction: 7 replacements",
        "• openai_api_key×1 → [REDACTED_OPENAI_API_KEY] (sk-A…ZZZZ)",
        "• unix_user_path×3 → <path>/[REDACTED_USER] (/Users/…/workspace/oppi)",
        "• email_address×2 → [REDACTED_EMAIL] (a***@example.com)",
        "• github_pat×1 → [REDACTED_GITHUB_TOKEN] (ghp_…9f7a)",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Share Session")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.themeFg)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Redaction report")
                            .font(.headline)
                            .foregroundStyle(.themeFg)
                            .accessibilityIdentifier("share-redaction-report.title")

                        ForEach(Array(reportLines.enumerated()), id: \.offset) { _, line in
                            reportLine(line)
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.themeBgDark)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.themeComment.opacity(0.35), lineWidth: 1)
                    )

                    Text("This preview mirrors the post-share report shown after automatic redaction.")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
                .padding(20)
            }
            .background(Color.themeBg.ignoresSafeArea())
            .navigationTitle("Session Timeline")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("screenshot.ready")
    }

    private func reportLine(_ line: String) -> some View {
        Text(line)
            .font(.footnote.monospaced())
            .foregroundStyle(.themeFg)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ShareRedactionSettingsPreview: View {
    @State private var policy = ShareSessionRedactionPolicy(
        secrets: true,
        emails: true,
        phones: true,
        userPaths: true,
        ipAddresses: true,
        jwtAndBearer: true,
        namesHeuristic: true
    )

    private let preflight = ShareSessionPrepareResult(
        canPublish: true,
        blocked: false,
        findings: [
            ShareSessionScanFinding(kind: "openai_api_key", count: 1),
        ],
        artifactBytes: 98_410,
        redaction: ShareSessionRedactionReport(
            policy: ShareSessionRedactionPolicy(
                secrets: true,
                emails: true,
                phones: true,
                userPaths: true,
                ipAddresses: true,
                jwtAndBearer: true,
                namesHeuristic: true
            ),
            totalReplacements: 11,
            findings: [
                ShareSessionRedactionFinding(
                    kind: "person_name_heuristic",
                    count: 4,
                    replacement: "[REDACTED_PERSON]",
                    samples: ["J*** A***"]
                ),
                ShareSessionRedactionFinding(
                    kind: "email_address",
                    count: 3,
                    replacement: "[REDACTED_EMAIL]",
                    samples: ["a***@example.com"]
                ),
                ShareSessionRedactionFinding(
                    kind: "phone_number",
                    count: 2,
                    replacement: "[REDACTED_PHONE]",
                    samples: ["+1…0199"]
                ),
                ShareSessionRedactionFinding(
                    kind: "unix_user_path",
                    count: 2,
                    replacement: "<path>/[REDACTED_USER]",
                    samples: ["/Users/…/workspace/oppi"]
                ),
            ]
        )
    )

    var body: some View {
        ShareSessionRedactionSheet(
            policy: $policy,
            preflight: preflight,
            isAnalyzing: false,
            errorMessage: nil,
            isSharing: false,
            onRefresh: {},
            onShare: {},
            onCancel: {}
        )
        .accessibilityIdentifier("screenshot.ready")
    }
}

// MARK: - Live Activity Preview

private struct LiveActivityPreviewScreen: View {
    let title: String
    let state: PiSessionAttributes.ContentState
    let isStale: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.08, green: 0.09, blue: 0.14)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Compact preview")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            previewCompactLeading
                            previewCompactTrailing
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Lock Screen preview")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        PreviewLockScreenCard(state: state, isStale: isStale)
                    }
                }
                .padding(24)
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("screenshot.ready")
    }

    private var previewCompactLeading: some View {
        HStack(spacing: 6) {
            Image(systemName: LiveActivityPresentation.primarySymbol(for: state))
                .font(.caption2)
            Text(state.primarySessionName)
                .font(.caption.bold())
                .lineLimit(1)
        }
        .foregroundStyle(LiveActivityPresentation.phaseColor(state.primaryPhase))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.92)))
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(0.08))
        )
    }

    @ViewBuilder
    private var previewCompactTrailing: some View {
        Group {
            if state.pendingApprovalCount > 0 {
                Text("+\(state.pendingApprovalCount)")
                    .foregroundStyle(.orange)
            } else {
                Text(LiveActivityPresentation.phaseShortLabel(state.primaryPhase))
                    .foregroundStyle(LiveActivityPresentation.phaseColor(state.primaryPhase))
            }
        }
        .font(.caption2.bold())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.92)))
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(0.08))
        )
    }
}

private struct PreviewLockScreenCard: View {
    let state: PiSessionAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: LiveActivityPresentation.primarySymbol(for: state))
                            .font(.caption)
                            .foregroundStyle(LiveActivityPresentation.phaseColor(state.primaryPhase))
                        Text(state.primarySessionName)
                            .font(.subheadline.bold())
                            .lineLimit(1)
                    }

                    if isStale {
                        PreviewStatusHint(text: "Update delayed", systemImage: "clock.badge.exclamationmark")
                    } else if let summary = state.topPermissionSummary,
                              !summary.isEmpty {
                        Text(summary)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    } else if let activity = LiveActivityPresentation.centerActivityText(state) {
                        Text(activity)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(LiveActivityPresentation.phaseLabel(state.primaryPhase))
                        .font(.caption2.bold())
                        .foregroundStyle(LiveActivityPresentation.phaseColor(state.primaryPhase))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(LiveActivityPresentation.phaseColor(state.primaryPhase).opacity(0.15))
                        .clipShape(Capsule())

                    if state.pendingApprovalCount > 0 {
                        let approvalCount = state.pendingApprovalCount
                        Text(approvalCount == 1 ? "1 approval" : "\(approvalCount) approvals")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                    } else if let summary = LiveActivityPresentation.changeStatsSummary(state) {
                        HStack(spacing: 6) {
                            if summary.filesChanged > 0 {
                                Text(summary.filesChanged == 1 ? "1 file" : "\(summary.filesChanged) files")
                            } else {
                                Text(summary.mutatingToolCalls == 1 ? "1 tool" : "\(summary.mutatingToolCalls) tools")
                            }

                            if summary.addedLines > 0 {
                                Text("+\(summary.addedLines)")
                                    .foregroundStyle(.green)
                            }
                            if summary.removedLines > 0 {
                                Text("-\(summary.removedLines)")
                                    .foregroundStyle(.red)
                            }
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    } else {
                        Text(LiveActivityPresentation.sessionSummary(state))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if !isStale,
                       state.primaryPhase == .working,
                       let start = state.sessionStartDate {
                        Text(timerInterval: start...Date.distantFuture, countsDown: false)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if state.topPermissionId != nil {
                if isStale {
                    PreviewStatusHint(text: "Open Oppi to review", systemImage: "iphone")
                } else {
                    HStack(spacing: 8) {
                        previewActionButton(title: "Deny", systemImage: "xmark", tint: .red, prominent: false)
                        previewActionButton(title: "Approve", systemImage: "checkmark", tint: .green, prominent: true)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06))
        )
    }

    private func previewActionButton(title: String, systemImage: String, tint: Color, prominent: Bool) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.bold())
            .foregroundStyle(prominent ? Color.white : tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(prominent ? tint : tint.opacity(0.15))
            )
    }
}

private struct PreviewStatusHint: View {
    let text: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .lineLimit(1)
    }
}

private extension PiSessionAttributes.ContentState {
    static let workingPreview = Self(
        primaryPhase: .working,
        primarySessionId: "session-working",
        primarySessionName: "Refactor Timeline",
        primaryTool: "Edit",
        primaryLastActivity: "Running Edit",
        totalActiveSessions: 2,
        sessionsAwaitingReply: 0,
        sessionsWorking: 2,
        primaryMutatingToolCalls: 3,
        primaryFilesChanged: 2,
        primaryAddedLines: 48,
        primaryRemovedLines: 12,
        topPermissionId: nil,
        topPermissionTool: nil,
        topPermissionSummary: nil,
        pendingApprovalCount: 0,
        sessionStartDate: Date().addingTimeInterval(-97)
    )

    static let approvalPreview = Self(
        primaryPhase: .needsApproval,
        primarySessionId: "session-approval",
        primarySessionName: "Deploy Server",
        primaryTool: "Bash",
        primaryLastActivity: "Approval required",
        totalActiveSessions: 1,
        sessionsAwaitingReply: 0,
        sessionsWorking: 0,
        primaryMutatingToolCalls: nil,
        primaryFilesChanged: nil,
        primaryAddedLines: nil,
        primaryRemovedLines: nil,
        topPermissionId: "perm-123",
        topPermissionTool: "bash",
        topPermissionSummary: "bash rm -rf /tmp/oppi-build-cache",
        pendingApprovalCount: 1,
        sessionStartDate: nil
    )

    static let donePreview = Self(
        primaryPhase: .ended,
        primarySessionId: "session-done",
        primarySessionName: "Review Release Notes",
        primaryTool: nil,
        primaryLastActivity: "Session ended",
        totalActiveSessions: 0,
        sessionsAwaitingReply: 0,
        sessionsWorking: 0,
        primaryMutatingToolCalls: nil,
        primaryFilesChanged: nil,
        primaryAddedLines: nil,
        primaryRemovedLines: nil,
        topPermissionId: nil,
        topPermissionTool: nil,
        topPermissionSummary: nil,
        pendingApprovalCount: 0,
        sessionStartDate: nil
    )
}

#endif
