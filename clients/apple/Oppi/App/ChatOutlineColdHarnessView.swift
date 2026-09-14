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
    @State private var connection = ChatOutlineColdHarnessView.makeConnection()
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

    private func diagnostic(_ id: String, _ value: String) -> some View {
        Text(value)
            .font(.system(size: 8))
            .opacity(0.02)
            .accessibilityIdentifier(id)
            .accessibilityValue(value)
            .accessibilityLabel(id)
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
                if window.rootViewController?.presentedViewController != nil {
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
#endif
