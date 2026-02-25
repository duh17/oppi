import Foundation
import Testing
import UIKit
@testable import Oppi

@MainActor
func timelineAllLabels(in root: UIView) -> [UILabel] {
    var labels: [UILabel] = []
    if let label = root as? UILabel {
        labels.append(label)
    }

    for child in root.subviews {
        labels.append(contentsOf: timelineAllLabels(in: child))
    }

    return labels
}

@MainActor
func timelineAllViews(in root: UIView) -> [UIView] {
    var views: [UIView] = [root]
    for child in root.subviews {
        views.append(contentsOf: timelineAllViews(in: child))
    }
    return views
}

@MainActor
func timelineAllTextViews(in root: UIView) -> [UITextView] {
    var textViews: [UITextView] = []
    if let textView = root as? UITextView {
        textViews.append(textView)
    }

    for child in root.subviews {
        textViews.append(contentsOf: timelineAllTextViews(in: child))
    }

    return textViews
}

/// Find the first UITextView anywhere in the view hierarchy.
@MainActor
func timelineFirstTextView(in root: UIView) -> UITextView? {
    timelineAllTextViews(in: root).first
}

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
func timelineAllImageViews(in root: UIView) -> [UIImageView] {
    var views: [UIImageView] = []
    if let iv = root as? UIImageView { views.append(iv) }
    for child in root.subviews { views.append(contentsOf: timelineAllImageViews(in: child)) }
    return views
}

@MainActor
func timelineAllGestureRecognizers(in root: UIView) -> [UIGestureRecognizer] {
    var recognizers: [UIGestureRecognizer] = root.gestureRecognizers ?? []
    for child in root.subviews {
        recognizers.append(contentsOf: timelineAllGestureRecognizers(in: child))
    }
    return recognizers
}

@MainActor
func assertHasDoubleTapGesture(in root: UIView) {
    let recognizers = timelineAllGestureRecognizers(in: root)
    let hasDoubleTap = recognizers.contains {
        guard let tap = $0 as? UITapGestureRecognizer else { return false }
        return tap.numberOfTapsRequired == 2
    }
    #expect(hasDoubleTap)
}

@MainActor
func timelineAllScrollViews(in root: UIView) -> [UIScrollView] {
    var views: [UIScrollView] = []
    if let scrollView = root as? UIScrollView { views.append(scrollView) }
    for child in root.subviews { views.append(contentsOf: timelineAllScrollViews(in: child)) }
    return views
}

@MainActor
func timelineRenderedText(of label: UILabel) -> String {
    label.attributedText?.string ?? label.text ?? ""
}

@MainActor
func timelineActionTitles(in menu: UIMenu) -> [String] {
    menu.children.compactMap { ($0 as? UIAction)?.title }
}

actor TimelineFetchProbe {
    private var startedCount = 0
    private var canceledCount = 0

    func markStarted() {
        startedCount += 1
    }

    func markCanceled() {
        canceledCount += 1
    }

    func snapshot() -> (started: Int, canceled: Int) {
        (startedCount, canceledCount)
    }
}

@MainActor
final class TimelineScrollMetricsCollectionView: UICollectionView {
    var testContentSize: CGSize = .zero
    var testAdjustedContentInset: UIEdgeInsets = .zero
    var testVisibleIndexPaths: [IndexPath] = []
    var testIsTracking = false
    var testIsDragging = false
    var testIsDecelerating = false

    override var contentSize: CGSize {
        get { testContentSize }
        set { testContentSize = newValue }
    }

    override var adjustedContentInset: UIEdgeInsets {
        testAdjustedContentInset
    }

    override var indexPathsForVisibleItems: [IndexPath] {
        testVisibleIndexPaths
    }

    override var isTracking: Bool {
        testIsTracking
    }

    override var isDragging: Bool {
        testIsDragging
    }

    override var isDecelerating: Bool {
        testIsDecelerating
    }

    init(frame: CGRect) {
        super.init(frame: frame, collectionViewLayout: UICollectionViewFlowLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
func timelineOffsetY(forDistanceFromBottom distance: CGFloat, in collectionView: TimelineScrollMetricsCollectionView) -> CGFloat {
    let insets = collectionView.adjustedContentInset
    let visibleHeight = collectionView.bounds.height - insets.top - insets.bottom
    return max(-insets.top, collectionView.contentSize.height - visibleHeight - distance)
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
    var toolSegmentStore: ToolSegmentStore { harness.toolSegmentStore }
    var connection: ServerConnection { harness.connection }
    var scrollController: ChatScrollController { harness.scrollController }
    var audioPlayer: AudioPlayerService { harness.audioPlayer }

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
func makeTimelineHarness(sessionId: String) -> TimelineTestHarness {
    let collectionView = UICollectionView(
        frame: CGRect(x: 0, y: 0, width: 390, height: 844),
        collectionViewLayout: UICollectionViewFlowLayout()
    )

    return makeTimelineHarness(sessionId: sessionId, collectionView: collectionView)
}

@MainActor
func makeWindowedTimelineHarness(
    sessionId: String,
    frame: CGRect = CGRect(x: 0, y: 0, width: 390, height: 844),
    useAnchoredCollectionView: Bool = false
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
    sessionId: String,
    reducer: TimelineReducer,
    toolOutputStore: ToolOutputStore,
    toolArgsStore: ToolArgsStore,
    toolSegmentStore: ToolSegmentStore = ToolSegmentStore(),
    connection: ServerConnection,
    scrollController: ChatScrollController,
    audioPlayer: AudioPlayerService
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
        onOpenFile: { _ in },
        onShowEarlier: onShowEarlier,
        scrollCommand: nil,
        scrollController: scrollController,
        reducer: reducer,
        toolOutputStore: toolOutputStore,
        toolArgsStore: toolArgsStore,
        toolSegmentStore: toolSegmentStore,
        connection: connection,
        audioPlayer: audioPlayer,
        theme: .dark,
        themeID: .dark
    )
}

@MainActor
func configuredTimelineCell(
    in collectionView: UICollectionView,
    item: Int,
    section: Int = 0
) throws -> UICollectionViewCell {
    let indexPath = IndexPath(item: item, section: section)

    // Never call dataSource.collectionView(_:cellForItemAt:) directly in tests.
    // UIKit expects dequeued cells to flow through its normal display pipeline;
    // bypassing that can trip diffable snapshot assertions on reconfigure.
    collectionView.layoutIfNeeded()
    if let cell = collectionView.cellForItem(at: indexPath) {
        return cell
    }

    collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
    collectionView.layoutIfNeeded()

    return try #require(collectionView.cellForItem(at: indexPath))
}

@MainActor
func expectTimelineRowsUseConfigurationType<T>(
    in collectionView: UICollectionView,
    items: [Int],
    section: Int = 0,
    as type: T.Type
) throws {
    for item in items {
        let cell = try configuredTimelineCell(in: collectionView, item: item, section: section)
        #expect(cell.contentConfiguration is T, "Expected \(type) at item \(item)")
    }
}

func waitForTimelineCondition(
    timeoutMs: Int,
    pollMs: Int = 10,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMs))

    while ContinuousClock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(pollMs))
    }

    return await condition()
}

func makeTimelineToolConfiguration(
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
        segmentAttributedTitle: nil,
        segmentAttributedTrailing: nil
    )
}

func makeTimelineAssistantConfiguration(
    text: String = "Assistant response with https://example.com",
    canFork: Bool = false,
    onFork: (() -> Void)? = nil
) -> AssistantTimelineRowConfiguration {
    AssistantTimelineRowConfiguration(
        text: text,
        isStreaming: false,
        canFork: canFork,
        onFork: onFork,
        themeID: .dark
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

@MainActor
func fittedTimelineSizeWithoutPrelayout(for view: UIView, width: CGFloat) -> CGSize {
    let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 800))
    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)

    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        view.topAnchor.constraint(equalTo: container.topAnchor),
    ])

    // Intentionally skip layoutIfNeeded to mirror the first self-sizing pass,
    // where scrollView.frameLayoutGuide widths can still be zero.
    return view.systemLayoutSizeFitting(
        CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
        withHorizontalFittingPriority: .required,
        verticalFittingPriority: .fittingSizeLevel
    )
}
