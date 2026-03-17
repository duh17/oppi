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
        let obs = onboardingState
        Task { @MainActor in
            obs.checkFirstRun()
            guard !obs.needsOnboarding else { return }
            guard pm.state == .stopped else { return }

            let dataDir = NSString("~/.config/oppi").expandingTildeInPath
            guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir) else { return }
            let baseURL = URL(string: "https://localhost:7749")!
            let client = MacAPIClient(baseURL: baseURL, token: token)

            let alreadyRunning = await client.checkHealth()
            if alreadyRunning {
                pm.markRunning()
            } else {
                pm.startWithDefaults()
            }
            hm.startMonitoring(baseURL: baseURL, token: token, processManager: pm)
            hm.checkPiCLIVersion()
        }
    }

    var body: some Scene {
        MenuBarExtra("Oppi", systemImage: menuBarIcon) {
            MenuBarPopover(
                processManager: processManager,
                healthMonitor: healthMonitor,
                permissionState: permissionState,
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
        }
        .menuBarExtraStyle(.window)

        Window("Oppi", id: "main") {
            MainWindowView(
                processManager: processManager,
                healthMonitor: healthMonitor,
                permissionState: permissionState,
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

    /// Auto-start the server on subsequent launches (config already exists).
    ///
    /// First checks if a server is already running (e.g. started from CLI).
    /// If healthy, adopts it — starts monitoring without spawning a child process.
    /// If not, spawns one.
    private func autoStartServer() {
        guard processManager.state == .stopped else { return }

        let dataDir = NSString("~/.config/oppi").expandingTildeInPath
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir) else { return }

        let baseURL = URL(string: "https://localhost:7749")!
        let client = MacAPIClient(baseURL: baseURL, token: token)

        // Check if a server is already running before spawning
        Task {
            let alreadyRunning = await client.checkHealth()
            if alreadyRunning {
                // Adopt the existing server — monitor it but don't spawn a child
                processManager.markRunning()
                healthMonitor.startMonitoring(
                    baseURL: baseURL,
                    token: token,
                    processManager: processManager
                )
                healthMonitor.checkPiCLIVersion()
            } else {
                processManager.startWithDefaults()
                healthMonitor.startMonitoring(
                    baseURL: baseURL,
                    token: token,
                    processManager: processManager
                )
                healthMonitor.checkPiCLIVersion()
            }
        }
    }

    private var menuBarIcon: String {
        switch processManager.state {
        case .running:
            "circle.fill"
        case .starting:
            "circle.dotted"
        case .failed:
            "exclamationmark.circle.fill"
        case .stopped, .stopping:
            "circle"
        }
    }
}
