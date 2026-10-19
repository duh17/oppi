#if DEBUG
import os
import SwiftUI
import UIKit

/// Debug-only harness for the chat Files control and Back handoff from a
/// workspace list: a fixture workspace list, workspace page, and chat pushed
/// through the router, as the app opens them.
///
/// Launch with `--nav-chrome-profile` or `PI_NAV_CHROME_PROFILE=1` on Simulator.
/// `--nav-chrome-chat-files-real-chat` shows the production chat;
/// `--nav-chrome-chat-back-local-repro` stops at the workspace page, whose
/// local chat pushes above it.
enum NavigationChromeProfileConfig {
    private static let environment = ProcessInfo.processInfo.environment
    private static let arguments = ProcessInfo.processInfo.arguments

    static var isEnabled: Bool {
#if targetEnvironment(simulator)
        arguments.contains("--nav-chrome-profile") || environment["PI_NAV_CHROME_PROFILE"] == "1"
#else
        false
#endif
    }

    static var chatFilesRealChatRepro: Bool {
        arguments.contains("--nav-chrome-chat-files-real-chat") || environment["PI_NAV_CHROME_CHAT_FILES_REAL_CHAT"] == "1"
    }

    static var chatBackLocalRepro: Bool {
        arguments.contains("--nav-chrome-chat-back-local-repro") || environment["PI_NAV_CHROME_CHAT_BACK_LOCAL_REPRO"] == "1"
    }
}

@MainActor
enum NavigationChromeProfiler {
    private static let logger = Logger(
        subsystem: AppIdentifiers.subsystem,
        category: "NavChromeProfile"
    )
    private static let signposter = OSSignposter(
        subsystem: AppIdentifiers.subsystem,
        category: "NavChromeProfile"
    )
    private static var startNs: UInt64?

    static func reset(label: String) {
        startNs = nowNs()
        logger.notice("event=reset label=\(label, privacy: .public)")
        signposter.emitEvent("nav.mark")
    }

    static func mark(_ event: String, metadata: [String: String] = [:]) {
        let elapsedMs: Int
        if let startNs {
            elapsedMs = Int((nowNs() &- startNs) / 1_000_000)
        } else {
            elapsedMs = 0
            startNs = nowNs()
        }

        let metadataText = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")

        logger.notice(
            "event=\(event, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public) \(metadataText, privacy: .public)"
        )
        signposter.emitEvent("nav.mark")
    }

    private static func nowNs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

private struct NavigationChromeProfileHeavyTimelineDestination: View {
    private static let initialRenderWindow = 80
    private static let renderWindowStep = 60
    private static let traceEvents = NavigationChromeProfileTimelineFixtures.makeTraceEvents(turnCount: 180)

    let route: String

    @State private var connection = ServerConnection()
    @State private var reducer = TimelineReducer()
    @State private var scrollController = ChatScrollController()
    @State private var renderWindow = initialRenderWindow
    @State private var scrollCommandNonce = 0
    @State private var pendingScrollCommand: ChatTimelineScrollCommand?

    private var visibleItems: [ChatItem] {
        Array(reducer.items.suffix(renderWindow))
    }

    private var hiddenCount: Int {
        max(0, reducer.items.count - visibleItems.count)
    }

    var body: some View {
        ChatTimelineCollectionHost(
            configuration: .init(
                items: visibleItems,
                hiddenCount: hiddenCount,
                renderWindowStep: Self.renderWindowStep,
                isBusy: false,
                streamingAssistantID: nil,
                sessionId: route,
                workspaceId: "nav-chrome-profile-workspace",
                onFork: { _ in },
                onBackSwipe: {},
                onShowEarlier: {
                    renderWindow = min(reducer.items.count, renderWindow + Self.renderWindowStep)
                },
                scrollCommand: pendingScrollCommand,
                scrollController: scrollController,
                reducer: reducer,
                toolOutputStore: reducer.toolOutputStore,
                toolArgsStore: reducer.toolArgsStore,
                toolSegmentStore: reducer.toolSegmentStore,
                toolDetailsStore: reducer.toolDetailsStore,
                sessionContent: connection.sessionContent,
                iconAssetCache: connection.iconAssetCache,
                currentModel: "profile/model",
                audioPlayer: connection.audioPlayer
            )
        )
        .background(Color.themeBg)
        .onAppear {
            NavigationChromeProfiler.mark(
                "heavy_timeline_host_appear",
                metadata: [
                    "route": route,
                    "events": String(Self.traceEvents.count),
                    "visible": String(visibleItems.count),
                ]
            )
            loadSyntheticTraceIfNeeded()
        }
    }

    private func loadSyntheticTraceIfNeeded() {
        guard reducer.items.isEmpty else { return }
        let startNs = DispatchTime.now().uptimeNanoseconds
        NavigationChromeProfiler.mark(
            "reducer_load_start",
            metadata: ["events": String(Self.traceEvents.count), "route": route]
        )
        reducer.loadSession(Self.traceEvents)
        renderWindow = TimelineRenderWindowPolicy.syncedWindow(
            currentWindow: renderWindow,
            totalItems: reducer.items.count
        )
        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000)
        NavigationChromeProfiler.mark(
            "reducer_load_end",
            metadata: [
                "durationMs": String(durationMs),
                "items": String(reducer.items.count),
                "route": route,
            ]
        )
        if let bottomID = visibleItems.last?.id {
            issueScrollCommand(id: bottomID, anchor: .bottom, animated: false)
        }
    }

    private func issueScrollCommand(id: String, anchor: ChatTimelineScrollCommand.Anchor, animated: Bool) {
        scrollCommandNonce &+= 1
        pendingScrollCommand = ChatTimelineScrollCommand(
            id: id,
            anchor: anchor,
            animated: animated,
            nonce: scrollCommandNonce
        )
    }
}

/// What the harness's pages share: each pushed page is its own SwiftUI graph,
/// so the state they edit lives in one observable model.
@MainActor @Observable
private final class NavigationChromeReproState {
    /// Pages the harness opened from the root list: the workspace page (and a
    /// session above it), not the local chat a workspace page pushes.
    var pathCount = 0
    var isFilePanelVisible = false
    var filesTapCount = 0
}

struct NavigationChromeProfileHarnessView: View {
    private static let workspace = Workspace(
        id: "nav-chrome-repro-workspace",
        name: "e2e-workspace",
        description: nil,
        icon: .symbol("square.grid.2x2"),
        systemPrompt: nil,
        hostMount: "/tmp/oppi-repro",
        tools: nil,
        gitStatusEnabled: false,
        runtime: .host,
        sandboxConfig: nil,
        createdAt: Date(timeIntervalSince1970: 1_770_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_770_000_000)
    )
    private static let serverId = "nav-chrome-repro-server"
    private static let sessionId = "nav-chrome-repro-session"

    @State private var navigation = AppNavigation()
    @State private var connection = Self.makeConnection()
    @State private var quickCommentTemplateStore = QuickCommentTemplateStore(templates: [])
    @State private var state = NavigationChromeReproState()

    var body: some View {
        RouterPreviewNavigation {
            NavigationChromeReproRoot(
                state: state,
                connection: connection,
                navigation: navigation,
                quickCommentTemplateStore: quickCommentTemplateStore
            )
        }
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            diagnosticsOverlay
        }
        .onAppear {
            navigation.launchPhase = .ready
            navigation.showOnboarding = false
            navigation.workspaceNavigationPresentation = .stack
            NavigationChromeProfiler.reset(label: "chat_files_repro")
            NavigationChromeProfiler.mark("chat_files_repro_appear")
        }
    }

    private var diagnosticsOverlay: some View {
        VStack(spacing: 0) {
            Text(String(state.pathCount))
                .accessibilityIdentifier("navChrome.repro.pathCount")
            Text(state.isFilePanelVisible ? "files" : "chat")
                .accessibilityIdentifier("navChrome.repro.surface")
            Text(String(state.filesTapCount))
                .accessibilityIdentifier("navChrome.repro.filesTapCount")
        }
        .frame(width: 1, height: 1)
        .opacity(0.01)
        .allowsHitTesting(false)
    }

    private static func makeConnection() -> ServerConnection {
        let connection = ServerConnection()
        connection.setPreviewServerId(serverId)
        connection.workspaceStore.workspacesByServer[serverId] = [workspace]
        connection.sessionStore.switchServer(to: serverId)
        connection.sessionStore.upsert(Session(
            id: sessionId,
            workspaceId: workspace.id,
            workspaceName: workspace.name,
            name: "Session Repro",
            status: .ready,
            createdAt: Date(timeIntervalSince1970: 1_770_000_010),
            lastActivity: Date(timeIntervalSince1970: 1_770_000_020),
            model: "profile/model",
            messageCount: 0,
            tokens: TokenUsage(input: 0, output: 0, cacheRead: nil, cacheWrite: nil),
            cost: 0,
            changeStats: SessionChangeStats(
                mutatingToolCalls: 1,
                filesChanged: 1,
                changedFiles: ["clients/apple/Oppi/App/NavigationChromeProfileHarnessView.swift"],
                changedFilesOverflow: nil,
                addedLines: 12,
                removedLines: 3
            ),
            contextTokens: 0,
            contextWindow: 128_000,
            firstMessage: nil,
            lastMessage: nil,
            thinkingLevel: "medium"
        ))
        return connection
    }
}

/// The workspace list, with the harness's pushes. It opens the workspace page
/// (local chat repro) or the chat straight away.
private struct NavigationChromeReproRoot: View {
    let state: NavigationChromeReproState
    let connection: ServerConnection
    let navigation: AppNavigation
    let quickCommentTemplateStore: QuickCommentTemplateStore
    @Environment(\.screenNavigator) private var navigator
    @State private var didAutoOpen = false

    var body: some View {
        List {
            Section("Workspace") {
                Button("Open e2e-workspace") {
                    openFromRoot()
                }
                .accessibilityIdentifier("navChrome.repro.openWorkspace")
            }
        }
        .accessibilityIdentifier("navChrome.repro.root")
        .listStyle(.insetGrouped)
        .themedListSurface()
        .navigationTitle("Workspaces")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !didAutoOpen else { return }
            didAutoOpen = true
            try? await Task.sleep(for: .milliseconds(250))
            openFromRoot()
        }
    }

    private func openFromRoot() {
        state.pathCount += 1
        if NavigationChromeProfileConfig.chatBackLocalRepro {
            navigator.push { workspaceDetail }
        } else {
            state.pathCount += 1
            navigator.push { chatDestination }
        }
    }

    private var workspaceDetail: some View {
        NavigationChromeReproWorkspace(
            state: state,
            connection: connection,
            navigation: navigation,
            quickCommentTemplateStore: quickCommentTemplateStore
        )
    }

    private var chatDestination: some View {
        NavigationChromeReproChat(
            state: state,
            connection: connection,
            navigation: navigation,
            quickCommentTemplateStore: quickCommentTemplateStore,
            ownsBackNavigation: true
        )
    }
}

private struct NavigationChromeReproWorkspace: View {
    let state: NavigationChromeReproState
    let connection: ServerConnection
    let navigation: AppNavigation
    let quickCommentTemplateStore: QuickCommentTemplateStore
    @Environment(\.screenNavigator) private var navigator

    var body: some View {
        List {
            Section("Sessions") {
                Button("Open Session") {
                    state.pathCount += 1
                    navigator.push {
                        NavigationChromeReproChat(
                            state: state,
                            connection: connection,
                            navigation: navigation,
                            quickCommentTemplateStore: quickCommentTemplateStore,
                            ownsBackNavigation: true
                        )
                    }
                }
                .accessibilityIdentifier("navChrome.repro.openSession")

                if NavigationChromeProfileConfig.chatBackLocalRepro {
                    Button("Open Local Chat") {
                        // Router push, not an AppNavigation path hop. Chat back
                        // must finish this push; SwiftUI dismiss() cannot pop it.
                        navigator.push {
                            NavigationChromeReproChat(
                                state: state,
                                connection: connection,
                                navigation: navigation,
                                quickCommentTemplateStore: quickCommentTemplateStore,
                                ownsBackNavigation: true
                            )
                        }
                    }
                    .accessibilityIdentifier("navChrome.repro.openLocalChat")
                }
            }
        }
        .accessibilityIdentifier("navChrome.repro.workspace")
        .listStyle(.insetGrouped)
        .themedListSurface()
        .navigationTitle("e2e-workspace")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The production chat, or a stand-in with a Files control and panel.
private struct NavigationChromeReproChat: View {
    let state: NavigationChromeReproState
    let connection: ServerConnection
    let navigation: AppNavigation
    let quickCommentTemplateStore: QuickCommentTemplateStore
    let ownsBackNavigation: Bool

    var body: some View {
        if NavigationChromeProfileConfig.chatFilesRealChatRepro {
            ChatView(
                sessionId: "nav-chrome-repro-session",
                workspaceIdHint: "nav-chrome-repro-workspace",
                isShellRoute: ownsBackNavigation
            )
            .withServerScopedEnvironment(connection)
            .environment(navigation)
            .environment(quickCommentTemplateStore)
        } else {
            NavigationChromeChatFilesReproChatView(state: state)
        }
    }
}

private struct NavigationChromeChatFilesReproChatView: View {
    @Environment(\.screenNavigator) private var navigator
    let state: NavigationChromeReproState

    var body: some View {
        ZStack(alignment: .trailing) {
            NavigationChromeProfileHeavyTimelineDestination(route: "chat-files-repro")
                .accessibilityIdentifier("navChrome.repro.chat")

            if state.isFilePanelVisible {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Files")
                        .font(.headline)
                        .accessibilityIdentifier("navChrome.chat.filesPanel")
                    HStack(spacing: 8) {
                        Button("Changed") {}
                        Button("All") {}
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(width: 260)
                .frame(maxHeight: .infinity)
                .background(Color.themeBg)
                .overlay(alignment: .leading) {
                    Divider().overlay(Color.themeComment.opacity(0.18))
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: state.isFilePanelVisible)
        .navigationTitle("Session Repro")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbarVisibility(.hidden, for: .bottomBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 10) {
                    Button { navigator.finish() } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("navChrome.chat.back")

                    Button {
                        state.filesTapCount += 1
                        state.isFilePanelVisible.toggle()
                        NavigationChromeProfiler.mark(
                            "chat_files_repro_files_tapped",
                            metadata: ["visible": String(state.isFilePanelVisible), "tapCount": String(state.filesTapCount)]
                        )
                    } label: {
                        Image(systemName: state.isFilePanelVisible ? "folder.fill" : "folder")
                            .font(.subheadline)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(state.isFilePanelVisible ? "Close chat files" : "Open chat files")
                    .accessibilityIdentifier("navChrome.chat.files")
                }
            }
        }
    }
}

private enum NavigationChromeProfileTimelineFixtures {
    static func makeTraceEvents(turnCount: Int) -> [TraceEvent] {
        var events: [TraceEvent] = []
        events.reserveCapacity(turnCount * 2 + 24)

        for turn in 1...turnCount {
            events.append(TraceEvent(
                id: "profile-u-\(turn)",
                type: .user,
                timestamp: timestamp(turn: turn, offset: 0),
                text: "Profile prompt \(turn): inspect navigation handoff and timeline startup latency.",
                tool: nil,
                args: nil,
                output: nil,
                toolCallId: nil,
                toolName: nil,
                isError: nil,
                thinking: nil
            ))

            events.append(TraceEvent(
                id: "profile-a-\(turn)",
                type: .assistant,
                timestamp: timestamp(turn: turn, offset: 1),
                text: assistantText(turn: turn),
                tool: nil,
                args: nil,
                output: nil,
                toolCallId: nil,
                toolName: nil,
                isError: nil,
                thinking: nil
            ))

            if turn.isMultiple(of: 18) {
                let toolCallId = "profile-tool-\(turn)"
                events.append(TraceEvent(
                    id: toolCallId,
                    type: .toolCall,
                    timestamp: timestamp(turn: turn, offset: 2),
                    text: nil,
                    tool: "bash",
                    args: ["command": .string("git status --short && xcrun xctrace record")],
                    output: nil,
                    toolCallId: nil,
                    toolName: nil,
                    isError: nil,
                    thinking: nil
                ))
                events.append(TraceEvent(
                    id: "profile-tool-result-\(turn)",
                    type: .toolResult,
                    timestamp: timestamp(turn: turn, offset: 3),
                    text: nil,
                    tool: nil,
                    args: nil,
                    output: String(repeating: "sample frame gap observed for route \(turn)\n", count: 24),
                    toolCallId: toolCallId,
                    toolName: "bash",
                    isError: false,
                    thinking: nil
                ))
            }
        }

        events.append(TraceEvent(
            id: "profile-system",
            type: .system,
            timestamp: timestamp(turn: turnCount + 1, offset: 0),
            text: "Profile fixture loaded \(turnCount) turns for navigation chrome timing",
            tool: nil,
            args: nil,
            output: nil,
            toolCallId: nil,
            toolName: nil,
            isError: nil,
            thinking: nil
        ))
        return events
    }

    private static func timestamp(turn: Int, offset: Int) -> String {
        let seconds = turn * 4 + offset
        return String(format: "2025-01-01T00:%02d:%02d.000Z", (seconds / 60) % 60, seconds % 60)
    }

    private static func assistantText(turn: Int) -> String {
        switch turn % 4 {
        case 0:
            return """
            ### Profile answer \(turn)

            This row intentionally mixes markdown, bullets, and code so the reducer and collection host have realistic first-render work.

            - transition: workspace list to timeline
            - turn: \(turn)
            - payload: \(String(repeating: "sample ", count: 16))

            ```swift
            struct ProfileSample\(turn) {
                let value = \(turn)
                func run() { print(value) }
            }
            ```
            """
        case 1:
            return "Short profile answer \(turn) with plain text and a few tokens."
        case 2:
            return """
            ```diff
            - old toolbar ownership waits for destination
            + active destination declares toolbar visibility
            + transition profiling measures frame gaps
            ```
            """
        default:
            return "Thinking through route \(turn): measure whether frame drops happen before timeline_appear, during reducer load, collection apply, or UIKit toolbar animation."
        }
    }
}
#endif
