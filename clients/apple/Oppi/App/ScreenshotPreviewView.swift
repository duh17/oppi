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
        case "extension-widget":
            ExtensionSurfacePreview()
        case "extension-dock-stress":
            ExtensionDockStressPreview()
        case "extension-dock-review-combined":
            ExtensionDockReviewCombinedPreview()
        case "extension-dock-scoped-agents":
            ExtensionDockScopedAgentsPreview()
        case "extension-dock-goal-detail":
            ExtensionDockGoalDetailStandalonePreview()
        case "streaming-flicker":
            StreamingFlickerPreviewView()
        case "ask-card":
            AskCardPreview()
        case "ask-card-multiselect-long":
            AskCardMultiSelectLongOptionsPreview()
        case "ask-card-expanded-sheet":
            AskCardExpandedSheetPreview()
        case "context-bar-overlap":
            ContextBarOverlapPreview()
        case "feature-tips":
            FeatureEducationTipsPreview()
        case "feature-tip-p0":
            FeatureEducationP0TipPreview()
        case "voice-message-expanded":
            VoiceMessageExpandedPreview()
        case "global-audio-banner":
            GlobalAudioBannerPreview()
        case "share-redaction-report":
            ShareRedactionReportPreview()
        case "share-redaction-settings":
            ShareRedactionSettingsPreview()
        case "split-file-navigation-regression":
            SplitFileNavigationRegressionPreview()
        case "live-activity-working":
            LiveActivityPreviewScreen(
                title: "Live Activity — Working",
                state: .workingPreview,
                isStale: false
            )
        case "live-activity-awaiting":
            LiveActivityPreviewScreen(
                title: "Live Activity — Awaiting Reply",
                state: .awaitingReplyPreview,
                isStale: false
            )
        case "live-activity-stale-awaiting":
            LiveActivityPreviewScreen(
                title: "Live Activity — Stale Awaiting Reply",
                state: .awaitingReplyPreview,
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

// MARK: - Split File Navigation Regression Preview

private struct SplitFileNavigationRegressionPreview: View {
    @State private var navigation = AppNavigation()
    @State private var lastPathCount = 0

    private static let workspace = Workspace(
        id: "preview-workspace",
        name: "oppi-dev",
        description: "Preview workspace",
        icon: "folder",
        systemPrompt: nil,
        hostMount: "~/workspace/oppi",
        gitStatusEnabled: true,
        createdAt: Date(),
        updatedAt: Date()
    )

    private static let workspaceTarget = WorkspaceNavTarget(serverId: "preview-server", workspace: workspace)
    private static let sessionTarget = WorkspaceSessionNavTarget(serverId: "preview-server", sessionId: "session-1")
    private static let linkedFileTarget = WorkspaceLinkedFileNavTarget.workspaceFile(
        serverId: "preview-server",
        workspaceId: "preview-workspace",
        path: "notes/second.md",
        fileName: "second.md"
    )

    var body: some View {
        @Bindable var nav = navigation

        NavigationStack(path: $nav.workspacePath) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Split file navigation regression")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.themeFg)

                Text("Open a session in split mode, push a linked file, then convert to compact stack.")
                    .font(.caption)
                    .foregroundStyle(.themeComment)

                Button("Open split session link then compact") {
                    openSplitLinkThenCompact()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("splitFileNavigation.open")

                Text("Path count: \(lastPathCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.themeComment)
                    .accessibilityIdentifier("splitFileNavigation.pathCount")

                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.themeBg.ignoresSafeArea())
            .navigationTitle("Regression")
            .navigationDestination(for: WorkspaceSessionNavTarget.self) { target in
                SplitFileNavigationSessionProbe(target: target)
            }
            .navigationDestination(for: WorkspaceLinkedFileNavTarget.self) { target in
                SplitFileNavigationLinkedFileProbe(target: target)
            }
        }
        .environment(navigation)
        .accessibilityIdentifier("screenshot.ready")
    }

    private func openSplitLinkThenCompact() {
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspaceSession(Self.sessionTarget, workspace: Self.workspaceTarget)
        navigation.openWorkspaceLinkedFile(Self.linkedFileTarget, workspace: Self.workspaceTarget)
        navigation.setWorkspaceNavigationPresentation(.stack)
        lastPathCount = navigation.workspacePath.count
    }
}

private struct SplitFileNavigationSessionProbe: View {
    let target: WorkspaceSessionNavTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session: \(target.sessionId)")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.themeFg)
                .accessibilityIdentifier("splitFileNavigation.session")

            Text("Back target preserved after compact conversion.")
                .font(.caption)
                .foregroundStyle(.themeComment)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.themeBg.ignoresSafeArea())
        .navigationTitle("Session")
    }
}

private struct SplitFileNavigationLinkedFileProbe: View {
    @Environment(\.dismiss) private var dismiss
    let target: WorkspaceLinkedFileNavTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(linkedFileLabel)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.themeFg)
                .accessibilityIdentifier("splitFileNavigation.linkedFile")

            Text("This destination was reconstructed from split detail path metadata.")
                .font(.caption)
                .foregroundStyle(.themeComment)

            Button("Back to session") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("splitFileNavigation.backToSession")

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.themeBg.ignoresSafeArea())
        .navigationTitle(fileName)
    }

    private var linkedFileLabel: String {
        switch target.kind {
        case .workspaceFile(let path, _):
            return "Linked file: \(path)"
        }
    }

    private var fileName: String {
        switch target.kind {
        case .workspaceFile(_, let fileName):
            return fileName
        }
    }
}

// MARK: - Extension Surface Preview

private struct ExtensionSurfacePreview: View {
    private static let autoresearchLines = [
        "━━ 🔬 autoresearch: Streaming markdown rendering latency experiment",
        "Runs: 21   9 kept   (conf: 17.1×)   12 discarded",
        "Baseline: ★ streaming_p95_us: 10,376.10µs #1",
        "Progress: ★ streaming_p95_us: 3,486.90µs #19   streaming_max_us: 8,256.20µs  −51.3%   streaming_avg_us: 2,415.90µs  −63.6%",
        "zero_change_max_us: 34.80µs  +5.8%   long_streaming_p95_us: 3,026.20µs   tail_segment_reparse_us: 712.40µs",
        "Checks: OppiTests/StreamingInlineReparseTests  ✓   OppiTests/StreamFinishFormattingTests  ✓   OppiTests/AssistantMarkdownLayoutTests  ✓",
        "Next: Add device validation loop after install/use before claiming CPU improvement.",
        "… (14 more lines)",
    ]

    private static let surface = ExtensionSurfaceState(
        widgets: [
            "autoresearch": ExtensionWidgetState(
                key: "autoresearch",
                lines: autoresearchLines,
                placement: "aboveEditor"
            ),
        ],
        nativeSurfaces: [
            "tasks": ExtensionNativeSurfaceState(
                key: "tasks",
                surface: ExtensionUINativeSurface(
                    version: 1,
                    id: "widget:tasks",
                    source: "widget",
                    presentation: ExtensionUINativePresentation(
                        style: "surfacePanel",
                        title: "1 of 5 tasks completed",
                        subtitle: nil
                    ),
                    blocks: [
                        .progress(
                            base: ExtensionUIBlockBase(id: "goal-progress", accessibility: nil),
                            label: nil,
                            value: 0.2,
                            indeterminate: nil
                        ),
                        .activityList(
                            base: ExtensionUIBlockBase(id: "goal-tasks", accessibility: nil),
                            rows: [
                                ExtensionUIActivityRow(
                                    id: "task-1",
                                    title: "Check Apple AVKit/AVFoundation playback requirements",
                                    subtitle: nil,
                                    detail: nil,
                                    state: "success",
                                    progress: nil,
                                    link: nil,
                                    children: nil
                                ),
                                ExtensionUIActivityRow(
                                    id: "task-2",
                                    title: "Read HTTP Range semantics from RFC",
                                    subtitle: nil,
                                    detail: nil,
                                    state: "running",
                                    progress: nil,
                                    link: nil,
                                    children: nil
                                ),
                                ExtensionUIActivityRow(
                                    id: "task-3",
                                    title: "Check Node.js stream/fs implementation details",
                                    subtitle: nil,
                                    detail: nil,
                                    state: "running",
                                    progress: nil,
                                    link: nil,
                                    children: nil
                                ),
                                ExtensionUIActivityRow(
                                    id: "task-4",
                                    title: "Compare current Oppi route against requirements",
                                    subtitle: nil,
                                    detail: nil,
                                    state: "inactive",
                                    progress: nil,
                                    link: nil,
                                    children: nil
                                ),
                                ExtensionUIActivityRow(
                                    id: "task-5",
                                    title: "Propose robust implementation and tests",
                                    subtitle: nil,
                                    detail: nil,
                                    state: "inactive",
                                    progress: nil,
                                    link: nil,
                                    children: nil
                                ),
                            ]
                        ),
                    ],
                    fallback: ExtensionUINativeFallback(
                        text: nil,
                        lines: ["1 of 5 tasks completed"]
                    )
                ),
                placement: "aboveEditor"
            ),
        ]
    )

    var body: some View {
        ZStack {
            Color.themeBg
                .ignoresSafeArea()

            VStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Extension surface")
                        .font(.headline)
                        .foregroundStyle(.themeFg)
                    Text("Native and terminal-compatible extension widgets use the same trailing disclosure control.")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ExtensionSurfacePanel(surface: Self.surface, placement: .aboveEditor)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
        }
        .accessibilityIdentifier("screenshot.ready")
    }
}

// MARK: - Ask Card Preview

private enum AskCardPreviewFixture {
    static let request: AskRequest = {
        let permissionRequest = ExtensionUIRequest(
            id: "preview-permission-gate",
            sessionId: "preview-session",
            method: "select",
            title: """
            Git push

            Pushing writes to a remote repository.

            ### Command

            ```bash
            git push origin main
            ```

            Allow this tool call?

              Allow once: Run this tool call now
              Deny: Block the tool call
            """,
            options: ["Allow once", "Deny"]
        )

        return permissionRequest.inlineAskRequest ?? AskRequest(
            id: "preview-permission-gate",
            sessionId: "preview-session",
            questions: [
                AskQuestion(
                    id: ExtensionUIRequest.inlineQuestionId,
                    question: "Git push",
                    options: [
                        AskOption(value: "Allow once", label: "Allow once", description: "Run this tool call now"),
                        AskOption(value: "Deny", label: "Deny", description: "Block the tool call"),
                    ],
                    multiSelect: false
                ),
            ],
            allowCustom: false,
            timeout: nil,
            responseEncoding: .extensionSelect
        )
    }()

    static let multiSelectLongOptionsRequest = AskRequest(
        id: "preview-multi-select-long-options",
        sessionId: "preview-session",
        questions: [
            AskQuestion(
                id: "sun_light_nav",
                question: "Sun, light, navigation, comms — select what is ready.",
                options: [
                    AskOption(
                        value: "offline_maps_gpx",
                        label: "Offline maps/GPX loaded on phone/GPS with route, waypoints, and alternate descent cached",
                        description: "CalTopo or Gaia route opens in airplane mode; phone/GPS battery plan tested."
                    ),
                    AskOption(
                        value: "weather_window",
                        label: "Weather window confirmed",
                        description: "Clear forecast."
                    ),
                    AskOption(
                        value: "inreach_radio_power",
                        label: "inReach/radios/battery bank tested with messages, charging cables, and team channel confirmed"
                    ),
                    AskOption(
                        value: "headlamp_backup",
                        label: "Headlamp + spare batteries/backup lamp in top pocket, not buried in the pack"
                    ),
                ],
                multiSelect: true
            ),
            AskQuestion(
                id: "food_water",
                question: "Food and water — select what is ready.",
                options: [
                    AskOption(value: "water_capacity", label: "4–5 L water capacity"),
                    AskOption(value: "electrolytes", label: "Electrolytes / salt plan"),
                ],
                multiSelect: true
            ),
        ],
        allowCustom: true,
        timeout: nil
    )
}

private struct AskCardPreview: View {
    @State private var currentPage = 0
    @State private var answers: [String: AskAnswer] = [:]
    @State private var lastAction = "Waiting for answer"

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    WorkingSpinnerView(tintColor: .themeComment.opacity(0.8), style: .brailleDots)
                        .frame(width: 14, height: 14)
                    Text("working…")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.themeComment.opacity(0.7))
                }
                .padding(.horizontal, 18)

                Spacer()

                VStack(alignment: .leading, spacing: 0) {
                    AskCard(
                        request: AskCardPreviewFixture.request,
                        currentPage: $currentPage,
                        answers: $answers,
                        onSubmit: { submittedAnswers in
                            lastAction = AskResponseEncoder.encode(submittedAnswers)
                        },
                        onIgnoreAll: {
                            lastAction = "Ignored"
                        }
                    )
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 6)

                    HStack(alignment: .center, spacing: 14) {
                        Circle()
                            .fill(Color.themeBgHighlight)
                            .overlay(
                                Image(systemName: "mic")
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(.themeFg)
                            )
                            .frame(width: 58, height: 58)
                            .overlay(Circle().stroke(Color.themeComment.opacity(0.3), lineWidth: 1))

                        Text("Type answer…")
                            .font(.title2)
                            .foregroundStyle(.themeComment)

                        Spacer()

                        Circle()
                            .fill(Color.themeBgHighlight)
                            .overlay(
                                Image(systemName: "xmark")
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(.themeFg)
                            )
                            .frame(width: 58, height: 58)
                            .overlay(Circle().stroke(Color.themeComment.opacity(0.3), lineWidth: 1))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)

                    HStack {
                        Text(lastAction)
                            .font(.caption)
                            .foregroundStyle(.themeComment.opacity(0.75))
                            .lineLimit(1)

                        Spacer()

                        Label("gpt-5.5", systemImage: "sparkle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.themeFg)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.themeBgHighlight, in: Capsule())

                        Text("max")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.themeFg)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.themeBgHighlight, in: Capsule())
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
                }
                .background(Color.themeBg.opacity(0.96), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .stroke(Color.themeComment.opacity(0.18), lineWidth: 1)
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 24)
        }
        .accessibilityIdentifier("screenshot.ready")
    }
}

private struct AskCardMultiSelectLongOptionsPreview: View {
    @State private var currentPage = 0
    @State private var answers: [String: AskAnswer] = [:]
    @State private var lastAction = "Waiting for answer"

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    WorkingSpinnerView(tintColor: .themeComment.opacity(0.8), style: .brailleDots)
                        .frame(width: 14, height: 14)
                    Text("working…")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.themeComment.opacity(0.7))
                }
                .padding(.horizontal, 18)

                Spacer()

                VStack(alignment: .leading, spacing: 0) {
                    AskCard(
                        request: AskCardPreviewFixture.multiSelectLongOptionsRequest,
                        currentPage: $currentPage,
                        answers: $answers,
                        onSubmit: { submittedAnswers in
                            lastAction = AskResponseEncoder.encode(submittedAnswers)
                        },
                        onIgnoreAll: {
                            lastAction = "Ignored"
                        }
                    )
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 6)

                    HStack(alignment: .center, spacing: 14) {
                        Circle()
                            .fill(Color.themeBgHighlight)
                            .overlay(
                                Image(systemName: "mic")
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(.themeFg)
                            )
                            .frame(width: 58, height: 58)
                            .overlay(Circle().stroke(Color.themeComment.opacity(0.3), lineWidth: 1))

                        Text("Select options or type…")
                            .font(.title2)
                            .foregroundStyle(.themeComment)

                        Spacer()

                        Circle()
                            .fill(Color.themeBgHighlight)
                            .overlay(
                                Image(systemName: "xmark")
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(.themeFg)
                            )
                            .frame(width: 58, height: 58)
                            .overlay(Circle().stroke(Color.themeComment.opacity(0.3), lineWidth: 1))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)

                    Text(lastAction)
                        .font(.caption)
                        .foregroundStyle(.themeComment.opacity(0.75))
                        .lineLimit(1)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 14)
                }
                .background(Color.themeBg.opacity(0.96), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .stroke(Color.themeComment.opacity(0.18), lineWidth: 1)
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 24)
        }
        .accessibilityIdentifier("screenshot.ready")
    }
}

private struct AskCardExpandedSheetPreview: View {
    @State private var currentPage = 0
    @State private var answers: [String: AskAnswer] = [:]
    @State private var isExpanded = true
    @State private var expandedSheetDetent: PresentationDetent = .large

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Text("Ask card")
                    .font(.headline)
                    .foregroundStyle(.themeFg)
                Text("Expanded sheet preview")
                    .font(.subheadline)
                    .foregroundStyle(.themeComment)
            }
        }
        .sheet(isPresented: $isExpanded) {
            AskCardExpanded(
                request: AskCardPreviewFixture.request,
                currentPage: $currentPage,
                answers: $answers,
                isExpanded: $isExpanded,
                onSubmit: { _ in },
                onIgnoreAll: {}
            )
            .presentationDetents([.medium, .large], selection: $expandedSheetDetent)
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
        .onAppear { isExpanded = true }
        .accessibilityIdentifier("screenshot.ready")
    }
}

// MARK: - Workspace Edit Preview

private struct WorkspaceEditPreview: View {
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

    private static let mockModels: [ModelInfo] = [
        ModelInfo(id: "anthropic/claude-sonnet-4-5", name: "Claude Sonnet 4.5", provider: "Anthropic", contextWindow: 200_000),
        ModelInfo(id: "openai/gpt-4.1", name: "GPT-4.1", provider: "OpenAI", contextWindow: 128_000),
        ModelInfo(id: "openai/o4-mini", name: "o4-mini", provider: "OpenAI", contextWindow: 200_000),
    ]

    private static let mockWorkspace = Workspace(
        id: "preview-ws",
        name: "oppi-dev",
        description: "iOS app development workspace",
        icon: "hammer",
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
                previewAvailableExtensions: Self.mockExtensions,
                previewAvailableModels: Self.mockModels
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

// MARK: - Context Bar Overlap Preview

private struct ContextBarOverlapPreview: View {
    @State private var connection = ServerConnection()

    private static let workspaceId = "preview-workspace"
    private static let currentSessionId = "session-current"

    private static let gitStatus = GitStatus(
        isGitRepo: true,
        branch: "main",
        headSha: "9f81c2a",
        ahead: 0,
        behind: 0,
        dirtyCount: 3,
        untrackedCount: 0,
        stagedCount: 0,
        files: [
            GitFileStatus(status: " M", path: "clients/apple/Oppi/Features/Chat/ChatView.swift", addedLines: 18, removedLines: 4),
            GitFileStatus(status: " M", path: "clients/apple/Oppi/Features/Chat/Support/WorkspaceContextBar.swift", addedLines: 42, removedLines: 9),
            GitFileStatus(status: " M", path: "server/src/session-events.ts", addedLines: 11, removedLines: 2),
        ],
        totalFiles: 3,
        addedLines: 71,
        removedLines: 15,
        stashCount: 0,
        lastCommitMessage: "Polish session context bar",
        lastCommitDate: nil,
        recentCommits: []
    )

    var body: some View {
        ZStack(alignment: .top) {
            Color.themeBg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cross-session overlap")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.themeFg)
                    Text("The current session still owns the list. The amber badge only marks files another session also touched.")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                WorkspaceContextBar(
                    gitStatus: Self.gitStatus,
                    isLoading: false,
                    workspaceId: Self.workspaceId,
                    sessionId: Self.currentSessionId,
                    initialExpanded: true
                )

                Spacer()
            }
        }
        .environment(connection.sessionStore)
        .environment(connection.askRequestStore)
        .environment(\.apiClient, connection.apiClient)
        .onAppear(perform: configureSessions)
        .accessibilityIdentifier("screenshot.ready")
    }

    private func configureSessions() {
        connection.sessionStore.switchServer(to: "preview-server")
        connection.sessionStore.activeSessionId = Self.currentSessionId
        connection.sessionStore.sessions = [Self.currentSession(), Self.otherSession()]
    }

    private static func currentSession() -> Session {
        var session = makeSession(id: currentSessionId, name: "Current session")
        session.changeStats = SessionChangeStats(
            mutatingToolCalls: 2,
            filesChanged: 2,
            changedFiles: [
                "/Users/example/workspace/oppi/clients/apple/Oppi/Features/Chat/ChatView.swift",
                "/Users/example/workspace/oppi/clients/apple/Oppi/Features/Chat/Support/WorkspaceContextBar.swift",
            ],
            changedFilesOverflow: nil,
            addedLines: 60,
            removedLines: 13
        )
        return session
    }

    private static func otherSession() -> Session {
        var session = makeSession(id: "session-other", name: "Parallel review")
        session.changeStats = SessionChangeStats(
            mutatingToolCalls: 2,
            filesChanged: 2,
            changedFiles: [
                "/Users/example/workspace/oppi/clients/apple/Oppi/Features/Chat/Support/WorkspaceContextBar.swift",
                "/Users/example/workspace/oppi/server/src/session-events.ts",
            ],
            changedFilesOverflow: nil,
            addedLines: 53,
            removedLines: 11
        )
        return session
    }

    private static func makeSession(id: String, name: String) -> Session {
        var session = Session(
            id: id,
            status: .ready,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastActivity: Date(timeIntervalSince1970: 1_700_000_100),
            messageCount: 4,
            tokens: TokenUsage(input: 1_000, output: 500),
            cost: 0.02
        )
        session.workspaceId = workspaceId
        session.name = name
        return session
    }
}

// MARK: - Feature Education Tips Preview

private struct FeatureEducationTipPreviewItem: Identifiable {
    let id: String
    let priority: String
    let title: String
    let message: String
    let trigger: String
    let completion: String
    let stories: String
}

private struct FeatureEducationTipsPreview: View {
    private static let priorities = ["P0", "P1", "P2"]
    private static let tips: [FeatureEducationTipPreviewItem] = [
        FeatureEducationTipPreviewItem(
            id: "open-tool-details",
            priority: "P0",
            title: "Open tool details",
            message: "Tap a tool row to inspect the command, output, diff, or file content.",
            trigger: "First completed non-ask tool row in chat",
            completion: "First tool row expanded",
            stories: "IOS-034, IOS-035, IOS-036"
        ),
        FeatureEducationTipPreviewItem(
            id: "tool-output-shortcuts",
            priority: "P0",
            title: "Use output shortcuts",
            message: "Double-tap or pinch expanded output to open it full screen. Touch and hold for copy actions.",
            trigger: "After first tool row is expanded and full-screen content is available",
            completion: "Full-screen opened or context menu used",
            stories: "IOS-034, IOS-042"
        ),
        FeatureEducationTipPreviewItem(
            id: "open-changed-files-bar",
            priority: "P0",
            title: "Review changed files",
            message: "Tap the changed-files bar to inspect files this session touched.",
            trigger: "First chat session with session-scoped changed files",
            completion: "Changed-files bar expanded",
            stories: "IOS-043, IOS-100"
        ),
        FeatureEducationTipPreviewItem(
            id: "answer-inline-asks-and-extension-prompts",
            priority: "P0",
            title: "Answer prompts here",
            message: "Pick an option or type a response here without returning to the Mac.",
            trigger: "First inline ask card or extension prompt appears",
            completion: "First prompt answered",
            stories: "IOS-009, IOS-059, IOS-061"
        ),
        FeatureEducationTipPreviewItem(
            id: "steer-vs-follow-up-while-busy",
            priority: "P0",
            title: "Choose how to send",
            message: "Use Steer to guide the current turn. Use Follow-up to queue the next instruction.",
            trigger: "Composer is busy and both send modes are available",
            completion: "First busy-send mode used",
            stories: "IOS-052, IOS-053"
        ),
        FeatureEducationTipPreviewItem(
            id: "select-text-for-review-comments",
            priority: "P0",
            title: "Comment on selected text",
            message: "Select text to stage a review comment for your next message.",
            trigger: "First diff, code, tool, or full-screen text view that supports comments",
            completion: "First review comment created",
            stories: "IOS-042, IOS-050"
        ),
        FeatureEducationTipPreviewItem(
            id: "context-bar-multi-select-and-drag-select",
            priority: "P1",
            title: "Select files quickly",
            message: "Tap Select, then drag down the file list to choose several files for a prompt template.",
            trigger: "Changed-files bar is expanded with at least two files",
            completion: "First context-bar multi-select",
            stories: "IOS-043, IOS-048, IOS-050"
        ),
        FeatureEducationTipPreviewItem(
            id: "message-queue-review-and-editing",
            priority: "P1",
            title: "Review queued messages",
            message: "Tap the queue to edit, reorder, or remove pending instructions before they send.",
            trigger: "A steering or follow-up message is queued",
            completion: "Message queue opened",
            stories: "IOS-053"
        ),
        FeatureEducationTipPreviewItem(
            id: "session-outline-tree",
            priority: "P1",
            title: "Open the session outline",
            message: "Use Outline to jump through messages, tool calls, and branches without scrolling.",
            trigger: "Long session, branched session, or outline button first visible",
            completion: "Session outline opened",
            stories: "IOS-025"
        ),
        FeatureEducationTipPreviewItem(
            id: "fork-from-a-point-in-history",
            priority: "P1",
            title: "Try another path",
            message: "Fork from a message to explore a new direction without changing the original session.",
            trigger: "User opens outline or message actions on a long session",
            completion: "First session fork created",
            stories: "IOS-024, IOS-025"
        ),
        FeatureEducationTipPreviewItem(
            id: "context-usage-inspector",
            priority: "P1",
            title: "Inspect context usage",
            message: "Tap context usage to see loaded skills, files, and token pressure before compacting.",
            trigger: "Context usage ring or bar first appears or crosses a warning threshold",
            completion: "Context inspector opened",
            stories: "IOS-044"
        ),
        FeatureEducationTipPreviewItem(
            id: "cross-session-attention",
            priority: "P1",
            title: "Find blocked sessions",
            message: "Attention badges point to sessions waiting for your answer.",
            trigger: "A pending ask appears outside the active chat",
            completion: "Attention session opened or answered",
            stories: "IOS-060, IOS-092"
        ),
        FeatureEducationTipPreviewItem(
            id: "file-repo-references",
            priority: "P1",
            title: "Reference repo files",
            message: "Type @ to add a workspace file reference without uploading the file.",
            trigger: "Composer focused in a workspace before first file reference",
            completion: "First file reference inserted",
            stories: "IOS-055"
        ),
        FeatureEducationTipPreviewItem(
            id: "slash-command-autocomplete",
            priority: "P1",
            title: "Run slash commands",
            message: "Type / at the start of a message to find commands like share or compact.",
            trigger: "Composer is empty and focused before first slash command",
            completion: "First slash command used",
            stories: "IOS-056"
        ),
        FeatureEducationTipPreviewItem(
            id: "expanded-full-screen-composer",
            priority: "P1",
            title: "Draft in full screen",
            message: "Use the expand button for long prompts; attachments and file references come with you.",
            trigger: "Prompt grows past compact composer threshold and expand button appears",
            completion: "Expanded composer opened",
            stories: "IOS-058"
        ),
        FeatureEducationTipPreviewItem(
            id: "workspace-row-previews",
            priority: "P2",
            title: "Preview sessions",
            message: "Tap a workspace row to preview active and recent sessions before opening it.",
            trigger: "Compact workspace list with active or recent sessions",
            completion: "Workspace row preview opened",
            stories: "IOS-013, IOS-014"
        ),
        FeatureEducationTipPreviewItem(
            id: "ipad-split-workspace-shell",
            priority: "P2",
            title: "Use the iPad sidebar",
            message: "Keep workspaces and sessions visible in the sidebar while chat stays open.",
            trigger: "First regular-width iPad launch after update",
            completion: "iPad sidebar navigation used",
            stories: "IOS-002"
        ),
        FeatureEducationTipPreviewItem(
            id: "quick-session-from-app-controls",
            priority: "P2",
            title: "Start faster",
            message: "Use Quick Session to start a prompt without drilling into a workspace first.",
            trigger: "Quick Session button or control is first available",
            completion: "Quick Session opened",
            stories: "IOS-026, IOS-096, IOS-097"
        ),
        FeatureEducationTipPreviewItem(
            id: "workspace-picker-in-quick-session",
            priority: "P2",
            title: "Pick the workspace",
            message: "Choose the target workspace before sending so the session starts in the right project.",
            trigger: "Quick Session sheet opens before first send",
            completion: "Quick Session workspace selected",
            stories: "IOS-027"
        ),
        FeatureEducationTipPreviewItem(
            id: "file-browser-fuzzy-search",
            priority: "P2",
            title: "Find files by name",
            message: "Use search to fuzzy-find files by path or filename.",
            trigger: "First file browser open in a workspace with many files",
            completion: "First file search used",
            stories: "IOS-064"
        ),
        FeatureEducationTipPreviewItem(
            id: "share-and-export-rendered-output",
            priority: "P2",
            title: "Share rendered output",
            message: "Use Share to export source, rendered documents, diffs, images, or PDFs.",
            trigger: "File, full-screen, or share viewer first exposes share action",
            completion: "First file or viewer share",
            stories: "IOS-067"
        ),
        FeatureEducationTipPreviewItem(
            id: "local-pi-session-import",
            priority: "P2",
            title: "Import local Pi sessions",
            message: "Tap an importable local session to bring previous Pi work into Oppi.",
            trigger: "Importable local Pi sessions appear in stopped history",
            completion: "First local Pi session imported",
            stories: "IOS-101"
        ),
        FeatureEducationTipPreviewItem(
            id: "stop-active-session-swipe-action",
            priority: "P2",
            title: "Stop a runaway session",
            message: "Swipe an active session row to stop work that should not keep running.",
            trigger: "First active session row in workspace list after a long run",
            completion: "First session stop from row",
            stories: "IOS-022"
        ),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    header

                    ForEach(Self.priorities, id: \.self) { priority in
                        prioritySection(priority)
                    }
                }
                .padding(16)
            }
            .accessibilityIdentifier("feature-tips.catalog")
            .background(Color.themeBg.ignoresSafeArea())
            .navigationTitle("Tips")
        }
        .tint(.themeBlue)
        .accessibilityIdentifier("screenshot.ready")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Feature education tips")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.themeFg)

            Text("Fixture catalogue for app-behavior tips. Each card maps a contextual trigger to the action that dismisses the tip.")
                .font(.subheadline)
                .foregroundStyle(.themeComment)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(Self.tips.count) tips covered")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.themeBlue)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.themeBlue.opacity(0.12), in: Capsule())
                .accessibilityIdentifier("feature-tips.total")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    private func prioritySection(_ priority: String) -> some View {
        let priorityTips = Self.tips.filter { $0.priority == priority }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(priority)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(priorityColor(priority))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(priorityColor(priority).opacity(0.14), in: Capsule())

                Text("\(priorityTips.count) tips")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }
            .accessibilityIdentifier("feature-tip-section.\(priority.lowercased())")

            ForEach(priorityTips) { tip in
                tipCard(tip)
            }
        }
        .padding(.top, 8)
    }

    private func tipCard(_ tip: FeatureEducationTipPreviewItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tip.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .accessibilityIdentifier("feature-tip.\(tip.id)")

                Spacer(minLength: 8)

                Text(tip.stories)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.themeComment)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Text(tip.message)
                .font(.subheadline)
                .foregroundStyle(.themeFg)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                metadataRow(label: "Trigger", value: tip.trigger)
                metadataRow(label: "Stops after", value: tip.completion)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.themeBgHighlight.opacity(0.74), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(priorityColor(tip.priority).opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feature-tip-card.\(tip.id)")
    }

    private func metadataRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.themeComment)
            Text(value)
                .font(.caption)
                .foregroundStyle(.themeComment)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func priorityColor(_ priority: String) -> Color {
        switch priority {
        case "P0": return .themeOrange
        case "P1": return .themeBlue
        default: return .themeComment
        }
    }
}

// MARK: - Global Audio Banner Preview

private struct GlobalAudioBannerPreview: View {
    var body: some View {
        TabView {
            NavigationStack {
                List {
                    Section("Recent") {
                        Label("Albert TTS plan", systemImage: "waveform")
                        Label("Branch + fork UX", systemImage: "arrow.triangle.branch")
                        Label("Release checklist", systemImage: "checklist")
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.themeBg)
                .navigationTitle("Workspaces")
            }
            .tabItem {
                Label("Workspaces", systemImage: "square.grid.2x2")
            }

            NavigationStack {
                Color.themeBg
                    .navigationTitle("Settings")
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
        }
        .toolbarBackground(Color.themeBg, for: .tabBar)
        .background(Color.themeBg.ignoresSafeArea())
        .accessibilityIdentifier("screenshot.ready")
    }
}

// MARK: - Voice Message Preview

private struct VoiceMessageExpandedPreview: View {
    private static let previewConfiguration = ToolTimelineRowConfiguration(
        itemID: "voice-preview-1",
        title: "Voice message",
        preview: nil,
        expandedContent: .audioMessage(
            text: "Got it. I’m reinstalling the iPhone app now, and I’ll launch it as part of the install so it comes back up cleanly.",
            attachmentId: "att-voice-preview-1",
            mimeType: "audio/wav",
            durationSeconds: 4.2,
            playbackBehavior: nil
        ),
        copyCommandText: nil,
        copyOutputText: nil,
        languageBadge: nil,
        trailing: nil,
        titleLineBreakMode: .byTruncatingTail,
        toolNamePrefix: "voice_speak",
        toolNameColor: .systemPurple,
        editAdded: nil,
        editRemoved: nil,
        collapsedImageBase64: nil,
        collapsedImageMimeType: nil,
        isExpanded: true,
        isDone: true,
        isError: false,
        startedAt: nil,
        elapsedSeconds: nil,
        segmentAttributedTitle: nil,
        segmentAttributedTrailing: nil
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Expanded voice message")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.themeFg)

                Text("Regression preview for the compact expanded voice-message card.")
                    .font(.caption)
                    .foregroundStyle(.themeComment)

                VoiceMessageToolRowRepresentable(configuration: Self.previewConfiguration, width: 370)
                    .frame(width: 370)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .background(Color.themeBg.ignoresSafeArea())
        .accessibilityIdentifier("screenshot.ready")
    }
}

private struct VoiceMessageToolRowRepresentable: UIViewRepresentable {
    let configuration: ToolTimelineRowConfiguration
    let width: CGFloat

    func makeUIView(context: Context) -> VoiceMessageToolRowHostView {
        VoiceMessageToolRowHostView(configuration: configuration, width: width)
    }

    func updateUIView(_ uiView: VoiceMessageToolRowHostView, context: Context) {
        uiView.update(configuration: configuration, width: width)
    }
}

private final class VoiceMessageToolRowHostView: UIView {
    private let contentView: ToolTimelineRowContentView
    private var widthConstraint: NSLayoutConstraint?
    private var targetWidth: CGFloat

    init(configuration: ToolTimelineRowConfiguration, width: CGFloat) {
        self.contentView = ToolTimelineRowContentView(configuration: configuration)
        self.targetWidth = width
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        let widthConstraint = contentView.widthAnchor.constraint(equalToConstant: width)
        self.widthConstraint = widthConstraint
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(configuration: ToolTimelineRowConfiguration, width: CGFloat) {
        targetWidth = width
        widthConstraint?.constant = width
        contentView.configuration = configuration
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        layoutIfNeeded()
        return contentView.systemLayoutSizeFitting(
            CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
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
        namesHeuristic: true,
        skills: true
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
                namesHeuristic: true,
                skills: true
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
        Text(LiveActivityPresentation.phaseShortLabel(state.primaryPhase))
            .font(.caption2.bold())
            .foregroundStyle(LiveActivityPresentation.phaseColor(state.primaryPhase))
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

                    if let summary = LiveActivityPresentation.changeStatsSummary(state) {
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
        sessionStartDate: Date().addingTimeInterval(-97)
    )

    static let awaitingReplyPreview = Self(
        primaryPhase: .awaitingReply,
        primarySessionId: "session-awaiting",
        primarySessionName: "Deploy Server",
        primaryTool: nil,
        primaryLastActivity: "Waiting for your next instruction",
        totalActiveSessions: 1,
        sessionsAwaitingReply: 1,
        sessionsWorking: 0,
        primaryMutatingToolCalls: nil,
        primaryFilesChanged: nil,
        primaryAddedLines: nil,
        primaryRemovedLines: nil,
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
        sessionStartDate: nil
    )
}

#endif
