import SwiftUI
import Sparkle

@main
struct OppiMacApp: App {

    // Sparkle updater — manages periodic background checks, download,
    // EdDSA verification, native update dialog, atomic install + relaunch.
    private let updaterController: SPUStandardUpdaterController

    @State private var processManager = ServerProcessManager()
    @State private var healthMonitor = ServerHealthMonitor()

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        MenuBarExtra("Oppi", systemImage: menuBarIcon) {
            MenuBarPopover(
                processManager: processManager,
                healthMonitor: healthMonitor,
                checkForUpdates: { [updaterController] in
                    updaterController.checkForUpdates(nil)
                }
            )
        }
        .menuBarExtraStyle(.window)

        Window("Oppi", id: "main") {
            MainWindowView(
                processManager: processManager,
                healthMonitor: healthMonitor
            )
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
