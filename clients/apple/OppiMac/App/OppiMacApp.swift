import AppKit
import Sparkle
import SwiftUI

@main
struct OppiMacApp: App {

    // Sparkle updater — manages periodic background checks, download,
    // EdDSA verification, native update dialog, atomic install + relaunch.
    private let updaterController: SPUStandardUpdaterController

    @State private var processManager = ServerProcessManager()
    @State private var healthMonitor = ServerHealthMonitor()
    @State private var permissionState = TCCPermissionState()
    @State private var onboardingState = OnboardingState()
    @State private var sessionMonitor = MacSessionMonitor()
    @State private var themeStore = ThemeStore()
    @State private var showOnboarding = false
    @State private var pendingSessionDeepLinkURL: URL?

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        MacAttentionNotificationService.shared.configureForLaunch()

        // Auto-start server from init. The .task on MenuBarPopover content only
        // fires when the popover is opened (.menuBarExtraStyle(.window) is lazy),
        // so we cannot depend on it for launch-time startup.
        let pm = processManager
        let hm = healthMonitor
        let sm = sessionMonitor
        let obs = onboardingState
        Task { @MainActor in
            obs.checkFirstRun()
            guard !obs.needsOnboarding else { return }
            guard pm.state == .stopped else { return }

            await MacServerLifecycle.startOrAttachFromLocalConfig(
                processManager: pm,
                healthMonitor: hm,
                sessionMonitor: sm,
                allowKillingExistingServer: !Self.isRunningTests
            )
        }
    }

    var body: some Scene {
        Window("Oppi", id: "main") {
            MainWindowView(
                processManager: processManager,
                healthMonitor: healthMonitor,
                permissionState: permissionState,
                sessionMonitor: sessionMonitor,
                pendingSessionDeepLinkURL: $pendingSessionDeepLinkURL,
                checkForUpdates: { [updaterController] in
                    updaterController.checkForUpdates(nil)
                }
            )
            .onOpenURL { url in
                guard MacSessionDeepLink.sessionId(from: url) != nil else { return }
                pendingSessionDeepLinkURL = url
            }
            .environment(themeStore)
            .environment(\.theme, themeStore.appTheme)
            .environment(\.themeID, themeStore.activeThemeID)
            .tint(.themeBlue)
            .background {
                MacThemeColorSchemeSyncView(themeStore: themeStore)
            }
            .preferredColorScheme(themeStore.preferredColorScheme)
            .background(MainWindowActivationView())
            .task {
                await permissionState.refresh()
                onboardingState.checkFirstRun()
                if onboardingState.needsOnboarding {
                    showOnboarding = true
                } else {
                    autoStartServer()
                }
            }
            .sheet(isPresented: $showOnboarding) {
                OnboardingWindow(
                    onboardingState: onboardingState,
                    permissionState: permissionState,
                    processManager: processManager,
                    healthMonitor: healthMonitor,
                    onComplete: {
                        showOnboarding = false
                    }
                )
            }
        }
        .defaultLaunchBehavior(.presented)

        MenuBarExtra {
            MenuBarPopover(
                processManager: processManager,
                healthMonitor: healthMonitor,
                sessionMonitor: sessionMonitor
            )
            .onAppear {
                sessionMonitor.setFastPolling(true)
            }
            .onDisappear {
                sessionMonitor.setFastPolling(false)
            }
        } label: {
            MenuBarIconView(
                processManager: processManager,
                sessionMonitor: sessionMonitor
            )
            .background {
                MacAttentionBannerNavigationHost(
                    pendingSessionDeepLinkURL: $pendingSessionDeepLinkURL
                )
            }
        }
        .menuBarExtraStyle(.window)
    }

    /// Auto-start or attach to the server on subsequent launches.
    private func autoStartServer() {
        guard processManager.state == .stopped else { return }

        Task {
            await MacServerLifecycle.startOrAttachFromLocalConfig(
                processManager: processManager,
                healthMonitor: healthMonitor,
                sessionMonitor: sessionMonitor,
                allowKillingExistingServer: !Self.isRunningTests
            )
        }
    }

    /// True when the app is launched as a test host (xcodebuild test).
    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

/// Host-route `oppi://session/<id>` only. Same contract as iOS `InAppSessionLink`.
enum MacSessionDeepLink {
    static func sessionId(from url: URL) -> String? {
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
        return sessionId
    }

    static func url(for sessionId: String) -> URL? {
        guard !sessionId.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "oppi"
        components.host = "session"
        let encoded = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId
        components.percentEncodedPath = "/\(encoded)"
        return components.url
    }
}

/// Banner tap opens the main window, then the existing `oppi://session/<id>` path.
enum MacAttentionBannerNavigation {
    static let mainWindowId = "main"

    struct Action: Equatable, Sendable {
        let openWindowId: String
        let sessionDeepLinkURL: URL
    }

    static func action(for sessionId: String) -> Action? {
        guard let sessionDeepLinkURL = MacSessionDeepLink.url(for: sessionId) else {
            return nil
        }
        return Action(openWindowId: mainWindowId, sessionDeepLinkURL: sessionDeepLinkURL)
    }

    @MainActor
    static func perform(
        sessionId: String,
        setPendingURL: (URL?) -> Void,
        openWindow: (String) -> Void,
        activateApp: () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    ) {
        guard let action = action(for: sessionId) else { return }
        openWindow(action.openWindowId)
        setPendingURL(action.sessionDeepLinkURL)
        activateApp()
    }
}

/// Lives on the menu-bar extra label so a tap still works when the main
/// window is closed. `MenuBarPopover` content is lazy; the label is not.
private struct MacAttentionBannerNavigationHost: View {
    @Binding var pendingSessionDeepLinkURL: URL?
    @Environment(\.openWindow) private var openMainWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear(perform: wire)
    }

    private func wire() {
        MacAttentionNotificationService.shared.onNavigateToSession = { sessionId in
            MacAttentionBannerNavigation.perform(
                sessionId: sessionId,
                setPendingURL: { pendingSessionDeepLinkURL = $0 },
                openWindow: { openMainWindow(id: $0) }
            )
        }
    }
}

/// External `oppi://session/<id>` opens a known session. Unknown IDs park
/// until Home's catalog load finishes, then get one owner-socket lookup before
/// falling back to Workspaces.
enum MacSessionDeepLinkNavigation {
    enum Destination: Equatable, Sendable {
        case selectSession(String)
        case selectTarget(MacSelectedSessionTarget)
        case showWorkspaces
        case park
        case ignore
    }

    static func destination(
        sessionId: String?,
        knownSessionIDs: Set<String>,
        catalogReady: Bool
    ) -> Destination {
        guard let sessionId, !sessionId.isEmpty else {
            return .ignore
        }
        if knownSessionIDs.contains(sessionId) {
            return .selectSession(sessionId)
        }
        if !catalogReady {
            return .park
        }
        return .showWorkspaces
    }

    static func shouldRetryAfterServerBecameReady(
        state: ServerProcessManager.State,
        hasPendingSessionDeepLink: Bool
    ) -> Bool {
        state == .running && hasPendingSessionDeepLink
    }

    @MainActor
    static func fetchedDestination(
        sessionId: String,
        isCurrentRequest: () -> Bool,
        fetchSession: (String) async throws -> Session
    ) async -> Destination {
        do {
            let session = try await fetchSession(sessionId)
            guard isCurrentRequest() else { return .ignore }
            guard session.id == sessionId,
                  let target = MacSelectedSessionTarget.from(session: session) else {
                return .showWorkspaces
            }
            return .selectTarget(target)
        } catch {
            guard isCurrentRequest() else { return .ignore }
            return .showWorkspaces
        }
    }
}

/// Keeps `ThemeStore` aligned with macOS appearance while mode is Match System.
private struct MacThemeColorSchemeSyncView: View {
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

/// Brings the launch window forward after SwiftUI attaches its content view.
/// The Window scene is explicitly presented on launch; this view handles app
/// activation when Oppi was started behind another application.
private struct MainWindowActivationView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        MainWindowActivationNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class MainWindowActivationNSView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Restored frames can sit on a disconnected ultra-wide; center on the active display.
        window.center()
    }
}

// MARK: - Menu bar icon

/// Renders the menu bar icon with an optional pulse animation when sessions are busy.
///
/// Icon state machine:
/// - Server stopped/stopping   → "circle" (outline)
/// - Server starting           → "circle.dotted"
/// - Server failed             → "exclamationmark.circle.fill"
/// - Server running, no active sessions → "circle" (outline)
/// - Server running, sessions active    → "circle.fill"
/// - Server running, any session busy   → "circle.fill" + pulse animation
private struct MenuBarIconView: View {

    let processManager: ServerProcessManager
    let sessionMonitor: MacSessionMonitor

    private var activeSessions: [StatsActiveSession] {
        sessionMonitor.stats?.activeSessions ?? []
    }

    private var hasActiveSessions: Bool {
        !activeSessions.isEmpty
    }

    private var hasBusySessions: Bool {
        activeSessions.contains { $0.isBusy }
    }

    private var iconName: String {
        switch processManager.state {
        case .starting:
            return "circle.dotted"
        case .failed:
            return "exclamationmark.circle.fill"
        case .stopped, .stopping:
            return "circle"
        case .running:
            return hasActiveSessions ? "circle.fill" : "circle"
        }
    }

    var body: some View {
        if hasBusySessions {
            Image(systemName: iconName)
                .symbolEffect(.pulse)
        } else {
            Image(systemName: iconName)
        }
    }
}
