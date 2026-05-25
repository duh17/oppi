import os.log
import SwiftUI
import UIKit

private let appLog = Logger(subsystem: AppIdentifiers.subsystem, category: "App")
#if DEBUG
nonisolated(unsafe) private var e2eInviteProcessedThisProcess = false
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

private struct ThemeColorSchemeSyncView: View {
    @Environment(\.colorScheme) private var colorScheme
    let themeStore: ThemeStore

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onAppear(perform: syncIfSystemMode)
            .onChange(of: colorScheme) { _, _ in
                syncIfSystemMode()
            }
            .onChange(of: themeStore.mode) { _, _ in
                syncIfSystemMode()
            }
    }

    private func syncIfSystemMode() {
        guard themeStore.mode == .system else { return }
        themeStore.updateSystemColorScheme(colorScheme)
    }
}

enum PermissionDeepLink {
    static func permissionID(from url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "pi" || scheme == "oppi" else {
            return nil
        }

        let host = url.host?.lowercased()
        let pathParts = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        if host == "permission" {
            if let first = pathParts.first, !first.isEmpty {
                return first.removingPercentEncoding ?? first
            }

            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let queryItems = components.queryItems,
               let rawId = queryItems.first(where: { $0.name == "id" })?.value,
               !rawId.isEmpty {
                return rawId.removingPercentEncoding ?? rawId
            }

            return nil
        }

        if host == nil || host?.isEmpty == true,
           pathParts.count >= 2,
           pathParts[0].lowercased() == "permission" {
            let rawId = pathParts[1]
            return rawId.removingPercentEncoding ?? rawId
        }

        return nil
    }
}

@main
struct OppiApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator = ConnectionCoordinator(serverStore: ServerStore())
    @State private var navigation = AppNavigation()
    @State private var themeStore = ThemeStore()
    @State private var piQuickActionStore = PiQuickActionStore()

    /// Convenience accessor — most lifecycle code targets the active connection.
    private var connection: ServerConnection { coordinator.activeConnection }
    private var serverStore: ServerStore { coordinator.serverStore }
#if DEBUG
    @State private var mainThreadLagWatchdog = MainThreadLagWatchdog()

#endif
    @State private var inAppBrowserDestination: InAppBrowserDestination?
    @State private var inviteBootstrapInFlight = false
    @State private var foregroundReconnectGate = ForegroundReconnectGate()
    @State private var backgroundKeepAlive = BackgroundKeepAlive()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
#if DEBUG
            if NavigationChromeProfileConfig.isEnabled {
                NavigationChromeProfileHarnessView()
            } else if UIHangHarnessConfig.isEnabled {
                UIHangHarnessView()
            } else if ScreenshotPreviewConfig.isEnabled {
                ScreenshotPreviewView()
            } else {
                appRootView
            }
#else
            appRootView
#endif
        }
    }

    private var appRootView: some View {
        ContentView()
            .environment(coordinator)
            .environment(coordinator.activeConnection)
            .environment(\.apiClient, coordinator.activeConnection.apiClient)
            .environment(coordinator.activeConnection.chatState)
            .environment(coordinator.activeConnection.sessionStore)
            .environment(coordinator.activeConnection.workspaceStore)
            .environment(coordinator.activeConnection.permissionStore)
            .environment(coordinator.activeConnection.askRequestStore)
            .environment(coordinator.activeConnection.audioPlayer)
            .environment(coordinator.activeConnection.gitStatusStore)
            .environment(coordinator.activeConnection.fileIndexStore)
            .environment(coordinator.activeConnection.messageQueueStore)
            .environment(coordinator.activeConnection.activityStore)
            .environment(navigation)
            .environment(coordinator.serverStore)
            .environment(themeStore)
            .environment(piQuickActionStore)
            .environment(\.piQuickActionStore, piQuickActionStore)
            .environment(\.theme, themeStore.appTheme)
            .tint(.themeBlue)
            .background {
                ThemeColorSchemeSyncView(themeStore: themeStore)
            }
            .preferredColorScheme(themeStore.preferredColorScheme)
            .onChange(of: scenePhase) { _, phase in
                handleScenePhase(phase)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                handleMemoryWarning()
            }
            .onReceive(NotificationCenter.default.publisher(for: FontPreferences.didChangeNotification)) { _ in
                MarkdownSegmentCache.shared.clearAll()
                ToolRowRenderCache.evictAll()
            }
            .onReceive(NotificationCenter.default.publisher(for: .inviteDeepLinkTapped)) { notification in
                guard let url = notification.object as? URL else { return }
                Task { @MainActor in await handleIncomingURL(url) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .webLinkTapped)) { notification in
                guard let url = notification.object as? URL else { return }
                guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                    return
                }
                inAppBrowserDestination = InAppBrowserDestination(url: url)
            }
            .onOpenURL { url in Task { @MainActor in await handleIncomingURL(url) } }
            .sheet(item: $inAppBrowserDestination) { destination in
                InAppBrowserView(url: destination.url)
            }
            .task {
                AppFont.rebuild()
                await SentryService.shared.configure()
                MetricKitService.shared.configure()
                DeviceResourceSampler.shared.configure()
#if DEBUG
                configureWatchdogHooks()
                mainThreadLagWatchdog.start()
#endif
                coordinator.startLANDiscovery()
                coordinator.startNetworkPathMonitor()
                await setupNotifications()
#if DEBUG
                // E2E test support: process invite URL from launch environment.
                // Must run BEFORE reconnectOnLaunch to prevent stale simulator
                // Keychain entries from flooding the ephemeral Docker server with
                // 401s on every old device token.
                if let e2eInvite = ProcessInfo.processInfo.environment["PI_E2E_INVITE_URL"],
                   let e2eURL = URL(string: e2eInvite) {
                    if e2eInviteProcessedThisProcess {
                        os_log(.error, "[E2E] Invite already processed this process; skipping duplicate bootstrap")
                        navigation.launchPhase = .ready
                        navigation.showOnboarding = false
                    } else {
                        // Wipe all stale servers before connecting anything
                        let staleCount = serverStore.servers.count
                        for server in serverStore.servers {
                            coordinator.removeServer(id: server.id)
                        }
                        os_log(.error, "[E2E] Cleared %{public}d stale servers", staleCount)

                        os_log(.error, "[E2E] Processing invite URL: %{public}@", e2eInvite.prefix(80).description)
                        await handleIncomingURL(e2eURL)
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
    }

    private struct InAppBrowserDestination: Identifiable {
        let url: URL

        var id: String { url.absoluteString }
    }

    private struct PendingPermissionLocation {
        let serverId: String
        let sessionId: String
        let connection: ServerConnection
    }

    @MainActor
    private func handleIncomingURL(_ url: URL) async {
#if DEBUG
        if let e2eInvite = ProcessInfo.processInfo.environment["PI_E2E_INVITE_URL"],
           url.absoluteString == e2eInvite {
            guard !e2eInviteProcessedThisProcess else { return }
            e2eInviteProcessedThisProcess = true
        }
#endif
        if await handleIncomingPermissionURL(url) {
            return
        }
        if handleIncomingSessionURL(url) {
            return
        }
        await handleIncomingInviteURL(url)
    }

    /// Handle `oppi://session/<sessionId>` deep links from Live Activity taps.
    @MainActor
    private func handleIncomingSessionURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "pi" || scheme == "oppi" else {
            return false
        }
        guard url.host?.lowercased() == "session" else {
            return false
        }
        let pathParts = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let rawId = pathParts.first, !rawId.isEmpty else {
            return false
        }
        let sessionId = rawId.removingPercentEncoding ?? rawId

        // Find which server owns this session and open it directly from the workspace stack.
        for (serverId, conn) in coordinator.connections
            where conn.sessionStore.sessions.contains(where: { $0.id == sessionId }) {
            openWorkspaceSession(serverId: serverId, sessionId: sessionId, connection: conn)
            return true
        }

        // Session not found locally — just open the app to workspaces tab.
        navigation.selectedTab = .workspaces
        navigation.workspacePath = NavigationPath()
        return true
    }

    @MainActor
    private func handleIncomingPermissionURL(_ url: URL) async -> Bool {
        guard let permissionId = PermissionDeepLink.permissionID(from: url) else {
            return false
        }

        if let location = pendingPermissionLocation(id: permissionId) {
            location.connection.syncLiveActivityPermissions()
            openWorkspaceSession(
                serverId: location.serverId,
                sessionId: location.sessionId,
                connection: location.connection
            )
            return true
        }

        // Best-effort refresh when app woke from deep link before local stores synced.
        await coordinator.refreshAllServers()

        if let location = pendingPermissionLocation(id: permissionId) {
            location.connection.syncLiveActivityPermissions()
            openWorkspaceSession(
                serverId: location.serverId,
                sessionId: location.sessionId,
                connection: location.connection
            )
            return true
        }

        connection.extensionToast = "Permission request no longer pending"
        return true
    }

    @MainActor
    private func openWorkspaceSession(
        serverId: String,
        sessionId: String,
        connection: ServerConnection
    ) {
        coordinator.switchToServer(serverId)
        connection.sessionStore.activeSessionId = sessionId
        navigation.selectedTab = .workspaces
        navigation.workspacePath = NavigationPath()
        navigation.workspacePath.append(
            WorkspaceSessionNavTarget(serverId: serverId, sessionId: sessionId)
        )
    }

    private func pendingPermissionLocation(id: String) -> PendingPermissionLocation? {
        for (serverId, conn) in coordinator.connections {
            if let request = conn.permissionStore.pending.first(where: { $0.id == id }) {
                return PendingPermissionLocation(
                    serverId: serverId,
                    sessionId: request.sessionId,
                    connection: conn
                )
            }
        }
        return nil
    }

    @MainActor
    private func handleIncomingInviteURL(_ url: URL) async {
        guard !inviteBootstrapInFlight else { return }
        guard let credentials = ServerCredentials.decodeInviteURL(url) else {
            if let scheme = url.scheme?.lowercased(), scheme == "pi" || scheme == "oppi" {
                connection.extensionToast = "Unsupported invite link format"
            }
            return
        }
        inviteBootstrapInFlight = true
        defer { inviteBootstrapInFlight = false }
        let existingCredentials = connection.credentials
        let hadExistingCredentials = existingCredentials != nil
        do {
#if DEBUG
            let bootstrap: InviteBootstrapResult
            if let e2eDeviceToken = ProcessInfo.processInfo.environment["OPPI_E2E_DEVICE_TOKEN"],
               !e2eDeviceToken.isEmpty {
                let effectiveCredentials = credentials.withAuthToken(e2eDeviceToken)
                guard let baseURL = effectiveCredentials.baseURL else {
                    throw InviteBootstrapError.message("Invalid E2E invite URL")
                }
                let api = APIClient(
                    baseURL: baseURL,
                    token: e2eDeviceToken,
                    tlsCertFingerprint: effectiveCredentials.normalizedTLSCertFingerprint
                )
                let sessions = try await api.listSessionsFromWorkspaces()
                bootstrap = InviteBootstrapResult(effectiveCredentials: effectiveCredentials, sessions: sessions)
            } else {
                bootstrap = try await InviteBootstrapService.validateAndBootstrap(
                    credentials: credentials,
                    existingCredentials: existingCredentials
                ) { reason in
                    if ProcessInfo.processInfo.environment["PI_E2E_INVITE_URL"] != nil {
                        return true
                    }
                    return await BiometricService.shared.authenticate(reason: reason)
                }
            }
#else
            let bootstrap = try await InviteBootstrapService.validateAndBootstrap(
                credentials: credentials,
                existingCredentials: existingCredentials
            ) { reason in
                return await BiometricService.shared.authenticate(reason: reason)
            }
#endif

            // Add to ServerStore via coordinator (creates connection state for split streams)
            guard let pairedServer = PairedServer(
                from: bootstrap.effectiveCredentials,
                sortOrder: serverStore.servers.count
            ) else {
                throw InviteBootstrapError.message("Missing server fingerprint in invite credentials")
            }
            coordinator.addServer(
                pairedServer,
                switchTo: true
            )

            // Reset the new connection's state
            connection.disconnectSession()
            connection.permissionStore.pending.removeAll()
            connection.sessionStore.sessions.removeAll()
            connection.sessionStore.activeSessionId = nil

            connection.sessionStore.markSyncStarted()
            connection.sessionStore.applyServerSnapshot(bootstrap.sessions, preserveRecentWindow: 0)
            connection.sessionStore.markSyncSucceeded()
            connection.syncLiveActivityPermissions()
            navigation.showOnboarding = false
            navigation.selectedTab = .workspaces
            if let api = connection.apiClient {
                MetricKitService.shared.setUploadClient(api)
                await connection.workspaceStore.load(api: api)
            }
            if ReleaseFeatures.pushNotificationsEnabled {
                await PushRegistration.shared.requestAndRegister()
                await coordinator.registerPushWithAllServers()
            }
            connection.extensionToast = "Connected to \(bootstrap.effectiveCredentials.host)"
        } catch {
            connection.sessionStore.markSyncFailed()
#if DEBUG
            if ProcessInfo.processInfo.environment["PI_E2E_INVITE_URL"] != nil, !serverStore.servers.isEmpty {
                navigation.showOnboarding = false
                navigation.launchPhase = .ready
                return
            }
#endif
            if !hadExistingCredentials { navigation.showOnboarding = true }
            connection.extensionToast = "Invite link failed: \(error.localizedDescription)"
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        let shouldReconnect = foregroundReconnectGate.shouldReconnect(for: phase)

        switch phase {
        case .active:
#if DEBUG
            mainThreadLagWatchdog.start()
#endif
            // Footprint telemetry on foreground — helps diagnose jetsam kills.
            let footprint = SentryService.currentFootprintMB()
            ClientLog.info("Memory", "Foreground", metadata: [
                "footprintMB": footprint.map(String.init) ?? "n/a",
                "reconnect": shouldReconnect ? "true" : "false",
            ])

            // Recover Live Activity if system ended it while backgrounded (8-hour limit, user removal).
            if ReleaseFeatures.liveActivitiesEnabled {
                LiveActivityManager.shared.recoverIfNeeded()
            }

            // Check for pending quick session request from widget extension.
            QuickSessionTrigger.shared.checkForPendingRequest()

            backgroundKeepAlive.end()

            if shouldReconnect {
                Task {
                    // Active server: full reconnect (WS, session metadata, lists)
                    await connection.reconnectIfNeeded()
                    // All other servers: reconnect + refresh
                    await coordinator.refreshInactiveServers()
                }
            }

        case .background:
#if DEBUG
            mainThreadLagWatchdog.stop()
#endif
            RestorationState.save(from: connection, coordinator: coordinator, navigation: navigation)

            // Keep the WS alive while agents are working so we receive
            // permission requests and status updates without reconnecting.
            let hasActiveAgent = connection.sessionStore.sessions.contains {
                $0.status == .busy || $0.status == .starting
            }
            if hasActiveAgent {
                backgroundKeepAlive.begin(sessionStore: connection.sessionStore)
            } else if coordinator.hasActiveAudioTransportPlayback {
                // Let live streamed playback continue under the audio background mode.
                // Local clips can finish without keeping the focused session stream open; only
                // active audio_stream delivery needs the transport to drain.
                backgroundKeepAlive.end()
            } else {
                // No active agents or playback — send graceful close so the
                // server sees 1001 (going away) instead of discovering the
                // dead connection via ping timeout (1006). This avoids a 30-60s
                // server-side wait and produces cleaner telemetry.
                connection.prepareForBackground()
                backgroundKeepAlive.end()
            }

        case .inactive:
            break

        @unknown default:
            break
        }
    }

    private func handleMemoryWarning() {
        let footprintBefore = SentryService.currentFootprintMB()

        ToolRowRenderCache.evictAll()
        let cacheStats = MarkdownSegmentCache.shared.snapshot()
        MarkdownSegmentCache.shared.clearAll()

        // Per-session reducer memory cleanup is handled by ChatView
        // (reducer is now per-session, not on ServerConnection).

        let footprintAfter = SentryService.currentFootprintMB()

        let cacheEntries = cacheStats.entries
        let cacheBytes = cacheStats.totalSourceBytes

        appLog.error(
            """
            MEM warning: footprint=\(footprintBefore ?? -1, privacy: .public)→\(footprintAfter ?? -1, privacy: .public)MB \
            cache=\(cacheEntries, privacy: .public)/\(cacheBytes, privacy: .public)B
            """
        )

        ClientLog.error("Memory", "Memory warning", metadata: [
            "footprintBeforeMB": footprintBefore.map(String.init) ?? "n/a",
            "footprintAfterMB": footprintAfter.map(String.init) ?? "n/a",
            "cacheEntries": String(cacheEntries),
            "cacheBytes": String(cacheBytes),
        ])
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

        guard let sessionId = connection.sessionStore.activeSessionId else { return }

        ClientLog.error(
            "Diagnostics",
            "Main-thread stall detected",
            metadata: [
                "sessionId": sessionId,
                "thresholdMs": String(context.thresholdMs),
                "footprintMB": context.footprintMB.map(String.init) ?? "n/a",
            ]
        )

        await SentryService.shared.captureMainThreadStall(
            thresholdMs: context.thresholdMs,
            footprintMB: context.footprintMB,
            sessionId: sessionId
        )
    }
#endif

    private func setupNotifications() async {
        guard ReleaseFeatures.pushNotificationsEnabled else {
            return
        }

        let notificationService = PermissionNotificationService.shared
        await notificationService.setup()

        // Wire notification actions back to the correct server's connection.
        // Permission responses go over WebSocket — find the right connection.
        let coord = coordinator
        notificationService.onPermissionResponse = { [weak coord] permissionId, action in
            guard let coord else { return }
            Task { @MainActor in
                // Find which server has this permission and respond via its connection
                for (_, conn) in coord.connections where conn.permissionStore.pending.contains(where: { $0.id == permissionId }) {
                    try? await conn.respondToPermission(id: permissionId, action: action)
                    return
                }
                // Fallback: try active connection
                try? await coord.activeConnection.respondToPermission(id: permissionId, action: action)
            }
        }

        // Configure push registration with the active connection
        PushRegistration.shared.configure(connection: connection)

        // Navigate to session when user taps a push notification body.
        // Cross-server: find which server owns the session and switch to it.
        notificationService.onNavigateToPermission = { [weak coord] _, sessionId in
            guard let coord, !sessionId.isEmpty else { return }
            Task { @MainActor in
                if let found = coord.findSession(id: sessionId) {
                    openWorkspaceSession(
                        serverId: found.serverId,
                        sessionId: sessionId,
                        connection: found.connection
                    )
                } else {
                    navigation.selectedTab = .workspaces
                    navigation.workspacePath = NavigationPath()
                }
            }
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
            navigation.showOnboarding = true
            navigation.launchPhase = .ready
            return
        }

        // Switch to the target server (creates + configures its ServerConnection)
        guard coordinator.switchToServer(server) else {
            launchOutcome = "invalid_credentials"
            navigation.showOnboarding = true
            navigation.launchPhase = .ready
            return
        }

        // Prepare paired server connections. Live sockets open from workspace/chat screens.
        coordinator.prepareAllConnections()

        guard let api = connection.apiClient else {
            launchOutcome = "no_api_client"
            navigation.showOnboarding = true
            navigation.launchPhase = .ready
            return
        }

        MetricKitService.shared.setUploadClient(api)

        // Never show onboarding when we have valid credentials.
        // Even if security profile check fails (server offline), show cached workspace.
        navigation.showOnboarding = false

        // Show What's New once per marketing version after onboarding.
        if WhatsNewManager.shouldShow {
            navigation.showWhatsNew = true
        }

        // Security profile is server-config managed and no longer required for launch.

        // 2. Restore UI state (tab, active session, draft)
        if let restored {
            navigation.selectedTab = AppTab(rawString: restored.selectedTab)
            connection.sessionStore.activeSessionId = restored.activeSessionId
            connection.chatState.composerDraft = restored.composerDraft
        }

        // 3. Show cached data immediately (before any network calls)
        let cache = TimelineCache.shared
        if let cachedSessions = await loadLaunchSessionCache(
            cache: cache,
            serverId: server.id,
            pairedServerCount: serverStore.servers.count
        ) {
            usedCachedSessions = true
            connection.sessionStore.applyServerSnapshot(cachedSessions)
            connection.syncAllWorkspaceSummariesFromLocalState()
            connection.syncLiveActivityPermissions()
        }

        // Cached workspace catalog — load before revealing UI so the
        // workspace list is populated on the first visible frame.
        // Cache-only: no network fetch, so this returns fast.
        await connection.workspaceStore.loadCachedCatalog(serverId: server.id)

        // Launch resolved: credentials valid, cached data applied.
        // Reveal the UI before the network refresh so the user sees
        // cached content immediately instead of a blank screen.
        navigation.launchPhase = .ready

        // 4. Refresh workspaces + recent workspace-scoped sessions from server.
        // Avoid the legacy global `/sessions` endpoint on launch; it returns every
        // stopped session and can be multi-megabyte on long-lived installs.
        await coordinator.refreshAllServers()
        launchOutcome = connection.workspaceStore.lastSyncFailed && connection.sessionStore.lastSyncFailed
            ? "offline_cache_only"
            : "online_refresh_ok"

        // 5. Register for push notifications with all paired servers
        if ReleaseFeatures.pushNotificationsEnabled {
            await PushRegistration.shared.requestAndRegister()
            await coordinator.registerPushWithAllServers()
        }
    }

    private func loadLaunchSessionCache(
        cache: TimelineCache,
        serverId: String,
        pairedServerCount: Int
    ) async -> [Session]? {
        if let cached = await cache.loadSessionList(serverId: serverId) {
            return cached
        }

        guard pairedServerCount == 1,
              let legacyCached = await cache.loadSessionList() else {
            return nil
        }

        await cache.saveSessionList(legacyCached, serverId: serverId)
        return legacyCached
    }
}
