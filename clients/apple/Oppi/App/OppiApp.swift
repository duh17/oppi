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

struct InAppDeepLinkIntent: Equatable, Sendable {
    let url: URL
    let sourceServerID: String?
}

enum InAppSessionServerResolution {
    static func resolve(
        sourceServerID: String?,
        sourceServerHasMatch: Bool,
        matchingServerIDs: [String]
    ) -> String? {
        if let sourceServerID {
            return sourceServerHasMatch ? sourceServerID : nil
        }
        let uniqueMatches = Set(matchingServerIDs)
        return uniqueMatches.count == 1 ? uniqueMatches.first : nil
    }
}

struct InAppSessionLink: Equatable, Sendable {
    let sessionId: String

    static func parse(_ url: URL) -> Self? {
        guard url.scheme?.lowercased() == "oppi",
              url.host?.lowercased() == "session" else {
            return nil
        }
        let pathParts = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard pathParts.count == 1,
              let rawId = pathParts.first,
              !rawId.isEmpty else {
            return nil
        }
        let sessionId = rawId.removingPercentEncoding ?? rawId
        guard !sessionId.isEmpty else { return nil }
        return Self(sessionId: sessionId)
    }
}

enum MissingSessionDeepLinkNavigationPolicy {
    @MainActor
    static func showWorkspaceRoot(in navigation: AppNavigation) {
        navigation.selectedTab = .workspaces
        navigation.clearWorkspaceSelections()
    }
}

enum SessionDeepLinkNavigationDisposition: Equatable {
    case open
    case park
    case showWorkspaceRoot
}

enum SessionDeepLinkNavigationPolicy {
    static func disposition(
        sessionIsAvailable: Bool,
        launchPhase: AppLaunchPhase,
        startupComplete: Bool,
        inviteBootstrapInFlight: Bool,
        parkingAllowed: Bool
    ) -> SessionDeepLinkNavigationDisposition {
        if sessionIsAvailable {
            return .open
        }
        let startupIsResolving = launchPhase == .resolving || !startupComplete
        if parkingAllowed && (startupIsResolving || inviteBootstrapInFlight) {
            return .park
        }
        return .showWorkspaceRoot
    }
}

enum SessionDeepLinkSessionResolution {
    /// Servers to try for `GET /sessions/:id` when the row is not cached.
    /// Active server first, then any server that already has this ask in memory.
    /// Do not probe the rest of the pairing list on the tap path.
    static func fetchServerIds(
        activeServerId: String?,
        serverIdsWithPendingAsk: [String]
    ) -> [String] {
        var ids: [String] = []
        if let activeServerId, !activeServerId.isEmpty {
            ids.append(activeServerId)
        }
        for serverId in serverIdsWithPendingAsk where !ids.contains(serverId) {
            ids.append(serverId)
        }
        return ids
    }
}

/// Production sequence after a session-targeted notification or `oppi://session` tap.
@MainActor
enum SessionNotificationOpen {
    static func openResolved(
        sessionId: String,
        serverId: String,
        connection: ServerConnection,
        navigation: AppNavigation,
        source: SessionNavigationSource
    ) async {
        await connection.prepareExternalSessionOpen(sessionId: sessionId)
        let workspaceId = connection.sessionReentryWorkspaceId(for: sessionId)
        navigation.selectedTab = .workspaces
        navigation.openSession(
            WorkspaceSessionNavTarget(
                serverId: serverId,
                sessionId: sessionId,
                workspaceId: workspaceId,
                routeScope: connection.sessionStore.routeScope(for: sessionId)
            ),
            source: source
        )
    }
}

@MainActor
enum AppStartupSequence {
    static func run(
        startupWork: () async -> Void,
        markComplete: () -> Void
    ) async {
        await startupWork()
        markComplete()
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

private struct PendingResourceReferenceChoice {
    let reference: ResourceReference
    let matches: [ResourceReferenceMatch]
}

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

enum FileLinkOpenPolicy {
    enum Kind: Equatable {
        case workspaceFile
        case hostFile
    }

    struct ResolvedLink: Equatable {
        let serverId: String
        let workspace: Workspace
        let kind: Kind
        let path: String

        var relativePath: String { path }

        var fileName: String {
            (path as NSString).lastPathComponent
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
            if let relativePath = payload.filePath.workspaceRelativePath(hostMount: workspace.hostMount) {
                return ResolvedLink(
                    serverId: serverId,
                    workspace: workspace,
                    kind: .workspaceFile,
                    path: relativePath
                )
            }
            return ResolvedLink(
                serverId: serverId,
                workspace: workspace,
                kind: .hostFile,
                path: payload.filePath
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
    @State private var appStartupComplete = false
    @State private var pendingSessionDeepLinkId: String?
    @State private var pendingResourceReferenceChoice: PendingResourceReferenceChoice?
    @State private var resourceReferenceRequestCoordinator = ResourceReferenceRequestCoordinator()
    @State private var foregroundReconnectGate = ForegroundReconnectGate()
    @State private var backgroundKeepAlive = BackgroundKeepAlive()
    @Environment(\.scenePhase) private var scenePhase

    private var resourceReferenceChoiceIsPresented: Binding<Bool> {
        Binding(
            get: { pendingResourceReferenceChoice != nil },
            set: { isPresented in
                if !isPresented, pendingResourceReferenceChoice != nil {
                    cancelResourceReferenceRequest()
                }
            }
        )
    }

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
            if WikiLineAnchorHarnessConfig.isEnabled {
                WikiLineAnchorHarnessView()
                    .ignoresSafeArea()
            } else if ReviewCommentStashHarnessConfig.isEnabled {
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
        let root = ContentView()
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
            .onChange(of: navigation.visibleSplitDiagnosticContext) { _, _ in
                recordDiagnosticContext(lifecycleEvent: "navigation", lifecycleStep: "split_destination")
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
            .onReceive(NotificationCenter.default.publisher(for: .inAppDeepLinkTapped)) { notification in
                guard let url = notification.object as? URL else { return }
                let sourceServerID = notification.userInfo?[
                    Notification.Name.inAppDeepLinkSourceServerIDKey
                ] as? String
                Task { @MainActor in
                    await handleInAppURL(InAppDeepLinkIntent(
                        url: url,
                        sourceServerID: sourceServerID
                    ))
                }
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

        return root
            .onReceive(NotificationCenter.default.publisher(for: .resourceReferenceTapped)) { notification in
                guard let reference = notification.object as? ResourceReference else { return }
                startResourceReferenceRequest(reference)
            }
            .onReceive(NotificationCenter.default.publisher(for: .fileLinkTapped)) { notification in
                guard let payload = notification.object as? FileLinkPayload else { return }
                Task { @MainActor in
                    _ = await handleIncomingFileLink(payload)
                }
            }
            .confirmationDialog(
                "Choose a resource",
                isPresented: resourceReferenceChoiceIsPresented,
                titleVisibility: .visible
            ) {
                if let choice = pendingResourceReferenceChoice {
                    ForEach(choice.matches, id: \.id) { match in
                        Button(match.choiceLabel) {
                            startOpeningResourceReferenceMatch(match)
                        }
                        .accessibilityLabel(match.accessibilityLabel)
                    }
                }
                Button("Cancel", role: .cancel) {
                    cancelResourceReferenceRequest()
                }
            } message: {
                if let choice = pendingResourceReferenceChoice {
                    Text("[[\(choice.reference.target)]] matches more than one resource.")
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
        await AppStartupSequence.run(
            startupWork: { await performAppStartupWork() },
            markComplete: { appStartupComplete = true }
        )
    }

    @MainActor
    private func performAppStartupWork() async {
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
    private func handleInAppURL(_ intent: InAppDeepLinkIntent) async {
        guard let link = InAppSessionLink.parse(intent.url) else {
            await handleIncomingURL(intent.url)
            return
        }
        let matches = coordinator.connections.compactMap { serverID, connection in
            connection.sessionStore.sessions.contains(where: { $0.id == link.sessionId })
                ? serverID
                : nil
        }
        guard let serverID = InAppSessionServerResolution.resolve(
            sourceServerID: intent.sourceServerID,
            sourceServerHasMatch: intent.sourceServerID.map(matches.contains) ?? false,
            matchingServerIDs: matches
        ), let connection = coordinator.connection(for: serverID) else {
            return
        }
        await openWorkspaceSession(
            serverId: serverID,
            sessionId: link.sessionId,
            connection: connection,
            source: .inAppHyperlink
        )
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
        if await handleIncomingSessionURL(url) {
            return
        }
        if await handleIncomingWorkspaceURL(url) {
            return
        }
        await handleIncomingInviteURL(url)
    }

    @MainActor
    private func startResourceReferenceRequest(_ reference: ResourceReference) {
        pendingResourceReferenceChoice = nil
        resourceReferenceRequestCoordinator.perform { token in
            await handleResourceReference(reference, token: token)
        }
    }

    @MainActor
    private func startOpeningResourceReferenceMatch(_ match: ResourceReferenceMatch) {
        guard let reference = pendingResourceReferenceChoice?.reference else { return }
        pendingResourceReferenceChoice = nil
        resourceReferenceRequestCoordinator.perform { token in
            await openResourceReferenceMatch(match, reference: reference, token: token)
        }
    }

    @MainActor
    private func cancelResourceReferenceRequest() {
        pendingResourceReferenceChoice = nil
        resourceReferenceRequestCoordinator.cancel()
    }

    @MainActor
    private func handleResourceReference(
        _ reference: ResourceReference,
        token: ResourceReferenceRequestCoordinator.Token
    ) async {
        guard !ResourceReferenceSelfLinkPolicy.isCurrentSession(reference) else {
            return
        }
        let sessionMatches = reference.lineAnchor == nil
            ? knownSessionMatches(for: reference.target)
            : []
        let fileLookup: ResourceReferenceFileLookup
        do {
            fileLookup = try await currentFileMatches(for: reference)
        } catch is CancellationError {
            // A superseded tap is dropped rather than surfaced as "right now".
            return
        } catch {
            // Host-file lookup never throws; unexpected workspace throws stay
            // "right now" instead of looking like a true unresolved file.
            fileLookup = .unavailable
        }
        guard resourceReferenceRequestCoordinator.isCurrent(token) else { return }

        switch ResourceReferenceCandidateCollector.resolve(
            reference,
            sessionMatches: sessionMatches,
            fileLookup: fileLookup
        ) {
        case .unavailable:
            connection.extensionToast = "Could not resolve [[\(reference.target)]] right now"
        case .authorizationFailed:
            connection.extensionToast = "Could not authorize host file [[\(reference.target)]]"
        case .resolution(.unresolved(let target)):
            connection.extensionToast = "Could not resolve [[\(target)]]"
        case .resolution(.resolved(let match)):
            await openResourceReferenceMatch(match, reference: reference, token: token)
        case .resolution(.ambiguous(let matches)):
            guard resourceReferenceRequestCoordinator.isCurrent(token) else { return }
            pendingResourceReferenceChoice = PendingResourceReferenceChoice(
                reference: reference,
                matches: matches
            )
        }
    }

    @MainActor
    private func knownSessionMatches(for target: String) -> [ResourceReferenceMatch] {
        coordinator.connections.flatMap { serverID, connection in
            connection.sessionStore.sessions.compactMap { session in
                guard session.id == target else { return nil }
                let workspaceName = session.workspaceId.flatMap { workspaceID in
                    connection.workspaceStore.workspaces.first { $0.id == workspaceID }?.name
                }
                return .session(SessionResourceReference(
                    serverID: serverID,
                    sessionID: session.id,
                    workspaceID: session.workspaceId,
                    displayName: session.displayTitle,
                    workspaceName: workspaceName,
                    serverName: resourceReferenceServerName(serverID)
                ))
            }
        }
    }

    @MainActor
    private func currentFileMatches(
        for reference: ResourceReference
    ) async throws -> ResourceReferenceFileLookup {
        switch ResourceReferenceFileLookupPolicy.kind(for: reference) {
        case .hostFile:
            return await currentHostFileMatches(for: reference)
        case .workspaceFile:
            return try await currentWorkspaceFileMatches(for: reference)
        }
    }

    @MainActor
    private func currentHostFileMatches(
        for reference: ResourceReference
    ) async -> ResourceReferenceFileLookup {
        guard let fileCandidatePath = reference.fileCandidatePath else {
            return .notApplicable
        }

        let scopes: [(serverID: String, connection: ServerConnection)]
        if let sourceServerID = reference.sourceServerID {
            guard let connection = coordinator.connection(for: sourceServerID) else {
                return .unavailable
            }
            scopes = [(sourceServerID, connection)]
        } else {
            scopes = coordinator.connections.map { ($0.key, $0.value) }
            guard !scopes.isEmpty else { return .unavailable }
        }

        var matches: [ResourceReferenceMatch] = []
        for scope in scopes {
            guard let apiClient = scope.connection.apiClient else { return .unavailable }
            do {
                let resolvedPath = try await apiClient.resolveHostFile(path: fileCandidatePath)
                try Task.checkCancellation()
                if let resolvedPath {
                    matches.append(.hostFile(HostFileResourceReference(
                        serverID: scope.serverID,
                        path: resolvedPath,
                        serverName: resourceReferenceServerName(scope.serverID)
                    )))
                }
            } catch let APIError.server(status, _) where status == 404 {
                continue
            } catch let APIError.server(status, _) where status == 401 || status == 403 {
                return .authorizationFailed
            } catch let APIError.codedServer(status, _, _) where status == 401 || status == 403 {
                return .authorizationFailed
            } catch {
                return .unavailable
            }
        }
        return .complete(matches)
    }

    @MainActor
    private func currentWorkspaceFileMatches(
        for reference: ResourceReference
    ) async throws -> ResourceReferenceFileLookup {
        guard reference.kind == .workspaceFile,
              let workspaceID = reference.workspaceID,
              let fileCandidatePath = reference.fileCandidatePath else {
            return .notApplicable
        }

        let scopes: [(serverID: String, connection: ServerConnection, workspace: Workspace)]
        if let sourceServerID = reference.sourceServerID {
            guard let connection = coordinator.connection(for: sourceServerID),
                  let workspace = connection.workspaceStore.workspaces.first(where: { $0.id == workspaceID }) else {
                return .unavailable
            }
            scopes = [(sourceServerID, connection, workspace)]
        } else {
            scopes = coordinator.connections.compactMap { serverID, connection in
                guard let workspace = connection.workspaceStore.workspaces.first(where: { $0.id == workspaceID }) else {
                    return nil
                }
                return (serverID, connection, workspace)
            }
            guard !scopes.isEmpty else { return .unavailable }
        }

        var matches: [ResourceReferenceMatch] = []
        for scope in scopes {
            guard let apiClient = scope.connection.apiClient else { return .unavailable }

            // Resolve the source session's checkout. A missing or foreign
            // source session means the checkout is unknown: list the main
            // checkout (nil) instead of failing closed, because a gitignored
            // workspace file (for example `.pi/skills/...`) may exist only on
            // the main checkout.
            let sourceSessionResolved: Bool
            let sourceSessionWorktreeID: String?
            if let sourceSessionID = reference.sourceSessionID,
               let sourceSession = scope.connection.sessionStore.session(id: sourceSessionID),
               sourceSession.workspaceId == workspaceID {
                sourceSessionResolved = true
                sourceSessionWorktreeID = sourceSession.worktreeId
            } else {
                sourceSessionResolved = false
                sourceSessionWorktreeID = nil
            }
            let firstWorktreeID = WorkspaceWikiLinkFileLookupPolicy.firstCheckout(
                sourceSessionResolved: sourceSessionResolved,
                sourceSessionWorktreeID: sourceSessionWorktreeID
            )

            var outcome = try await exactFileListingResult(
                fileCandidatePath,
                workspaceID: workspaceID,
                worktreeID: firstWorktreeID,
                apiClient: apiClient
            )
            let effectiveWorktreeID = WorkspaceWikiLinkFileLookupPolicy.resolvedCheckout(
                sourceSessionResolved: sourceSessionResolved,
                sourceSessionWorktreeID: sourceSessionWorktreeID,
                firstOutcome: outcome
            )

            // A git-ignored workspace file (for example `.pi/skills/...`) is
            // not checked out into a fresh worktree. If the worktree lookup is
            // a deterministic absence, retry the same workspace-relative path
            // against the main checkout before declaring the link unresolvable.
            // The server's realpath sandbox still bounds both lookups.
            if effectiveWorktreeID != firstWorktreeID {
                outcome = try await exactFileListingResult(
                    fileCandidatePath,
                    workspaceID: workspaceID,
                    worktreeID: effectiveWorktreeID,
                    apiClient: apiClient
                )
            }

            switch outcome {
            case .present:
                matches.append(.workspaceFile(WorkspaceFileResourceReference(
                    serverID: scope.serverID,
                    workspaceID: workspaceID,
                    worktreeID: effectiveWorktreeID,
                    path: fileCandidatePath,
                    workspaceName: scope.workspace.name,
                    serverName: resourceReferenceServerName(scope.serverID)
                )))
            case .absent:
                break
            case .truncated, .unavailable:
                return .unavailable
            }
        }

        return .complete(matches)
    }

    @MainActor
    private func exactFileListingResult(
        _ filePath: String,
        workspaceID: String,
        worktreeID: String?,
        apiClient: APIClient
    ) async throws -> ExactFileListingOutcome {
        let fileName = (filePath as NSString).lastPathComponent
        let parent = (filePath as NSString).deletingLastPathComponent
        let directoryPath = parent.isEmpty || parent == "." ? "" : parent + "/"

        let listing: DirectoryListingResponse
        do {
            listing = try await apiClient.listWorkspaceDirectory(
                workspaceId: workspaceID,
                path: directoryPath,
                worktreeId: worktreeID
            )
        } catch {
            // A superseded tap must stay silent: propagate cancellation instead
            // of turning it into a transient "right now" failure.
            try Task.checkCancellation()
            return WorkspaceWikiLinkFileLookupPolicy.isDeterministicAbsence(error)
                ? .absent
                : .unavailable
        }

        try Task.checkCancellation()
        switch ResourceFileCandidatePolicy.directoryResult(
            fileName: fileName,
            entries: listing.entries,
            truncated: listing.truncated
        ) {
        case .some(true):
            return .present
        case .some(false):
            return .absent
        case .none:
            return .truncated
        }
    }

    @MainActor
    private func openResourceReferenceMatch(
        _ match: ResourceReferenceMatch,
        reference: ResourceReference,
        token: ResourceReferenceRequestCoordinator.Token
    ) async {
        switch match {
        case .session(let session):
            guard !ResourceReferenceSelfLinkPolicy.isCurrentSession(reference) else {
                return
            }
            guard let connection = coordinator.connection(for: session.serverID) else {
                guard resourceReferenceRequestCoordinator.isCurrent(token) else { return }
                self.connection.extensionToast = "Could not open session \(session.sessionID)"
                return
            }
            guard await coordinator.switchToServerReady(session.serverID, shouldActivate: {
                resourceReferenceRequestCoordinator.isCurrent(token)
            }), resourceReferenceRequestCoordinator.isCurrent(token) else {
                return
            }
            let workspaceID = connection.sessionReentryWorkspaceId(for: session.sessionID)
            let routeScope = connection.sessionStore.routeScope(for: session.sessionID)
            connection.sessionStore.activeSessionId = session.sessionID
            connection.prepareForSessionReentry(session.sessionID, workspaceIdHint: workspaceID)
            navigation.openReferencedSession(WorkspaceSessionNavTarget(
                serverId: session.serverID,
                sessionId: session.sessionID,
                workspaceId: workspaceID,
                routeScope: routeScope
            ))

        case .workspaceFile(let file):
            guard let connection = coordinator.connection(for: file.serverID),
                  let workspace = connection.workspaceStore.workspaces.first(where: { $0.id == file.workspaceID }) else {
                guard resourceReferenceRequestCoordinator.isCurrent(token) else { return }
                self.connection.extensionToast = "Could not open file \(file.path)"
                return
            }
            guard await coordinator.switchToServerReady(file.serverID, shouldActivate: {
                resourceReferenceRequestCoordinator.isCurrent(token)
            }), resourceReferenceRequestCoordinator.isCurrent(token) else {
                return
            }

            if let sourceSessionID = reference.sourceSessionID,
               let sourceServerID = reference.sourceServerID {
                // Session IDs are only unique within one server. Keep this
                // pre-navigation capture scoped so another server's chat cannot
                // freeze its viewport when IDs happen to collide.
                NotificationCenter.default.post(
                    name: .workspaceLinkedFileWillOpen,
                    object: sourceSessionID,
                    userInfo: [Notification.Name.workspaceLinkedFileSourceServerIDKey: sourceServerID]
                )
            }
            navigation.openWorkspaceLinkedFile(
                .workspaceFile(
                    serverId: file.serverID,
                    workspaceId: file.workspaceID,
                    worktreeId: file.worktreeID,
                    path: file.path,
                    lineAnchor: reference.lineAnchor
                ),
                workspace: WorkspaceNavTarget(serverId: file.serverID, workspace: workspace)
            )

        case .hostFile(let file):
            guard let connection = coordinator.connection(for: file.serverID) else {
                guard resourceReferenceRequestCoordinator.isCurrent(token) else { return }
                self.connection.extensionToast = "Could not open file \(file.path)"
                return
            }
            guard await coordinator.switchToServerReady(file.serverID, shouldActivate: {
                resourceReferenceRequestCoordinator.isCurrent(token)
            }), resourceReferenceRequestCoordinator.isCurrent(token) else {
                return
            }

            if let sourceSessionID = reference.sourceSessionID,
               let sourceServerID = reference.sourceServerID {
                NotificationCenter.default.post(
                    name: .workspaceLinkedFileWillOpen,
                    object: sourceSessionID,
                    userInfo: [Notification.Name.workspaceLinkedFileSourceServerIDKey: sourceServerID]
                )
            }
            // Host files stay on the current stack. Do not select another
            // workspace or pretend the file lives in this checkout.
            navigation.openWorkspaceLinkedFile(
                .hostFile(
                    serverId: file.serverID,
                    workspaceId: reference.workspaceID ?? "",
                    path: file.path,
                    lineAnchor: reference.lineAnchor
                )
            )
        }
    }

    private func resourceReferenceServerName(_ serverID: String) -> String {
        serverStore.server(for: serverID)?.name ?? "Server \(serverID.prefix(8))"
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

        let workspace: WorkspaceNavTarget?
        if case .workspaceFile = resolution.target.kind {
            workspace = WorkspaceNavTarget(serverId: resolution.target.serverId, workspace: resolution.workspace)
        } else {
            workspace = nil
        }
        navigation.openWorkspaceLinkedFile(resolution.target, workspace: workspace)
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
        let kind: WorkspaceLinkedFileKind
        switch resolution.kind {
        case .workspaceFile:
            kind = .workspaceFile(path: resolution.path, fileName: resolution.fileName)
        case .hostFile:
            kind = .hostFile(path: resolution.path, fileName: resolution.fileName)
        }
        return (
            target: WorkspaceLinkedFileNavTarget(
                serverId: resolution.serverId,
                workspaceId: payload.workspaceID,
                kind: kind
            ),
            workspace: resolution.workspace
        )
    }

    /// Handle external `oppi://session/<sessionId>` URLs, including Live Activity taps.
    @MainActor
    private func handleIncomingSessionURL(_ url: URL) async -> Bool {
        guard url.scheme?.lowercased() == "oppi" else {
            return false
        }
        guard url.host?.lowercased() == "session" else {
            return false
        }
        guard let link = InAppSessionLink.parse(url) else {
            return false
        }
        await navigateToSessionFromDeepLink(
            link.sessionId,
            source: .externalURL,
            parkingAllowed: true
        )
        return true
    }

    @MainActor
    private func consumePendingSessionDeepLinkIfNeeded() async {
        guard let sessionId = pendingSessionDeepLinkId else { return }
        pendingSessionDeepLinkId = nil
        await navigateToSessionFromDeepLink(
            sessionId,
            source: .externalURL,
            parkingAllowed: false
        )
    }

    @MainActor
    private func navigateToSessionFromDeepLink(
        _ sessionId: String,
        source: SessionNavigationSource,
        parkingAllowed: Bool
    ) async {
        let foundSession = await coordinator.findOrFetchSession(id: sessionId)
        switch SessionDeepLinkNavigationPolicy.disposition(
            sessionIsAvailable: foundSession != nil,
            launchPhase: navigation.launchPhase,
            startupComplete: appStartupComplete,
            inviteBootstrapInFlight: inviteBootstrapInFlight,
            parkingAllowed: parkingAllowed
        ) {
        case .open:
            guard let foundSession else { return }
            await openWorkspaceSession(
                serverId: foundSession.serverId,
                sessionId: sessionId,
                connection: foundSession.connection,
                source: source
            )
        case .park:
            // URL and notification routes share this one-shot launch parking slot.
            pendingSessionDeepLinkId = sessionId
        case .showWorkspaceRoot:
            showWorkspaceRootForMissingSessionDeepLink()
        }
    }

    @MainActor
    private func showWorkspaceRootForMissingSessionDeepLink() {
        MissingSessionDeepLinkNavigationPolicy.showWorkspaceRoot(in: navigation)
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
        connection: ServerConnection,
        source: SessionNavigationSource = .externalURL
    ) async {
        guard await coordinator.switchToServerReady(serverId) else { return }
        await SessionNotificationOpen.openResolved(
            sessionId: sessionId,
            serverId: serverId,
            connection: connection,
            navigation: navigation,
            source: source
        )
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
        let existingCredentials = credentials.normalizedServerFingerprint
            .flatMap { serverStore.server(for: $0)?.credentials }
            ?? serverStore.server(forHost: credentials.host, port: credentials.port)?.credentials
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
            if AppLaunchPairingPolicy.shouldShowOnboardingAfterInviteFailure(
                pairedServerCount: serverStore.servers.count
            ) {
                navigation.showOnboarding = true
            }
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
            return navigation.visibleSplitDiagnosticContext.sessionId
        case .stack:
            return navigation.workspaceStackDiagnosticContext.sessionId
        }
    }

    @MainActor
    private func diagnosticVisibleWorkspaceId() -> String? {
        switch navigation.workspaceNavigationPresentation {
        case .split:
            return navigation.visibleSplitDiagnosticContext.workspaceId
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
            return navigation.visibleSplitDiagnosticContext.screen
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
                    // A paired shell may still be waiting for its first usable
                    // transport. Foreground is an explicit recovery boundary for
                    // setup as well as for established streams.
                    if let activeServerId = coordinator.activeServerId,
                       let activeConnection = coordinator.connection(for: activeServerId),
                       activeConnection.credentials == nil {
                        await coordinator.recoverUnconfiguredServerAfterBoundary(activeServerId)
                        if activeConnection.credentials != nil,
                           ReleaseFeatures.remotePushNotificationsEnabled {
                            await coordinator.registerPushWithAllServers()
                        }
                    } else {
                        await connection.reconnectIfNeeded()
                    }
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

        // Navigate to session when user taps an attention notification body.
        // The service may deliver a tap latched before this handler was wired.
        notificationService.onNavigateToSession = { sessionId in
            guard !sessionId.isEmpty else { return }
            Task { @MainActor in
                await navigateToSessionFromDeepLink(
                    sessionId,
                    source: .externalURL,
                    parkingAllowed: true
                )
            }
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
           preparedConnection.apiClient != nil {
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

        // 6. Register for remote push notifications with all paired servers.
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
