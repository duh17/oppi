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

/// The stand-in chat: the timeline over a synthetic 180-turn trace, a Back
/// and a Files control, and a stand-in Files panel. UIKit, like the chat.
@MainActor
private final class NavigationChromeReproChatController: UIViewController {
    private static let initialRenderWindow = 80
    private static let renderWindowStep = 60
    private static let traceEvents = NavigationChromeProfileTimelineFixtures.makeTraceEvents(turnCount: 180)
    private static let route = "chat-files-repro"

    private let state: NavigationChromeReproState
    private let connection = ServerConnection()
    private let reducer = TimelineReducer()
    private let scrollController = ChatScrollController()
    private let timeline = ChatTimelineController()
    private var collectionView: UICollectionView?
    private var renderWindow = initialRenderWindow
    private var scrollCommandNonce = 0
    private var pendingScrollCommand: ChatTimelineScrollCommand?
    private let filesPanel = UIStackView()
    private lazy var filesItem = UIBarButtonItem(
        image: UIImage(systemName: "folder"),
        primaryAction: UIAction { [weak self] _ in self?.toggleFiles() }
    )

    init(state: NavigationChromeReproState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = "Session Repro"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.hidesBackButton = true
        let back = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                Router.finish(self)
            }
        )
        back.accessibilityLabel = "Back"
        back.accessibilityIdentifier = "navChrome.chat.back"
        filesItem.accessibilityIdentifier = "navChrome.chat.files"
        navigationItem.leftBarButtonItems = [back, filesItem]

        let collectionView = timeline.makeCollectionView(
            configuration: makeConfiguration(),
            contentRoot: HostFactory.root(near: self)
        )
        collectionView.accessibilityIdentifier = "navChrome.repro.chat"
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(collectionView)
        self.collectionView = collectionView

        let title = UILabel()
        title.text = "Files"
        title.font = .preferredFont(forTextStyle: .headline)
        title.accessibilityIdentifier = "navChrome.chat.filesPanel"
        let tabs = UIStackView(arrangedSubviews: [
            UIButton(configuration: .plain(), primaryAction: UIAction(title: "Changed") { _ in }),
            UIButton(configuration: .plain(), primaryAction: UIAction(title: "All") { _ in }),
        ])
        tabs.spacing = 8
        filesPanel.addArrangedSubview(title)
        filesPanel.addArrangedSubview(tabs)
        filesPanel.addArrangedSubview(UIView())
        filesPanel.axis = .vertical
        filesPanel.alignment = .leading
        filesPanel.spacing = 12
        filesPanel.isLayoutMarginsRelativeArrangement = true
        filesPanel.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        filesPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(filesPanel)
        NSLayoutConstraint.activate([
            filesPanel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            filesPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            filesPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            filesPanel.widthAnchor.constraint(equalToConstant: 260),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
        NavigationChromeProfiler.mark(
            "heavy_timeline_host_appear",
            metadata: [
                "route": Self.route,
                "events": String(Self.traceEvents.count),
                "visible": String(visibleItems.count),
            ]
        )
        loadSyntheticTraceIfNeeded()
    }

    override func updateProperties() {
        super.updateProperties()
        let palette = HostFactory.root(near: self)?.themeStore.activeThemeID.palette ?? ThemeRuntimeState.currentPalette()
        let colors = ComposerThemeColors(palette: palette)
        let open = state.isFilePanelVisible
        view.backgroundColor = colors.bg
        filesPanel.backgroundColor = colors.bg
        filesItem.image = UIImage(systemName: open ? "folder.fill" : "folder")
        filesItem.accessibilityLabel = open ? "Close chat files" : "Open chat files"
        UIView.animate(withDuration: 0.18) {
            self.filesPanel.alpha = open ? 1 : 0
        }
        filesPanel.isHidden = false
        filesPanel.isUserInteractionEnabled = open
        filesPanel.accessibilityElementsHidden = !open
    }

    private func toggleFiles() {
        state.filesTapCount += 1
        state.isFilePanelVisible.toggle()
        NavigationChromeProfiler.mark(
            "chat_files_repro_files_tapped",
            metadata: ["visible": String(state.isFilePanelVisible), "tapCount": String(state.filesTapCount)]
        )
    }

    private var visibleItems: [ChatItem] {
        Array(reducer.items.suffix(renderWindow))
    }

    private func makeConfiguration() -> ChatTimelineConfiguration {
        let visibleItems = visibleItems
        return ChatTimelineConfiguration(
            items: visibleItems,
            hiddenCount: max(0, reducer.items.count - visibleItems.count),
            renderWindowStep: Self.renderWindowStep,
            isBusy: false,
            streamingAssistantID: nil,
            sessionId: Self.route,
            workspaceId: "nav-chrome-profile-workspace",
            onFork: { _ in },
            onBackSwipe: {},
            onShowEarlier: { [weak self] in
                guard let self else { return }
                self.renderWindow = min(self.reducer.items.count, self.renderWindow + Self.renderWindowStep)
                self.applyTimeline()
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
    }

    private func applyTimeline() {
        guard let collectionView else { return }
        timeline.update(configuration: makeConfiguration(), collectionView: collectionView)
    }

    private func loadSyntheticTraceIfNeeded() {
        guard reducer.items.isEmpty else { return }
        let startNs = DispatchTime.now().uptimeNanoseconds
        NavigationChromeProfiler.mark(
            "reducer_load_start",
            metadata: ["events": String(Self.traceEvents.count), "route": Self.route]
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
                "route": Self.route,
            ]
        )
        if let bottomID = visibleItems.last?.id {
            scrollCommandNonce &+= 1
            pendingScrollCommand = ChatTimelineScrollCommand(
                id: bottomID,
                anchor: .bottom,
                animated: false,
                nonce: scrollCommandNonce
            )
        }
        applyTimeline()
    }

    deinit {
        MainActor.assumeIsolated {
            if let collectionView { timeline.dismantle(collectionView) }
        }
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
    @State private var state = NavigationChromeReproState()

    var body: some View {
        RouterPreviewNavigation {
            NavigationChromeReproRoot(
                state: state,
                connection: connection,
                navigation: navigation
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
            let state = state
            let connection = connection
            let navigation = navigation
            navigator.push {
                NavigationChromeReproWorkspace(state: state, connection: connection, navigation: navigation)
            }
        } else {
            state.pathCount += 1
            navigator.push(makeNavigationChromeReproChat(state: state, connection: connection, navigation: navigation))
        }
    }
}

private struct NavigationChromeReproWorkspace: View {
    let state: NavigationChromeReproState
    let connection: ServerConnection
    let navigation: AppNavigation
    @Environment(\.screenNavigator) private var navigator

    var body: some View {
        List {
            Section("Sessions") {
                Button("Open Session") {
                    state.pathCount += 1
                    navigator.push(makeNavigationChromeReproChat(state: state, connection: connection, navigation: navigation))
                }
                .accessibilityIdentifier("navChrome.repro.openSession")

                if NavigationChromeProfileConfig.chatBackLocalRepro {
                    Button("Open Local Chat") {
                        // Router push, not an AppNavigation path hop. Chat back
                        // must finish this push.
                        navigator.push(makeNavigationChromeReproChat(state: state, connection: connection, navigation: navigation))
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
@MainActor
private func makeNavigationChromeReproChat(
    state: NavigationChromeReproState,
    connection: ServerConnection,
    navigation: AppNavigation
) -> UIViewController {
    guard NavigationChromeProfileConfig.chatFilesRealChatRepro else {
        return NavigationChromeReproChatController(state: state)
    }
    return ChatViewController(
        sessionId: "nav-chrome-repro-session",
        connection: connection,
        navigation: navigation,
        workspaceIdHint: "nav-chrome-repro-workspace"
    )
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
