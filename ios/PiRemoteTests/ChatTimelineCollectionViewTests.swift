import Foundation
import Testing
import UIKit
@testable import PiRemote

@Suite("ChatTimelineCollectionView.Coordinator")
struct ChatTimelineCollectionViewCoordinatorTests {

    @MainActor
    @Test func uniqueItemsKeepingLastRetainsLatestDuplicate() {
        let first = ChatItem.systemEvent(id: "dup", message: "first")
        let middle = ChatItem.error(id: "middle", message: "middle")
        let second = ChatItem.systemEvent(id: "dup", message: "second")

        let result = ChatTimelineCollectionView.Coordinator.uniqueItemsKeepingLast([first, middle, second])

        #expect(result.orderedIDs == ["middle", "dup"])
        #expect(result.itemByID["dup"] == second)
        #expect(result.itemByID["middle"] == middle)
    }

    @MainActor
    @Test func toolOutputCompletionDispositionGuardsStaleAndCanceledStates() {
        #expect(
            ChatTimelineCollectionView.Coordinator.toolOutputCompletionDisposition(
                output: "ok",
                isTaskCancelled: false,
                activeSessionID: "s1",
                currentSessionID: "s1",
                itemExists: true
            ) == .apply
        )

        #expect(
            ChatTimelineCollectionView.Coordinator.toolOutputCompletionDisposition(
                output: "ok",
                isTaskCancelled: true,
                activeSessionID: "s1",
                currentSessionID: "s1",
                itemExists: true
            ) == .canceled
        )

        #expect(
            ChatTimelineCollectionView.Coordinator.toolOutputCompletionDisposition(
                output: "ok",
                isTaskCancelled: false,
                activeSessionID: "s1",
                currentSessionID: "s2",
                itemExists: true
            ) == .staleSession
        )

        #expect(
            ChatTimelineCollectionView.Coordinator.toolOutputCompletionDisposition(
                output: "ok",
                isTaskCancelled: false,
                activeSessionID: "s1",
                currentSessionID: "s1",
                itemExists: false
            ) == .missingItem
        )

        #expect(
            ChatTimelineCollectionView.Coordinator.toolOutputCompletionDisposition(
                output: "",
                isTaskCancelled: false,
                activeSessionID: "s1",
                currentSessionID: "s1",
                itemExists: true
            ) == .emptyOutput
        )
    }

    @MainActor
    @Test func sessionSwitchCancelsInFlightToolOutputLoad() async {
        let harness = makeHarness(sessionId: "session-a")
        let probe = FetchProbe()

        harness.coordinator._fetchToolOutputForTesting = { _, _ in
            await probe.markStarted()
            do {
                try await Task.sleep(for: .seconds(5))
                return "late output"
            } catch is CancellationError {
                await probe.markCanceled()
                throw CancellationError()
            }
        }

        harness.coordinator._triggerLoadFullToolOutputForTesting(
            itemID: "tool-1",
            outputByteCount: 128,
            in: harness.collectionView
        )

        #expect(await waitForCondition(timeoutMs: 600) {
            await MainActor.run {
                harness.coordinator._toolOutputLoadTaskCountForTesting == 1
            }
        })

        let sessionB = makeConfiguration(
            sessionId: "session-b",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: sessionB, to: harness.collectionView)

        #expect(await waitForCondition(timeoutMs: 800) {
            let counts = await probe.snapshot()
            let taskCount = await MainActor.run {
                harness.coordinator._toolOutputLoadTaskCountForTesting
            }
            return counts.canceled == 1 && taskCount == 0
        })

        #expect(harness.coordinator._loadingToolOutputIDsForTesting.isEmpty)
        #expect(harness.toolOutputStore.fullOutput(for: "tool-1").isEmpty)
        #expect(harness.coordinator._toolOutputCanceledCountForTesting >= 1)
    }

    @MainActor
    @Test func removedItemCancelsInFlightToolOutputLoad() async {
        let harness = makeHarness(sessionId: "session-a")
        let probe = FetchProbe()

        harness.coordinator._fetchToolOutputForTesting = { _, _ in
            await probe.markStarted()
            do {
                try await Task.sleep(for: .seconds(5))
                return "late output"
            } catch is CancellationError {
                await probe.markCanceled()
                throw CancellationError()
            }
        }

        harness.coordinator._triggerLoadFullToolOutputForTesting(
            itemID: "tool-1",
            outputByteCount: 128,
            in: harness.collectionView
        )

        #expect(await waitForCondition(timeoutMs: 600) {
            await MainActor.run {
                harness.coordinator._toolOutputLoadTaskCountForTesting == 1
            }
        })

        let removed = makeConfiguration(
            items: [],
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: removed, to: harness.collectionView)

        #expect(await waitForCondition(timeoutMs: 800) {
            let counts = await probe.snapshot()
            let taskCount = await MainActor.run {
                harness.coordinator._toolOutputLoadTaskCountForTesting
            }
            return counts.canceled == 1 && taskCount == 0
        })

        #expect(harness.coordinator._loadingToolOutputIDsForTesting.isEmpty)
        #expect(harness.toolOutputStore.fullOutput(for: "tool-1").isEmpty)
        #expect(harness.coordinator._toolOutputCanceledCountForTesting >= 1)
    }

    @MainActor
    @Test func successfulToolOutputFetchAppendsAndClearsTaskState() async {
        let harness = makeHarness(sessionId: "session-a")

        harness.coordinator._fetchToolOutputForTesting = { _, _ in
            try await Task.sleep(for: .milliseconds(20))
            return "full output body"
        }

        harness.coordinator._triggerLoadFullToolOutputForTesting(
            itemID: "tool-1",
            outputByteCount: 128,
            in: harness.collectionView
        )

        #expect(await waitForCondition(timeoutMs: 800) {
            await MainActor.run {
                harness.toolOutputStore.fullOutput(for: "tool-1") == "full output body"
            }
        })

        #expect(harness.coordinator._toolOutputAppliedCountForTesting == 1)
        #expect(harness.coordinator._toolOutputStaleDiscardCountForTesting == 0)
        #expect(harness.coordinator._toolOutputLoadTaskCountForTesting == 0)
        #expect(harness.coordinator._loadingToolOutputIDsForTesting.isEmpty)
    }
}

@Suite("ToolTimelineRowContentView")
struct ToolTimelineRowContentViewTests {

    @MainActor
    @Test func emptyCollapsedBodyProducesFiniteCompactHeight() {
        let config = makeToolConfiguration(isExpanded: false)
        let view = ToolTimelineRowContentView(configuration: config)

        let size = fittedSize(for: view, width: 370)

        #expect(size.width.isFinite)
        #expect(size.height.isFinite)
        #expect(size.height > 0)
        #expect(size.height < 220)
    }

    @MainActor
    @Test func emptyExpandedBodyProducesFiniteCompactHeight() {
        let config = makeToolConfiguration(
            expandedText: nil,
            expandedCommandText: nil,
            expandedOutputText: nil,
            showSeparatedCommandAndOutput: true,
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        let size = fittedSize(for: view, width: 370)

        #expect(size.width.isFinite)
        #expect(size.height.isFinite)
        #expect(size.height > 0)
        #expect(size.height < 220)
    }

    @MainActor
    @Test func transitionFromExpandedContentToEmptyBodyStaysFinite() {
        let expanded = makeToolConfiguration(
            expandedCommandText: "echo hi",
            expandedOutputText: "hi",
            showSeparatedCommandAndOutput: true,
            isExpanded: true
        )
        let emptyExpanded = makeToolConfiguration(
            expandedCommandText: nil,
            expandedOutputText: nil,
            showSeparatedCommandAndOutput: true,
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: expanded)
        _ = fittedSize(for: view, width: 370)

        view.configuration = emptyExpanded
        let size = fittedSize(for: view, width: 370)

        #expect(size.width.isFinite)
        #expect(size.height.isFinite)
        #expect(size.height > 0)
        #expect(size.height < 220)
    }
}

@Suite("AssistantTimelineRowContentView")
struct AssistantTimelineRowContentViewTests {
    @MainActor
    @Test func enablesLinkDataDetectors() throws {
        let view = AssistantTimelineRowContentView(configuration: makeAssistantConfiguration())
        let textView = try #require(view.subviews.compactMap { $0 as? UITextView }.first)

        #expect(textView.dataDetectorTypes.contains(.link))
    }

    @MainActor
    @Test func injectsCustomSchemeLinkAttribute() throws {
        let customURL = "oppi://pair?invite=test_payload"
        let text = "Use \(customURL) to connect"
        let view = AssistantTimelineRowContentView(configuration: makeAssistantConfiguration(text: text))
        let textView = try #require(view.subviews.compactMap { $0 as? UITextView }.first)

        let nsText = text as NSString
        let range = nsText.range(of: customURL)
        #expect(range.location != NSNotFound)

        let linkedValue = textView.attributedText.attribute(.link, at: range.location, effectiveRange: nil)
        let linkedURL = try #require(linkedValue as? URL)
        #expect(linkedURL.absoluteString == customURL)
    }

    @MainActor
    @Test func excludesTrailingBacktickFromCustomSchemeLinkAttribute() throws {
        let customURL = "oppi://pair?invite=test_payload"
        let text = "Use `\(customURL)` to connect"
        let view = AssistantTimelineRowContentView(configuration: makeAssistantConfiguration(text: text))
        let textView = try #require(view.subviews.compactMap { $0 as? UITextView }.first)

        let nsText = text as NSString
        let range = nsText.range(of: customURL)
        #expect(range.location != NSNotFound)

        let linkedValue = textView.attributedText.attribute(.link, at: range.location, effectiveRange: nil)
        let linkedURL = try #require(linkedValue as? URL)
        #expect(linkedURL.absoluteString == customURL)

        let trailingBacktickIndex = range.location + range.length
        let trailingBacktickLink = textView.attributedText.attribute(.link, at: trailingBacktickIndex, effectiveRange: nil)
        #expect(trailingBacktickLink == nil)
    }

    @MainActor
    @Test func interceptsInviteLinksAndRoutesInternally() throws {
        let view = AssistantTimelineRowContentView(configuration: makeAssistantConfiguration())
        let url = try #require(URL(string: "oppi://connect?v=2&invite=test-payload"))

        final class URLCapture: @unchecked Sendable {
            var value: URL?
        }
        let observed = URLCapture()

        let observer = NotificationCenter.default.addObserver(
            forName: .inviteDeepLinkTapped,
            object: nil,
            queue: nil
        ) { notification in
            observed.value = notification.object as? URL
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let shouldOpenExternally = view.textView(
            UITextView(),
            shouldInteractWith: url,
            in: NSRange(location: 0, length: 0),
            interaction: .invokeDefaultAction
        )

        #expect(!shouldOpenExternally)
        #expect(observed.value == url)
    }

    @MainActor
    @Test func allowsHttpLinksToOpenWithSystemDefault() throws {
        let view = AssistantTimelineRowContentView(configuration: makeAssistantConfiguration())
        let url = try #require(URL(string: "https://example.com/docs"))

        final class URLCapture: @unchecked Sendable {
            var value: URL?
        }
        let observed = URLCapture()

        let observer = NotificationCenter.default.addObserver(
            forName: .inviteDeepLinkTapped,
            object: nil,
            queue: nil
        ) { notification in
            observed.value = notification.object as? URL
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let shouldOpenExternally = view.textView(
            UITextView(),
            shouldInteractWith: url,
            in: NSRange(location: 0, length: 0),
            interaction: .invokeDefaultAction
        )

        #expect(shouldOpenExternally)
        #expect(observed.value == nil)
    }
}

private actor FetchProbe {
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

private struct TimelineHarness {
    let coordinator: ChatTimelineCollectionView.Coordinator
    let collectionView: UICollectionView
    let reducer: TimelineReducer
    let toolOutputStore: ToolOutputStore
    let toolArgsStore: ToolArgsStore
    let connection: ServerConnection
    let scrollController: ChatScrollController
    let audioPlayer: AudioPlayerService
}

@MainActor
private func makeHarness(sessionId: String) -> TimelineHarness {
    let collectionView = UICollectionView(
        frame: CGRect(x: 0, y: 0, width: 390, height: 844),
        collectionViewLayout: UICollectionViewFlowLayout()
    )
    let coordinator = ChatTimelineCollectionView.Coordinator()
    coordinator.configureDataSource(collectionView: collectionView)

    let reducer = TimelineReducer()
    let toolOutputStore = ToolOutputStore()
    let toolArgsStore = ToolArgsStore()
    let connection = ServerConnection()
    let scrollController = ChatScrollController()
    let audioPlayer = AudioPlayerService()

    let initial = makeConfiguration(
        sessionId: sessionId,
        reducer: reducer,
        toolOutputStore: toolOutputStore,
        toolArgsStore: toolArgsStore,
        connection: connection,
        scrollController: scrollController,
        audioPlayer: audioPlayer
    )
    coordinator.apply(configuration: initial, to: collectionView)

    return TimelineHarness(
        coordinator: coordinator,
        collectionView: collectionView,
        reducer: reducer,
        toolOutputStore: toolOutputStore,
        toolArgsStore: toolArgsStore,
        connection: connection,
        scrollController: scrollController,
        audioPlayer: audioPlayer
    )
}

@MainActor
private func makeConfiguration(
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
    sessionId: String,
    reducer: TimelineReducer,
    toolOutputStore: ToolOutputStore,
    toolArgsStore: ToolArgsStore,
    connection: ServerConnection,
    scrollController: ChatScrollController,
    audioPlayer: AudioPlayerService
) -> ChatTimelineCollectionView.Configuration {
    ChatTimelineCollectionView.Configuration(
        items: items,
        hiddenCount: 0,
        renderWindowStep: 50,
        isBusy: false,
        streamingAssistantID: nil,
        sessionId: sessionId,
        workspaceId: "ws-test",
        onFork: { _ in },
        onOpenFile: { _ in },
        onShowEarlier: {},
        scrollCommand: nil,
        scrollController: scrollController,
        reducer: reducer,
        toolOutputStore: toolOutputStore,
        toolArgsStore: toolArgsStore,
        connection: connection,
        audioPlayer: audioPlayer,
        theme: .tokyoNight,
        themeID: .tokyoNight
    )
}

private func waitForCondition(
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

private func makeToolConfiguration(
    title: String = "$ bash",
    preview: String? = nil,
    expandedText: String? = nil,
    expandedCommandText: String? = nil,
    expandedOutputText: String? = nil,
    showSeparatedCommandAndOutput: Bool = false,
    isExpanded: Bool,
    isDone: Bool = true,
    isError: Bool = false
) -> ToolTimelineRowConfiguration {
    ToolTimelineRowConfiguration(
        title: title,
        preview: preview,
        expandedText: expandedText,
        expandedCommandText: expandedCommandText,
        expandedOutputText: expandedOutputText,
        showSeparatedCommandAndOutput: showSeparatedCommandAndOutput,
        copyCommandText: nil,
        copyOutputText: nil,
        trailing: nil,
        titleLineBreakMode: .byTruncatingTail,
        toolNamePrefix: "$",
        toolNameColor: .systemGreen,
        editAdded: nil,
        editRemoved: nil,
        isExpanded: isExpanded,
        isDone: isDone,
        isError: isError
    )
}

private func makeAssistantConfiguration(
    text: String = "Assistant response with https://example.com"
) -> AssistantTimelineRowConfiguration {
    AssistantTimelineRowConfiguration(
        text: text,
        isStreaming: false,
        canFork: false,
        onFork: nil,
        themeID: .tokyoNight
    )
}

@MainActor
private func fittedSize(for view: UIView, width: CGFloat) -> CGSize {
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
