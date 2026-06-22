#if DEBUG
import Darwin.Mach
import SwiftUI
import UIKit

// MARK: - Harness Configuration

enum UIHangHarnessConfig {
    private struct LaunchContext {
        let isEnabled: Bool
        let streamDisabled: Bool
        let includeVisualFixtures: Bool
        let includeWriteMarkdownFixture: Bool
        let mixedContentFixtures: Bool
        let queueHarnessEnabled: Bool
        let assistantOverlapFixture: Bool
    }

    // periphery:ignore - debug harness state container
    private struct StickyState {
        let noStream: Bool
        let includeVisualFixtures: Bool
        let includeWriteMarkdownFixture: Bool
        let mixedContentFixtures: Bool
        let queueHarnessEnabled: Bool
        let assistantOverlapFixture: Bool
    }

    // XCTest repeat mode can transiently reinstall/relaunch the app without
    // preserving our explicit harness launch args/env. Persist the last
    // harness launch knobs briefly so simulator relaunches stay in harness mode.
    // periphery:ignore - debug harness persistence keys
    private static let stickyTimestampKey = "\(AppIdentifiers.subsystem).uiHangHarness.sticky.timestamp"
    // periphery:ignore - debug harness persistence keys
    private static let stickyNoStreamKey = "\(AppIdentifiers.subsystem).uiHangHarness.sticky.noStream"
    // periphery:ignore - debug harness persistence keys
    private static let stickyVisualFixturesKey = "\(AppIdentifiers.subsystem).uiHangHarness.sticky.visualFixtures"
    // periphery:ignore - debug harness persistence keys
    private static let stickyWriteMarkdownFixtureKey = "\(AppIdentifiers.subsystem).uiHangHarness.sticky.writeMarkdownFixture"
    // periphery:ignore - debug harness persistence keys
    private static let stickyMixedContentKey = "\(AppIdentifiers.subsystem).uiHangHarness.sticky.mixedContent"
    // periphery:ignore - debug harness persistence keys
    private static let stickyQueueHarnessKey = "\(AppIdentifiers.subsystem).uiHangHarness.sticky.queueHarness"
    // periphery:ignore - debug harness persistence keys
    private static let stickyAssistantOverlapFixtureKey = "\(AppIdentifiers.subsystem).uiHangHarness.sticky.assistantOverlapFixture"
    // Keep sticky harness launch knobs alive long enough for long-running UI
    // suites where CoreSimulator may relaunch the app mid-run.
    // periphery:ignore - debug harness TTL constant
    private static let stickyTTLSeconds: TimeInterval = 900

    private static let launchContext = resolveLaunchContext()

    static var isEnabled: Bool {
#if DEBUG
#if targetEnvironment(simulator)
        launchContext.isEnabled
#else
        false
#endif
#else
        false
#endif
    }

    static var streamDisabled: Bool {
#if DEBUG
        launchContext.streamDisabled
#else
        true
#endif
    }

    static var uiTestMode: Bool {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return environment["PI_UI_HANG_UI_TEST_MODE"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
#else
        false
#endif
    }

    static var includeVisualFixtures: Bool {
#if DEBUG
        if !uiTestMode { return true }
        return launchContext.includeVisualFixtures
#else
        false
#endif
    }

    static var includeWriteMarkdownFixture: Bool {
#if DEBUG
        launchContext.includeWriteMarkdownFixture
#else
        false
#endif
    }

    static var mixedContentFixtures: Bool {
#if DEBUG
        launchContext.mixedContentFixtures
#else
        false
#endif
    }

    static var queueHarnessEnabled: Bool {
#if DEBUG
        launchContext.queueHarnessEnabled
#else
        false
#endif
    }

    static var assistantOverlapFixture: Bool {
#if DEBUG
        launchContext.assistantOverlapFixture
#else
        false
#endif
    }

#if DEBUG
#if targetEnvironment(simulator)
    private static func resolveLaunchContext() -> LaunchContext {
        let processInfo = ProcessInfo.processInfo
        let environment = processInfo.environment

        let explicitHarness = processInfo.arguments.contains("--ui-hang-harness")
            || environment["PI_UI_HANG_HARNESS"] == "1"
        let explicitNoStream = environment["PI_UI_HANG_NO_STREAM"] == "1"
        let explicitVisualFixtures = environment["PI_UI_HANG_INCLUDE_VISUAL_FIXTURES"] == "1"
        let explicitWriteMarkdownFixture = environment["PI_UI_HANG_INCLUDE_WRITE_MD_FIXTURE"] == "1"
        let explicitMixedContent = environment["PI_UI_HANG_MIXED_CONTENT"] == "1"
        let explicitQueueHarness = environment["PI_UI_HANG_QUEUE_HARNESS"] == "1"
        let explicitAssistantOverlapFixture = environment["PI_UI_HANG_ASSISTANT_OVERLAP_FIXTURE"] == "1"

        if explicitHarness {
            persistStickyState(
                noStream: explicitNoStream,
                includeVisualFixtures: explicitVisualFixtures,
                includeWriteMarkdownFixture: explicitWriteMarkdownFixture,
                mixedContentFixtures: explicitMixedContent,
                queueHarnessEnabled: explicitQueueHarness,
                assistantOverlapFixture: explicitAssistantOverlapFixture
            )
            return LaunchContext(
                isEnabled: true,
                streamDisabled: explicitNoStream,
                includeVisualFixtures: explicitVisualFixtures,
                includeWriteMarkdownFixture: explicitWriteMarkdownFixture,
                mixedContentFixtures: explicitMixedContent,
                queueHarnessEnabled: explicitQueueHarness,
                assistantOverlapFixture: explicitAssistantOverlapFixture
            )
        }

        if isLikelyXCTestHarnessRelaunch(environment: environment),
           let stickyState = loadStickyState() {
            return LaunchContext(
                isEnabled: true,
                streamDisabled: stickyState.noStream,
                includeVisualFixtures: stickyState.includeVisualFixtures,
                includeWriteMarkdownFixture: stickyState.includeWriteMarkdownFixture,
                mixedContentFixtures: stickyState.mixedContentFixtures,
                queueHarnessEnabled: stickyState.queueHarnessEnabled,
                assistantOverlapFixture: stickyState.assistantOverlapFixture
            )
        }

        if !isLikelyXCTestHarnessRelaunch(environment: environment) {
            clearStickyState()
        }

        return LaunchContext(
            isEnabled: false,
            streamDisabled: explicitNoStream,
            includeVisualFixtures: explicitVisualFixtures,
            includeWriteMarkdownFixture: explicitWriteMarkdownFixture,
            mixedContentFixtures: explicitMixedContent,
            queueHarnessEnabled: explicitQueueHarness,
            assistantOverlapFixture: explicitAssistantOverlapFixture
        )
    }

    private static func isLikelyXCTestHarnessRelaunch(environment: [String: String]) -> Bool {
        let hasSession = environment["XCTestSessionIdentifier"] != nil
        let hasBundleInjectPath = environment["XCTestBundleInjectPath"] != nil
        let injectedIntoUnusedHost = environment["XCInjectBundleInto"] == "unused"
        return hasSession && hasBundleInjectPath && injectedIntoUnusedHost
    }

    private static var stickyDefaults: UserDefaults {
        guard let bundleID = Bundle.main.bundleIdentifier?.lowercased() else {
            return .standard
        }
        return UserDefaults(suiteName: "group.\(bundleID)") ?? .standard
    }

    private static func persistStickyState(
        noStream: Bool,
        includeVisualFixtures: Bool,
        includeWriteMarkdownFixture: Bool,
        mixedContentFixtures: Bool,
        queueHarnessEnabled: Bool,
        assistantOverlapFixture: Bool
    ) {
        let now = Date().timeIntervalSince1970
        stickyDefaults.set(now, forKey: stickyTimestampKey)
        stickyDefaults.set(noStream, forKey: stickyNoStreamKey)
        stickyDefaults.set(includeVisualFixtures, forKey: stickyVisualFixturesKey)
        stickyDefaults.set(includeWriteMarkdownFixture, forKey: stickyWriteMarkdownFixtureKey)
        stickyDefaults.set(mixedContentFixtures, forKey: stickyMixedContentKey)
        stickyDefaults.set(queueHarnessEnabled, forKey: stickyQueueHarnessKey)
        stickyDefaults.set(assistantOverlapFixture, forKey: stickyAssistantOverlapFixtureKey)
    }

    private static func loadStickyState(now: Date = Date()) -> StickyState? {
        let defaults = stickyDefaults
        guard let timestamp = defaults.object(forKey: stickyTimestampKey) as? TimeInterval else {
            return nil
        }

        if now.timeIntervalSince1970 - timestamp > stickyTTLSeconds {
            clearStickyState()
            return nil
        }

        return StickyState(
            noStream: defaults.bool(forKey: stickyNoStreamKey),
            includeVisualFixtures: defaults.bool(forKey: stickyVisualFixturesKey),
            includeWriteMarkdownFixture: defaults.bool(forKey: stickyWriteMarkdownFixtureKey),
            mixedContentFixtures: defaults.bool(forKey: stickyMixedContentKey),
            queueHarnessEnabled: defaults.bool(forKey: stickyQueueHarnessKey),
            assistantOverlapFixture: defaults.bool(forKey: stickyAssistantOverlapFixtureKey)
        )
    }

    private static func clearStickyState() {
        let defaults = stickyDefaults
        defaults.removeObject(forKey: stickyTimestampKey)
        defaults.removeObject(forKey: stickyNoStreamKey)
        defaults.removeObject(forKey: stickyVisualFixturesKey)
        defaults.removeObject(forKey: stickyWriteMarkdownFixtureKey)
        defaults.removeObject(forKey: stickyMixedContentKey)
        defaults.removeObject(forKey: stickyQueueHarnessKey)
        defaults.removeObject(forKey: stickyAssistantOverlapFixtureKey)
    }
#else
    private static func resolveLaunchContext() -> LaunchContext {
        LaunchContext(
            isEnabled: false,
            streamDisabled: true,
            includeVisualFixtures: false,
            includeWriteMarkdownFixture: false,
            mixedContentFixtures: false,
            queueHarnessEnabled: false,
            assistantOverlapFixture: false
        )
    }
#endif
#else
    private static func resolveLaunchContext() -> LaunchContext {
        LaunchContext(
            isEnabled: false,
            streamDisabled: true,
            includeVisualFixtures: false,
            includeWriteMarkdownFixture: false,
            mixedContentFixtures: false,
            queueHarnessEnabled: false,
            assistantOverlapFixture: false
        )
    }
#endif
}

// MARK: - Harness View

struct UIHangHarnessView: View {
    private enum HarnessSession: String, CaseIterable {
        case alpha
        case beta
        case gamma

        var title: String { rawValue.capitalized }
        var accessibilityID: String { "harness.session.\(rawValue)" }
    }

    private static let initialRenderWindow = 80
    private static let renderWindowStep = 60

    private static let fixtureItems: [HarnessSession: [ChatItem]] = {
        var result: [HarnessSession: [ChatItem]] = [:]
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        // UI tests need fast launch and quiescence. Default to smaller fixtures
        // in XCTest mode, unless explicitly running mixed-content scenarios.
        let turnsPerSession = UIHangHarnessConfig.uiTestMode ? 36 : 120
        let usePlainAssistantText = UIHangHarnessConfig.uiTestMode
            && !UIHangHarnessConfig.mixedContentFixtures

        for (sessionIndex, session) in HarnessSession.allCases.enumerated() {
            var items: [ChatItem] = []
            items.reserveCapacity(turnsPerSession * 2)

            for turn in 1...turnsPerSession {
                let offset = Double((sessionIndex * 10_000) + turn)
                let ts = baseDate.addingTimeInterval(offset)

                items.append(.userMessage(
                    id: "\(session.rawValue)-u-\(turn)",
                    text: "\(session.title) prompt \(turn): summarize and explain this response with examples.",
                    images: [],
                    timestamp: ts
                ))

                let assistantText: String
                if usePlainAssistantText {
                    assistantText = "\(session.title) answer \(turn) plain text payload for UI reliability harness."
                } else if UIHangHarnessConfig.mixedContentFixtures {
                    switch turn % 3 {
                    case 0:
                        assistantText = "\(session.title) answer \(turn) plain payload mixed-content lane."
                    case 1:
                        assistantText = """
                        ### \(session.title) answer \(turn)

                        Mixed markdown segment.

                        - turn: \(turn)
                        - value: \(turn * 17)

                        `inline-code-token-\(turn)`
                        """
                    default:
                        assistantText = """
                        ```swift
                        struct HarnessSample\(turn) {
                            let value = \(turn)
                        }
                        ```
                        """
                    }
                } else {
                    assistantText = """
                    ### \(session.title) answer \(turn)

                    Synthetic markdown content for timeline stress.

                    - turn: \(turn)
                    - value: \(turn * 17)

                    ```swift
                    let value = \(turn)
                    print(value)
                    ```
                    """
                }

                items.append(.assistantMessage(
                    id: "\(session.rawValue)-a-\(turn)",
                    text: assistantText,
                    timestamp: ts.addingTimeInterval(0.2)
                ))
            }

            if UIHangHarnessConfig.includeVisualFixtures {
                let visualBaseOffset = Double((sessionIndex * 10_000) + turnsPerSession + 500)
                let visualTS = baseDate.addingTimeInterval(visualBaseOffset)
                let sessionPrefix = session.rawValue
                let sessionID = "harness-\(sessionPrefix)"

                items.append(.userMessage(
                    id: "\(sessionPrefix)-visual-user-image",
                    text: "Image attachment example for visual routing check.",
                    images: [
                        ImageAttachment(
                            data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO5YpU8AAAAASUVORK5CYII=",
                            mimeType: "image/png"
                        ),
                    ],
                    timestamp: visualTS
                ))

                items.append(.assistantMessage(
                    id: "\(sessionPrefix)-visual-assistant-markdown",
                    text: """
                    # Visual markdown sample

                    - bullet one
                    - bullet two

                    ```swift
                    print(\"markdown + syntax highlight parity\")
                    ```
                    """,
                    timestamp: visualTS.addingTimeInterval(0.1)
                ))

                items.append(.thinking(
                    id: "\(sessionPrefix)-visual-thinking",
                    preview: "Deliberating about renderer parity and fallback policy…",
                    hasMore: true,
                    isDone: true
                ))

                items.append(.toolCall(
                    id: "\(sessionPrefix)-visual-tool-bash",
                    tool: "bash",
                    argsSummary: "command: git status --short",
                    outputPreview: "M ios/Oppi/Features/Chat/ChatTimelineCollectionView.swift",
                    outputByteCount: 96,
                    isError: false,
                    isDone: true
                ))

                items.append(.toolCall(
                    id: "\(sessionPrefix)-visual-tool-read",
                    tool: "read",
                    argsSummary: "path: ios/Oppi/Features/Chat/ChatTimelineCollectionView.swift",
                    outputPreview: "import SwiftUI\\nimport UIKit",
                    outputByteCount: 512,
                    isError: false,
                    isDone: true
                ))

                items.append(.toolCall(
                    id: "\(sessionPrefix)-visual-tool-write",
                    tool: "write",
                    argsSummary: "path: docs/notes.md",
                    outputPreview: "",
                    outputByteCount: 128,
                    isError: false,
                    isDone: true
                ))

                items.append(.toolCall(
                    id: "\(sessionPrefix)-visual-tool-edit",
                    tool: "edit",
                    argsSummary: "path: ios/Oppi/App/OppiApp.swift",
                    outputPreview: "",
                    outputByteCount: 256,
                    isError: false,
                    isDone: true
                ))

                items.append(.toolCall(
                    id: "\(sessionPrefix)-visual-tool-extension-a",
                    tool: "extensions.lookup",
                    argsSummary: "query: renderer parity checklist",
                    outputPreview: "- [ ] keep renderer parity checklist up to date",
                    outputByteCount: 80,
                    isError: false,
                    isDone: true
                ))

                items.append(.toolCall(
                    id: "\(sessionPrefix)-visual-tool-extension-b",
                    tool: "extensions.notes",
                    argsSummary: "query: harness markdown payload",
                    outputPreview: "",
                    outputByteCount: 2_400,
                    isError: false,
                    isDone: true
                ))

                items.append(.toolCall(
                    id: "\(sessionPrefix)-visual-tool-read-image",
                    tool: "read",
                    argsSummary: "path: fixtures/harness-image.png",
                    outputPreview: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO5YpU8AAAAASUVORK5CYII=",
                    outputByteCount: 144,
                    isError: false,
                    isDone: true
                ))

                items.append(.toolCall(
                    id: "\(sessionPrefix)-visual-tool-unknown",
                    tool: "grep",
                    argsSummary: "pattern: TODO",
                    outputPreview: "docs/notes.md:12: TODO: tighten regression harness",
                    outputByteCount: 96,
                    isError: false,
                    isDone: true
                ))

                items.append(.systemEvent(
                    id: "\(sessionPrefix)-visual-system",
                    message: "Context compacted for visual pass"
                ))

                items.append(.error(
                    id: "\(sessionPrefix)-visual-error",
                    message: "Sample error row for native renderer visual verification"
                ))

                // Expandable compaction summary for expand/collapse UI testing.
                // Detail exceeds 140 chars so CompactionPresentation.canExpand is true.
                items.append(.systemEvent(
                    id: "\(sessionPrefix)-visual-compaction-expandable",
                    message: "Context compacted (8192 tokens): The conversation context was compacted to stay within the model context window. Previous discussion covered architecture patterns for the ChatTimelineCollectionView, performance optimization strategies for UIKit cell reuse, and debugging approaches for main thread stalls during rapid scrolling operations with expanded tool output rows."
                ))

                items.append(.audioClip(
                    id: "\(sessionPrefix)-visual-audio",
                    title: "Harness Audio Clip",
                    fileURL: URL(fileURLWithPath: "/tmp/\(sessionPrefix)-harness-audio.wav"),
                    timestamp: visualTS.addingTimeInterval(0.2)
                ))
            }

            if UIHangHarnessConfig.assistantOverlapFixture {
                items.append(.assistantMessage(
                    id: "\(session.rawValue)-assistant-overlap",
                    text: Self.assistantOverlapFixtureText(phase: 0, session: session),
                    timestamp: baseDate.addingTimeInterval(Double((sessionIndex * 10_000) + turnsPerSession + 900))
                ))
            }

            result[session] = items
        }

        return result
    }()

    private static let assistantOverlapLastPhase = 1

    private static func assistantOverlapFixtureText(phase: Int, session: HarnessSession) -> String {
        switch phase {
        case 0:
            return "Overlap repro fixture — \(session.title).\n\nShort intro before the rich markdown arrives."
        default:
            return """
            Overlap repro fixture — \(session.title).

            This paragraph stays short at first, then the renderer suddenly has to fit multiple rich blocks in one assistant row.

            ```swift
            enum TimelineScrollIntent {
                case none
                case initialBottom(id: String)
                case jumpToBottom(id: String, animated: Bool)
                case navigateTo(id: String)
            }
            ```

            ```swift
            if explicitIntent {
                performExplicitScroll()
            } else if detached {
                preserveViewport()
            } else if isBusy {
                keepTailVisibleWithinComfortBand()
            } else {
                settleToExactBottomIfStillAttached()
            }
            ```

            The key simplification: streaming is not a scroll animation anymore. Streaming is content appearing, scrolling only nudges.
            """
        }
    }

    @State private var connection = ServerConnection()
    @State private var harnessReducer = TimelineReducer()
    @State private var scrollController = ChatScrollController()

    @State private var selectedSession: HarnessSession = .alpha
    @State private var sessionItems: [HarnessSession: [ChatItem]] = Self.fixtureItems
    @State private var renderWindow = Self.initialRenderWindow

    @State private var pendingScrollCommand: ChatTimelineScrollCommand?
    @State private var scrollCommandNonce = 0

    @State private var heartbeat = 0
    @State private var stallCount = 0
    @State private var streamTick = 0

    @State private var streamEnabled = !UIHangHarnessConfig.streamDisabled
    @State private var diagnosticsTask: Task<Void, Never>?
    @State private var streamTask: Task<Void, Never>?

    @State private var themeID = ThemeRuntimeState.currentThemeID()
    @State private var originalThemeID = ThemeRuntimeState.currentThemeID()
    @State private var inputText = ""
    @State private var frameIntervalMonitor = HarnessFrameIntervalMonitor()

    @State private var queueStates: [HarnessSession: MessageQueueState] = [:]
    @State private var queueBusyStreamingBehavior: StreamingBehavior = .steer
    @State private var queueSystemEventSerial = 0
    @State private var assistantOverlapPhaseBySession: [HarnessSession: Int] = [:]
    @State private var assistantOverlapReadySnapshot = 0
    @State private var assistantRowHeightSnapshot = -1
    @State private var assistantRenderedOverlapSnapshot = -1
    @State private var assistantOverflowSnapshot = -1

    private var currentItems: [ChatItem] {
        sessionItems[selectedSession] ?? []
    }

    private var currentQueueState: MessageQueueState {
        queueStates[selectedSession] ?? .empty
    }

    private var showsQueueContainer: Bool {
        !currentQueueState.steering.isEmpty || !currentQueueState.followUp.isEmpty
    }

    private var queueVisibleValue: Int {
        showsQueueContainer ? 1 : 0
    }

    private var queueSteeringCount: Int {
        currentQueueState.steering.count
    }

    private var queueFollowUpCount: Int {
        currentQueueState.followUp.count
    }

    private var queueVersionValue: Int {
        currentQueueState.version
    }

    private var queueStartedEventCount: Int {
        currentItems.reduce(into: 0) { partial, item in
            guard case .systemEvent(_, let message) = item,
                  message.hasPrefix("Message Queue •"),
                  message.contains("started") else {
                return
            }
            partial += 1
        }
    }

    private var visibleItems: [ChatItem] {
        Array(currentItems.suffix(renderWindow))
    }

    private var hiddenCount: Int {
        max(0, currentItems.count - visibleItems.count)
    }

    private var streamTargetID: String {
        streamItemID(for: selectedSession)
    }

    private var assistantOverlapItemID: String {
        "\(selectedSession.rawValue)-assistant-overlap"
    }

    private var assistantOverlapPhaseValue: Int {
        assistantOverlapPhaseBySession[selectedSession] ?? 0
    }

    private var assistantOverlapReadyValue: Int {
        assistantOverlapReadySnapshot
    }

    private var assistantRowHeightValue: Int {
        assistantRowHeightSnapshot
    }

    private var assistantOverlapRenderedValue: Int {
        assistantRenderedOverlapSnapshot
    }

    private var assistantOverflowValue: Int {
        assistantOverflowSnapshot
    }

    /// For UI test harness mode, disable busy cursor/working indicator animations
    /// so XCUITest can reach idle between interactions.
    private var collectionStreamingAssistantID: String? {
        if UIHangHarnessConfig.assistantOverlapFixture,
           currentItems.contains(where: { $0.id == assistantOverlapItemID }) {
            return assistantOverlapItemID
        }

        guard streamEnabled, !UIHangHarnessConfig.uiTestMode else { return nil }
        return streamTargetID
    }

    private var collectionIsBusy: Bool {
        streamEnabled && !UIHangHarnessConfig.uiTestMode
    }

    private var topVisibleIndex: Int {
        guard let id = scrollController.currentTopVisibleItemId,
              let index = visibleItems.firstIndex(where: { $0.id == id }) else {
            return -1
        }
        return index
    }

    private var nearBottomValue: Int {
        scrollController.isCurrentlyNearBottom ? 1 : 0
    }

    private var themeOrdinal: Int {
        switch themeID {
        case .dark: return 0
        case .oled: return 1
        case .light: return 2
        case .night: return 3
        case .custom: return 4
        }
    }

    private var perfSnapshot: ChatTimelinePerf.Snapshot {
        ChatTimelinePerf.snapshot()
    }

    private var frameMetricsSnapshot: HarnessFrameIntervalSnapshot {
        frameIntervalMonitor.snapshot()
    }

    private var nativeAssistantMode: Int { 1 }
    private var nativeUserMode: Int { 1 }
    private var nativeThinkingMode: Int { 1 }
    private var nativeToolMode: Int { 1 }

    private var visualToolCount: Int {
        currentItems.reduce(into: 0) { partialResult, item in
            if case .toolCall(let id, _, _, _, _, _, _) = item,
               id.contains("-visual-tool-") {
                partialResult += 1
            }
        }
    }

    private var extensionMarkdownToolID: String {
        extensionMarkdownToolItemID(for: selectedSession)
    }

    private var extensionTextToolID: String {
        extensionTextToolItemID(for: selectedSession)
    }

    private var writeMarkdownToolID: String {
        writeMarkdownToolItemID(for: selectedSession)
    }

    private var readMarkdownToolID: String {
        readMarkdownToolItemID(for: selectedSession)
    }

    private var extensionMarkdownIsExpandedValue: Int {
        harnessReducer.expandedItemIDs.contains(extensionMarkdownToolID) ? 1 : 0
    }

    private var extensionTextIsExpandedValue: Int {
        harnessReducer.expandedItemIDs.contains(extensionTextToolID) ? 1 : 0
    }

    private var extensionMarkdownIsTopVisibleValue: Int {
        scrollController.currentTopVisibleItemId == extensionMarkdownToolID ? 1 : 0
    }

    private var writeMarkdownIsExpandedValue: Int {
        harnessReducer.expandedItemIDs.contains(writeMarkdownToolID) ? 1 : 0
    }

    private var readMarkdownIsExpandedValue: Int {
        harnessReducer.expandedItemIDs.contains(readMarkdownToolID) ? 1 : 0
    }

    private var offsetYValue: Int {
        Int(scrollController.currentContentOffsetY.rounded())
    }

    private var bottomItemID: String? {
        visibleItems.last?.id
    }

    var body: some View {
        VStack(spacing: 10) {
            Text("Harness Ready")
                .font(.caption)
                .accessibilityIdentifier("harness.ready")

            controlsBar

            if UIHangHarnessConfig.queueHarnessEnabled, showsQueueContainer {
                MessageQueueContainer(
                    queue: currentQueueState,
                    busyStreamingBehavior: $queueBusyStreamingBehavior,
                    onApply: { baseVersion, steering, followUp in
                        try applyQueueDraft(baseVersion: baseVersion, steering: steering, followUp: followUp)
                    },
                    onRefresh: {}
                )
                .accessibilityIdentifier("harness.queue.container")
            }

            ChatTimelineCollectionHost(
                configuration: .init(
                    items: visibleItems,
                    hiddenCount: hiddenCount,
                    renderWindowStep: Self.renderWindowStep,
                    isBusy: collectionIsBusy,
                    streamingAssistantID: collectionStreamingAssistantID,
                    sessionId: "harness-\(selectedSession.rawValue)",
                    workspaceId: "harness-workspace",
                    onFork: { _ in },
                    onShowEarlier: {
                        renderWindow = min(currentItems.count, renderWindow + Self.renderWindowStep)
                    },
                    scrollCommand: pendingScrollCommand,
                    scrollController: scrollController,
                    reducer: harnessReducer,
                    toolOutputStore: harnessReducer.toolOutputStore,
                    toolArgsStore: harnessReducer.toolArgsStore,
                    toolSegmentStore: harnessReducer.toolSegmentStore,
                    toolDetailsStore: harnessReducer.toolDetailsStore,
                    connection: connection,
                    audioPlayer: connection.audioPlayer
                )
            )
            .accessibilityIdentifier("harness.timeline")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.themeBg)

            TextField("Harness input", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("harness.input")

            diagnosticsBar
        }
        .padding()
        .background(Color.themeBg.ignoresSafeArea())
        .onAppear {
            originalThemeID = ThemeRuntimeState.currentThemeID()
            ThemeRuntimeState.setThemeID(themeID)
            resetRuntimeMetrics()
            frameIntervalMonitor.start()
            renderWindow = min(Self.initialRenderWindow, currentItems.count)
            seedVisualToolFixtures()
            ensureAssistantOverlapFixtureExists()
            startDiagnosticsLoop()
            restartStreamingLoop()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                scrollToBottom(animated: false)
            }
        }
        .onDisappear {
            diagnosticsTask?.cancel()
            diagnosticsTask = nil
            streamTask?.cancel()
            streamTask = nil
            frameIntervalMonitor.stop()
            ThemeRuntimeState.setThemeID(originalThemeID)
        }
        .onChange(of: selectedSession) { _, _ in
            renderWindow = min(Self.initialRenderWindow, currentItems.count)
            seedVisualToolFixtures()
            ensureAssistantOverlapFixtureExists()
            heartbeat &+= 1
            restartStreamingLoop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                scrollToBottom(animated: false)
            }
        }
        .onChange(of: streamEnabled) { _, _ in
            heartbeat &+= 1
            restartStreamingLoop()
        }
        .onChange(of: themeID) { _, newThemeID in
            ThemeRuntimeState.setThemeID(newThemeID)
            heartbeat &+= 1
        }
    }

    private var controlsBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(HarnessSession.allCases, id: \.self) { session in
                    Button(session.title) {
                        selectedSession = session
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(session.accessibilityID)
                }
            }

            HStack(spacing: 8) {
                Button("Top") { scrollToTop(animated: !UIHangHarnessConfig.uiTestMode) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("harness.scroll.top")

                Button("Bottom") { scrollToBottom(animated: !UIHangHarnessConfig.uiTestMode) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("harness.scroll.bottom")

                Button("Expand") {
                    renderWindow = currentItems.count
                    heartbeat &+= 1
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("harness.expand.all")

                Button("ToolSet") {
                    expandVisualToolSet()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("harness.tools.render")

                Button("Extension") {
                    focusExtensionMarkdownTool()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("harness.extension.focus")

                Button("Extension Text") {
                    focusExtensionTextTool()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("harness.extensionText.focus")

                Button("Write Markdown") {
                    focusWriteMarkdownTool()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("harness.writeMarkdown.focus")

                Button("Read Markdown") {
                    focusReadMarkdownTool()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("harness.readMarkdown.focus")

                if UIHangHarnessConfig.assistantOverlapFixture {
                    Button("Assistant Overlap") {
                        focusAssistantOverlapFixture()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("harness.assistantOverlap.focus")

                    Button("Advance Overlap") {
                        advanceAssistantOverlapFixture()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("harness.assistantOverlap.advance")
                }

                Button("Visual Image") {
                    scrollToVisualUserImage(animated: false)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("harness.visual.image")

                Button(streamEnabled ? "Pause Stream" : "Resume Stream") {
                    streamEnabled.toggle()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("harness.stream.toggle")

                Button("Pulse") { pulseStream(count: 6) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("harness.stream.pulse")

                Button("Theme") { toggleTheme() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("harness.theme.toggle")

                Button("Diag") {
                    refreshDiagnostics()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("harness.diag.tick")

                Button("Reset Metrics") {
                    resetRuntimeMetrics()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("harness.metrics.reset")
            }

            if UIHangHarnessConfig.queueHarnessEnabled {
                HStack(spacing: 8) {
                    Button("Queue Steer") {
                        enqueueQueueItem(kind: .steer)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("harness.queue.enqueueSteer")

                    Button("Queue Follow") {
                        enqueueQueueItem(kind: .followUp)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("harness.queue.enqueueFollow")

                    Button("Start Steer") {
                        startQueueItem(kind: .steer)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("harness.queue.startSteer")

                    Button("Start Follow") {
                        startQueueItem(kind: .followUp)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("harness.queue.startFollow")

                    Button("Clear Queue") {
                        clearQueueItems()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("harness.queue.clear")
                }
            }
        }
    }

    private var diagnosticsBar: some View {
        let perf = perfSnapshot
        let frame = frameMetricsSnapshot

        return HStack(spacing: 10) {
            diagnosticValue(id: "diag.heartbeat", value: heartbeat)
            diagnosticValue(id: "diag.stallCount", value: stallCount)
            diagnosticValue(id: "diag.itemCount", value: currentItems.count)
            diagnosticValue(id: "diag.nearBottom", value: nearBottomValue)
            diagnosticValue(id: "diag.topIndex", value: topVisibleIndex)
            diagnosticValue(id: "diag.offsetY", value: offsetYValue)
            diagnosticValue(id: "diag.streamTick", value: streamTick)
            diagnosticValue(id: "diag.theme", value: themeOrdinal)
            diagnosticValue(id: "diag.nativeMode", value: nativeAssistantMode)
            diagnosticValue(id: "diag.nativeUserMode", value: nativeUserMode)
            diagnosticValue(id: "diag.nativeThinkingMode", value: nativeThinkingMode)
            diagnosticValue(id: "diag.nativeToolMode", value: nativeToolMode)
            diagnosticValue(id: "diag.visualTools", value: visualToolCount)
            diagnosticValue(id: "diag.extensionExpanded", value: extensionMarkdownIsExpandedValue)
            diagnosticValue(id: "diag.extensionTextExpanded", value: extensionTextIsExpandedValue)
            diagnosticValue(id: "diag.writeMarkdownExpanded", value: writeMarkdownIsExpandedValue)
            diagnosticValue(id: "diag.readMarkdownExpanded", value: readMarkdownIsExpandedValue)
            diagnosticValue(id: "diag.assistantOverlapReady", value: assistantOverlapReadyValue)
            diagnosticValue(id: "diag.assistantOverlapPhase", value: assistantOverlapPhaseValue)
            diagnosticValue(id: "diag.assistantRowHeightPx", value: assistantRowHeightValue)
            diagnosticValue(id: "diag.assistantRenderedOverlapPx", value: assistantOverlapRenderedValue)
            diagnosticValue(id: "diag.assistantOverflowPx", value: assistantOverflowValue)
            diagnosticValue(id: "diag.extensionTop", value: extensionMarkdownIsTopVisibleValue)
            diagnosticValue(id: "diag.applyMs", value: perf.applyLastMs)
            diagnosticValue(id: "diag.layoutMs", value: perf.layoutLastMs)
            diagnosticValue(id: "diag.cellMs", value: perf.cellConfigureLastMs)
            diagnosticValue(id: "diag.applyMax", value: perf.applyMaxMs)
            diagnosticValue(id: "diag.layoutMax", value: perf.layoutMaxMs)
            diagnosticValue(id: "diag.cellMax", value: perf.cellConfigureMaxMs)
            diagnosticValue(id: "diag.perfGuardrail", value: perf.hardGuardrailBreachCount)
            diagnosticValue(id: "diag.failsafeRows", value: perf.failsafeConfigureCount)
            diagnosticValue(id: "diag.scrollRate", value: perf.scrollCommandsPerSecond)
            diagnosticValue(id: "diag.frameSamples", value: frame.sampleCount)
            diagnosticValue(id: "diag.frameP95", value: frame.p95IntervalMs)
            diagnosticValue(id: "diag.frameP99", value: frame.p99IntervalMs)
            diagnosticValue(id: "diag.frameMax", value: frame.maxIntervalMs)
            diagnosticValue(id: "diag.frameOver34Pct", value: frame.over34MsPercent)
            diagnosticValue(id: "diag.frameOver50Pct", value: frame.over50MsPercent)
            diagnosticValue(id: "diag.frameOver50", value: frame.over50MsCount)
            diagnosticValue(id: "diag.queueVisible", value: queueVisibleValue)
            diagnosticValue(id: "diag.queueSteeringCount", value: queueSteeringCount)
            diagnosticValue(id: "diag.queueFollowUpCount", value: queueFollowUpCount)
            diagnosticValue(id: "diag.queueVersion", value: queueVersionValue)
            diagnosticValue(id: "diag.queueStartedEvents", value: queueStartedEventCount)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resetRuntimeMetrics() {
        ChatTimelinePerf.reset()
        frameIntervalMonitor.reset()
    }

    private func startDiagnosticsLoop() {
        diagnosticsTask?.cancel()
        diagnosticsTask = nil

        // UI tests need deterministic idle windows; a continuously mutating
        // heartbeat would prevent XCTest from considering the app idle.
        guard !UIHangHarnessConfig.uiTestMode else { return }

        diagnosticsTask = Task { @MainActor in
            var lastTick = ContinuousClock.now

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                let now = ContinuousClock.now
                if now - lastTick > .milliseconds(1_500) {
                    stallCount &+= 1
                }
                heartbeat &+= 1
                lastTick = now
            }
        }
    }

    private func restartStreamingLoop() {
        streamTask?.cancel()
        streamTask = nil

        guard streamEnabled else { return }

        let session = selectedSession
        let streamID = streamItemID(for: session)
        ensureStreamItemExists(session: session, streamID: streamID)

        // In UI test mode, stream progression is driven by explicit "Pulse"
        // button taps so XCTest can reach idle deterministically.
        guard !UIHangHarnessConfig.uiTestMode else { return }

        streamTask = Task { @MainActor in
            while !Task.isCancelled {
                appendStreamToken(session: session, streamID: streamID)
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func ensureStreamItemExists(session: HarnessSession, streamID: String) {
        var items = sessionItems[session] ?? []
        guard !items.contains(where: { $0.id == streamID }) else { return }

        items.append(.assistantMessage(
            id: streamID,
            text: "",
            timestamp: Date()
        ))

        sessionItems[session] = items
    }

    private func appendStreamToken(session: HarnessSession, streamID: String) {
        var items = sessionItems[session] ?? []

        guard let index = items.firstIndex(where: { $0.id == streamID }) else {
            ensureStreamItemExists(session: session, streamID: streamID)
            return
        }

        let token = " token_\(streamTick % 23)"

        if case .assistantMessage(_, let text, let timestamp) = items[index] {
            items[index] = .assistantMessage(id: streamID, text: text + token, timestamp: timestamp)
        }

        sessionItems[session] = items
        streamTick &+= 1

        let visible = Array(items.suffix(renderWindow))
        scrollController.itemCount = visible.count

        // Busy streaming follow is intentionally owned by
        // ChatTimelineCollectionHost after layout settles. The harness should
        // exercise the same ambient tail governor as production rather than
        // emitting scrollToItem commands on every token.
    }

    private func pulseStream(count: Int) {
        guard streamEnabled else {
            streamEnabled = true
            return
        }

        let session = selectedSession
        let streamID = streamItemID(for: session)
        ensureStreamItemExists(session: session, streamID: streamID)

        for _ in 0..<count {
            appendStreamToken(session: session, streamID: streamID)
        }
    }

    private func streamItemID(for session: HarnessSession) -> String {
        "harness-stream-\(session.rawValue)"
    }

    private func visualToolIDs(for session: HarnessSession) -> [String] {
        let prefix = session.rawValue
        return [
            "\(prefix)-visual-tool-bash",
            "\(prefix)-visual-tool-read",
            "\(prefix)-visual-tool-write",
            "\(prefix)-visual-tool-edit",
            "\(prefix)-visual-tool-extension-a",
            "\(prefix)-visual-tool-extension-b",
            "\(prefix)-visual-tool-read-image",
            "\(prefix)-visual-tool-unknown",
        ]
    }

    private func extensionMarkdownToolItemID(for session: HarnessSession) -> String {
        "\(session.rawValue)-visual-tool-extension-b"
    }

    private func extensionTextToolItemID(for session: HarnessSession) -> String {
        "\(session.rawValue)-visual-tool-extension-a"
    }

    private func writeMarkdownToolItemID(for session: HarnessSession) -> String {
        "\(session.rawValue)-visual-tool-write"
    }

    private func readMarkdownToolItemID(for session: HarnessSession) -> String {
        "\(session.rawValue)-visual-tool-read"
    }

    private func visualExtensionMarkdown(for session: HarnessSession) -> String {
        var sections: [String] = ["# Extension harness notes — \(session.title)"]
        for index in 1...22 {
            sections.append("## Segment \(index)")
            sections.append(
                "- detail \(index).1\n- detail \(index).2\n- detail \(index).3\n- detail \(index).4"
            )
        }
        return sections.joined(separator: "\n\n")
    }

    private func visualExtensionTextOutput(for session: HarnessSession) -> String {
        let bodySections = (1...28).map { index in
            "section \(index): detail \(index).1, detail \(index).2, detail \(index).3"
        }

        return ([
            "extension lookup result — \(session.title)",
            "status: in_progress",
        ] + bodySections).joined(separator: "\n")
    }

    private func visualWriteMarkdownContent() -> String {
        var sections: [String] = [
            "# Chat Timeline Code Paths (Streaming + Normal Output)",
            "Status: current as of 2026-03-01.",
            "",
            "This fixture mirrors a long-form write payload that tends to trigger scroll staggering when expanded.",
        ]

        for index in 1...32 {
            sections.append("## Section \(index)")
            sections.append(
                "1. live streaming output\n2. finalized output\n3. reconnect catch-up\n4. fallback reload"
            )
            sections.append(
                "Detailed paragraph \(index): explain reducer, coalescer, and collection-view self-sizing interactions for markdown-heavy rows."
            )
        }

        return sections.joined(separator: "\n\n")
    }

    private func visualReadMarkdownContent(for session: HarnessSession) -> String {
        var sections: [String] = [
            "# Read Harness Markdown — \(session.title)",
            "This fixture mirrors long markdown loaded via the read tool on a .md path.",
        ]

        for index in 1...36 {
            sections.append("## Read section \(index)")
            sections.append("- reducer path\n- markdown layout pass\n- viewport height\n- scroll ownership")
            sections.append(
                "Explanation \(index): verify expanded read markdown rows do not induce stagger, snapback, or offset oscillation under drag stress."
            )
        }

        return sections.joined(separator: "\n\n")
    }

    private func seedVisualToolFixtures() {
        seedExtensionMarkdownFixtures()
        seedExtensionTextFixtures()
        seedReadMarkdownFixtures()

        if UIHangHarnessConfig.includeWriteMarkdownFixture {
            seedWriteMarkdownFixtures()
        }
    }

    private func seedExtensionMarkdownFixtures() {
        let extensionIDs = Set(HarnessSession.allCases.map(extensionMarkdownToolItemID(for:)))
        harnessReducer.toolOutputStore.clear(itemIDs: extensionIDs)

        for session in HarnessSession.allCases {
            let extensionID = extensionMarkdownToolItemID(for: session)
            let markdown = visualExtensionMarkdown(for: session)

            harnessReducer.toolArgsStore.set([
                "text": .string(markdown),
                "tags": .array([
                    .string("harness"),
                    .string("extension-markdown"),
                    .string(session.rawValue),
                ]),
            ], for: extensionID)
            _ = harnessReducer.toolOutputStore.append(markdown, to: extensionID)
        }
    }

    private func seedExtensionTextFixtures() {
        let extensionIDs = Set(HarnessSession.allCases.map(extensionTextToolItemID(for:)))
        harnessReducer.toolOutputStore.clear(itemIDs: extensionIDs)

        for session in HarnessSession.allCases {
            let extensionID = extensionTextToolItemID(for: session)
            let output = visualExtensionTextOutput(for: session)
            _ = harnessReducer.toolOutputStore.append(output, to: extensionID)
        }
    }

    private func seedReadMarkdownFixtures() {
        let readIDs = Set(HarnessSession.allCases.map(readMarkdownToolItemID(for:)))
        harnessReducer.toolOutputStore.clear(itemIDs: readIDs)

        for session in HarnessSession.allCases {
            let readID = readMarkdownToolItemID(for: session)
            let markdown = visualReadMarkdownContent(for: session)

            harnessReducer.toolArgsStore.set([
                "path": .string("design/read-harness-markdown.md"),
                "offset": .number(1),
                "limit": .number(800),
            ], for: readID)

            _ = harnessReducer.toolOutputStore.append(markdown, to: readID)
        }
    }

    private func seedWriteMarkdownFixtures() {
        for session in HarnessSession.allCases {
            let writeID = writeMarkdownToolItemID(for: session)
            let markdown = visualWriteMarkdownContent()

            harnessReducer.toolArgsStore.set([
                "path": .string("design/chat-timeline-code-paths.md"),
                "content": .string(markdown),
            ], for: writeID)

            harnessReducer.toolOutputStore.clear(itemIDs: Set([writeID]))
        }
    }

    private func visualUserImageItemID(for session: HarnessSession) -> String {
        "\(session.rawValue)-visual-user-image"
    }

    private func expandVisualToolSet() {
        let ids = visualToolIDs(for: selectedSession)
        guard !ids.isEmpty else { return }

        for id in ids {
            harnessReducer.expandedItemIDs.insert(id)
        }

        heartbeat &+= 1
        scrollToBottom(animated: false)
    }

    private func focusExtensionMarkdownTool() {
        focusTool(itemID: extensionMarkdownToolItemID(for: selectedSession))
    }

    private func focusExtensionTextTool() {
        focusTool(itemID: extensionTextToolItemID(for: selectedSession))
    }

    private func focusWriteMarkdownTool() {
        focusTool(itemID: writeMarkdownToolItemID(for: selectedSession))
    }

    private func focusReadMarkdownTool() {
        focusTool(itemID: readMarkdownToolItemID(for: selectedSession))
    }

    private func focusTool(itemID: String) {
        guard currentItems.contains(where: { $0.id == itemID }) else { return }

        renderWindow = currentItems.count
        harnessReducer.expandedItemIDs.insert(itemID)
        heartbeat &+= 1
        issueScrollCommand(id: itemID, anchor: .top, animated: false)
    }

    private func scrollToVisualUserImage(animated: Bool) {
        let itemID = visualUserImageItemID(for: selectedSession)
        guard currentItems.contains(where: { $0.id == itemID }) else { return }
        issueScrollCommand(id: itemID, anchor: .top, animated: animated)
    }

    private func focusAssistantOverlapFixture() {
        ensureAssistantOverlapFixtureExists()
        guard currentItems.contains(where: { $0.id == assistantOverlapItemID }) else { return }
        renderWindow = currentItems.count
        heartbeat &+= 1
        issueScrollCommand(id: assistantOverlapItemID, anchor: .top, animated: false)
        scheduleAssistantOverlapDiagnosticsRefresh()
    }

    private func ensureAssistantOverlapFixtureExists() {
        guard UIHangHarnessConfig.assistantOverlapFixture,
              !currentItems.contains(where: { $0.id == assistantOverlapItemID }) else {
            return
        }

        var items = currentItems
        items.append(.assistantMessage(
            id: assistantOverlapItemID,
            text: Self.assistantOverlapFixtureText(phase: assistantOverlapPhaseValue, session: selectedSession),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(items.count + 9_000))
        ))
        sessionItems[selectedSession] = items
    }

    private func advanceAssistantOverlapFixture() {
        ensureAssistantOverlapFixtureExists()
        guard UIHangHarnessConfig.assistantOverlapFixture,
              assistantOverlapPhaseValue < Self.assistantOverlapLastPhase,
              let index = currentItems.firstIndex(where: { $0.id == assistantOverlapItemID }),
              case .assistantMessage(_, _, let timestamp) = currentItems[index] else {
            return
        }

        let nextPhase = assistantOverlapPhaseValue + 1
        var items = currentItems
        items[index] = .assistantMessage(
            id: assistantOverlapItemID,
            text: Self.assistantOverlapFixtureText(phase: nextPhase, session: selectedSession),
            timestamp: timestamp
        )
        sessionItems[selectedSession] = items
        assistantOverlapPhaseBySession[selectedSession] = nextPhase
        heartbeat &+= 1
        scheduleAssistantOverlapDiagnosticsRefresh()
    }

    private func debugAssistantOverlapRowView(itemID: String) -> AssistantTimelineRowContentView? {
        let rowIdentifier = "chat.timeline.assistant.\(itemID)"
        let cellIdentifier = "chat.timeline.row.\(itemID)"

        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows.reversed() {
                window.layoutIfNeeded()
                if let row = debugFindAssistantOverlapRow(in: window, identifier: rowIdentifier) {
                    return row
                }
                guard let cell = debugFindTimelineCell(in: window, identifier: cellIdentifier) else { continue }
                if let row = debugFindAssistantOverlapRow(in: cell) {
                    return row
                }
            }
        }

        return nil
    }

    private func debugFindTimelineCell(in root: UIView, identifier: String) -> SafeSizingCell? {
        if let cell = root as? SafeSizingCell,
           cell.accessibilityIdentifier == identifier {
            return cell
        }

        for subview in root.subviews {
            if let cell = debugFindTimelineCell(in: subview, identifier: identifier) {
                return cell
            }
        }

        return nil
    }

    private func debugFindAssistantOverlapRow(
        in root: UIView,
        identifier: String? = nil
    ) -> AssistantTimelineRowContentView? {
        if let row = root as? AssistantTimelineRowContentView,
           identifier == nil || row.accessibilityIdentifier == identifier {
            return row
        }

        for subview in root.subviews {
            if let row = debugFindAssistantOverlapRow(in: subview, identifier: identifier) {
                return row
            }
        }

        return nil
    }

    private func setCurrentQueueState(_ state: MessageQueueState) {
        queueStates[selectedSession] = state
    }

    private func applyQueueDraft(
        baseVersion: Int,
        steering: [MessageQueueDraftItem],
        followUp: [MessageQueueDraftItem]
    ) throws {
        let current = currentQueueState
        guard baseVersion == current.version else {
            throw QueueHarnessError.versionMismatch
        }

        let steeringItems = steering.map {
            MessageQueueItem(
                id: $0.id ?? UUID().uuidString,
                message: $0.message,
                attachments: $0.attachments,
                createdAt: $0.createdAt ?? Int(Date().timeIntervalSince1970 * 1_000)
            )
        }

        let followUpItems = followUp.map {
            MessageQueueItem(
                id: $0.id ?? UUID().uuidString,
                message: $0.message,
                attachments: $0.attachments,
                createdAt: $0.createdAt ?? Int(Date().timeIntervalSince1970 * 1_000)
            )
        }

        setCurrentQueueState(
            MessageQueueState(
                version: current.version + 1,
                steering: steeringItems,
                followUp: followUpItems
            )
        )
    }

    private func enqueueQueueItem(kind: MessageQueueKind) {
        let now = Int(Date().timeIntervalSince1970 * 1_000)
        let item = MessageQueueItem(
            id: UUID().uuidString,
            message: kind == .steer
                ? "Harness steer message \(streamTick + 1)"
                : "Harness follow-up message \(streamTick + 1)",
            createdAt: now
        )

        var next = currentQueueState
        switch kind {
        case .steer:
            next.steering.append(item)
        case .followUp:
            next.followUp.append(item)
        }

        next.version += 1
        setCurrentQueueState(next)
        heartbeat &+= 1
    }

    private func startQueueItem(kind: MessageQueueKind) {
        var next = currentQueueState
        let startedItem: MessageQueueItem

        switch kind {
        case .steer:
            guard !next.steering.isEmpty else { return }
            startedItem = next.steering.removeFirst()
        case .followUp:
            guard !next.followUp.isEmpty else { return }
            startedItem = next.followUp.removeFirst()
        }

        next.version += 1
        setCurrentQueueState(next)

        queueSystemEventSerial &+= 1
        let label = kind == .steer ? "Steering" : "Follow-up"
        let message = "Message Queue • \(label) started: \(startedItem.message)"

        var items = currentItems
        items.append(.systemEvent(
            id: "\(selectedSession.rawValue)-queue-started-\(queueSystemEventSerial)",
            message: message
        ))
        sessionItems[selectedSession] = items

        heartbeat &+= 1
    }

    private func clearQueueItems() {
        var next = currentQueueState
        next.steering = []
        next.followUp = []
        next.version += 1
        setCurrentQueueState(next)
        heartbeat &+= 1
    }

    private func toggleTheme() {
        switch themeID {
        case .dark:
            themeID = .oled
        case .oled:
            themeID = .light
        case .light:
            themeID = .night
        case .night, .custom:
            themeID = .dark
        }
    }

    private func refreshDiagnostics() {
        captureAssistantOverlapDiagnostics()
        heartbeat &+= 1
    }

    private func scheduleAssistantOverlapDiagnosticsRefresh(retriesRemaining: Int = 12) {
        guard UIHangHarnessConfig.assistantOverlapFixture, retriesRemaining > 0 else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            captureAssistantOverlapDiagnostics()
            heartbeat &+= 1

            if assistantOverlapReadySnapshot == 0 || assistantOverlapPhaseValue < Self.assistantOverlapLastPhase {
                scheduleAssistantOverlapDiagnosticsRefresh(retriesRemaining: retriesRemaining - 1)
            }
        }
    }

    private func captureAssistantOverlapDiagnostics() {
        guard UIHangHarnessConfig.assistantOverlapFixture else {
            assistantOverlapReadySnapshot = 0
            assistantRowHeightSnapshot = -1
            assistantRenderedOverlapSnapshot = -1
            assistantOverflowSnapshot = -1
            return
        }

        if let row = debugAssistantOverlapRowView(itemID: assistantOverlapItemID) {
            assistantOverlapReadySnapshot = 1
            assistantRowHeightSnapshot = Int(row.bounds.height.rounded())
            assistantRenderedOverlapSnapshot = Int(row.debugMarkdownRenderedOverlapPoints.rounded())
            assistantOverflowSnapshot = Int(row.debugMarkdownOverflowPoints.rounded())
            return
        }

        guard let snapshot = AssistantTimelineRowContentView.debugSnapshot(for: assistantOverlapItemID) else {
            assistantOverlapReadySnapshot = 0
            assistantRowHeightSnapshot = -1
            assistantRenderedOverlapSnapshot = -1
            assistantOverflowSnapshot = -1
            return
        }

        assistantOverlapReadySnapshot = 1
        assistantRowHeightSnapshot = Int(snapshot.frameHeight.rounded())
        assistantRenderedOverlapSnapshot = Int(snapshot.overlapPoints.rounded())
        assistantOverflowSnapshot = Int(snapshot.overflowPoints.rounded())
    }

    private func scrollToTop(animated: Bool) {
        guard let firstID = visibleItems.first?.id else { return }
        issueScrollCommand(id: firstID, anchor: .top, animated: animated)
    }

    private func scrollToBottom(animated: Bool) {
        guard let bottomItemID else { return }
        issueScrollCommand(id: bottomItemID, anchor: .bottom, animated: animated)
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

    private func diagnosticValue(id: String, value: Int) -> some View {
        Text("\(value)")
            .font(.caption2.monospacedDigit())
            .accessibilityIdentifier(id)
            .accessibilityLabel("\(value)")
            .accessibilityValue("\(value)")
    }
}

private enum QueueHarnessError: LocalizedError {
    case versionMismatch

    var errorDescription: String? {
        switch self {
        case .versionMismatch:
            return "Queue version mismatch"
        }
    }
}

// MARK: - Frame Interval Metrics

struct HarnessFrameIntervalSnapshot: Sendable {
    let sampleCount: Int
    let p95IntervalMs: Int
    let p99IntervalMs: Int
    let maxIntervalMs: Int
    let over50MsCount: Int
    let over34MsPercent: Int
    let over50MsPercent: Int
}

@MainActor
final class HarnessFrameIntervalMonitor: NSObject {
    private let interval34Ms = 34
    private let interval50Ms = 50
    private let maxSamples = 1_200

    private var displayLink: CADisplayLink?
    private var previousTimestamp: CFTimeInterval?
    private var intervalsMs: [Int] = []
    private var over34MsCount = 0
    private var over50MsCount = 0

    func start() {
        guard displayLink == nil else { return }

        let displayLink = CADisplayLink(target: self, selector: #selector(handleDisplayLink(_:)))
        displayLink.preferredFramesPerSecond = 0
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        previousTimestamp = nil
    }

    func reset() {
        previousTimestamp = nil
        intervalsMs.removeAll(keepingCapacity: false)
        over34MsCount = 0
        over50MsCount = 0
    }

    func snapshot() -> HarnessFrameIntervalSnapshot {
        guard !intervalsMs.isEmpty else {
            return HarnessFrameIntervalSnapshot(
                sampleCount: 0,
                p95IntervalMs: 0,
                p99IntervalMs: 0,
                maxIntervalMs: 0,
                over50MsCount: 0,
                over34MsPercent: 0,
                over50MsPercent: 0
            )
        }

        let sorted = intervalsMs.sorted()
        let sampleCount = sorted.count
        let p95 = percentileValue(in: sorted, percentile: 0.95)
        let p99 = percentileValue(in: sorted, percentile: 0.99)
        let maxInterval = sorted.last ?? 0

        return HarnessFrameIntervalSnapshot(
            sampleCount: sampleCount,
            p95IntervalMs: p95,
            p99IntervalMs: p99,
            maxIntervalMs: maxInterval,
            over50MsCount: over50MsCount,
            over34MsPercent: percent(part: over34MsCount, total: sampleCount),
            over50MsPercent: percent(part: over50MsCount, total: sampleCount)
        )
    }

    @objc
    private func handleDisplayLink(_ link: CADisplayLink) {
        let timestamp = link.timestamp
        guard let previousTimestamp else {
            self.previousTimestamp = timestamp
            return
        }

        let deltaMs = max(0, Int(((timestamp - previousTimestamp) * 1_000).rounded()))
        self.previousTimestamp = timestamp
        recordInterval(deltaMs)
    }

    private func recordInterval(_ value: Int) {
        intervalsMs.append(value)
        if value >= interval34Ms {
            over34MsCount &+= 1
        }
        if value >= interval50Ms {
            over50MsCount &+= 1
        }

        if intervalsMs.count > maxSamples {
            let removed = intervalsMs.removeFirst()
            if removed >= interval34Ms {
                over34MsCount = max(0, over34MsCount - 1)
            }
            if removed >= interval50Ms {
                over50MsCount = max(0, over50MsCount - 1)
            }
        }
    }

    private func percentileValue(in sorted: [Int], percentile: Double) -> Int {
        let clamped = min(1.0, max(0.0, percentile))
        let index = Int((Double(sorted.count - 1) * clamped).rounded(.down))
        return sorted[max(0, min(sorted.count - 1, index))]
    }

    private func percent(part: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int((Double(part) / Double(total) * 100).rounded())
    }
}

// MARK: - Main Thread Lag Watchdog

#if DEBUG
struct MainThreadStallContext: Sendable {
    let thresholdMs: Int
    let footprintMB: Int?
}

final class MainThreadLagWatchdog {
    var onStall: ((MainThreadStallContext) -> Void)?
    private let queue = DispatchQueue(label: "\(AppIdentifiers.subsystem).main-thread-watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?

    private let intervalMs = 1_000
    private let warnThresholdMs = 700
    private let stallLogCooldownMs = 2_000

    private var lastStallLogUptimeNs: UInt64 = 0

    func start() {
        guard timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .milliseconds(intervalMs),
            repeating: .milliseconds(intervalMs),
            leeway: .milliseconds(100)
        )

        timer.setEventHandler { [weak self] in
            self?.probeMainThread()
        }

        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func probeMainThread() {
        let thresholdMs = warnThresholdMs

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + .milliseconds(thresholdMs)) == .timedOut {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            let cooldownNs = UInt64(stallLogCooldownMs) * 1_000_000
            guard nowNs &- lastStallLogUptimeNs >= cooldownNs else { return }
            lastStallLogUptimeNs = nowNs

            let footprintMB = Self.currentFootprintMB()

            onStall?(
                MainThreadStallContext(
                    thresholdMs: thresholdMs,
                    footprintMB: footprintMB
                )
            )
        }
    }

    private static func currentFootprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)

        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / 1_048_576)
    }
}
#endif
#endif
