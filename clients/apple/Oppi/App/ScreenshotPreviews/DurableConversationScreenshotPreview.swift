#if DEBUG
import SwiftUI
import UIKit

/// Conversation chrome for durable sessions (`SCREENSHOT_SCREEN=durable-conversation`):
/// the real timeline in `.conversation` style with work folded into
/// "Worked · N steps" pills, the chat title with its model subtitle, and the
/// real `ChatInputBar` with the session toolbar. No server; the reducer is
/// seeded from a trace so pill durations are stable.
///
/// `-running` ends on a turn still working (live "Working · N steps" pill,
/// busy composer); `-expanded` opens the weather turn through the same
/// scroll-target path a jump-to-item uses.
struct DurableConversationScreenshotPreview: View {
    enum Scenario {
        case settled
        case running
        case expanded
    }

    let themeID: ThemeID
    let scenario: Scenario

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

    init(themeID: ThemeID, scenario: Scenario = .settled) {
        self.themeID = themeID
        self.scenario = scenario
        ThemeRuntimeState.setThemeID(themeID)
    }

    private var isBusy: Bool { scenario == .running }

    var body: some View {
        NavigationStack {
            ChatTimelineView(
                sessionId: Self.sessionId,
                serverId: nil,
                workspaceId: nil,
                isBusy: isBusy,
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
            sessionManager.reducer.loadSession(Self.trace(for: scenario))
            if scenario == .expanded {
                scrollController.scrollTargetID = "t3"
            }
        }
        .accessibilityIdentifier("screenshot.ready")
    }

    private var composer: some View {
        ChatInputBar(
            text: $text,
            textBeforeRecording: $textBeforeRecording,
            pendingAttachments: $attachments,
            pendingRepoPointers: $repoPointers,
            isBusy: isBusy,
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

    /// Settled scenarios use a fixed clock so pill durations are stable. The
    /// running turn is anchored to now, so its live pill reads seconds.
    private static func trace(for scenario: Scenario) -> [TraceEvent] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = scenario == .running
            ? Date().addingTimeInterval(-128)
            : Date(timeIntervalSince1970: 1_791_576_000) // 2026-10-09T20:00:00Z
        func at(_ seconds: Int) -> String {
            formatter.string(from: start.addingTimeInterval(TimeInterval(seconds)))
        }
        let settledTurns = earlierTurns(at: at)
        guard scenario == .running else {
            return settledTurns + [
                TraceEvent(id: "r4", type: .toolResult, timestamp: at(126), output: "playing",
                           toolCallId: "t4", toolName: "bash", isError: false),
                TraceEvent(id: "a3", type: .assistant, timestamp: at(127),
                           text: "Playing **Underneath the Sky** by Oasis."),
            ]
        }
        return settledTurns + [
            TraceEvent(id: "r4", type: .toolResult, timestamp: at(124), output: "no device",
                       toolCallId: "t4", toolName: "bash", isError: false),
            TraceEvent(id: "t5", type: .toolCall, timestamp: at(125), tool: "bash",
                       args: ["command": .string("music devices --json")]),
        ]
    }

    private static func earlierTurns(at: (Int) -> String) -> [TraceEvent] { [
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
    ] }
}

/// Every "Worked \u{00B7} N steps" pill state through the real row content view
/// (`SCREENSHOT_SCREEN=durable-conversation-pills`). Rows after the first
/// replay what a collection view does to a visible cell: the row is already
/// laid out, then receives the next configuration (stream update, tap, press,
/// reuse). Each pill must stay a capsule in every row.
struct DurableConversationPillStatesPreview: View {
    let themeID: ThemeID
    private let liveStart = Date().addingTimeInterval(-8)

    init(themeID: ThemeID) {
        self.themeID = themeID
        ThemeRuntimeState.setThemeID(themeID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                state("Running", [live("running")])
                state("Running \u{00B7} stream update", [live("running-update"), live("running-update")])
                state("Finished \u{00B7} collapsed", [settled("finished"), settled("finished")])
                state("Expanded \u{00B7} after tap", [settled("expanded"), settled("expanded", isExpanded: true)])
                state(
                    "Collapsed \u{00B7} after second tap",
                    [settled("collapsed", isExpanded: true), settled("collapsed")]
                )
                state("Pressed", [settled("pressed"), settled("pressed", isHighlighted: true)])
                state("Reused cell \u{00B7} thinking \u{2192} finished", [thinking("reused"), settled("reused")])
                state("Thinking", [thinking("thinking")])
            }
            .padding(16)
        }
        .background(Color.themeBg.ignoresSafeArea())
        .preferredColorScheme(themeID.preferredColorScheme)
        .accessibilityIdentifier("screenshot.ready")
    }

    private func state(
        _ title: String,
        _ configurations: [QuietWorkLineTimelineRowConfiguration]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.themeFgDim)
            ReconfiguredPillRow(configurations: configurations)
                .frame(height: 44)
        }
    }

    private func workLine(
        _ id: String,
        buckets: [QuietWorkBucket],
        isExpanded: Bool = false,
        isLive: Bool,
        endedAt: Date? = nil
    ) -> QuietTimelineWorkLine {
        QuietTimelineWorkLine(
            id: "durable-pill.\(id)",
            turnID: id,
            sourceItemIDs: [id],
            buckets: buckets,
            displayStyle: .icons,
            isExpanded: isExpanded,
            isLive: isLive,
            liveStartedAt: isLive ? liveStart : Date(timeIntervalSince1970: 0),
            intervalEndedAt: endedAt
        )
    }

    private func live(_ id: String) -> QuietWorkLineTimelineRowConfiguration {
        QuietWorkLineTimelineRowConfiguration(
            workLine: workLine(id, buckets: [.init(kind: .tooling, count: 2)], isLive: true),
            chromeStyle: .conversation
        )
    }

    private func settled(
        _ id: String,
        isExpanded: Bool = false,
        isHighlighted: Bool = false
    ) -> QuietWorkLineTimelineRowConfiguration {
        QuietWorkLineTimelineRowConfiguration(
            workLine: workLine(
                id,
                buckets: [.init(kind: .read, count: 1), .init(kind: .tooling, count: 1)],
                isExpanded: isExpanded,
                isLive: false,
                endedAt: Date(timeIntervalSince1970: 9)
            ),
            chromeStyle: .conversation,
            isHighlighted: isHighlighted
        )
    }

    private func thinking(_ id: String) -> QuietWorkLineTimelineRowConfiguration {
        QuietWorkLineTimelineRowConfiguration(
            workLine: workLine(id, buckets: [], isLive: true),
            chromeStyle: .conversation
        )
    }
}

/// Hosts one real work-line content view and applies each later configuration
/// after the row has laid out, the way a visible cell is reconfigured.
private struct ReconfiguredPillRow: UIViewRepresentable {
    let configurations: [QuietWorkLineTimelineRowConfiguration]

    func makeUIView(context: Context) -> ReconfiguredPillHostView {
        ReconfiguredPillHostView(configurations: configurations)
    }

    func updateUIView(_ uiView: ReconfiguredPillHostView, context: Context) {}
}

private final class ReconfiguredPillHostView: UIView {
    private let row: QuietWorkLineTimelineRowContentView
    private var pending: ArraySlice<QuietWorkLineTimelineRowConfiguration>

    init(configurations: [QuietWorkLineTimelineRowConfiguration]) {
        row = QuietWorkLineTimelineRowContentView(configuration: configurations[0])
        pending = configurations.dropFirst()
        super.init(frame: .zero)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        while let next = pending.popFirst() {
            row.layoutIfNeeded()
            row.configuration = next
        }
    }
}
#endif
