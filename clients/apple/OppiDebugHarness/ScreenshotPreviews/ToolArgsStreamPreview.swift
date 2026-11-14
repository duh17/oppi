#if DEBUG
import UIKit

// MARK: - Tool Arguments Stream Preview

/// `SCREENSHOT_SCREEN=tool-args-stream`: one generic tool call whose arguments
/// stream in through the real reducer, the `toolUpdate` events the server sends
/// while the model writes them, painted by the chat timeline as an expanded
/// row. The call has no input roles, so the row shows its arguments as YAML.
/// A long `task` argument grows 12 characters every 50 ms (about 30 s); the
/// call then starts, prints one line, and finishes. A double tap on the row
/// pushes the full-screen reader over the timeline, as chat does.
///
/// `toolArgsStream.state` reads `streaming` until the arguments are complete,
/// then `done` once the call has finished.
final class ToolArgsStreamPreviewController: PreviewRootController {
    init(root: AppRootEnvironment) {
        super.init(
            root: root,
            themeStore: root.themeStore,
            content: PreviewHost.screenStack(root: root) { ToolArgsStreamTimelineController(root: root) }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

private final class ToolArgsStreamTimelineController: UIViewController, NavigationBarHiding {
    private static let sessionID = "preview-args-stream"
    private static let toolID = "spawn-worker"
    private static let tool = "subagent"
    private static let chunk = 12

    var hidesNavigationBar: Bool { true }

    private let root: AppRootEnvironment
    private let connection = ServerConnection()
    private let reducer = TimelineReducer()
    private let scrollController = ChatScrollController()
    private let timeline = ChatTimelineController()
    private let payloadStore = ChatReaderPayloadStore()
    private let navigation = SceneNavigation()
    private let stateLabel = UILabel()
    private var collectionView: UICollectionView?
    private var streamTimer: Timer?
    private var streamedCount = 0

    init(root: AppRootEnvironment) {
        self.root = root
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        streamTimer?.invalidate()
        if let collectionView {
            timeline.dismantle(collectionView)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .themeBg
        _ = reducer.appendUserMessage("Spawn a worker to make the thinking menus match.")
        reducer.process(.agentStart(sessionId: Self.sessionID))
        sendArguments()
        reducer.expandedItemIDs.insert(Self.toolID)

        timeline.contentRoot = root
        let collectionView = timeline.makeCollectionView(configuration: makeConfiguration(), contentRoot: root)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        stateLabel.accessibilityIdentifier = "toolArgsStream.state"
        stateLabel.font = .preferredFont(forTextStyle: .caption2)
        stateLabel.textColor = .themeComment
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stateLabel)

        NSLayoutConstraint.activate([
            stateLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            stateLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            collectionView.topAnchor.constraint(equalTo: stateLabel.bottomAnchor, constant: 4),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.collectionView = collectionView
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard streamTimer == nil, streamedCount < Self.task.count else { return }
        streamTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.streamNextChunk() }
        }
    }

    // MARK: Stream

    private func streamNextChunk() {
        streamedCount = min(Self.task.count, streamedCount + Self.chunk)
        sendArguments()
        if streamedCount == Self.task.count {
            streamTimer?.invalidate()
            streamTimer = nil
            finishCall()
        }
        render()
    }

    private func sendArguments() {
        reducer.process(.toolUpdate(
            sessionId: Self.sessionID,
            toolEventId: Self.toolID,
            tool: Self.tool,
            args: arguments(taskLength: streamedCount)
        ))
    }

    private func finishCall() {
        reducer.process(.toolStart(
            sessionId: Self.sessionID,
            toolEventId: Self.toolID,
            tool: Self.tool,
            args: arguments(taskLength: Self.task.count)
        ))
        reducer.process(.toolOutput(ToolOutputEventPayload(
            sessionId: Self.sessionID,
            toolEventId: Self.toolID,
            output: "Spawned thinking-menu-order (anthropic/claude-sonnet-5-5).",
            isError: false
        )))
        reducer.process(.toolEnd(sessionId: Self.sessionID, toolEventId: Self.toolID))
    }

    private func arguments(taskLength: Int) -> [String: JSONValue] {
        var args: [String: JSONValue] = [
            "action": .string("spawn"),
            "model": .string("anthropic/claude-sonnet-5-5"),
            "name": .string("thinking-menu-order"),
        ]
        if taskLength > 0 {
            args["task"] = .string(String(Self.task.prefix(taskLength)))
        }
        return args
    }

    private var isStreaming: Bool { streamedCount < Self.task.count }

    // MARK: Timeline

    private func render() {
        stateLabel.text = isStreaming ? "streaming" : "done"
        guard let collectionView else { return }
        timeline.update(configuration: makeConfiguration(), collectionView: collectionView)
    }

    private func makeConfiguration() -> ChatTimelineConfiguration {
        ChatTimelineConfiguration(
            items: reducer.items,
            hiddenCount: 0,
            renderWindowStep: 60,
            streamingAssistantID: nil,
            sessionId: Self.sessionID,
            workspaceId: "preview-workspace",
            onFork: { _ in },
            onOpenChatReader: { [weak self] payload in self?.openReader(payload) },
            onBackSwipe: {},
            onShowEarlier: {},
            scrollController: scrollController,
            reducer: reducer,
            toolOutputStore: reducer.toolOutputStore,
            toolArgsStore: reducer.toolArgsStore,
            toolSegmentStore: reducer.toolSegmentStore,
            toolDetailsStore: reducer.toolDetailsStore,
            sessionContent: connection.sessionContent,
            iconAssetCache: connection.iconAssetCache,
            audioPlayer: connection.audioPlayer
        )
    }

    private func openReader(_ payload: ChatReaderPayload) {
        payloadStore.removeAll()
        let route = payloadStore.store(payload)
        Router.push(ChatReaderViewController(target: route, store: payloadStore, navigation: navigation), from: self)
    }

    /// A worker brief as long as the ones a lead writes: short lines in
    /// steps with blank lines between them, so the YAML block scalar grows
    /// down the reader whether or not it wraps.
    private static let task: String = {
        let paragraph = """
        Find both menus: the Quick Session composer and the chat composer,
        at iPad regular width and iPhone compact, and why the order differs.
        Likely one builds its UIMenu with preferredMenuElementOrder automatic,
        which reverses items above a bottom-positioned button,
        and the other uses fixed.
        """
        return (1 ... 24).map { "Step \($0). " + paragraph }.joined(separator: "\n\n") + "\n\nEnd of brief."
    }()
}
#endif
