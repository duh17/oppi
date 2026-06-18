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

enum WorkspaceDeepLink {
    struct Payload: Equatable, Sendable {
        let path: String
        let name: String?
        let serverFingerprint: String?
    }

    static func fingerprintsMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalizedFingerprint(lhs) == normalizedFingerprint(rhs)
    }

    static func payload(from url: URL) -> Payload? {
        guard url.scheme?.lowercased() == "oppi" else {
            return nil
        }
        guard routeName(from: url) == "workspace" else {
            return nil
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }
        guard let path = trimmedQueryValue("path", in: queryItems), !path.isEmpty else {
            return nil
        }

        let name = nonEmptyTrimmedQueryValue("name", in: queryItems)
        let serverFingerprint = nonEmptyTrimmedQueryValue("server", in: queryItems)
        return Payload(path: path, name: name, serverFingerprint: serverFingerprint)
    }

    private static func routeName(from url: URL) -> String? {
        if let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            return host.lowercased()
        }
        return url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .first?
            .lowercased()
    }

    private static func trimmedQueryValue(_ name: String, in queryItems: [URLQueryItem]) -> String? {
        queryItems
            .first { $0.name.lowercased() == name }
            .flatMap(\.value)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmptyTrimmedQueryValue(_ name: String, in queryItems: [URLQueryItem]) -> String? {
        guard let value = trimmedQueryValue(name, in: queryItems), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func normalizedFingerprint(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("sha256:") {
            return String(trimmed.dropFirst("sha256:".count))
        }
        return trimmed
    }
}

enum FileLinkOpenPolicy {
    struct ResolvedLink: Equatable {
        let serverId: String
        let workspace: Workspace
        let relativePath: String

        var fileName: String {
            (relativePath as NSString).lastPathComponent
        }
    }

    static func resolve(
        payload: FileLinkPayload,
        workspacesByServer: [String: [Workspace]]
    ) -> ResolvedLink? {
        for (serverId, workspaces) in workspacesByServer {
            guard let workspace = workspaces.first(where: { $0.id == payload.workspaceID }) else {
                continue
            }
            guard let relativePath = payload.filePath.workspaceRelativePath(hostMount: workspace.hostMount) else {
                return nil
            }
            return ResolvedLink(
                serverId: serverId,
                workspace: workspace,
                relativePath: relativePath
            )
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
    @State private var quickCommentTemplateStore = QuickCommentTemplateStore()

    /// Convenience accessor — most lifecycle code targets the active connection.
    private var connection: ServerConnection { coordinator.activeConnection }
    private var serverStore: ServerStore { coordinator.serverStore }
#if DEBUG
    @State private var mainThreadLagWatchdog = MainThreadLagWatchdog()

#endif
    @State private var inviteBootstrapInFlight = false
    @State private var foregroundReconnectGate = ForegroundReconnectGate()
    @State private var backgroundKeepAlive = BackgroundKeepAlive()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
#if DEBUG
            if FullScreenReviewCommentHarnessConfig.isEnabled {
                FullScreenReviewCommentHarnessView()
                    .ignoresSafeArea()
            } else if CodeGutterAlignmentHarnessConfig.isEnabled {
                CodeGutterAlignmentHarnessView()
                    .ignoresSafeArea()
            } else if CodeBlockWrappingHarnessConfig.isEnabled {
                CodeBlockWrappingHarnessView()
                    .ignoresSafeArea()
            } else if NavigationChromeProfileConfig.isEnabled {
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
            .environment(coordinator.activeConnection.askRequestStore)
            .environment(coordinator.activeConnection.audioPlayer)
            .environment(coordinator.activeConnection.gitStatusStore)
            .environment(coordinator.activeConnection.fileIndexStore)
            .environment(coordinator.activeConnection.messageQueueStore)
            .environment(navigation)
            .environment(coordinator.serverStore)
            .environment(themeStore)
            .environment(quickCommentTemplateStore)
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
                switch AppPreferences.Browser.linkOpeningMode {
                case .inApp:
                    InAppBrowserPresenter.present(url: url)
                case .external:
                    UIApplication.shared.open(url)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .fileLinkTapped)) { notification in
                guard let payload = notification.object as? FileLinkPayload else { return }
                Task { @MainActor in
                    _ = handleIncomingFileLink(payload)
                }
            }
            .onOpenURL { url in Task { @MainActor in await handleIncomingURL(url) } }
            .task {
                AppFont.rebuild()
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
                scheduleE2EInAppBrowserIfRequested()
#endif
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

#if DEBUG
    @MainActor
    private func scheduleE2EInAppBrowserIfRequested() {
        guard let url = Self.e2eInAppBrowserURL() else {
            return
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            InAppBrowserPresenter.present(url: url)
        }
    }

    private static func e2eInAppBrowserURL() -> URL? {
        let rawURL = ProcessInfo.processInfo.environment["OPPI_E2E_OPEN_IN_APP_BROWSER_URL"]
            ?? ProcessInfo.processInfo.arguments
                .first(where: { $0.hasPrefix("--e2e-open-in-app-browser=") })?
                .dropFirst("--e2e-open-in-app-browser=".count)
                .description

        guard let rawURL,
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
#endif

    @MainActor
    private func handleIncomingURL(_ url: URL) async {
#if DEBUG
        if let e2eInvite = ProcessInfo.processInfo.environment["PI_E2E_INVITE_URL"],
           url.absoluteString == e2eInvite {
            guard !e2eInviteProcessedThisProcess else { return }
            e2eInviteProcessedThisProcess = true
        }
#endif
        if handleIncomingSessionURL(url) {
            return
        }
        if handleIncomingWorkspaceURL(url) {
            return
        }
        if handleIncomingQuickSessionShareURL(url) {
            return
        }
        await handleIncomingInviteURL(url)
    }

    @MainActor
    private func handleIncomingFileLink(_ payload: FileLinkPayload) -> Bool {
        guard let resolution = resolveFileLink(payload) else {
            connection.extensionToast = "Could not open this file link"
            return false
        }
        guard coordinator.switchToServer(resolution.target.serverId) else {
            connection.extensionToast = "Could not open the server for this file link"
            return false
        }

        navigation.openWorkspaceLinkedFile(
            resolution.target,
            workspace: WorkspaceNavTarget(serverId: resolution.target.serverId, workspace: resolution.workspace)
        )
        return true
    }

    private func resolveFileLink(_ payload: FileLinkPayload) -> (target: WorkspaceLinkedFileNavTarget, workspace: Workspace)? {
        let workspacesByServer = Dictionary(
            uniqueKeysWithValues: coordinator.connections.map { serverId, connection in
                (serverId, connection.workspaceStore.workspaces)
            }
        )
        guard let resolution = FileLinkOpenPolicy.resolve(
            payload: payload,
            workspacesByServer: workspacesByServer
        ) else {
            return nil
        }
        return (
            target: WorkspaceLinkedFileNavTarget(
                serverId: resolution.serverId,
                workspaceId: payload.workspaceID,
                kind: .workspaceFile(path: resolution.relativePath, fileName: resolution.fileName)
            ),
            workspace: resolution.workspace
        )
    }

    /// Handle `oppi://session/<sessionId>` deep links from Live Activity taps.
    @MainActor
    private func handleIncomingSessionURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "oppi" else {
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
    private func handleIncomingQuickSessionShareURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "oppi",
              url.host?.lowercased() == "quick-session-share" else {
            return false
        }
        let payloadId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name.lowercased() == "id" }?
            .value
        guard let payloadId, !payloadId.isEmpty else {
            connection.extensionToast = "Could not open the shared item"
            return true
        }
        QuickSessionTrigger.shared.requestPresentation(sharePayloadId: payloadId)
        return true
    }

    /// Handle `oppi://workspace?path=<path>&name=<name>[&server=<fingerprint>]` deep links.
    @MainActor
    private func handleIncomingWorkspaceURL(_ url: URL) -> Bool {
        guard let payload = WorkspaceDeepLink.payload(from: url) else { return false }
        guard let server = workspaceDeepLinkTargetServer(for: payload) else { return true }
        guard coordinator.switchToServer(server) else {
            connection.extensionToast = "Could not open the server for this workspace link"
            return true
        }

        navigation.pendingWorkspaceDeepLink = payload
        navigation.selectedTab = .workspaces
        navigation.workspacePath = NavigationPath()
        return true
    }

    @MainActor
    private func workspaceDeepLinkTargetServer(for payload: WorkspaceDeepLink.Payload) -> PairedServer? {
        if let fingerprint = payload.serverFingerprint {
            if let server = serverStore.servers.first(where: { WorkspaceDeepLink.fingerprintsMatch($0.id, fingerprint) }) {
                return server
            }
            connection.extensionToast = "Server not found for this workspace link"
            return nil
        }

        if serverStore.servers.count == 1, let server = serverStore.servers.first {
            return server
        }

        if serverStore.servers.isEmpty {
            connection.extensionToast = "Pair a server before opening workspace links"
        } else {
            connection.extensionToast = "Workspace link needs a server fingerprint"
        }
        return nil
    }

    @MainActor
    private func openWorkspaceSession(
        serverId: String,
        sessionId: String,
        connection: ServerConnection
    ) {
        coordinator.switchToServer(serverId)
        let workspaceId = connection.sessionReentryWorkspaceId(for: sessionId)
        connection.sessionStore.activeSessionId = sessionId
        connection.prepareForSessionReentry(sessionId, workspaceIdHint: workspaceId)
        navigation.selectedTab = .workspaces
        navigation.setWorkspaceSessionPath(serverId: serverId, sessionId: sessionId, workspaceId: workspaceId)
    }

    @MainActor
    private func handleIncomingInviteURL(_ url: URL) async {
        guard !inviteBootstrapInFlight else { return }
        guard let credentials = ServerCredentials.decodeInviteURL(url) else {
            if url.scheme?.lowercased() == "oppi" {
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
            connection.sessionStore.sessions.removeAll()
            connection.sessionStore.activeSessionId = nil

            connection.sessionStore.markSyncStarted()
            connection.sessionStore.applyServerSnapshot(bootstrap.sessions, preserveRecentWindow: 0)
            connection.sessionStore.markSyncSucceeded()
            connection.syncLiveActivityState()
            navigation.showOnboarding = false
            navigation.selectedTab = .workspaces
            if let api = connection.apiClient {
                MetricKitService.shared.setUploadClient(api)
                await connection.workspaceStore.load(api: api)
            }
            if ReleaseFeatures.remotePushNotificationsEnabled {
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
            let footprint = AppDiagnosticsService.currentFootprintMB()
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

            // Keep the WS alive while agents are working so we receive status
            // updates without reconnecting.
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
        let footprintBefore = AppDiagnosticsService.currentFootprintMB()

        ToolRowRenderCache.evictAll()
        let cacheStats = MarkdownSegmentCache.shared.snapshot()
        MarkdownSegmentCache.shared.clearAll()

        // Per-session reducer memory cleanup is handled by ChatView
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
    }
#endif

    private func setupNotifications() async {
        guard ReleaseFeatures.localAttentionNotificationsEnabled else {
            return
        }

        let notificationService = AttentionNotificationService.shared
        notificationService.configureForLaunch()

        // Configure remote push registration only when the APNs lane is enabled.
        if ReleaseFeatures.remotePushNotificationsEnabled {
            PushRegistration.shared.configure(connection: connection)
        }

        let navigateToSessionFromNotification: (String) -> Void = { [weak coordinator] sessionId in
            guard let coordinator, !sessionId.isEmpty else { return }
            Task { @MainActor in
                if let found = coordinator.findSession(id: sessionId) {
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

        // Navigate to session when user taps an attention notification body.
        // Cross-server: find which server owns the session and switch to it.
        notificationService.onNavigateToSession = { sessionId in
            navigateToSessionFromNotification(sessionId)
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
            connection.syncLiveActivityState()
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

        // 5. Register for remote push notifications with all paired servers.
        if ReleaseFeatures.remotePushNotificationsEnabled {
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
