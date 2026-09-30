import Foundation
import UIKit
@testable import Oppi

/// Find the first view of a specific type anywhere in the view hierarchy.
@MainActor
func timelineFirstView<T: UIView>(ofType type: T.Type, in root: UIView) -> T? {
    if let match = root as? T { return match }
    for child in root.subviews {
        if let found = timelineFirstView(ofType: type, in: child) { return found }
    }
    return nil
}

@MainActor
struct TimelineTestHarness {
    let sessionId: String
    let coordinator: ChatTimelineCollectionHost.Controller
    let collectionView: UICollectionView
    let reducer: TimelineReducer
    let toolOutputStore: ToolOutputStore
    let toolArgsStore: ToolArgsStore
    let toolSegmentStore: ToolSegmentStore
    let connection: ServerConnection
    let scrollController: ChatScrollController
    let audioPlayer: AudioPlayerService
}

@MainActor
extension TimelineTestHarness {
    func applyAndLayout(
        items: [ChatItem] = [
            .toolCall(
                id: "tool-1",
                tool: "bash",
                argsSummary: "echo hi",
                outputPreview: "hi",
                outputByteCount: 128,
                isError: false,
                isDone: true
            ),
        ],
        hiddenCount: Int = 0,
        renderWindowStep: Int = 50,
        isBusy: Bool = false,
        streamingAssistantID: String? = nil,
        onShowEarlier: @escaping () -> Void = {}
    ) {
        let config = makeTimelineConfiguration(
            items: items,
            hiddenCount: hiddenCount,
            renderWindowStep: renderWindowStep,
            isBusy: isBusy,
            streamingAssistantID: streamingAssistantID,
            onShowEarlier: onShowEarlier,
            sessionId: sessionId,
            reducer: reducer,
            toolOutputStore: toolOutputStore,
            toolArgsStore: toolArgsStore,
            toolSegmentStore: toolSegmentStore,
            connection: connection,
            scrollController: scrollController,
            audioPlayer: audioPlayer
        )
        coordinator.apply(configuration: config, to: collectionView)
        collectionView.layoutIfNeeded()
    }
}

@MainActor
struct WindowedTimelineHarness {
    let window: UIWindow
    let harness: TimelineTestHarness

    var sessionId: String { harness.sessionId }
    var coordinator: ChatTimelineCollectionHost.Controller { harness.coordinator }
    var collectionView: UICollectionView { harness.collectionView }
    var reducer: TimelineReducer { harness.reducer }
    var toolOutputStore: ToolOutputStore { harness.toolOutputStore }
    var toolArgsStore: ToolArgsStore { harness.toolArgsStore }
    var scrollController: ChatScrollController { harness.scrollController }

    func applyItems(
        _ items: [ChatItem],
        hiddenCount: Int = 0,
        renderWindowStep: Int = 50,
        isBusy: Bool = true,
        streamingID: String? = nil,
        onShowEarlier: @escaping () -> Void = {}
    ) {
        harness.applyAndLayout(
            items: items,
            hiddenCount: hiddenCount,
            renderWindowStep: renderWindowStep,
            isBusy: isBusy,
            streamingAssistantID: streamingID,
            onShowEarlier: onShowEarlier
        )
    }

}

@MainActor
func makeWindowedTimelineHarness(
    sessionId: String,
    frame: CGRect = CGRect(x: 0, y: 0, width: 390, height: 844),
    useAnchoredCollectionView: Bool = true
) -> WindowedTimelineHarness {
    let window = UIWindow(frame: frame)
    let layout = ChatTimelineCollectionHost.makeTestLayout()
    let collectionView: UICollectionView

    if useAnchoredCollectionView {
        collectionView = AnchoredCollectionView(frame: window.bounds, collectionViewLayout: layout)
    } else {
        collectionView = UICollectionView(frame: window.bounds, collectionViewLayout: layout)
    }

    collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(collectionView)
    window.makeKeyAndVisible()

    let harness = makeTimelineHarness(sessionId: sessionId, collectionView: collectionView)
    return WindowedTimelineHarness(window: window, harness: harness)
}

@MainActor
private func makeTimelineHarness(sessionId: String, collectionView: UICollectionView) -> TimelineTestHarness {
    let coordinator = ChatTimelineCollectionHost.Controller()
    coordinator.configureDataSource(collectionView: collectionView)

    let reducer = TimelineReducer()
    let toolOutputStore = ToolOutputStore()
    let toolArgsStore = ToolArgsStore()
    let toolSegmentStore = ToolSegmentStore()
    let connection = ServerConnection()
    let scrollController = ChatScrollController()
    let audioPlayer = AudioPlayerService()

    let initial = makeTimelineConfiguration(
        sessionId: sessionId,
        reducer: reducer,
        toolOutputStore: toolOutputStore,
        toolArgsStore: toolArgsStore,
        toolSegmentStore: toolSegmentStore,
        connection: connection,
        scrollController: scrollController,
        audioPlayer: audioPlayer
    )
    coordinator.apply(configuration: initial, to: collectionView)

    return TimelineTestHarness(
        sessionId: sessionId,
        coordinator: coordinator,
        collectionView: collectionView,
        reducer: reducer,
        toolOutputStore: toolOutputStore,
        toolArgsStore: toolArgsStore,
        toolSegmentStore: toolSegmentStore,
        connection: connection,
        scrollController: scrollController,
        audioPlayer: audioPlayer
    )
}

@MainActor
func makeTimelineConfiguration(
    items: [ChatItem] = [
        .toolCall(
            id: "tool-1",
            tool: "bash",
            argsSummary: "echo hi",
            outputPreview: "hi",
            outputByteCount: 128,
            isError: false,
            isDone: true
        ),
    ],
    hiddenCount: Int = 0,
    renderWindowStep: Int = 50,
    isBusy: Bool = false,
    streamingAssistantID: String? = nil,
    onShowEarlier: @escaping () -> Void = {},
    scrollCommand: ChatTimelineScrollCommand? = nil,
    sessionId: String,
    reducer: TimelineReducer,
    toolOutputStore: ToolOutputStore,
    toolArgsStore: ToolArgsStore,
    toolSegmentStore: ToolSegmentStore = ToolSegmentStore(),
    connection: ServerConnection,
    scrollController: ChatScrollController,
    audioPlayer: AudioPlayerService,
    topOverlap: CGFloat = 0,
    bottomOverlap: CGFloat = 0
) -> ChatTimelineCollectionHost.Configuration {
    ChatTimelineCollectionHost.Configuration(
        items: items,
        hiddenCount: hiddenCount,
        renderWindowStep: renderWindowStep,
        isBusy: isBusy,
        streamingAssistantID: streamingAssistantID,
        sessionId: sessionId,
        workspaceId: "ws-test",
        onFork: { _ in },
        onBackSwipe: {},
        onShowEarlier: onShowEarlier,
        scrollCommand: scrollCommand,
        scrollController: scrollController,
        reducer: reducer,
        toolOutputStore: toolOutputStore,
        toolArgsStore: toolArgsStore,
        toolSegmentStore: toolSegmentStore,
        sessionContent: connection.sessionContent,
        iconAssetCache: connection.iconAssetCache,
        audioPlayer: audioPlayer,
        topOverlap: topOverlap,
        bottomOverlap: bottomOverlap
    )
}

func makeTimelineToolConfiguration(
    itemID: String = "tool-test",
    title: String = "$ bash",
    preview: String? = nil,
    expandedContent: ToolPresentationBuilder.ToolExpandedContent? = nil,
    copyCommandText: String? = nil,
    copyOutputText: String? = nil,
    languageBadge: String? = nil,
    trailing: String? = nil,
    toolNamePrefix: String? = "$",
    toolNameColor: UIColor = .systemGreen,
    collapsedImageBase64: String? = nil,
    collapsedImageMimeType: String? = nil,
    isExpanded: Bool,
    isDone: Bool = true,
    isError: Bool = false
) -> ToolTimelineRowConfiguration {
    ToolTimelineRowConfiguration(
        itemID: itemID,
        title: title,
        preview: preview,
        expandedContent: expandedContent,
        copyCommandText: copyCommandText,
        copyOutputText: copyOutputText,
        languageBadge: languageBadge,
        trailing: trailing,
        titleLineBreakMode: .byTruncatingTail,
        toolNamePrefix: toolNamePrefix,
        toolNameColor: toolNameColor,
        editAdded: nil,
        editRemoved: nil,
        collapsedImageBase64: collapsedImageBase64,
        collapsedImageMimeType: collapsedImageMimeType,
        isExpanded: isExpanded,
        isDone: isDone,
        isError: isError,
        startedAt: nil,
        elapsedSeconds: nil,
        segmentAttributedTitle: nil,
        segmentAttributedTrailing: nil
    )
}

@MainActor
func fittedTimelineSize(for view: UIView, width: CGFloat) -> CGSize {
    let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 800))
    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)

    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        view.topAnchor.constraint(equalTo: container.topAnchor),
    ])

    container.setNeedsLayout()
    container.layoutIfNeeded()

    return view.systemLayoutSizeFitting(
        CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
        withHorizontalFittingPriority: .required,
        verticalFittingPriority: .fittingSizeLevel
    )
}
