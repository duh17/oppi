import AppIntents
import os.log
import SwiftUI
import UIKit

private let appLog = Logger(subsystem: AppIdentifiers.subsystem, category: "App")
private let lifecycleSignposter = OSSignposter(
    subsystem: AppIdentifiers.subsystem,
    category: "AppLifecyclePerf"
)
#if DEBUG
/// Bounded scene-transition state for the DEBUG/E2E accessibility probe.
/// It deliberately excludes user, server, workspace, and session values.
@MainActor
final class E2ELifecycleDiagnostics {
    static let shared = E2ELifecycleDiagnostics()

    private(set) var sequence = 0
    private(set) var backgroundCompleted = 0
    private(set) var activeCompleted = 0
    private(set) var backgroundDurationMs = 0
    private(set) var activeDurationMs = 0
    private(set) var phase = "unknown"
    private(set) var step = "unknown"

    func record(phase: String, step: String) {
        sequence &+= 1
        self.phase = phase
        self.step = step
    }

    /// Completion is recorded at the full app-owned synchronous scene-handler
    /// boundary. It excludes system scene delivery and asynchronous reconnect work.
    func complete(phase: String, durationMs: Int) {
        let boundedDurationMs = min(60_000, max(0, durationMs))
        switch phase {
        case "background":
            backgroundCompleted &+= 1
            backgroundDurationMs = boundedDurationMs
        case "active":
            activeCompleted &+= 1
            activeDurationMs = boundedDurationMs
        default:
            break
        }
    }

    var accessibilityValue: String {
        "seq=\(sequence) phase=\(phase) step=\(step) bgCompleted=\(backgroundCompleted) activeCompleted=\(activeCompleted) bgMs=\(backgroundDurationMs) activeMs=\(activeDurationMs)"
    }
}
#endif

/// Gate reconnect work so foreground transitions only trigger recovery
/// after an actual background cycle (not every inactive↔active bounce).
struct ForegroundReconnectGate {
    private(set) var hasEnteredBackground = false

    mutating func shouldReconnect(for phase: ScenePhase) -> Bool {
        switch phase {
        case .background:
            hasEnteredBackground = true
            return false

        case .active:
            let shouldReconnect = hasEnteredBackground
            hasEnteredBackground = false
            return shouldReconnect

        case .inactive:
            return false

        @unknown default:
            return false
        }
    }
}



/// A `[[link]]` that matched more than one resource; the user picks one.
struct LaunchRefreshTelemetryOutcome: Equatable, Sendable {
    let overall: String
    let workspace: String
    let session: String

    static func resolve(
        selectedServerReady: Bool,
        workspaceFailed: Bool,
        sessionFailed: Bool
    ) -> Self {
        guard selectedServerReady else {
            return Self(
                overall: "offline_cache_only",
                workspace: "not_attempted",
                session: "not_attempted"
            )
        }

        let workspace = workspaceFailed ? "failure" : "success"
        let session = sessionFailed ? "failure" : "success"
        let overall: String
        switch (workspaceFailed, sessionFailed) {
        case (false, false):
            overall = "online_refresh_ok"
        case (true, true):
            overall = "offline_cache_only"
        default:
            overall = "online_refresh_partial"
        }
        return Self(overall: overall, workspace: workspace, session: session)
    }
}

/// The app: its scoped services, launch, scene phases, diagnostics, and
/// memory. Every open (URLs, notification taps, Siri, controls, links) goes to
/// the window's `AppOpener`; the UIKit scene (`SceneDelegate`) owns the window
/// and forwards URLs and phases, and `AppRootViewController` owns what the
/// window shows.
@MainActor @Observable
final class OppiApp {
    let root: AppRootEnvironment
    private var coordinator: ConnectionCoordinator { root.coordinator }
    private var navigation: AppNavigation { root.navigation }
    private var composerDraftStore: ComposerDraftStore { root.composerDraftStore }
    private var opener: AppOpener { root.opener }

    /// Convenience accessor — most lifecycle code targets the active connection.
    private var connection: ServerConnection { coordinator.activeConnection }
    private var serverStore: ServerStore { coordinator.serverStore }

    @ObservationIgnored private let navigationRouteTelemetry = NavigationRouteTelemetryCoalescer()
    @ObservationIgnored private let mainThreadLagWatchdog = MainThreadLagWatchdog()
    @ObservationIgnored private var foregroundReconnectGate = ForegroundReconnectGate()
    @ObservationIgnored private let backgroundKeepAlive = BackgroundKeepAlive()
    @ObservationIgnored private var scenePhase: ScenePhase = .inactive
    @ObservationIgnored private var appEventObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var hasConnectedScene = false

    init() {
#if DEBUG
        // E2E runs with real transitions off so taps are not racing animation.
        // A case that proves a transition handoff opts back in: see
        // `OPPI_E2E_ANIMATIONS` in TimelineInlineVideoNativePlayE2ETests.
        if ProcessInfo.processInfo.environment["PI_E2E_INVITE_URL"] != nil,
           ProcessInfo.processInfo.environment["OPPI_E2E_ANIMATIONS"] != "1" {
            UIView.setAnimationsEnabled(false)
        }
#endif
        FeatureEducationTips.configure()
        LocalHTTPCache.disableDiskCacheAndPurgeLeftovers()
        let coordinator = ConnectionCoordinator(
            serverStore: ServerStore(),
            seenStorage: SessionSeenLedgerStorage(defaults: .standard)
        )
        let navigation = AppNavigation()
        let composerDraftStore = ComposerDraftStore()
        // The opener exists before any scene connects, so a notification
        // response or scene URL delivered during launch has its owner.
        let opener = AppOpener(
            coordinator: coordinator,
            navigation: navigation,
            composerDraftStore: composerDraftStore
        )
        root = AppRootEnvironment(
            coordinator: coordinator,
            navigation: navigation,
            themeStore: ThemeStore(),
            quickCommentTemplateStore: QuickCommentTemplateStore(),
            composerDraftStore: composerDraftStore,
            chatReaderPayloadStore: ChatReaderPayloadStore(),
            sessionRows: SessionRowDisplayStore(),
            opener: opener
        )
    }

    /// The window's root: a debug harness chosen by launch arguments, else the app.
    func makeRootViewController() -> UIViewController {
#if DEBUG
        if ReviewCommentStashHarnessConfig.isEnabled {
            return ReviewCommentStashHarnessController(root: root)
        }
        if let debugHarness {
            // Harnesses and previews render app screens, the timeline, and
            // UIKit-hosted SwiftUI without the app's root controller. The
            // router and HostFactory need the app root above them there too.
            return HostFactory.content(debugHarness.modifier(AppLockAccessibilityHidden()), root: root)
        }
#endif
        return AppRootViewController(app: self)
    }

    // MARK: - Scene

    /// The scene's window is up: wire the app-wide handlers and launch.
    func sceneDidConnect() {
        guard !hasConnectedScene else { return }
        hasConnectedScene = true
        observeAppEvents()
        observeNavigation()
        recordDiagnosticContext(lifecycleEvent: "root", lifecycleStep: "appear")
        Task {
            await startApp()
            OppiShortcutsProvider.updateAppShortcutParameters()
        }
    }

    func sceneWillEnterForeground() { changeScenePhase(to: .inactive) }
    func sceneDidBecomeActive() {
        changeScenePhase(to: .active)
        // A request whose server was unreachable retries here.
        opener.sceneDidBecomeActive()
    }
    func sceneWillResignActive() { changeScenePhase(to: .inactive) }
    func sceneDidEnterBackground() {
        opener.sceneDidEnterBackground()
        changeScenePhase(to: .background)
    }

    private func changeScenePhase(to phase: ScenePhase) {
        guard phase != scenePhase else { return }
        scenePhase = phase
        handleScenePhase(phase)
    }

    // MARK: - App-wide events

    private func observeAppEvents() {
        observeAppEvent(UIApplication.didReceiveMemoryWarningNotification) { app, _ in
            app.handleMemoryWarning()
        }
        observeAppEvent(AppFont.didRebuildNotification) { _, _ in
            MarkdownSegmentCache.shared.clearAll()
            ToolRowRenderCache.evictAll()
        }
        // Message fonts bake the Dynamic Type size in at rebuild.
        observeAppEvent(UIContentSizeCategory.didChangeNotification) { _, _ in
            AppFont.rebuild()
        }
    }

    private func observeAppEvent(
        _ name: Notification.Name,
        perform: @escaping @MainActor (OppiApp, Notification) -> Void
    ) {
        appEventObservers.append(NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Delivered on the main queue, where it stays.
            nonisolated(unsafe) let notification = notification
            MainActor.assumeIsolated {
                guard let self else { return }
                perform(self, notification)
            }
        })
    }

    /// Navigation changes feed the crash context and route telemetry.
    private func observeNavigation() {
        let navigation = navigation
        recordNavigationChanges("launch_phase") { navigation.launchPhase }
        recordNavigationChanges("onboarding") { navigation.showOnboarding }
        recordNavigationChanges("quick_session") { navigation.showQuickSession }
        recordNavigationChanges("workspace_filter") { navigation.selectedWorkspaceFilter }
        recordNavigationChanges("workspace_stack_depth") { navigation.workspaceStackRouteElements.count }
        recordNavigationChanges("stack_destination") { navigation.workspaceStackDiagnosticContext }
        recordNavigationChanges("split_destination") { navigation.visibleSplitDiagnosticContext }
        recordNavigationChanges("split_detail_depth") { navigation.splitDetailPathElements.count }
    }

    private func recordNavigationChanges<Value: Equatable & Sendable>(
        _ step: String,
        of value: @escaping @MainActor @Sendable () -> Value
    ) {
        onChange(of: value) { app in
            app.recordDiagnosticContext(lifecycleEvent: "navigation", lifecycleStep: step)
        }
    }

    /// Runs `perform` each time `value` changes, not for its first value.
    private func onChange<Value: Equatable & Sendable>(
        of value: @escaping @MainActor @Sendable () -> Value,
        perform: @escaping @MainActor (OppiApp) -> Void
    ) {
        Task { [weak self] in
            var previous: Value?
            for await current in Observations(value) {
                defer { previous = current }
                guard let previous, previous != current else { continue }
                guard let self else { return }
                perform(self)
            }
        }
    }

#if DEBUG
    /// The harness or screenshot preview chosen by launch arguments, or nil
    /// for the app.
    private var debugHarness: AnyView? {
        if HTMLDOMAnnotationHarnessConfig.isEnabled {
            return AnyView(HTMLDOMAnnotationHarnessView().ignoresSafeArea())
        }
        if WikiLineAnchorHarnessConfig.isEnabled {
            return AnyView(WikiLineAnchorHarnessView().ignoresSafeArea())
        }
        if SemanticPickHarnessConfig.isEnabled {
            return AnyView(SemanticPickHarnessView().ignoresSafeArea())
        }
        if FullScreenReviewCommentHarnessConfig.isEnabled {
            return AnyView(FullScreenReviewCommentHarnessView().ignoresSafeArea())
        }
        if CodeGutterAlignmentHarnessConfig.isEnabled {
            return AnyView(CodeGutterAlignmentHarnessView().ignoresSafeArea())
        }
        if CodeBlockWrappingHarnessConfig.isEnabled {
            return AnyView(CodeBlockWrappingHarnessView().ignoresSafeArea())
        }
        if ChatOutlineColdHarnessConfig.isEnabled {
            return AnyView(ChatOutlineColdHarnessView())
        }
        if NavigationChromeProfileConfig.isEnabled {
            return AnyView(NavigationChromeProfileHarnessView())
        }
        if UIHangHarnessConfig.isEnabled {
            return AnyView(UIHangHarnessView())
        }
        if ScreenshotPreviewConfig.isEnabled {
            if ScreenshotPreviewConfig.screen == "usage" {
                return AnyView(UsageChromePreview())
            }
            return AnyView(ScreenshotPreviewView())
        }
        return nil
    }
#endif

    @MainActor
    private func startApp() async {
        await performAppStartupWork()
        // Launch is over: the opener can now run what waited for it (a
        // cold-launch URL or notification tap included).
        opener.launchDidFinish()
    }

    @MainActor
    private func performAppStartupWork() async {
        AppFont.rebuild()
        MetricKitService.shared.configure()
        DeviceResourceSampler.shared.configure()
        configureWatchdogHooks()
        mainThreadLagWatchdog.start()
        LocalDataProtection.upgradeStoredFilesIfNeeded()
        await composerDraftStore.load()
        coordinator.startLANDiscovery()
        coordinator.startNetworkPathMonitor()
        TailnetNodeController.shared.onRouteChange = { [coordinator] in
            Task { await coordinator.handleTailnetRouteChange() }
        }
        TailnetNodeController.shared.startAtLaunchIfNeeded(
            pairedHosts: coordinator.serverStore.servers.map(\.host)
        )
        // Navigation gates know sessions only by id; their workspace and
        // Incognito state come from the loaded stores.
        ScopedLockService.shared.sessionLookup = { [coordinator] serverId, sessionId in
            coordinator.connection(for: serverId)?.sessionStore.session(id: sessionId)
        }
        await setupNotifications()
        AppIconBadgeService.shared.start(coordinator: coordinator)
#if DEBUG
        opener.scheduleE2EInAppBrowserIfRequested()

        // E2E test support: process invite URL from launch environment.
        // Must run BEFORE reconnectOnLaunch to prevent stale simulator
        // Keychain entries from flooding the ephemeral Docker server with
        // 401s on every old device token.
        // A focused two-server UI test can override a stale invite inherited from
        // the simulator's test runner, or skip replay after opening its second link.
        let e2eOverride = ProcessInfo.processInfo.environment["OPPI_E2E_LAUNCH_INVITE"]
        let e2eInvite = e2eOverride == "skip" ? nil :
            (e2eOverride ?? ProcessInfo.processInfo.environment["PI_E2E_INVITE_URL"])
        if let e2eInvite, let e2eURL = URL(string: e2eInvite) {
            if AppOpener.e2eLaunchInviteAlreadyProcessed {
                os_log(.error, "[E2E] Invite already processed this process; skipping duplicate bootstrap")
                navigation.launchPhase = .ready
                navigation.showOnboarding = false
            } else {
                // Drop leftover simulator pairings. Keep a DeviceAuthSession for
                // this invite identity so a relaunch can refresh instead of
                // replaying a consumed pairing token.
                let inviteCredentials = ServerCredentials.decodeInviteURL(e2eURL)
                var removed = 0
                for server in serverStore.servers {
                    let preserve = inviteCredentials.map {
                        E2EAppAuthBootstrap.shouldPreserveServer(server, matching: $0)
                    } ?? false
                    if !preserve {
                        await coordinator.removeServer(id: server.id)
                        removed += 1
                    }
                }
                os_log(.error, "[E2E] Cleared %{public}d stale servers", removed)

                os_log(.error, "[E2E] Processing invite URL: %{public}@", e2eInvite.prefix(80).description)
                // The launch invite is launch: run its bootstrap in place.
                await opener.runInviteForLaunch(e2eURL)
                navigation.launchPhase = .ready
                os_log(.error, "[E2E] Invite processing complete. showOnboarding=%{public}d workspaces=%{public}d",
                       navigation.showOnboarding ? 1 : 0,
                       connection.workspaceStore.workspaces.count)
            }
        } else {
            await reconnectOnLaunch()
        }
#else
        await reconnectOnLaunch()
#endif
    }


    @MainActor
    private func recordDiagnosticContext(
        phase: ScenePhase? = nil,
        lifecycleEvent: String? = nil,
        lifecycleStep: String? = nil
    ) {
        MetricKitCrashContextStore.recordAppContext(
            sessionId: diagnosticVisibleSessionId(),
            workspaceId: diagnosticVisibleWorkspaceId(),
            activeServerId: coordinator.activeServerId,
            screen: diagnosticScreenLabel(),
            scenePhase: diagnosticScenePhase(phase ?? scenePhase),
            lifecycleEvent: lifecycleEvent,
            lifecycleStep: lifecycleStep
        )
        noteNavigationRouteIfNeeded(lifecycleEvent: lifecycleEvent)
    }

    @MainActor
    private func noteNavigationRouteIfNeeded(lifecycleEvent: String?) {
        guard lifecycleEvent == "navigation" || lifecycleEvent == "root" else { return }
        navigationRouteTelemetry.note(navigation.navigationRouteSnapshot)
    }

    @MainActor
    private func activeComposerDraftRecord() -> ComposerDraftRecord? {
        guard let serverID = coordinator.activeServerId,
              let sessionID = diagnosticVisibleSessionId() ?? connection.sessionStore.activeSessionId,
              let workspaceID = diagnosticVisibleWorkspaceId()
                ?? connection.sessionStore.workspaceId(for: sessionID),
              let key = ComposerDraftKey(
                  serverID: serverID,
                  workspaceID: workspaceID,
                  sessionID: sessionID
              ) else {
            return nil
        }
        return composerDraftStore.record(for: key)
    }

    @MainActor
    private func diagnosticVisibleSessionId() -> String? {
        navigation.visibleDiagnosticSessionId()
    }

    @MainActor
    private func diagnosticVisibleWorkspaceId() -> String? {
        navigation.visibleDiagnosticWorkspaceId()
    }

    @MainActor
    private func diagnosticScreenLabel() -> String {
        navigation.diagnosticScreenLabel()
    }

    private func diagnosticScenePhase(_ phase: ScenePhase) -> String {
        switch phase {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    @MainActor
    private func diagnosticLifecycleMetadata(phase: ScenePhase, step: String) -> [String: String] {
        var metadata: [String: String] = [
            "phase": diagnosticScenePhase(phase),
            "step": step,
            "screen": diagnosticScreenLabel(),
        ]
        if let sessionId = diagnosticVisibleSessionId() {
            metadata["sessionId"] = sessionId
        }
        if let workspaceId = diagnosticVisibleWorkspaceId() {
            metadata["workspaceId"] = workspaceId
        }
        if let activeServerId = coordinator.activeServerId {
            metadata["activeServerId"] = activeServerId
        }
        return metadata
    }

    @MainActor
    private func recordLifecycleStep(_ phase: ScenePhase, _ step: String, flush: Bool = false) {
        let phaseLabel = diagnosticScenePhase(phase)
#if DEBUG
        E2ELifecycleDiagnostics.shared.record(phase: phaseLabel, step: step)
#endif
        recordDiagnosticContext(phase: phase, lifecycleEvent: "scene_phase", lifecycleStep: step)
        ClientLog.info(
            "Lifecycle",
            "Scene phase \(phaseLabel) \(step)",
            metadata: diagnosticLifecycleMetadata(phase: phase, step: step),
            flush: flush
        )
    }

    @MainActor
    private func handleScenePhase(_ phase: ScenePhase) {
        let phaseLabel = diagnosticScenePhase(phase)
        let handlerStartedAt = ProcessInfo.processInfo.systemUptime
        let foregroundInterval = phase == .active
            ? lifecycleSignposter.beginInterval("scene.foreground")
            : nil
        let backgroundInterval = phase == .background
            ? lifecycleSignposter.beginInterval("scene.background")
            : nil
        let shouldReconnect = foregroundReconnectGate.shouldReconnect(for: phase)
        recordLifecycleStep(phase, "begin", flush: phase == .background)

        switch phase {
        case .active:
            mainThreadLagWatchdog.start()
            // Footprint telemetry on foreground — helps diagnose jetsam kills.
            let footprint = AppDiagnosticsService.currentFootprintMB()
            ClientLog.info("Memory", "Foreground", metadata: [
                "footprintMB": footprint.map(String.init) ?? "n/a",
                "reconnect": shouldReconnect ? "true" : "false",
            ])

            // Pick up Live Activities started, ended, or dismissed while backgrounded.
            LiveActivityManager.shared.recoverIfNeeded()

            backgroundKeepAlive.end()
            SSHTerminalRegistry.shared.appDidBecomeActive()
            AppIconBadgeService.shared.appDidBecomeActive()
            AttentionNotificationService.shared.removeFallbackNotifications()

            if shouldReconnect {
                let reconnectInterval = lifecycleSignposter.beginInterval("foreground.reconnect")
                Task { @MainActor in
                    defer {
                        lifecycleSignposter.endInterval("foreground.reconnect", reconnectInterval)
                    }
                    // A paired shell may still be waiting for its first usable
                    // transport. Foreground is an explicit recovery boundary for
                    // setup as well as for established streams.
                    if let activeServerId = coordinator.activeServerId,
                       let activeConnection = coordinator.connection(for: activeServerId),
                       activeConnection.credentials == nil {
                        await coordinator.recoverUnconfiguredServerAfterBoundary(activeServerId)
                    } else {
                        await connection.reconnectIfNeeded()
                    }
                    // All other servers: reconnect + refresh
                    await coordinator.refreshInactiveServers()
                }
            }

        case .background:
            // First, so the background task that keeps SSH terminals running
            // for their grace period starts before anything else can take time.
            SSHTerminalRegistry.shared.appDidEnterBackground()
            let draftFallbackInterval = lifecycleSignposter.beginInterval("scene.background.draft_fallback")
            composerDraftStore.saveQuickSessionLifecycleFallback()
            composerDraftStore.saveLifecycleFallback(activeComposerDraftRecord())
            Task { await composerDraftStore.flush() }
            lifecycleSignposter.endInterval("scene.background.draft_fallback", draftFallbackInterval)

            let restorationInterval = lifecycleSignposter.beginInterval("scene.background.restoration_save")
            recordLifecycleStep(phase, "restoration_save_begin", flush: true)
            RestorationState.save(from: connection, coordinator: coordinator, navigation: navigation)
            recordLifecycleStep(phase, "restoration_save_done", flush: true)
            lifecycleSignposter.endInterval("scene.background.restoration_save", restorationInterval)

            // Keep the WS alive while agents are working so we receive status
            // updates without reconnecting.
            if coordinator.hasActiveAgentTransport {
                let keepAliveInterval = lifecycleSignposter.beginInterval("scene.background.keep_alive")
                lifecycleSignposter.emitEvent("background.mode.keep_alive")
                recordLifecycleStep(phase, "keep_alive_begin", flush: true)
                backgroundKeepAlive.begin(coordinator: coordinator)
                lifecycleSignposter.endInterval("scene.background.keep_alive", keepAliveInterval)
            } else if coordinator.hasActiveAudioTransportPlayback {
                // Let live streamed playback continue under the audio background mode.
                // Local clips can finish without keeping the focused session stream open; only
                // active audio_stream delivery needs the transport to drain.
                let audioTransportInterval = lifecycleSignposter.beginInterval("scene.background.audio_transport")
                lifecycleSignposter.emitEvent("background.mode.audio_transport")
                recordLifecycleStep(phase, "audio_transport_background", flush: true)
                backgroundKeepAlive.end()
                lifecycleSignposter.endInterval("scene.background.audio_transport", audioTransportInterval)
            } else {
                // No active agents or playback — send graceful close so the
                // server sees 1001 (going away) instead of discovering the
                // dead connection via ping timeout (1006). This avoids a 30-60s
                // server-side wait and produces cleaner telemetry.
                let gracefulCloseInterval = lifecycleSignposter.beginInterval("scene.background.graceful_close")
                lifecycleSignposter.emitEvent("background.mode.graceful_close")
                recordLifecycleStep(phase, "prepare_for_background_begin", flush: true)
                coordinator.prepareAllForBackground()
                recordLifecycleStep(phase, "prepare_for_background_done", flush: true)
                backgroundKeepAlive.end()
                lifecycleSignposter.endInterval("scene.background.graceful_close", gracefulCloseInterval)
            }

        case .inactive:
            let inactiveDraftFallbackInterval = lifecycleSignposter.beginInterval("scene.inactive.draft_fallback")
            composerDraftStore.saveQuickSessionLifecycleFallback()
            composerDraftStore.saveLifecycleFallback(activeComposerDraftRecord())
            Task { await composerDraftStore.flush() }
            lifecycleSignposter.endInterval("scene.inactive.draft_fallback", inactiveDraftFallbackInterval)

        @unknown default:
            break
        }

        recordLifecycleStep(phase, "end", flush: phase == .background)
        if phase == .background {
            mainThreadLagWatchdog.stopAfterGracePeriod(10_000)
        }

        // This is only app-owned synchronous work in this handler. It excludes
        // UIKit/SwiftUI scene delivery, suspension time, and async reconnect work.
        let synchronousHandlerDurationMs = max(0, Int(
            ((ProcessInfo.processInfo.systemUptime - handlerStartedAt) * 1_000).rounded()
        ))
#if DEBUG
        E2ELifecycleDiagnostics.shared.complete(phase: phaseLabel, durationMs: synchronousHandlerDurationMs)
#endif
        if let foregroundInterval {
            lifecycleSignposter.endInterval("scene.foreground", foregroundInterval)
        }
        if let backgroundInterval {
            lifecycleSignposter.endInterval("scene.background", backgroundInterval)
        }
    }

    private func handleMemoryWarning() {
        let footprintBefore = AppDiagnosticsService.currentFootprintMB()

        ToolRowRenderCache.evictAll()
        let cacheStats = MarkdownSegmentCache.shared.snapshot()
        MarkdownSegmentCache.shared.clearAll()

        // Per-session reducer memory cleanup is handled by ChatViewController
        // (reducer is now per-session, not on ServerConnection).

        let footprintAfter = AppDiagnosticsService.currentFootprintMB()

        let cacheEntries = cacheStats.entries
        let cacheBytes = cacheStats.totalSourceBytes

        appLog.error(
            """
            MEM warning: footprint=\(footprintBefore ?? -1, privacy: .public)→\(footprintAfter ?? -1, privacy: .public)MB \
            cache=\(cacheEntries, privacy: .public)/\(cacheBytes, privacy: .public)B
            """
        )

        var warningMetadata: [String: String] = [
            "footprintBeforeMB": footprintBefore.map(String.init) ?? "n/a",
            "footprintAfterMB": footprintAfter.map(String.init) ?? "n/a",
            "cacheEntries": String(cacheEntries),
            "cacheBytes": String(cacheBytes),
            "screen": diagnosticScreenLabel(),
        ]
        if let sessionId = diagnosticVisibleSessionId() {
            warningMetadata["sessionId"] = sessionId
        }
        ClientLog.error("Memory", "Memory warning", metadata: warningMetadata)
    }

    private func configureWatchdogHooks() {
        mainThreadLagWatchdog.onStall = { context in
            var metadata = MetricKitCrashContextStore.recordMainThreadStall(
                thresholdMs: context.thresholdMs,
                footprintMB: context.footprintMB,
                sequence: context.sequence
            )
            metadata["sequence"] = String(context.sequence)
            metadata["thresholdMs"] = String(context.thresholdMs)
            metadata["detectedAtMs"] = String(context.detectedAtMs)
            metadata["footprintMB"] = context.footprintMB.map(String.init) ?? "n/a"
            ClientLog.error(
                "Diagnostics",
                "Main-thread stall detected",
                metadata: metadata,
                flush: true
            )
        }
        mainThreadLagWatchdog.onRecovery = { context in
            var metadata = MetricKitCrashContextStore.recordMainThreadStallRecovery(
                sequence: context.sequence,
                durationMs: context.durationMs
            )
            metadata["sequence"] = String(context.sequence)
            metadata["durationMs"] = String(context.durationMs)
            metadata["recoveredAtMs"] = String(context.recoveredAtMs)
            ClientLog.info(
                "Diagnostics",
                "Main-thread stall recovered",
                metadata: metadata,
                flush: true
            )
        }
    }

    private func setupNotifications() async {
        let notificationService = AttentionNotificationService.shared
        notificationService.configureForLaunch()
        // The service delivers its responses to the owner. AppDelegate also
        // wires this synchronously, before any response can arrive; setting it
        // again here keeps the launch path independent of that ordering.
        notificationService.opener = opener
        notificationService.isSessionOnScreen = { [coordinator] serverId, sessionId in
            coordinator.connection(for: serverId)?.isFocusedSession(sessionId) ?? false
        }
    }

    private func reconnectOnLaunch() async {
        let startedAt = Date()
        var launchOutcome = "unknown"
        var workspaceRefreshOutcome = "unknown"
        var sessionRefreshOutcome = "unknown"
        var usedCachedSessions = false

        defer {
            let outcome = launchOutcome
            let workspaceOutcome = workspaceRefreshOutcome
            let sessionOutcome = sessionRefreshOutcome
            let usedCache = usedCachedSessions
            let launchDurationMs = max(0, Int((Date().timeIntervalSince(startedAt) * 1_000.0).rounded()))

            Task.detached(priority: .utility) {
                let metrics = await TimelineCache.shared.metrics()
                let metadata: [String: String] = [
                    "outcome": outcome,
                    "workspaceOutcome": workspaceOutcome,
                    "sessionOutcome": sessionOutcome,
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
                        root=\(URL(filePath: metrics.rootPath).lastPathComponent, privacy: .public)
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

        // 1. Load credentials — prefer restored server, then first server
        let restored = RestorationState.load()
        let targetServer: PairedServer?
        if let restoredServerId = restored?.activeServerId,
           let server = serverStore.server(for: restoredServerId) {
            targetServer = server
        } else {
            targetServer = serverStore.servers.first
        }

        guard let server = targetServer else {
            launchOutcome = "no_credentials"
            workspaceRefreshOutcome = "not_attempted"
            sessionRefreshOutcome = "not_attempted"
            navigation.showOnboarding = true
            navigation.launchPhase = .ready
            return
        }

        // A persisted PairedServer is authoritative for launch presentation.
        // Publish its stores immediately so transport availability can never
        // send an already-paired user back through onboarding.
        let launchConnection = coordinator.activatePairedServerShell(server)

        // Show What's New after an upgrade. First install is not a changelog.
        if WhatsNewManager.shouldShow {
            navigation.showWhatsNew = true
        } else {
            WhatsNewManager.recordFirstLaunchIfNeeded()
        }

        // 2. Restore UI state (tab, active session, draft)
        if let restored {
            navigation.selectedTab = AppTab(rawString: restored.selectedTab)
            launchConnection.sessionStore.activeSessionId = restored.activeSessionId
            composerDraftStore.stageLegacyDraft(
                text: restored.composerDraft,
                serverID: restored.activeServerId,
                sessionID: restored.activeSessionId
            )
        }

        // 3. Load local state before any network wait. The normal paired shell
        // renders cached content—or its ordinary empty/offline state—while the
        // connection badge reports transport preparation and recovery.
        let cache = TimelineCache.shared
        let preparedConnection = await PairedLaunchSequence.revealThenPrepare(
            loadLocalState: {
                if let cachedSessions = await loadLaunchSessionCache(
                    cache: cache,
                    serverId: server.id
                ) {
                    usedCachedSessions = true
                    launchConnection.sessionStore.applyServerSnapshot(cachedSessions)
                    launchConnection.syncAllWorkspaceSummariesFromLocalState()
                    launchConnection.syncLiveActivityState()
                }
                await launchConnection.workspaceStore.loadCachedCatalog(serverId: server.id)
            },
            reveal: {
                navigation.revealPairedServerShell()
            },
            // 4. Prepare the HTTPS endpoint after revealing the paired shell.
            prepare: {
                await coordinator.ensureConnectionReady(for: server)
            }
        )
        var selectedServerReady = false
        if preparedConnection.credentials != nil,
           preparedConnection.apiClient != nil,
           coordinator.activeServerId == server.id {
            // The picker may have selected another paired shell during bootstrap.
            selectedServerReady = await coordinator.switchToServerReady(server)
        }
        if selectedServerReady {
            MetricKitService.shared.setUploadClient(preparedConnection.apiClient)
        }
        // Transport not-ready is not a catalog/session sync failure. Keep the
        // cached inbox and Connecting/Recovering until an actual list request
        // fails. Launch telemetry below still records offline_cache_only.

        // Prepare other paired servers even when the selected server is offline.
        // One unavailable host must not suppress their refresh, push, or metrics setup.
        await coordinator.prepareInactiveConnectionsReady(excluding: server.id)

        // 5. Refresh workspaces + recent workspace-scoped sessions from server.
        // Avoid the legacy global `/sessions` endpoint on launch; it returns every
        // stopped session and can be multi-megabyte on long-lived installs.
        if selectedServerReady {
            await coordinator.refreshAllServers()
            let refreshOutcome = LaunchRefreshTelemetryOutcome.resolve(
                selectedServerReady: true,
                workspaceFailed: preparedConnection.workspaceStore.lastSyncFailed,
                sessionFailed: preparedConnection.sessionStore.lastSyncFailed
            )
            launchOutcome = refreshOutcome.overall
            workspaceRefreshOutcome = refreshOutcome.workspace
            sessionRefreshOutcome = refreshOutcome.session
        } else {
            await coordinator.refreshInactiveServers()
            let refreshOutcome = LaunchRefreshTelemetryOutcome.resolve(
                selectedServerReady: false,
                workspaceFailed: false,
                sessionFailed: false
            )
            launchOutcome = refreshOutcome.overall
            workspaceRefreshOutcome = refreshOutcome.workspace
            sessionRefreshOutcome = refreshOutcome.session
        }
    }

    func loadLaunchSessionCache(
        cache: TimelineCache,
        serverId: String
    ) async -> [Session]? {
        if let cached = await cache.loadSessionList(serverId: serverId) {
            return cached
        }

        return nil
    }
}
