import os.log
import SwiftUI
import UIKit

private let appLog = Logger(subsystem: AppIdentifiers.subsystem, category: "App")

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

@main
struct OppiApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator = ConnectionCoordinator(serverStore: ServerStore())
    @State private var navigation = AppNavigation()
    @State private var themeStore = ThemeStore()

    /// Convenience accessor — most lifecycle code targets the active connection.
    private var connection: ServerConnection { coordinator.activeConnection }
    private var serverStore: ServerStore { coordinator.serverStore }
#if DEBUG
    @State private var mainThreadLagWatchdog = MainThreadLagWatchdog()
    @State private var autoClientLogUploadInFlight = false
    @State private var lastAutoClientLogUploadMs: Int64 = 0
#endif
    @State private var inviteBootstrapInFlight = false
    @State private var foregroundReconnectGate = ForegroundReconnectGate()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if UIHangHarnessConfig.isEnabled {
                UIHangHarnessView()
            } else {
                ContentView()
                    .environment(coordinator)
                    .environment(coordinator.activeConnection)
                    .environment(coordinator.activeConnection.sessionStore)
                    .environment(coordinator.activeConnection.permissionStore)
                    .environment(coordinator.activeConnection.reducer)
                    .environment(coordinator.activeConnection.reducer.toolOutputStore)
                    .environment(coordinator.activeConnection.reducer.toolArgsStore)
                    .environment(coordinator.activeConnection.audioPlayer)
                    .environment(navigation)
                    .environment(coordinator.serverStore)
                    .environment(themeStore)
                    .environment(\.theme, themeStore.appTheme)
                    .preferredColorScheme(themeStore.preferredColorScheme)
                    .onChange(of: scenePhase) { _, phase in
                        handleScenePhase(phase)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                        handleMemoryWarning()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .inviteDeepLinkTapped)) { notification in
                        guard let url = notification.object as? URL else { return }
                        Task { @MainActor in await handleIncomingInviteURL(url) }
                    }
                    .onOpenURL { url in Task { @MainActor in await handleIncomingInviteURL(url) } }
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
            let bootstrap = try await InviteBootstrapService.validateAndBootstrap(
                credentials: credentials,
                existingCredentials: existingCredentials
            ) { reason in await BiometricService.shared.authenticate(reason: reason) }

            // Add to ServerStore via coordinator (creates connection + opens /stream)
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
            connection.reducer.reset()
            connection.permissionStore.pending.removeAll()
            connection.sessionStore.sessions.removeAll()
            connection.sessionStore.activeSessionId = nil

            connection.sessionStore.markSyncStarted()
            connection.sessionStore.applyServerSnapshot(bootstrap.sessions, preserveRecentWindow: 0)
            connection.sessionStore.markSyncSucceeded()
            navigation.showOnboarding = false
            navigation.selectedTab = .workspaces
            if let api = connection.apiClient { await connection.workspaceStore.load(api: api) }
            if ReleaseFeatures.pushNotificationsEnabled {
                await PushRegistration.shared.requestAndRegister()
                await coordinator.registerPushWithAllServers()
            }
            connection.extensionToast = "Connected to \(bootstrap.effectiveCredentials.host)"
        } catch {
            connection.sessionStore.markSyncFailed()
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
            // Flush all connections on background
            for (_, conn) in coordinator.connections {
                conn.flushAndSuspend()
            }
            RestorationState.save(from: connection, coordinator: coordinator, navigation: navigation)

        case .inactive:
            break

        @unknown default:
            break
        }
    }

    private func handleMemoryWarning() {
        let footprintBefore = SentryService.currentFootprintMB()

        let cacheStats = MarkdownSegmentCache.shared.snapshot()
        MarkdownSegmentCache.shared.clearAll()

        let reducerStats = connection.reducer.handleMemoryWarning()

        let footprintAfter = SentryService.currentFootprintMB()

        let cacheEntries = cacheStats.entries
        let cacheBytes = cacheStats.totalSourceBytes
        let toolOutputBytes = reducerStats.toolOutputBytesCleared
        let collapsedExpandedItems = reducerStats.expandedItemsCollapsed
        let imagesStripped = reducerStats.imagesStripped

        appLog.error(
            """
            MEM warning: footprint=\(footprintBefore ?? -1, privacy: .public)→\(footprintAfter ?? -1, privacy: .public)MB \
            cache=\(cacheEntries, privacy: .public)/\(cacheBytes, privacy: .public)B \
            toolOutput=\(toolOutputBytes, privacy: .public)B \
            expanded=\(collapsedExpandedItems, privacy: .public) \
            images=\(imagesStripped, privacy: .public)
            """
        )

        ClientLog.error("Memory", "Memory warning", metadata: [
            "footprintBeforeMB": footprintBefore.map(String.init) ?? "n/a",
            "footprintAfterMB": footprintAfter.map(String.init) ?? "n/a",
            "cacheEntries": String(cacheEntries),
            "cacheBytes": String(cacheBytes),
            "toolOutputBytes": String(toolOutputBytes),
            "imagesStripped": String(imagesStripped),
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
                for (_, conn) in coord.connections {
                    if conn.permissionStore.pending.contains(where: { $0.id == permissionId }) {
                        try? await conn.respondToPermission(id: permissionId, action: action)
                        return
                    }
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
                    coord.switchToServer(found.serverId)
                    found.connection.sessionStore.activeSessionId = sessionId
                }
                navigation.selectedTab = .workspaces
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
            return
        }

        // Switch to the target server (creates + configures its ServerConnection)
        guard coordinator.switchToServer(server) else {
            launchOutcome = "invalid_credentials"
            navigation.showOnboarding = true
            return
        }

        // Open /stream WebSocket for ALL paired servers (concurrent connections)
        coordinator.connectAllStreams()

        guard let api = connection.apiClient else {
            launchOutcome = "no_api_client"
            navigation.showOnboarding = true
            return
        }

        // Never show onboarding when we have valid credentials.
        // Even if security profile check fails (server offline), show cached workspace.
        navigation.showOnboarding = false

        // Security profile is server-config managed and no longer required for launch.

        // 2. Restore UI state (tab, active session, draft, scroll position)
        if let restored {
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

            // 6. Load workspaces + skills — coordinator handles multi-server
            await coordinator.refreshAllServers()

            // 7. Register for push notifications with all paired servers
            if ReleaseFeatures.pushNotificationsEnabled {
                await PushRegistration.shared.requestAndRegister()
                await coordinator.registerPushWithAllServers()
            }
        } catch {
            connection.sessionStore.markSyncFailed()
            launchOutcome = "offline_cache_only"
            // Offline — cached data already shown above
        }
    }
}
