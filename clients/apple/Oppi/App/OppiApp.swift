import os.log
import SwiftUI
import UIKit

private let appLog = Logger(subsystem: AppIdentifiers.subsystem, category: "App")
private let lifecycleSignposter = OSSignposter(
    subsystem: AppIdentifiers.subsystem,
    category: "AppLifecyclePerf"
)
#if DEBUG
nonisolated(unsafe) private var e2eInviteProcessedThisProcess = false

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
    @State private var composerDraftStore = ComposerDraftStore()

    /// Convenience accessor — most lifecycle code targets the active connection.
    private var connection: ServerConnection { coordinator.activeConnection }
    private var serverStore: ServerStore { coordinator.serverStore }
    @State private var mainThreadLagWatchdog = MainThreadLagWatchdog()

    @State private var inviteBootstrapInFlight = false
    @State private var pendingSessionDeepLinkId: String?
    @State private var foregroundReconnectGate = ForegroundReconnectGate()
    @State private var backgroundKeepAlive = BackgroundKeepAlive()
    @Environment(\.scenePhase) private var scenePhase

    init() {
#if DEBUG
        if ProcessInfo.processInfo.environment["PI_E2E_INVITE_URL"] != nil {
            UIView.setAnimationsEnabled(false)
        }
#endif
        FeatureEducationTips.configure()
    }

    var body: some Scene {
        WindowGroup {
#if DEBUG
            if ReviewCommentStashHarnessConfig.isEnabled {
                ReviewCommentStashHarnessView()
            } else if FullScreenReviewCommentHarnessConfig.isEnabled {
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
            .withServerScopedEnvironment(coordinator.activeConnection)
            .environment(navigation)
            .environment(coordinator.serverStore)
            .environment(themeStore)
            .environment(quickCommentTemplateStore)
            .environment(\.composerDraftStore, composerDraftStore)
            .environment(\.theme, themeStore.appTheme)
            .environment(\.themeID, themeStore.activeThemeID)
            .tint(.themeBlue)
            .background {
                ThemeColorSchemeSyncView(themeStore: themeStore)
            }
            .preferredColorScheme(themeStore.preferredColorScheme)
            .onAppear {
                recordDiagnosticContext(lifecycleEvent: "root", lifecycleStep: "appear")
            }
            .onChange(of: scenePhase) { _, phase in
                handleScenePhase(phase)
            }
            .onChange(of: navigation.launchPhase) { _, _ in
                recordDiagnosticContext(lifecycleEvent: "navigation", lifecycleStep: "launch_phase")
            }
            .onChange(of: navigation.showOnboarding) { _, _ in
                recordDiagnosticContext(lifecycleEvent: "navigation", lifecycleStep: "onboarding")
            }
            .onChange(of: navigation.showQuickSession) { _, _ in
                recordDiagnosticContext(lifecycleEvent: "navigation", lifecycleStep: "quick_session")
            }
            .onChange(of: navigation.selectedWorkspaceFilter) { _, _ in
                recordDiagnosticContext(lifecycleEvent: "navigation", lifecycleStep: "workspace_filter")
            }
            .onChange(of: navigation.workspacePath.count) { _, _ in
                recordDiagnosticContext(lifecycleEvent: "navigation", lifecycleStep: "workspace_path")
            }
            .onChange(of: navigation.workspaceStackDiagnosticContext) { _, _ in
                recordDiagnosticContext(lifecycleEvent: "navigation", lifecycleStep: "stack_destination")
            }
            .onChange(of: navigation.splitDetailTarget) { _, _ in
                recordDiagnosticContext(lifecycleEvent: "navigation", lifecycleStep: "split_detail")
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
                    _ = await handleIncomingFileLink(payload)
                }
            }
            .onOpenURL { url in Task { @MainActor in await handleIncomingURL(url) } }
            .task {
                await startApp()
                await consumePendingSessionDeepLinkIfNeeded()
            }
    }

    @MainActor
    private func startApp() async {
        AppFont.rebuild()
        MetricKitService.shared.configure()
        DeviceResourceSampler.shared.configure()
        configureWatchdogHooks()
        mainThreadLagWatchdog.start()
        await composerDraftStore.load()
        coordinator.startLANDiscovery()
        coordinator.startNetworkPathMonitor()
        await setupNotifications()
#if DEBUG
        scheduleE2EInAppBrowserIfRequested()

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
                    await coordinator.removeServer(id: server.id)
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
        if await handleIncomingSessionURL(url) {
            return
        }
        if await handleIncomingWorkspaceURL(url) {
            return
        }
        await handleIncomingInviteURL(url)
    }

    @MainActor
    private func handleIncomingFileLink(_ payload: FileLinkPayload) async -> Bool {
        guard let resolution = resolveFileLink(payload) else {
            connection.extensionToast = "Could not open this file link"
            return false
        }
        guard await coordinator.switchToServerReady(resolution.target.serverId) else {
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
    private func handleIncomingSessionURL(_ url: URL) async -> Bool {
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

        if await openSessionDeepLinkIfAvailable(sessionId) {
            return true
        }

        // A cold-launch URL can arrive before credentials and cached sessions
        // finish loading. Keep the route until startup has populated the stores.
        if navigation.launchPhase == .resolving || inviteBootstrapInFlight {
            pendingSessionDeepLinkId = sessionId
            return true
        }

        showWorkspaceRootForMissingSessionDeepLink()
        return true
    }

    @MainActor
    private func consumePendingSessionDeepLinkIfNeeded() async {
        guard let sessionId = pendingSessionDeepLinkId else { return }
        pendingSessionDeepLinkId = nil
        if !(await openSessionDeepLinkIfAvailable(sessionId)) {
            showWorkspaceRootForMissingSessionDeepLink()
        }
    }

    @MainActor
    private func openSessionDeepLinkIfAvailable(_ sessionId: String) async -> Bool {
        for (serverId, conn) in coordinator.connections
            where conn.sessionStore.sessions.contains(where: { $0.id == sessionId }) {
            await openWorkspaceSession(serverId: serverId, sessionId: sessionId, connection: conn)
            return true
        }
        return false
    }

    @MainActor
    private func showWorkspaceRootForMissingSessionDeepLink() {
        navigation.selectedTab = .workspaces
        navigation.workspacePath = NavigationPath()
    }

    /// Handle `oppi://workspace?path=<path>&name=<name>[&server=<fingerprint>]` deep links.
    @MainActor
    private func handleIncomingWorkspaceURL(_ url: URL) async -> Bool {
        guard let payload = WorkspaceDeepLink.payload(from: url) else { return false }
        guard let server = workspaceDeepLinkTargetServer(for: payload) else { return true }
        guard await coordinator.switchToServerReady(server) else {
            connection.extensionToast = "Could not open the server for this workspace link"
            return true
        }

        navigation.pendingWorkspaceDeepLink = payload
        navigation.showAllWorkspaceSessions()
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
    ) async {
        guard await coordinator.switchToServerReady(serverId) else { return }
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
            guard await coordinator.addServerReady(
                pairedServer,
                switchTo: true
            ) else {
                throw InviteBootstrapError.message("Connection blocked by server transport policy")
            }

            // Reset the newly selected connection. The environment connection
            // can still point at the previous server during deep-link handling.
            let selectedConnection = coordinator.activeConnection
            selectedConnection.disconnectSession()
            selectedConnection.sessionStore.sessions.removeAll()
            selectedConnection.sessionStore.activeSessionId = nil

            selectedConnection.sessionStore.markSyncStarted()
            selectedConnection.sessionStore.applyServerSnapshot(bootstrap.sessions, preserveRecentWindow: 0)
            selectedConnection.sessionStore.markSyncSucceeded()
            selectedConnection.syncLiveActivityState()
            navigation.showOnboarding = false
            navigation.selectedTab = .workspaces
            if let api = selectedConnection.apiClient {
                MetricKitService.shared.setUploadClient(api)
                await selectedConnection.refreshWorkspaceCatalog(force: true)
            }
            if ReleaseFeatures.remotePushNotificationsEnabled {
                await PushRegistration.shared.requestAndRegister()
                await coordinator.registerPushWithAllServers()
            }
#if DEBUG
            if ProcessInfo.processInfo.environment["PI_E2E_INVITE_URL"] == nil {
                selectedConnection.extensionToast = "Connected to \(bootstrap.effectiveCredentials.name)"
            }
#else
            selectedConnection.extensionToast = "Connected to \(bootstrap.effectiveCredentials.name)"
#endif
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
        switch navigation.workspaceNavigationPresentation {
        case .split:
            if case .session(let target) = navigation.splitDetailTarget {
                return target.sessionId
            }
            return nil
        case .stack:
            return navigation.workspaceStackDiagnosticContext.sessionId
        }
    }

    @MainActor
    private func diagnosticVisibleWorkspaceId() -> String? {
        switch navigation.workspaceNavigationPresentation {
        case .split:
            switch navigation.splitDetailTarget {
            case .session(let target):
                return target.workspaceId ?? navigation.splitSelectedWorkspace?.workspace.id
            case .fileBrowser(let target):
                return target.workspaceId
            case .linkedFile(let target):
                return target.workspaceId
            case .workspaceConfiguration(let target):
                return target.workspace.id
            case .utility, nil:
                return navigation.splitSelectedWorkspace?.workspace.id
                    ?? navigation.selectedWorkspaceFilter?.workspace.id
            }
        case .stack:
            return navigation.workspaceStackDiagnosticContext.workspaceId
        }
    }

    @MainActor
    private func diagnosticScreenLabel() -> String {
        guard navigation.launchPhase == .ready else { return "launch_resolving" }
        if navigation.showOnboarding { return "onboarding" }
        if navigation.showQuickSession { return "quick_session" }

        switch navigation.workspaceNavigationPresentation {
        case .stack:
            return navigation.workspaceStackDiagnosticContext.screen
        case .split:
            switch navigation.splitDetailTarget {
            case .session:
                return "chat"
            case .fileBrowser:
                return "file_browser"
            case .linkedFile:
                return "linked_file"
            case .workspaceConfiguration:
                return "workspace_configuration"
            case .utility(let target):
                return "utility_\(diagnosticUtilityLabel(target))"
            case nil:
                return navigation.splitSelectedWorkspace == nil
                    ? "workspace_split_inbox_all"
                    : "workspace_split_inbox_filtered"
            }
        }
    }

    private func diagnosticUtilityLabel(_ target: WorkspaceUtilityNavTarget) -> String {
        switch target {
        case .schedules: "schedules"
        case .agents: "agents"
        case .manageServers: "manage_servers"
        case .appSettings: "app_settings"
        }
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

            // Recover Live Activity if system ended it while backgrounded (8-hour limit, user removal).
            if ReleaseFeatures.liveActivitiesEnabled {
                LiveActivityManager.shared.recoverIfNeeded()
            }

            backgroundKeepAlive.end()

            if shouldReconnect {
                let reconnectInterval = lifecycleSignposter.beginInterval("foreground.reconnect")
                Task { @MainActor in
                    defer {
                        lifecycleSignposter.endInterval("foreground.reconnect", reconnectInterval)
                    }
                    // Active server: full reconnect (WS, session metadata, lists)
                    await connection.reconnectIfNeeded()
                    // All other servers: reconnect + refresh
                    await coordinator.refreshInactiveServers()
                }
            }

        case .background:
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
        guard ReleaseFeatures.localAttentionNotificationsEnabled else {
            return
        }

        let notificationService = AttentionNotificationService.shared
        notificationService.configureForLaunch()

        // Configure remote push registration only when the APNs lane is enabled.
        if ReleaseFeatures.remotePushNotificationsEnabled {
            PushRegistration.shared.configure(coordinator: coordinator)
        }

        let navigateToSessionFromNotification: (String) -> Void = { [weak coordinator] sessionId in
            guard let coordinator, !sessionId.isEmpty else { return }
            Task { @MainActor in
                if let found = coordinator.findSession(id: sessionId) {
                    await openWorkspaceSession(
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

        // Prepare the target transport before switching. Iroh startup awaits its
        // ephemeral loopback listener and never persists that local URL.
        let preparedConnection = await coordinator.ensureConnectionReady(for: server)
        guard preparedConnection.credentials != nil,
              await coordinator.switchToServerReady(server) else {
            launchOutcome = "invalid_credentials"
            navigation.showOnboarding = true
            navigation.launchPhase = .ready
            return
        }

        // Prepare paired server connections. Live sockets open from workspace/chat screens.
        await coordinator.prepareAllConnectionsReady()

        guard connection.apiClient != nil else {
            launchOutcome = "no_api_client"
            navigation.showOnboarding = true
            navigation.launchPhase = .ready
            return
        }

        MetricKitService.shared.setUploadClient(connection.apiClient)

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
            composerDraftStore.stageLegacyDraft(
                text: restored.composerDraft,
                serverID: restored.activeServerId,
                sessionID: restored.activeSessionId
            )
        }

        // 3. Show cached data immediately (before any network calls)
        let cache = TimelineCache.shared
        if let cachedSessions = await loadLaunchSessionCache(
            cache: cache,
            serverId: server.id
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
