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
        let mixedContentFixtures: Bool
    }

    private struct StickyState {
        let noStream: Bool
        let includeVisualFixtures: Bool
        let mixedContentFixtures: Bool
    }

    // XCTest repeat mode can transiently reinstall/relaunch the app without
    // preserving our explicit harness launch args/env. Persist the last
    // harness launch knobs briefly so simulator relaunches stay in harness mode.
    private static let stickyTimestampKey = "\(AppIdentifiers.subsystem).uiHangHarness.sticky.timestamp"
    private static let stickyNoStreamKey = "\(AppIdentifiers.subsystem).uiHangHarness.sticky.noStream"
    private static let stickyVisualFixturesKey = "\(AppIdentifiers.subsystem).uiHangHarness.sticky.visualFixtures"
    private static let stickyMixedContentKey = "\(AppIdentifiers.subsystem).uiHangHarness.sticky.mixedContent"
    private static let stickyTTLSeconds: TimeInterval = 180

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

    static var mixedContentFixtures: Bool {
#if DEBUG
        launchContext.mixedContentFixtures
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
        let explicitMixedContent = environment["PI_UI_HANG_MIXED_CONTENT"] == "1"

        if explicitHarness {
            persistStickyState(
                noStream: explicitNoStream,
                includeVisualFixtures: explicitVisualFixtures,
                mixedContentFixtures: explicitMixedContent
            )
            return LaunchContext(
                isEnabled: true,
                streamDisabled: explicitNoStream,
                includeVisualFixtures: explicitVisualFixtures,
                mixedContentFixtures: explicitMixedContent
            )
        }

        if isLikelyXCTestHarnessRelaunch(environment: environment),
           let stickyState = loadStickyState() {
            return LaunchContext(
                isEnabled: true,
                streamDisabled: stickyState.noStream,
                includeVisualFixtures: stickyState.includeVisualFixtures,
                mixedContentFixtures: stickyState.mixedContentFixtures
            )
        }

        if !isLikelyXCTestHarnessRelaunch(environment: environment) {
            clearStickyState()
        }

        return LaunchContext(
            isEnabled: false,
            streamDisabled: explicitNoStream,
            includeVisualFixtures: explicitVisualFixtures,
            mixedContentFixtures: explicitMixedContent
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
        mixedContentFixtures: Bool
    ) {
        let now = Date().timeIntervalSince1970
        stickyDefaults.set(now, forKey: stickyTimestampKey)
        stickyDefaults.set(noStream, forKey: stickyNoStreamKey)
        stickyDefaults.set(includeVisualFixtures, forKey: stickyVisualFixturesKey)
        stickyDefaults.set(mixedContentFixtures, forKey: stickyMixedContentKey)
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
            mixedContentFixtures: defaults.bool(forKey: stickyMixedContentKey)
        )
    }

    private static func clearStickyState() {
        let defaults = stickyDefaults
        defaults.removeObject(forKey: stickyTimestampKey)
        defaults.removeObject(forKey: stickyNoStreamKey)
        defaults.removeObject(forKey: stickyVisualFixturesKey)
        defaults.removeObject(forKey: stickyMixedContentKey)
    }
#else
    private static func resolveLaunchContext() -> LaunchContext {
        LaunchContext(
            isEnabled: false,
            streamDisabled: true,
            includeVisualFixtures: false,
            mixedContentFixtures: false
        )
    }
#endif
#else
    private static func resolveLaunchContext() -> LaunchContext {
        LaunchContext(
            isEnabled: false,
            streamDisabled: true,
            includeVisualFixtures: false,
            mixedContentFixtures: false
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

                items.append(.permission(
                    PermissionRequest(
                        id: "\(sessionPrefix)-visual-permission-pending",
                        sessionId: sessionID,
                        tool: "bash",
                        input: [
                            "command": .string("rm -rf /tmp/demo"),
                        ],
                        displaySummary: "command: rm -rf /tmp/demo",
                        reason: "Filesystem mutation requires approval",
                        timeoutAt: visualTS.addingTimeInterval(120),
                        expires: true
                    )
                ))

                items.append(.permissionResolved(
                    id: "\(sessionPrefix)-visual-permission-resolved",
                    outcome: .allowed,
                    tool: "read",
                    summary: "path: ios/Oppi/Features/Chat/ChatTimelineCollectionView.swift"
                ))

                items.append(.systemEvent(
                    id: "\(sessionPrefix)-visual-system",
                    message: "Context compacted for visual pass"
                ))

                items.append(.error(
                    id: "\(sessionPrefix)-visual-error",
                    message: "Sample error row for native renderer visual verification"
                ))

                items.append(.audioClip(
                    id: "\(sessionPrefix)-visual-audio",
                    title: "Harness Audio Clip",
                    fileURL: URL(fileURLWithPath: "/tmp/\(sessionPrefix)-harness-audio.wav"),
                    timestamp: visualTS.addingTimeInterval(0.2)
                ))
            }

            result[session] = items
        }

        return result
    }()

    @State private var connection = ServerConnection()
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

    private var currentItems: [ChatItem] {
        sessionItems[selectedSession] ?? []
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

    /// For UI test harness mode, disable busy cursor/working indicator animations
    /// so XCUITest can reach idle between interactions.
    private var collectionStreamingAssistantID: String? {
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
        case .light: return 1
        case .custom: return 2
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

    private var extensionMarkdownIsExpandedValue: Int {
        connection.reducer.expandedItemIDs.contains(extensionMarkdownToolID) ? 1 : 0
    }

    private var extensionTextIsExpandedValue: Int {
        connection.reducer.expandedItemIDs.contains(extensionTextToolID) ? 1 : 0
    }

    private var extensionMarkdownIsTopVisibleValue: Int {
        scrollController.currentTopVisibleItemId == extensionMarkdownToolID ? 1 : 0
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
                    onOpenFile: { _ in },
                    onShowEarlier: {
                        renderWindow = min(currentItems.count, renderWindow + Self.renderWindowStep)
                    },
                    scrollCommand: pendingScrollCommand,
                    scrollController: scrollController,
                    reducer: connection.reducer,
                    toolOutputStore: connection.reducer.toolOutputStore,
                    toolArgsStore: connection.reducer.toolArgsStore,
                    toolSegmentStore: connection.reducer.toolSegmentStore,
                    toolDetailsStore: connection.reducer.toolDetailsStore,
                    connection: connection,
                    audioPlayer: connection.audioPlayer,
                    theme: themeID.appTheme,
                    themeID: themeID
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
            seedExtensionMarkdownFixtures()
            seedExtensionTextFixtures()
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
            seedExtensionMarkdownFixtures()
            seedExtensionTextFixtures()
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

        if UIHangHarnessConfig.uiTestMode {
            if scrollController.isCurrentlyNearBottom, let bottomID = visible.last?.id {
                issueScrollCommand(id: bottomID, anchor: .bottom, animated: false)
            }
        } else {
            scrollController.handleContentChange(
                isBusy: true,
                streamingAssistantID: streamID,
                bottomItemID: visible.last?.id
            ) { targetID in
                issueScrollCommand(id: targetID, anchor: .bottom, animated: false)
            }
        }
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

    private func seedExtensionMarkdownFixtures() {
        let extensionIDs = Set(HarnessSession.allCases.map(extensionMarkdownToolItemID(for:)))
        connection.reducer.toolOutputStore.clear(itemIDs: extensionIDs)

        for session in HarnessSession.allCases {
            let extensionID = extensionMarkdownToolItemID(for: session)
            let markdown = visualExtensionMarkdown(for: session)

            connection.reducer.toolArgsStore.set([
                "text": .string(markdown),
                "tags": .array([
                    .string("harness"),
                    .string("extension-markdown"),
                    .string(session.rawValue),
                ]),
            ], for: extensionID)
            _ = connection.reducer.toolOutputStore.append(markdown, to: extensionID)
        }
    }

    private func seedExtensionTextFixtures() {
        let extensionIDs = Set(HarnessSession.allCases.map(extensionTextToolItemID(for:)))
        connection.reducer.toolOutputStore.clear(itemIDs: extensionIDs)

        for session in HarnessSession.allCases {
            let extensionID = extensionTextToolItemID(for: session)
            let output = visualExtensionTextOutput(for: session)
            _ = connection.reducer.toolOutputStore.append(output, to: extensionID)
        }
    }

    private func visualUserImageItemID(for session: HarnessSession) -> String {
        "\(session.rawValue)-visual-user-image"
    }

    private func expandVisualToolSet() {
        let ids = visualToolIDs(for: selectedSession)
        guard !ids.isEmpty else { return }

        for id in ids {
            connection.reducer.expandedItemIDs.insert(id)
        }

        heartbeat &+= 1
        scrollToBottom(animated: false)
    }

    private func focusExtensionMarkdownTool() {
        let extensionID = extensionMarkdownToolItemID(for: selectedSession)
        guard currentItems.contains(where: { $0.id == extensionID }) else { return }

        renderWindow = currentItems.count
        connection.reducer.expandedItemIDs.insert(extensionID)
        heartbeat &+= 1
        issueScrollCommand(id: extensionID, anchor: .top, animated: false)
    }

    private func focusExtensionTextTool() {
        let extensionID = extensionTextToolItemID(for: selectedSession)
        guard currentItems.contains(where: { $0.id == extensionID }) else { return }

        renderWindow = currentItems.count
        connection.reducer.expandedItemIDs.insert(extensionID)
        heartbeat &+= 1
        issueScrollCommand(id: extensionID, anchor: .top, animated: false)
    }

    private func scrollToVisualUserImage(animated: Bool) {
        let itemID = visualUserImageItemID(for: selectedSession)
        guard currentItems.contains(where: { $0.id == itemID }) else { return }
        issueScrollCommand(id: itemID, anchor: .top, animated: animated)
    }

    private func toggleTheme() {
        switch themeID {
        case .dark:
            themeID = .light
        case .light, .custom:
            themeID = .dark
        }
    }

    private func refreshDiagnostics() {
        heartbeat &+= 1
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

// MARK: - Frame Interval Metrics

struct HarnessFrameIntervalSnapshot: Sendable {
    let sampleCount: Int
    let p95IntervalMs: Int
    let p99IntervalMs: Int
    let maxIntervalMs: Int
    let over34MsCount: Int
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
                over34MsCount: 0,
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
            over34MsCount: over34MsCount,
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
