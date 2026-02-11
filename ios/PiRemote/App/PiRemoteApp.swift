import Darwin.Mach
import os.log
import SwiftUI
import UIKit

private let appLog = Logger(subsystem: "dev.chenda.PiRemote", category: "App")

@main
struct PiRemoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var connection = ServerConnection()
    @State private var navigation = AppNavigation()
    @State private var themeStore = ThemeStore()
#if DEBUG
    @State private var mainThreadLagWatchdog = MainThreadLagWatchdog()
    @State private var autoClientLogUploadInFlight = false
    @State private var lastAutoClientLogUploadMs: Int64 = 0
#endif
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if UIHangHarnessConfig.isEnabled {
                UIHangHarnessView()
            } else {
                ContentView()
                    .environment(connection)
                    .environment(connection.sessionStore)
                    .environment(connection.permissionStore)
                    .environment(connection.reducer)
                    .environment(connection.reducer.toolOutputStore)
                    .environment(connection.reducer.toolArgsStore)
                    .environment(connection.audioPlayer)
                    .environment(navigation)
                    .environment(themeStore)
                    .environment(\.theme, themeStore.appTheme)
                    .preferredColorScheme(themeStore.preferredColorScheme)
                    .onChange(of: scenePhase) { _, phase in
                        handleScenePhase(phase)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                        handleMemoryWarning()
                    }
                    .task {
                        await SentryService.shared.configure()
#if DEBUG
                        configureWatchdogHooks()
                        mainThreadLagWatchdog.start()
#endif
                        await setupNotifications()
                        await reconnectOnLaunch()
                    }
            }
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
#if DEBUG
            mainThreadLagWatchdog.start()
#endif
            Task { await connection.reconnectIfNeeded() }
        case .background:
#if DEBUG
            mainThreadLagWatchdog.stop()
#endif
            connection.flushAndSuspend()
            RestorationState.save(from: connection, navigation: navigation)
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func handleMemoryWarning() {
        let cacheStats = MarkdownSegmentCache.shared.snapshot()
        MarkdownSegmentCache.shared.clearAll()

        let reducerStats = connection.reducer.handleMemoryWarning()

        let cacheEntries = cacheStats.entries
        let cacheBytes = cacheStats.totalSourceBytes
        let toolOutputBytes = reducerStats.toolOutputBytesCleared
        let collapsedExpandedItems = reducerStats.expandedItemsCollapsed
        let imagesStripped = reducerStats.imagesStripped

        appLog.error(
            """
            MEM warning: cache=\(cacheEntries, privacy: .public)/\(cacheBytes, privacy: .public)B \
            toolOutput=\(toolOutputBytes, privacy: .public)B \
            expanded=\(collapsedExpandedItems, privacy: .public) \
            images=\(imagesStripped, privacy: .public)
            """
        )
    }

    private func configureWatchdogHooks() {
#if DEBUG
        mainThreadLagWatchdog.onStall = { context in
            Task { @MainActor in
                await self.handleWatchdogStall(context)
            }
        }
#endif
    }

#if DEBUG
    @MainActor
    private func handleWatchdogStall(_ context: MainThreadStallContext) async {
        guard scenePhase == .active else { return }
        guard !navigation.showOnboarding else { return }
        guard !autoClientLogUploadInFlight else { return }

        let nowMs = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        let cooldownMs: Int64 = 90_000
        guard nowMs - lastAutoClientLogUploadMs >= cooldownMs else { return }

        guard let sessionId = connection.sessionStore.activeSessionId else { return }
        guard let api = connection.apiClient else { return }

        autoClientLogUploadInFlight = true
        lastAutoClientLogUploadMs = nowMs

        ClientLog.error(
            "Diagnostics",
            "Auto-upload triggered by main-thread stall",
            metadata: [
                "sessionId": sessionId,
                "thresholdMs": String(context.thresholdMs),
                "footprintMB": context.footprintMB.map(String.init) ?? "n/a",
                "crumb": context.crumb,
                "rows": String(context.rows),
            ]
        )

        await SentryService.shared.captureMainThreadStall(
            thresholdMs: context.thresholdMs,
            footprintMB: context.footprintMB,
            crumb: context.crumb,
            rows: context.rows,
            sessionId: sessionId
        )

        let entries = await ClientLogBuffer.shared.snapshot(limit: 500, sessionId: sessionId)
        guard !entries.isEmpty else {
            autoClientLogUploadInFlight = false
            return
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"

        let request = ClientLogUploadRequest(
            generatedAt: nowMs,
            trigger: "stall-watchdog-auto",
            appVersion: version,
            buildNumber: build,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: UIDevice.current.model,
            entries: entries
        )

        guard let workspaceId = connection.sessionStore.workspaceId(for: sessionId), !workspaceId.isEmpty else {
            autoClientLogUploadInFlight = false
            return
        }

        do {
            try await api.uploadClientLogs(workspaceId: workspaceId, sessionId: sessionId, request: request)
            if connection.sessionStore.activeSessionId == sessionId {
                connection.reducer.appendSystemEvent("Auto-uploaded \(entries.count) client log entries after stall")
            }
        } catch {
            ClientLog.error(
                "Diagnostics",
                "Auto-upload failed",
                metadata: [
                    "sessionId": sessionId,
                    "error": error.localizedDescription,
                ]
            )
        }

        autoClientLogUploadInFlight = false
    }
#endif

    private func setupNotifications() async {
        let notificationService = PermissionNotificationService.shared
        await notificationService.setup()

        // Wire notification actions back to the connection
        notificationService.onPermissionResponse = { [weak connection] permissionId, action in
            guard let connection else {
                return
            }
            Task {
                try? await connection.respondToPermission(id: permissionId, action: action)
            }
        }

        // Configure push registration with the connection
        PushRegistration.shared.configure(connection: connection)

        // Navigate to session when user taps a push notification body
        notificationService.onNavigateToPermission = { [weak connection] _, sessionId in
            guard let connection, !sessionId.isEmpty else {
                return
            }
            connection.sessionStore.activeSessionId = sessionId
            navigation.selectedTab = .workspaces
        }
    }

    private func reconnectOnLaunch() async {
        let startedAt = Date()
        var launchOutcome = "unknown"
        var usedCachedSessions = false

        defer {
            let outcome = launchOutcome
            let usedCache = usedCachedSessions
            let launchDurationMs = max(0, Int((Date().timeIntervalSince(startedAt) * 1_000.0).rounded()))

            Task.detached(priority: .utility) {
                let metrics = await TimelineCache.shared.metrics()
                let metadata: [String: String] = [
                    "outcome": outcome,
                    "durationMs": String(launchDurationMs),
                    "usedCachedSessions": usedCache ? "1" : "0",
                    "cacheHits": String(metrics.hits),
                    "cacheMisses": String(metrics.misses),
                    "decodeFailures": String(metrics.decodeFailures),
                    "cacheWrites": String(metrics.writes),
                    "avgLoadMs": String(metrics.averageLoadMs),
                ]

                ClientLog.info("Cache", "Launch cache telemetry", metadata: metadata)

                if launchDurationMs >= 1_500 || metrics.decodeFailures > 0 {
                    appLog.error(
                        """
                        CACHE launch outcome=\(outcome, privacy: .public) \
                        durMs=\(launchDurationMs, privacy: .public) \
                        hits=\(metrics.hits, privacy: .public) \
                        misses=\(metrics.misses, privacy: .public) \
                        decodeFailures=\(metrics.decodeFailures, privacy: .public) \
                        root=\(metrics.rootPath, privacy: .public)
                        """
                    )
                } else {
                    appLog.notice(
                        """
                        CACHE launch outcome=\(outcome, privacy: .public) \
                        durMs=\(launchDurationMs, privacy: .public) \
                        usedCached=\(usedCache, privacy: .public)
                        """
                    )
                }
            }
        }

        // 1. Load credentials from Keychain
        guard var creds = KeychainService.loadCredentials() else {
            launchOutcome = "no_credentials"
            navigation.showOnboarding = true
            return
        }

        guard connection.configure(credentials: creds) else {
            launchOutcome = "invalid_credentials"
            navigation.showOnboarding = true
            return
        }

        guard let api = connection.apiClient else {
            launchOutcome = "no_api_client"
            navigation.showOnboarding = true
            return
        }

        // Enforce trust + transport contract as early as possible.
        do {
            let profile = try await api.securityProfile()

            if let violation = ConnectionSecurityPolicy.evaluate(host: creds.host, profile: profile) {
                launchOutcome = "blocked_transport_policy"
                appLog.error("SECURITY transport policy blocked host=\(creds.host, privacy: .public): \(violation.localizedDescription, privacy: .public)")
                navigation.showOnboarding = true
                return
            }

            let serverFingerprint = profile.identity.normalizedFingerprint
            let storedFingerprint = creds.normalizedServerFingerprint

            if (profile.requirePinnedServerIdentity ?? false) {
                if let serverFingerprint, let storedFingerprint, serverFingerprint != storedFingerprint {
                    launchOutcome = "identity_mismatch"
                    appLog.error(
                        "SECURITY pinned identity mismatch host=\(creds.host, privacy: .public) stored=\(storedFingerprint, privacy: .public) server=\(serverFingerprint, privacy: .public)"
                    )
                    navigation.showOnboarding = true
                    return
                }

                if serverFingerprint == nil {
                    launchOutcome = "missing_server_fingerprint"
                    appLog.error("SECURITY pinned identity required but server fingerprint missing")
                    navigation.showOnboarding = true
                    return
                }
            }

            let upgraded = creds.applyingSecurityProfile(profile)
            if upgraded != creds {
                try? KeychainService.saveCredentials(upgraded)
                creds = upgraded
                guard connection.configure(credentials: upgraded) else {
                    launchOutcome = "blocked_transport_policy"
                    navigation.showOnboarding = true
                    return
                }
            }
        } catch {
            launchOutcome = "missing_security_profile"
            appLog.error("SECURITY profile check failed on launch: \(error.localizedDescription, privacy: .public)")
            navigation.showOnboarding = true
            return
        }

        navigation.showOnboarding = false

        // 2. Restore UI state (tab, active session, draft, scroll position)
        if let restored = RestorationState.load() {
            navigation.selectedTab = AppTab(rawString: restored.selectedTab)
            connection.sessionStore.activeSessionId = restored.activeSessionId
            connection.composerDraft = restored.composerDraft
            connection.scrollAnchorItemId = restored.scrollAnchorItemId
            connection.scrollWasNearBottom = restored.wasNearBottom ?? true
        }

        // 3. Show cached data immediately (before any network calls)
        let cache = TimelineCache.shared
        if let cachedSessions = await cache.loadSessionList() {
            usedCachedSessions = true
            connection.sessionStore.applyServerSnapshot(cachedSessions)
        }

        // 4. Refresh session list from server
        connection.sessionStore.markSyncStarted()
        do {
            let sessions = try await api.listSessions()
            launchOutcome = "online_refresh_ok"

            connection.sessionStore.applyServerSnapshot(sessions)
            connection.sessionStore.markSyncSucceeded()
            Task.detached { await TimelineCache.shared.saveSessionList(sessions) }

            // 5. Evict trace caches for deleted sessions
            let activeIds = Set(sessions.map(\.id))
            Task.detached { await TimelineCache.shared.evictStaleTraces(keepIds: activeIds) }

            // 6. Load workspaces + skills (cache-backed internally)
            await connection.workspaceStore.load(api: api)

            // 7. Register for push notifications (after successful server connection)
            await PushRegistration.shared.requestAndRegister()
        } catch {
            connection.sessionStore.markSyncFailed()
            launchOutcome = "offline_cache_only"
            // Offline — cached data already shown above
        }
    }
}

private enum UIHangHarnessConfig {
    static var isEnabled: Bool {
#if DEBUG
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("--ui-hang-harness")
            || processInfo.environment["PI_UI_HANG_HARNESS"] == "1"
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
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
#else
        false
#endif
    }
}

private struct UIHangHarnessView: View {
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
        case .tokyoNight: return 0
        case .tokyoNightDay: return 1
        case .appleDark: return 2
        }
    }

    private var perfSnapshot: ChatTimelinePerf.Snapshot {
        ChatTimelinePerf.snapshot()
    }

    private var nativeAssistantMode: Int { 1 }
    private var nativeUserMode: Int { 1 }
    private var nativeThinkingMode: Int { 1 }
    private var nativeToolMode: Int { 1 }

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
                    connection: connection,
                    audioPlayer: connection.audioPlayer,
                    theme: themeID.appTheme,
                    themeID: themeID
                )
            )
            .background(Color.tokyoBg)

            TextField("Harness input", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("harness.input")

            diagnosticsBar
        }
        .padding()
        .background(Color.tokyoBg.ignoresSafeArea())
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
            diagnosticValue(id: "diag.applyMs", value: perf.applyLastMs)
            diagnosticValue(id: "diag.layoutMs", value: perf.layoutLastMs)
            diagnosticValue(id: "diag.cellMs", value: perf.cellConfigureLastMs)
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
        scrollController._diagnosticItemCount = visible.count

        if UIHangHarnessConfig.uiTestMode {
            if scrollController.isCurrentlyNearBottom, let bottomID = visible.last?.id {
                issueScrollCommand(id: bottomID, anchor: .bottom, animated: false)
            }
        } else {
            scrollController.handleRenderVersionChange(
                streamingID: streamID,
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

    private func toggleTheme() {
        switch themeID {
        case .tokyoNight:
            themeID = .tokyoNightDay
        case .tokyoNightDay:
            themeID = .appleDark
        case .appleDark:
            themeID = .tokyoNight
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

#if DEBUG
private struct MainThreadStallContext: Sendable {
    let thresholdMs: Int
    let footprintMB: Int?
    let crumb: String
    let rows: Int
}

private final class MainThreadLagWatchdog {
    var onStall: ((MainThreadStallContext) -> Void)?
    private let queue = DispatchQueue(label: "dev.chenda.PiRemote.main-thread-watchdog", qos: .utility)
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
