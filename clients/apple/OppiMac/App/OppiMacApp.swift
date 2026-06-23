import SwiftUI
import Sparkle

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
    @State private var showOnboarding = false

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

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
        MenuBarExtra {
            MenuBarPopover(
                processManager: processManager,
                healthMonitor: healthMonitor,
                permissionState: permissionState,
                sessionMonitor: sessionMonitor,
                checkForUpdates: { [updaterController] in
                    updaterController.checkForUpdates(nil)
                }
            )
            .task {
                // Refresh permissions when popover is opened. Server auto-start
                // runs from init() — this .task only fires on popover open
                // (.menuBarExtraStyle(.window) lazily instantiates content).
                await permissionState.refresh()
            }
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
        }
        .menuBarExtraStyle(.window)

        Window("Oppi", id: "main") {
            MainWindowView(
                processManager: processManager,
                healthMonitor: healthMonitor,
                permissionState: permissionState,
                sessionMonitor: sessionMonitor,
                checkForUpdates: { [updaterController] in
                    updaterController.checkForUpdates(nil)
                }
            )
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
