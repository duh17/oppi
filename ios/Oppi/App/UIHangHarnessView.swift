import Darwin.Mach
import SwiftUI

// MARK: - Harness Configuration

enum UIHangHarnessConfig {
    static var isEnabled: Bool {
#if DEBUG
#if targetEnvironment(simulator)
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("--ui-hang-harness")
            || processInfo.environment["PI_UI_HANG_HARNESS"] == "1"
#else
        return false
#endif
#else
        return false
#endif
    }

    static var streamDisabled: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["PI_UI_HANG_NO_STREAM"] == "1"
#else
        true
#endif
    }

    static var uiTestMode: Bool {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return environment["PI_UI_HANG_UI_TEST_MODE"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
#else
        false
#endif
    }

    static var includeVisualFixtures: Bool {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return !uiTestMode || environment["PI_UI_HANG_INCLUDE_VISUAL_FIXTURES"] == "1"
#else
        false
#endif
    }
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

        // UI tests need fast launch and quiescence. Use smaller, plain-text
        // fixtures in XCTest mode to avoid long markdown parse warmups.
        let turnsPerSession = UIHangHarnessConfig.uiTestMode ? 36 : 120
        let usePlainAssistantText = UIHangHarnessConfig.uiTestMode

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
                    id: "\(sessionPrefix)-visual-tool-todo",
                    tool: "todo",
                    argsSummary: "action: list, status: in_progress",
                    outputPreview: "- [ ] keep renderer parity checklist up to date",
                    outputByteCount: 80,
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
                        risk: .high,
                        reason: "Filesystem mutation in host mode",
                        timeoutAt: visualTS.addingTimeInterval(120),
                        expires: true,
                        resolutionOptions: nil
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

    private var bottomItemID: String? {
        visibleItems.last?.id
    }

    var body: some View {
        VStack(spacing: 10) {
            Text("Harness Ready")
                .font(.caption)
                .accessibilityIdentifier("harness.ready")

            controlsBar

            ChatTimelineCollectionView(
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
                    connection: connection,
                    audioPlayer: connection.audioPlayer,
                    theme: themeID.appTheme,
                    themeID: themeID
                )
            )
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
            ChatTimelinePerf.reset()
            renderWindow = min(Self.initialRenderWindow, currentItems.count)
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
            ThemeRuntimeState.setThemeID(originalThemeID)
        }
        .onChange(of: selectedSession) { _, _ in
            renderWindow = min(Self.initialRenderWindow, currentItems.count)
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
            }
        }
    }

    private var diagnosticsBar: some View {
        let perf = perfSnapshot
        return HStack(spacing: 10) {
            diagnosticValue(id: "diag.heartbeat", value: heartbeat)
            diagnosticValue(id: "diag.stallCount", value: stallCount)
            diagnosticValue(id: "diag.itemCount", value: currentItems.count)
            diagnosticValue(id: "diag.nearBottom", value: nearBottomValue)
            diagnosticValue(id: "diag.topIndex", value: topVisibleIndex)
            diagnosticValue(id: "diag.streamTick", value: streamTick)
            diagnosticValue(id: "diag.theme", value: themeOrdinal)
            diagnosticValue(id: "diag.nativeMode", value: nativeAssistantMode)
            diagnosticValue(id: "diag.nativeUserMode", value: nativeUserMode)
            diagnosticValue(id: "diag.nativeThinkingMode", value: nativeThinkingMode)
            diagnosticValue(id: "diag.nativeToolMode", value: nativeToolMode)
            diagnosticValue(id: "diag.visualTools", value: visualToolCount)
            diagnosticValue(id: "diag.applyMs", value: perf.applyLastMs)
            diagnosticValue(id: "diag.layoutMs", value: perf.layoutLastMs)
            diagnosticValue(id: "diag.cellMs", value: perf.cellConfigureLastMs)
            diagnosticValue(id: "diag.applyMax", value: perf.applyMaxMs)
            diagnosticValue(id: "diag.layoutMax", value: perf.layoutMaxMs)
            diagnosticValue(id: "diag.cellMax", value: perf.cellConfigureMaxMs)
            diagnosticValue(id: "diag.perfGuardrail", value: perf.hardGuardrailBreachCount)
            diagnosticValue(id: "diag.failsafeRows", value: perf.failsafeConfigureCount)
            diagnosticValue(id: "diag.scrollRate", value: perf.scrollCommandsPerSecond)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            "\(prefix)-visual-tool-todo",
            "\(prefix)-visual-tool-read-image",
            "\(prefix)-visual-tool-unknown",
        ]
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

// MARK: - Main Thread Breadcrumb

/// Lightweight breadcrumb placeholders kept for stall reports.
/// Hot-path writers were intentionally removed to reduce instrumentation overhead.
enum MainThreadBreadcrumb {
    static var current: String { "n/a" }
    static var rowCount: Int { 0 }
}

// MARK: - Main Thread Lag Watchdog

#if DEBUG
struct MainThreadStallContext: Sendable {
    let thresholdMs: Int
    let footprintMB: Int?
    let crumb: String
    let rows: Int
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

            let crumb = MainThreadBreadcrumb.current
            let rows = MainThreadBreadcrumb.rowCount
            let footprintMB = Self.currentFootprintMB()

            onStall?(
                MainThreadStallContext(
                    thresholdMs: thresholdMs,
                    footprintMB: footprintMB,
                    crumb: crumb,
                    rows: rows
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
