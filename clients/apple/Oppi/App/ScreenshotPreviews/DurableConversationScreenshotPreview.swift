#if DEBUG
import SwiftUI

/// Conversation chrome for durable sessions (`SCREENSHOT_SCREEN=durable-conversation`):
/// the real timeline in `.conversation` style with work folded into
/// "Worked · N steps" pills, the chat title with its model subtitle, and the
/// real `ChatInputBar` with the session toolbar. No server; the reducer is
/// seeded from a trace so pill durations are stable.
struct DurableConversationScreenshotPreview: View {
    let themeID: ThemeID

    @State private var connection = ServerConnection()
    @State private var sessionManager = ChatSessionManager(sessionId: Self.sessionId)
    @State private var scrollController = ChatScrollController()
    @State private var audioPlayer = AudioPlayerService()
    @State private var audioLifecycleCoordinator = AudioLifecycleCoordinator()
    @State private var text = ""
    @State private var textBeforeRecording: String?
    @State private var attachments: [PendingAttachment] = []
    @State private var repoPointers: [PendingFileReference] = []
    @State private var busyBehavior: StreamingBehavior = .steer
    @State private var footerHeight: CGFloat = 0
    @State private var seeded = false

    private static let sessionId = "durable-conversation"

    init(themeID: ThemeID) {
        self.themeID = themeID
        ThemeRuntimeState.setThemeID(themeID)
    }

    var body: some View {
        NavigationStack {
            ChatTimelineView(
                sessionId: Self.sessionId,
                serverId: nil,
                workspaceId: nil,
                isBusy: false,
                extensionWorkingState: nil,
                extensionHiddenThinkingLabel: nil,
                currentModel: Self.session.model,
                sessionContent: connection.sessionContent,
                iconAssetCache: nil,
                openDestination: nil,
                loadOlderPage: nil,
                scrollController: scrollController,
                sessionManager: sessionManager,
                audioLifecycleCoordinator: audioLifecycleCoordinator,
                quietModeEnabled: true,
                chromeStyle: .conversation,
                onFork: { _ in },
                onOpenCurrentFile: { _ in },
                onBackSwipe: {},
                reviewCommentSelectionRouter: nil,
                topOverlap: 0,
                bottomOverlap: footerHeight
            )
            .overlay(alignment: .bottom) {
                composer
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Image(systemName: "chevron.left")
                        .font(.headline.weight(.semibold))
                        .frame(width: 36, height: 36)
                }
                ToolbarItem(placement: .principal) {
                    ChatSessionTitleView(
                        sessionId: Self.sessionId,
                        sessionDisplayName: "Researcher",
                        assistantIdentityPresentation: .globalAvatar,
                        agentIcon: nil,
                        cost: nil,
                        terminalMirrorIndicator: nil,
                        maxWidth: 240,
                        subtitle: "gpt-5.5 \u{00B7} High"
                    )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: "ellipsis")
                        .frame(width: 36, height: 36)
                }
            }
        }
        .environment(sessionManager.reducer)
        .environment(sessionManager.reducer.toolOutputStore)
        .environment(sessionManager.reducer.toolArgsStore)
        .environment(audioPlayer)
        .preferredColorScheme(themeID.preferredColorScheme)
        .task {
            guard !seeded else { return }
            seeded = true
            ThemeRuntimeState.setThemeID(themeID)
            NotificationCenter.default.post(name: .oppiThemeDidChange, object: nil)
            sessionManager.reducer.loadSession(Self.trace)
        }
        .accessibilityIdentifier("screenshot.ready")
    }

    private var composer: some View {
        ChatInputBar(
            text: $text,
            textBeforeRecording: $textBeforeRecording,
            pendingAttachments: $attachments,
            pendingRepoPointers: $repoPointers,
            isBusy: false,
            busyStreamingBehavior: $busyBehavior,
            isSending: false,
            sendProgressText: nil,
            isStopping: false,
            showForceStop: false,
            isForceStopInFlight: false,
            slashCommands: [],
            fileSuggestions: [],
            onFileSuggestionQuery: nil,
            onSend: {},
            onStop: {},
            onForceStop: {},
            onExpand: {},
            externalFocusRequestID: 0,
            appliesOuterPadding: true,
            actionRow: {
                SessionToolbar(
                    session: Self.session,
                    thinkingLevel: .high,
                    onModelTap: {},
                    onThinkingSelect: { _ in }
                )
            }
        )
    }

    private static let session = Session(
        id: sessionId,
        workspaceId: "home",
        workspaceName: "home",
        name: "Researcher",
        status: .ready,
        createdAt: Date(timeIntervalSince1970: 1_770_000_000),
        lastActivity: Date(timeIntervalSince1970: 1_770_000_600),
        model: "openai/gpt-5.5",
        messageCount: 6,
        tokens: TokenUsage(input: 12_000, output: 2_400),
        cost: 0,
        engine: .durable
    )

    private static func at(_ seconds: Int) -> String {
        String(format: "2026-10-09T20:%02d:%02d.000Z", seconds / 60, seconds % 60)
    }

    private static let trace: [TraceEvent] = [
        TraceEvent(id: "u1", type: .user, timestamp: at(0), text: "What's in my Work list?"),
        TraceEvent(id: "t1", type: .toolCall, timestamp: at(2), tool: "bash",
                   args: ["command": .string("remindctl list Work --json")]),
        TraceEvent(id: "r1", type: .toolResult, timestamp: at(3), output: "15 reminders",
                   toolCallId: "t1", toolName: "bash", isError: false),
        TraceEvent(
            id: "a1", type: .assistant, timestamp: at(5),
            text: "Your **Work** list has **15 open tasks**: 7 with due dates and 8 undated. "
                + "The next two are due Monday — finalize your apps list at 09:00, then look "
                + "into the Chase API, Xero, and Stripe at 14:00."
        ),
        TraceEvent(id: "u2", type: .user, timestamp: at(60), text: "Weather tomorrow?"),
        TraceEvent(id: "th2", type: .thinking, timestamp: at(61), thinking: "Check the forecast."),
        TraceEvent(id: "t2", type: .toolCall, timestamp: at(62), tool: "read",
                   args: ["path": .string("~/.config/location.json")]),
        TraceEvent(id: "r2", type: .toolResult, timestamp: at(63), output: "{\"city\":\"Seattle\"}",
                   toolCallId: "t2", toolName: "read", isError: false),
        TraceEvent(id: "t3", type: .toolCall, timestamp: at(64), tool: "bash",
                   args: ["command": .string("weather --tomorrow")]),
        TraceEvent(id: "r3", type: .toolResult, timestamp: at(68), output: "Rain 94%, 16-21C",
                   toolCallId: "t3", toolName: "bash", isError: false),
        TraceEvent(
            id: "a2", type: .assistant, timestamp: at(69),
            text: "Tomorrow, **Saturday, October 10**, looks rainy where you are, with a "
                + "**94% chance of rain** and temperatures around **16–21°C**. Bring an umbrella."
        ),
        TraceEvent(id: "u3", type: .user, timestamp: at(120), text: "Play Underneath the Sky."),
        TraceEvent(id: "t4", type: .toolCall, timestamp: at(121), tool: "bash",
                   args: ["command": .string("music play 'Underneath the Sky'")]),
        TraceEvent(id: "r4", type: .toolResult, timestamp: at(126), output: "playing",
                   toolCallId: "t4", toolName: "bash", isError: false),
        TraceEvent(id: "a3", type: .assistant, timestamp: at(127),
                   text: "Playing **Underneath the Sky** by Oasis."),
    ]
}
#endif
