import os.log
import SwiftUI
import UIKit

private let appLog = Logger(subsystem: "dev.chenda.Oppi", category: "App")

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
    @State private var connection = ServerConnection()
    @State private var navigation = AppNavigation()
    @State private var serverStore = ServerStore()
    @State private var themeStore = ThemeStore()
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
                    .environment(connection)
                    .environment(connection.sessionStore)
                    .environment(connection.permissionStore)
                    .environment(connection.reducer)
                    .environment(connection.reducer.toolOutputStore)
                    .environment(connection.reducer.toolArgsStore)
                    .environment(connection.audioPlayer)
                    .environment(navigation)
                    .environment(serverStore)
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
        let existingCredentials = connection.credentials ?? KeychainService.loadCredentials()
        let hadExistingCredentials = existingCredentials != nil
        do {
            let bootstrap = try await InviteBootstrapService.validateAndBootstrap(
                credentials: credentials,
                existingCredentials: existingCredentials
            ) { reason in await BiometricService.shared.authenticate(reason: reason) }

            connection.disconnectSession()
            connection.reducer.reset()
            connection.permissionStore.pending.removeAll()
            connection.sessionStore.sessions.removeAll()
            connection.sessionStore.activeSessionId = nil
            // Add to ServerStore (handles fingerprint dedup)
            serverStore.addOrUpdate(from: bootstrap.effectiveCredentials)
            try KeychainService.saveCredentials(bootstrap.effectiveCredentials)
            guard connection.configure(credentials: bootstrap.effectiveCredentials) else {
                throw InviteBootstrapError.message("Connection blocked by server transport policy")
            }

            connection.sessionStore.markSyncStarted()
            connection.sessionStore.applyServerSnapshot(bootstrap.sessions, preserveRecentWindow: 0)
            connection.sessionStore.markSyncSucceeded()
            navigation.showOnboarding = false
            navigation.selectedTab = .workspaces
            if let api = connection.apiClient { await connection.workspaceStore.load(api: api) }
            await PushRegistration.shared.requestAndRegister()
            // Register push with all servers (new server included)
            if serverStore.servers.count > 1 {
                await PushRegistration.shared.registerWithAllServers(serverStore.servers)
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
                Task { await connection.reconnectIfNeeded() }
            }

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

        // 1. Load credentials — prefer multi-server store, fallback to legacy
        let initialCreds: ServerCredentials
        if let firstServer = serverStore.servers.first {
            initialCreds = firstServer.credentials
        } else if let legacy = KeychainService.loadCredentials() {
            initialCreds = legacy
        } else {
            launchOutcome = "no_credentials"
            navigation.showOnboarding = true
            return
        }
        var creds = initialCreds

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

        // Never show onboarding when we have valid credentials.
        // Even if security profile check fails (server offline), show cached workspace.
        navigation.showOnboarding = false

        // Enforce trust + transport contract as early as possible.
        do {
            let profile = try await api.securityProfile()

            if let violation = ConnectionSecurityPolicy.evaluate(host: creds.host, profile: profile) {
                launchOutcome = "blocked_transport_policy"
                appLog.error("SECURITY transport policy blocked host=\(creds.host, privacy: .public): \(violation.localizedDescription, privacy: .public)")
                connection.extensionToast = "Server blocked: \(violation.localizedDescription)"
                return
            }

            let serverFingerprint = profile.identity.normalizedFingerprint
            let storedFingerprint = creds.normalizedServerFingerprint

            if profile.requirePinnedServerIdentity ?? false {
                if let serverFingerprint, let storedFingerprint, serverFingerprint != storedFingerprint {
                    launchOutcome = "identity_mismatch"
                    appLog.error(
                        "SECURITY pinned identity mismatch host=\(creds.host, privacy: .public) stored=\(storedFingerprint, privacy: .public) server=\(serverFingerprint, privacy: .public)"
                    )
                    connection.extensionToast = "Server identity changed. Re-pair from Settings."
                    return
                }

                if serverFingerprint == nil {
                    launchOutcome = "missing_server_fingerprint"
                    appLog.error("SECURITY pinned identity required but server fingerprint missing")
                    connection.extensionToast = "Server identity missing. Re-pair from Settings."
                    return
                }
            }

            let upgraded = creds.applyingSecurityProfile(profile)
            if upgraded != creds {
                try? KeychainService.saveCredentials(upgraded)
                // Keep ServerStore in sync with security profile upgrades
                serverStore.addOrUpdate(from: upgraded)
                creds = upgraded
                guard connection.configure(credentials: upgraded) else {
                    launchOutcome = "blocked_transport_policy"
                    connection.extensionToast = "Server transport policy changed. Re-pair from Settings."
                    return
                }
            }
        } catch {
            launchOutcome = "missing_security_profile"
            appLog.error("SECURITY profile check failed on launch: \(error.localizedDescription, privacy: .public)")
            // Server unreachable — continue with cached data, don't kick to onboarding.
        }

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
            if serverStore.servers.count > 1 {
                await connection.workspaceStore.loadAll(servers: serverStore.servers)
            } else {
                await connection.workspaceStore.load(api: api)
                // Populate per-server data for grouped UI
                if let serverId = connection.currentServerId {
                    connection.workspaceStore.workspacesByServer[serverId] = connection.workspaceStore.workspaces
                    connection.workspaceStore.skillsByServer[serverId] = connection.workspaceStore.skills
                    if !connection.workspaceStore.serverOrder.contains(serverId) {
                        connection.workspaceStore.serverOrder = [serverId]
                    }
                    connection.workspaceStore.serverFreshness[serverId] = ServerSyncState()
                    connection.workspaceStore.serverFreshness[serverId]?.markSyncSucceeded()
                }
            }

            // 7. Register for push notifications with all paired servers
            await PushRegistration.shared.requestAndRegister()
            if serverStore.servers.count > 1 {
                await PushRegistration.shared.registerWithAllServers(serverStore.servers)
            }
        } catch {
            connection.sessionStore.markSyncFailed()
            launchOutcome = "offline_cache_only"
            // Offline — cached data already shown above
        }
    }
}
