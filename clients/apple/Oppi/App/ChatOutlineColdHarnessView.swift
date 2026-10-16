#if DEBUG
import SwiftUI
import UIKit

/// Deterministic, serverless ChatView toolbar/outline harness.
///
/// Launch with `--chat-outline-cold-harness` or `PI_CHAT_OUTLINE_COLD_HARNESS=1`.
enum ChatOutlineColdHarnessConfig {
    static let sessionA = "cold-outline-session-a"
    static let sessionB = "cold-outline-session-b"
    static let targetItemID = "cold-outline-target"
    static let targetText = "COLD_OUTLINE_TARGET_ROW"
    static let streamToken = " COLD_OUTLINE_STREAM"
    static let fillPrefix = "COLD_OUTLINE_FILL_"

    private static let environment = ProcessInfo.processInfo.environment
    private static let arguments = ProcessInfo.processInfo.arguments

    static var isEnabled: Bool {
#if targetEnvironment(simulator)
        arguments.contains("--chat-outline-cold-harness")
            || environment["PI_CHAT_OUTLINE_COLD_HARNESS"] == "1"
#else
        false
#endif
    }
}

struct ChatOutlineColdHarnessView: View {
    private static let workspace = Workspace(
        id: "cold-outline-workspace",
        name: "e2e-workspace",
        description: nil,
        icon: .symbol("square.grid.2x2"),
        systemPrompt: nil,
        hostMount: "/tmp/oppi-outline-cold",
        tools: nil,
        gitStatusEnabled: false,
        runtime: .host,
        sandboxConfig: nil,
        createdAt: Date(timeIntervalSince1970: 1_770_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_770_000_000)
    )
    private static let serverId = "cold-outline-server"

    @State private var navigation = AppNavigation()
    @State private var connection = Self.makeConnection()
    @State private var quickCommentTemplateStore = QuickCommentTemplateStore(templates: [])
    @State private var composerDraftStore = ComposerDraftStore()
    @State private var sessionId = ChatOutlineColdHarnessConfig.sessionA
    @State private var didAutoOpen = false
    @State private var probe = ChatOutlineColdHarnessProbeState()
    @State private var pendingSeedSessionId: String?
    @State private var armStreamOnOutline = false

    private var workspaceTarget: WorkspaceNavTarget {
        WorkspaceNavTarget(serverId: Self.serverId, workspace: Self.workspace)
    }

    private var sessionTarget: WorkspaceSessionNavTarget {
        WorkspaceSessionNavTarget(
            serverId: Self.serverId,
            sessionId: sessionId,
            workspaceId: Self.workspace.id
        )
    }

    var body: some View {
        @Bindable var nav = navigation

        NavigationStack(path: $nav.workspacePath) {
            List {
                Button("Open Session") {
                    openChat()
                }
                .accessibilityIdentifier("chat.outline.harness.openSession")
            }
            .accessibilityIdentifier("chat.outline.harness.root")
            .navigationTitle("Workspaces")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: WorkspaceNavTarget.self) { _ in
                Text("Workspace")
                    .navigationTitle("e2e-workspace")
            }
            .navigationDestination(for: WorkspaceSessionNavTarget.self) { _ in
                ChatView(
                    sessionId: sessionId,
                    workspaceIdHint: Self.workspace.id,
                    ownsWorkspacePathBackNavigation: true
                )
                .withServerScopedEnvironment(connection)
                .environment(navigation)
                .environment(quickCommentTemplateStore)
                .id(sessionId)
            }
        }
        .environment(navigation)
        .environment(\.composerDraftStore, composerDraftStore)
        .overlay(alignment: .topLeading) {
            probeOverlay
        }
        .onAppear {
            navigation.launchPhase = .ready
            navigation.showOnboarding = false
            navigation.workspaceNavigationPresentation = .stack
        }
        .task {
            await autoOpenChatIfNeeded()
            while !Task.isCancelled {
                refreshProbe()
                tryPendingSeed()
                tryArmedStream()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private var probeOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            probeButton("Seed A", id: "chat.outline.harness.seedA") {
                pendingSeedSessionId = ChatOutlineColdHarnessConfig.sessionA
                tryPendingSeed()
            }
            probeButton("Clear", id: "chat.outline.harness.clear") {
                timelineController()?.ownedClock.lastConfiguration?.reducer.reset()
                refreshProbe()
            }
            probeButton("Rebind B", id: "chat.outline.harness.rebindB") {
                sessionId = ChatOutlineColdHarnessConfig.sessionB
                refreshProbe()
            }
            probeButton("Seed B", id: "chat.outline.harness.seedB") {
                pendingSeedSessionId = ChatOutlineColdHarnessConfig.sessionB
                tryPendingSeed()
            }
            probeButton("Arm stream", id: "chat.outline.harness.armStream") {
                armStreamOnOutline = true
            }
            probeButton("Reset perf", id: "chat.outline.harness.resetPerf") {
                ChatTimelinePerf.reset()
                refreshProbe()
            }
            ChatOutlineColdHarnessDiagnostics(probe: probe)
        }
        .padding(.top, 96)
        .padding(.leading, 4)
        .allowsHitTesting(true)
    }

    private func probeButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.01))
            .accessibilityIdentifier(id)
    }


    private func autoOpenChatIfNeeded() async {
        guard !didAutoOpen else { return }
        didAutoOpen = true
        try? await Task.sleep(for: .milliseconds(250))
        guard navigation.workspacePath.isEmpty else { return }
        openChat()
    }

    private func openChat() {
        navigation.openWorkspace(workspaceTarget)
        navigation.openWorkspaceSession(sessionTarget, workspace: workspaceTarget)
    }

    private func tryPendingSeed() {
        guard let sessionId = pendingSeedSessionId,
              let configuration = timelineController()?.ownedClock.lastConfiguration,
              configuration.sessionId == sessionId
        else {
            return
        }
        configuration.reducer.loadSession(Self.makeTraceEvents())
        pendingSeedSessionId = nil
        refreshProbe()
    }

    private func tryArmedStream() {
        guard armStreamOnOutline, isOutlinePresented() else { return }
        armStreamOnOutline = false
        stream()
    }

    private func stream() {
        guard let reducer = timelineController()?.ownedClock.lastConfiguration?.reducer else { return }
        let sessionId = probe.sessionId
        if reducer.items.isEmpty {
            reducer.processBatch([
                .agentStart(sessionId: sessionId),
                .textDelta(sessionId: sessionId, delta: ChatOutlineColdHarnessConfig.streamToken),
            ])
        } else {
            reducer.processBatch([
                .textDelta(sessionId: sessionId, delta: ChatOutlineColdHarnessConfig.streamToken),
            ])
        }
        refreshProbe()
    }

    private func refreshProbe() {
        let controller = timelineController()
        let configuration = controller?.ownedClock.lastConfiguration
        let snapshot = ChatTimelinePerf.snapshot()
        let collectionView = timelineCollectionView()
        probe.ready = controller?.isObservingOwnedTimelineForTesting == true
        probe.sessionId = configuration?.sessionId ?? sessionId
        probe.itemCount = configuration?.reducer.items.count ?? 0
        probe.outlineAvailable = configuration?.outlineAvailability?.isAvailable == true
        probe.hostUpdateUIViewCount = snapshot.hostUpdateUIViewCount
        probe.controllerOwnedApplyCount = snapshot.controllerOwnedApplyCount
        probe.topVisibleItemId = configuration?.scrollController.currentTopVisibleItemId ?? ""
        probe.targetItemId = ChatOutlineColdHarnessConfig.targetItemID
        probe.highlightedItemId = highlightedItemId(controller: controller, collectionView: collectionView)
    }

    private func timelineCollectionView() -> UICollectionView? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                if let collection = firstTimelineCollectionView(in: window) {
                    return collection
                }
            }
        }
        return nil
    }

    private func timelineController() -> ChatTimelineCollectionHost.Controller? {
        timelineCollectionView()?.delegate as? ChatTimelineCollectionHost.Controller
    }

    private func firstTimelineCollectionView(in view: UIView) -> UICollectionView? {
        if let collection = view as? UICollectionView,
           collection.accessibilityIdentifier == "chat.timeline" {
            return collection
        }
        for child in view.subviews {
            if let found = firstTimelineCollectionView(in: child) {
                return found
            }
        }
        return nil
    }

    private func isOutlinePresented() -> Bool {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                if let presented = window.rootViewController?.presentedViewController,
                   !presented.isBeingPresented,
                   presented.viewIfLoaded?.window != nil {
                    return true
                }
            }
        }
        return false
    }

    private func highlightedItemId(
        controller: ChatTimelineCollectionHost.Controller?,
        collectionView: UICollectionView?
    ) -> String {
        guard let controller, let collectionView else { return "" }
        for (index, id) in controller.currentIDs.enumerated() {
            guard let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? SafeSizingCell
            else { continue }
            if cell.isShowingNavigationHighlightForTesting {
                return id
            }
        }
        return ""
    }

    private static func makeConnection() -> ServerConnection {
        let connection = ServerConnection()
        connection.setPreviewServerId(serverId)
        connection.setAPIClientForTesting(nil)
        connection.workspaceStore.workspacesByServer[serverId] = [workspace]
        connection.sessionStore.switchServer(to: serverId)
        connection.sessionStore.upsert(makeHarnessSession(id: ChatOutlineColdHarnessConfig.sessionA))
        connection.sessionStore.upsert(makeHarnessSession(id: ChatOutlineColdHarnessConfig.sessionB))
        return connection
    }

    private static func makeHarnessSession(id: String) -> Session {
        Session(
            id: id,
            workspaceId: workspace.id,
            workspaceName: workspace.name,
            name: id == ChatOutlineColdHarnessConfig.sessionA ? "Session A" : "Session B",
            status: .stopped,
            createdAt: Date(timeIntervalSince1970: 1_770_000_010),
            lastActivity: Date(timeIntervalSince1970: 1_770_000_020),
            model: "harness/model",
            messageCount: 0,
            tokens: TokenUsage(input: 0, output: 0, cacheRead: nil, cacheWrite: nil),
            cost: 0,
            contextTokens: 0,
            contextWindow: 128_000,
            firstMessage: nil,
            lastMessage: nil,
            thinkingLevel: "medium"
        )
    }

    private static func makeTraceEvents() -> [TraceEvent] {
        var events: [TraceEvent] = []
        events.append(
            TraceEvent(
                id: ChatOutlineColdHarnessConfig.targetItemID,
                type: .user,
                timestamp: "2026-09-14T12:00:00.000Z",
                text: ChatOutlineColdHarnessConfig.targetText,
                tool: nil,
                args: nil,
                output: nil,
                toolCallId: nil,
                toolName: nil,
                isError: nil,
                thinking: nil
            )
        )
        for turn in 1...10 {
            events.append(
                TraceEvent(
                    id: "cold-outline-user-\(turn)",
                    type: .user,
                    timestamp: "2026-09-14T12:00:\(String(format: "%02d", turn)).000Z",
                    text: """
                    \(ChatOutlineColdHarnessConfig.fillPrefix)\(turn)
                    Filler user turn with enough height to push the target row off-screen.
                    """,
                    tool: nil,
                    args: nil,
                    output: nil,
                    toolCallId: nil,
                    toolName: nil,
                    isError: nil,
                    thinking: nil
                )
            )
            events.append(
                TraceEvent(
                    id: "cold-outline-assistant-\(turn)",
                    type: .assistant,
                    timestamp: "2026-09-14T12:01:\(String(format: "%02d", turn)).000Z",
                    text: """
                    \(ChatOutlineColdHarnessConfig.fillPrefix)assistant-\(turn)
                    Filler assistant reply used only to lengthen the timeline.
                    Line three keeps the row tall enough for a real jump.
                    """,
                    tool: nil,
                    args: nil,
                    output: nil,
                    toolCallId: nil,
                    toolName: nil,
                    isError: nil,
                    thinking: nil
                )
            )
        }
        return events
    }
}

/// The probe readouts, in a view of their own: read in the harness body, each
/// probe change re-rendered the harness and re-created the chat under test,
/// which counted as a chat update.
private struct ChatOutlineColdHarnessDiagnostics: View {
    let probe: ChatOutlineColdHarnessProbeState

    var body: some View {
        diagnostic("chat.outline.harness.ready", probe.ready ? "1" : "0")
        diagnostic("chat.outline.harness.sessionId", probe.sessionId)
        diagnostic("chat.outline.harness.itemCount", String(probe.itemCount))
        diagnostic("chat.outline.harness.outlineAvailable", probe.outlineAvailable ? "1" : "0")
        diagnostic("chat.outline.harness.hostUpdateUIViewCount", String(probe.hostUpdateUIViewCount))
        diagnostic(
            "chat.outline.harness.controllerOwnedApplyCount",
            String(probe.controllerOwnedApplyCount)
        )
        diagnostic("chat.outline.harness.topVisibleItemId", probe.topVisibleItemId)
        diagnostic("chat.outline.harness.targetItemId", probe.targetItemId)
        diagnostic("chat.outline.harness.highlightedItemId", probe.highlightedItemId)
    }

    private func diagnostic(_ id: String, _ value: String) -> some View {
        Text(value)
            .font(.system(size: 8))
            .opacity(0.02)
            .accessibilityIdentifier(id)
            .accessibilityValue(value)
            .accessibilityLabel(id)
    }
}

@MainActor
@Observable
private final class ChatOutlineColdHarnessProbeState {
    var ready = false
    var sessionId = ChatOutlineColdHarnessConfig.sessionA
    var itemCount = 0
    var outlineAvailable = false
    var hostUpdateUIViewCount = 0
    var controllerOwnedApplyCount = 0
    var topVisibleItemId = ""
    var targetItemId = ChatOutlineColdHarnessConfig.targetItemID
    var highlightedItemId = ""
}

// MARK: - Chat routes harness

/// Every router modal and side panel chat owns, on the production `ChatView`
/// with fixture services and an in-process stub server
/// (`SCREENSHOT_SCREEN=chat-routes`). The chat is a router screen at the root
/// of a `RouterNavigationController`. The timeline carries a user message with
/// a commit pill and a file pill; the context bar has a changed file and a
/// commit; one review comment is staged; Share is enabled.
/// `CHAT_ROUTES_STATUS=busy` makes the session busy (busy send mode picker);
/// `CHAT_ROUTES_ASK=1` puts a two-question ask in the composer.
/// `chatRoutes.createdSessions` counts the new sessions the stub received.
/// Leading controls open the timeline's commit and file viewers through the
/// production presenter (a test tap on a timeline pill did not reach the pill
/// control), and the composers' photo library and canvas covers without the
/// attach menu, which keeps the app from idling for UI tests.
struct ChatRoutesHarnessView: View {
    @State private var connection = ChatRoutesFixture.connection
    @State private var navigation = AppNavigation()
    @State private var quickCommentTemplateStore = QuickCommentTemplateStore(
        templates: QuickCommentTemplate.builtInDefaults
    )
    @State private var stub = ChatRoutesStubRecord.shared

    var body: some View {
        RouterPreviewNavigation {
            ChatView(
                sessionId: ChatRoutesFixture.sessionId,
                workspaceIdHint: ChatRoutesFixture.workspace.id
            )
            .withServerScopedEnvironment(connection)
            .environment(navigation)
            .environment(quickCommentTemplateStore)
        }
        .ignoresSafeArea()
        .overlay(alignment: .leading) {
            VStack(alignment: .leading, spacing: 2) {
                harnessControl("chatRoutes.openCommitViewer") {
                    ChatRoutesFixture.openFromTimeline(.commitDetail(sha: ChatRoutesFixture.commitSha), connection: connection)
                }
                harnessControl("chatRoutes.openFileViewer") {
                    ChatRoutesFixture.openFromTimeline(
                        .workspaceFile(UserMessagePathPill(kind: .repoFile, path: ChatRoutesFixture.changedPath)),
                        connection: connection
                    )
                }
                ChatRoutesCoverControls()
            }
            .padding(.top, 240)
        }
        .overlay(alignment: .bottomTrailing) {
            Text("\(stub.createdSessions)")
                .font(.system(size: 8))
                .opacity(0.02)
                .accessibilityIdentifier("chatRoutes.createdSessions")
                .accessibilityValue("\(stub.createdSessions)")
                .allowsHitTesting(false)
        }
        .task {
            navigation.launchPhase = .ready
            navigation.showOnboarding = false
            // The connect loop has no server to stream from, and it resets the
            // chat's state; keep the fixture timeline and Share loaded.
            while !Task.isCancelled {
                ChatRoutesFixture.seedTimelineIfNeeded()
                ChatRoutesFixture.enableShare(on: connection)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}

private func harnessControl(_ identifier: String, action: @escaping @MainActor () -> Void) -> some View {
    HarnessControl(identifier: identifier, action: action)
        .frame(width: 12, height: 12)
}

/// A UIKit button: on iPhone and iPad, test taps on a SwiftUI button in this
/// overlay, above the chat's UIKit navigation controller, never reached it.
private struct HarnessControl: UIViewRepresentable {
    let identifier: String
    let action: @MainActor () -> Void

    final class Coordinator {
        var action: @MainActor () -> Void
        init(action: @escaping @MainActor () -> Void) { self.action = action }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.01)
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = identifier
        let coordinator = context.coordinator
        button.addAction(UIAction { _ in coordinator.action() }, for: .primaryActionTriggered)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action
    }
}

/// The composers' photo library and canvas covers, as the inline and expanded
/// composers attach them.
private struct ChatRoutesCoverControls: View {
    @State private var showsPhotoLibrary = false
    @State private var showsCanvas = false
    @State private var text = ""
    @State private var attachments: [PendingAttachment] = []
    @State private var importError: String?
    @State private var importEpoch: UInt64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            harnessControl("chatRoutes.photoLibrary") { showsPhotoLibrary = true }
            harnessControl("chatRoutes.canvas") { showsCanvas = true }
        }
        .composerPhotoLibraryCover(
            isPresented: $showsPhotoLibrary,
            pendingAttachments: $attachments,
            importError: $importError,
            localImportEpoch: $importEpoch
        )
        .composerCanvasCover(isPresented: $showsCanvas, text: $text, pendingAttachments: $attachments)
    }
}

/// What the stub server received, so a test sees a save land.
@MainActor @Observable
private final class ChatRoutesStubRecord {
    static let shared = ChatRoutesStubRecord()
    var createdSessions = 0
}

private enum ChatRoutesFixture {
    static let serverId = "chat-routes-server"
    static let sessionId = "chat-routes-session"
    static let commitSha = "abc1234"
    static let changedPath = "Sources/App.swift"
    /// A file the session wrote outside Git's changes: the Files panel opens
    /// its current bytes instead of a review.
    static let touchedPath = "Notes/plan.md"
    static let skillName = "route-skill"
    static let seedMarkerId = "chat-routes-user"

    static let workspace = Workspace(
        id: "chat-routes-ws",
        name: "routes-workspace",
        description: nil,
        icon: .symbol("square.grid.2x2"),
        systemPrompt: nil,
        hostMount: "/tmp/oppi-chat-routes",
        tools: nil,
        gitStatusEnabled: true,
        runtime: .host,
        sandboxConfig: nil,
        createdAt: Date(timeIntervalSince1970: 1_770_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_770_000_000)
    )

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Built once per launch, before the chat mounts.
    @MainActor static let connection: ServerConnection = {
        resetLocalState()
        return makeConnection()
    }()

    @MainActor private static func makeConnection() -> ServerConnection {
        let connection = ServerConnection()
        connection.setPreviewServerId(serverId)
        connection.setAPIClientForTesting(api)
        // Context's usage and loaded skills come over the session socket,
        // which the harness never opens: answer `get_session_stats`, and fail
        // every other send the way an unopened socket does.
        connection._sendMessageForTesting = { [weak connection] message in
            guard case .getSessionStats(let requestId?) = message else {
                throw WebSocketError.notConnected
            }
            Task { @MainActor in
                _ = connection?.commands.resolveCommandResult(
                    command: "get_session_stats",
                    requestId: requestId,
                    success: true,
                    data: sessionStats,
                    error: nil
                )
            }
        }
        connection.workspaceStore.workspacesByServer[serverId] = [workspace]
        connection.sessionStore.switchServer(to: serverId)
        connection.sessionStore.upsert(session(
            id: sessionId,
            status: environment["CHAT_ROUTES_STATUS"] == "busy" ? .busy : .ready
        ))
        enableShare(on: connection)
        connection.chatState.cachedModels = models
        if environment["CHAT_ROUTES_ASK"] == "1" {
            connection.askRequestStore.switchServer(to: serverId)
            _ = connection.askRequestStore.set(ask, for: sessionId)
        }
        return connection
    }

    @MainActor static func enableShare(on connection: ServerConnection) {
        guard connection.chatState.slashCommands.isEmpty else { return }
        connection.chatState.slashCommands = [
            SlashCommand(name: "share", description: "Share session", source: .builtin),
        ]
    }

    /// One staged review comment, the recommended share policy, and the Files
    /// panel on Changed on every launch.
    @MainActor private static func resetLocalState() {
        AppPreferences.Share.setRedactionPolicy(.recommended)
        ChatFileBrowserPanelTabStore.shared.setTab(.changed, for: sessionId)
        let store = ReviewCommentStore()
        store.load(workspaceId: workspace.id, sessionId: sessionId)
        for comment in store.comments {
            store.delete(commentId: comment.id)
        }
        _ = try? store.create(
            workspaceId: workspace.id,
            sessionId: sessionId,
            body: "Route comment",
            reference: ReviewCommentReference(
                source: .timelineText,
                label: "Timeline",
                path: nil,
                side: nil,
                startLine: nil,
                endLine: nil,
                selectedText: "Routes",
                languageHint: nil,
                toolCallId: nil,
                timelineItemId: seedMarkerId,
                url: nil
            )
        )
    }

    static func session(id: String, status: SessionStatus) -> Session {
        Session(
            id: id,
            workspaceId: workspace.id,
            workspaceName: workspace.name,
            name: id == sessionId ? "Routes" : "New routes session",
            status: status,
            createdAt: Date(timeIntervalSince1970: 1_770_000_010),
            lastActivity: Date(timeIntervalSince1970: 1_770_000_020),
            model: "anthropic/claude-routes",
            messageCount: 1,
            tokens: TokenUsage(input: 0, output: 0, cacheRead: nil, cacheWrite: nil),
            cost: 0,
            changeStats: SessionChangeStats(
                mutatingToolCalls: 1,
                filesChanged: 2,
                changedFiles: [changedPath, touchedPath],
                changedFilesOverflow: nil,
                addedLines: 2,
                removedLines: 1
            ),
            contextTokens: 1_000,
            contextWindow: 128_000,
            firstMessage: nil,
            lastMessage: nil,
            thinkingLevel: "medium"
        )
    }

    static let sessionStats: JSONValue = [
        "tokens": ["input": 800, "output": 200, "cacheRead": 0, "cacheWrite": 0, "total": 1_000],
        "cost": 0.01,
        "loadedResources": [
            "skills": [["name": .string(skillName), "description": "Routes through the panel", "path": "/tmp/oppi-chat-routes/.pi/skills/route-skill"]],
            "extensions": [],
        ],
    ]

    static let models = [
        ModelInfo(id: "claude-routes", name: "Claude Routes", provider: "anthropic", contextWindow: 200_000),
        ModelInfo(id: "gpt-routes", name: "GPT Routes", provider: "openai", contextWindow: 200_000),
    ]

    static let ask = AskRequest(
        id: "chat-routes-ask",
        sessionId: sessionId,
        questions: [
            AskQuestion(
                id: "first",
                question: "Which route first?",
                options: [AskOption(value: "sheet", label: "Sheet"), AskOption(value: "popover", label: "Popover")],
                multiSelect: false
            ),
            AskQuestion(
                id: "second",
                question: "Which route next?",
                options: [AskOption(value: "push", label: "Push"), AskOption(value: "column", label: "Column")],
                multiSelect: false
            ),
        ],
        allowCustom: true,
        timeout: nil,
        workspaceId: workspace.id
    )

    static let gitStatus = GitStatus(
        isGitRepo: true,
        branch: "main",
        headSha: commitSha,
        ahead: 0,
        behind: 0,
        dirtyCount: 1,
        untrackedCount: 0,
        stagedCount: 0,
        files: [GitFileStatus(status: " M", path: changedPath, addedLines: 2, removedLines: 1)],
        totalFiles: 1,
        addedLines: 2,
        removedLines: 1,
        stashCount: 0,
        lastCommitMessage: "Route commit",
        lastCommitDate: nil,
        recentCommits: [GitCommitSummary(sha: commitSha, message: "Route commit", date: "2026-10-15T18:00:00Z")]
    )

    /// A user message with a commit pill and a file pill, then filler turns so
    /// the outline has entries.
    @MainActor static func seedTimelineIfNeeded() {
        guard let reducer = timelineReducer(),
              !reducer.items.contains(where: { $0.id == seedMarkerId }) else { return }
        let userText = UserMessageAttachmentPresentation.makeDisplayText(
            text: "Review the routes",
            pendingAttachments: [],
            pendingRepoPointers: [
                PendingFileReference(path: commitSha, isDirectory: false, kind: .gitCommit, commitMessage: "Route commit"),
                PendingFileReference(path: changedPath, isDirectory: false),
            ]
        )
        var events = [traceEvent(id: seedMarkerId, type: .user, text: userText)]
        for turn in 1...4 {
            events.append(traceEvent(id: "chat-routes-assistant-\(turn)", type: .assistant, text: "ROUTES_FILL_\(turn) reply."))
        }
        reducer.loadSession(events)
    }

    private static func traceEvent(id: String, type: TraceEventType, text: String) -> TraceEvent {
        TraceEvent(
            id: id,
            type: type,
            timestamp: "2026-10-15T18:00:00.000Z",
            text: text,
            tool: nil,
            args: nil,
            output: nil,
            toolCallId: nil,
            toolName: nil,
            isError: nil,
            thinking: nil
        )
    }

    /// What a timeline pill tap does: the chat's destination presenter, from
    /// the timeline.
    @MainActor static func openFromTimeline(_ destination: ChatTimelineDestination, connection: ServerConnection) {
        guard let timeline = timelineCollectionInWindows(),
              let presenter = sequence(first: timeline as UIResponder, next: \.next)
                .lazy.compactMap({ $0 as? UIViewController }).first else { return }
        ChatTimelineDestinationPresenter(connection: connection).open(ChatTimelineDestinationRequest(
            destination: destination,
            serverId: serverId,
            workspaceId: workspace.id,
            sessionId: sessionId,
            reviewCommentSelectionScope: nil,
            sourceView: timeline,
            presenter: presenter
        ))
    }

    @MainActor private static func timelineCollectionInWindows() -> UICollectionView? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                if let collection = timelineCollection(in: window) { return collection }
            }
        }
        return nil
    }

    @MainActor private static func timelineReducer() -> TimelineReducer? {
        guard let controller = timelineCollectionInWindows()?.delegate as? ChatTimelineCollectionHost.Controller,
              let configuration = controller.ownedClock.lastConfiguration,
              configuration.sessionId == sessionId else { return nil }
        return configuration.reducer
    }

    @MainActor private static func timelineCollection(in view: UIView) -> UICollectionView? {
        if let collection = view as? UICollectionView, collection.accessibilityIdentifier == "chat.timeline" {
            return collection
        }
        for child in view.subviews {
            if let found = timelineCollection(in: child) { return found }
        }
        return nil
    }

    /// A client whose requests `ChatRoutesURLProtocol` answers in-process.
    @MainActor static let api: APIClient = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatRoutesURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://\(ChatRoutesURLProtocol.host)") ?? URL(fileURLWithPath: "/"),
            token: "preview-token",
            configuration: config
        )
    }()
}

/// The chat's server, for the requests the routes make: Git status, a commit
/// and its diff, a review diff, file text, the workspace root listing, a
/// skill and its file, models, session changes, and a new session (counted).
/// Everything else is a 404.
private final class ChatRoutesURLProtocol: URLProtocol {
    static let host = "chat-routes.oppi"

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let workspace = "/workspaces/chat-routes-ws"
        let body: Data?
        var contentType = "application/json"
        switch (request.httpMethod ?? "GET", url.path) {
        case ("GET", "\(workspace)/git/status"):
            body = try? JSONEncoder().encode(ChatRoutesFixture.gitStatus)
        case ("GET", "\(workspace)/git/commits/abc1234"):
            body = Self.json([
                "sha": "abc1234",
                "message": "Route commit",
                "date": "2026-10-15T18:00:00Z",
                "author": "Chen",
                "files": [["path": "Sources/App.swift", "status": "M", "addedLines": 2, "removedLines": 1]],
                "addedLines": 2,
                "removedLines": 1,
            ])
        case ("GET", "\(workspace)/git/commits/abc1234/diff"), ("GET", "\(workspace)/git/diff"):
            body = Self.json(Self.diff)
        case ("GET", "\(workspace)/quick-actions"):
            body = Self.json(["actions": []])
        case ("GET", "\(workspace)/sessions/chat-routes-session/changes"):
            body = Self.json([
                "workspaceId": "chat-routes-ws",
                "sessionId": "chat-routes-session",
                "files": [["path": "Sources/App.swift"], ["path": "Notes/plan.md"]],
                "changedFileCount": 2,
                "changedFilesOverflow": 0,
            ])
        case ("GET", "\(workspace)/contents"):
            body = Self.json([
                "path": "",
                "entries": [["name": "App.swift", "path": "Sources/App.swift", "type": "file", "size": 20, "modifiedAt": 1_800_000_000_000]],
                "truncated": false,
            ])
        case ("GET", "/skills/route-skill"):
            body = Self.json([
                "skill": ["name": "route-skill", "description": "Routes through the panel", "path": "/tmp/oppi-chat-routes/.pi/skills/route-skill"],
                "content": "# Route skill\n\nOpens inside the Context panel.",
                "files": ["SKILL.md", "notes.md"],
            ])
        case ("GET", "/skills/route-skill/file"):
            body = Self.json(["content": "Route skill notes\n"])
        case ("GET", "\(workspace)/paths"):
            body = Self.json(["paths": ["Sources/App.swift"], "truncated": false])
        case ("GET", "/files/current"):
            contentType = "text/plain"
            body = Data("let route = \"chat\"\n".utf8)
        case ("GET", "/models"):
            body = Self.json([
                "models": ChatRoutesFixture.models.map { model in
                    ["id": model.id, "name": model.name, "provider": model.provider, "contextWindow": model.contextWindow, "isDefault": false]
                },
            ])
        case ("POST", "\(workspace)/sessions"):
            struct Created: Encodable { let session: Session }
            body = try? JSONEncoder().encode(Created(
                session: ChatRoutesFixture.session(id: "chat-routes-new-session", status: .ready)
            ))
            Task { @MainActor in ChatRoutesStubRecord.shared.createdSessions += 1 }
        default:
            body = nil
        }
        guard let http = HTTPURLResponse(
            url: url,
            statusCode: body == nil ? 404 : 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data(#"{"error":"Not found"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static var diff: [String: Any] { [
        "workspaceId": "chat-routes-ws",
        "path": "Sources/App.swift",
        "baselineText": "let route = \"swiftui\"\n",
        "currentText": "let route = \"uikit\"\n",
        "addedLines": 1,
        "removedLines": 1,
        "hunks": [
            [
                "oldStart": 1,
                "oldCount": 1,
                "newStart": 1,
                "newCount": 1,
                "lines": [
                    ["kind": "removed", "text": "let route = \"swiftui\"", "oldLine": 1, "newLine": NSNull(), "spans": NSNull()],
                    ["kind": "added", "text": "let route = \"uikit\"", "oldLine": NSNull(), "newLine": 1, "spans": NSNull()],
                ],
            ],
        ],
    ] }

    private static func json(_ object: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }
}
#endif
