import Combine
import SwiftUI

extension Notification.Name {
    static let navigateToTab = Notification.Name("OppiMac.navigateToTab")
}

struct MainWindowView: View {

    let processManager: ServerProcessManager
    let healthMonitor: ServerHealthMonitor
    let permissionState: TCCPermissionState
    let checkForUpdates: @MainActor () -> Void

    @State private var selectedTab: SidebarTab? = .status

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                ForEach(SidebarTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.icon)
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
        } detail: {
            if let tab = selectedTab {
                detailView(for: tab)
            } else {
                Text("Select an item")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onReceive(NotificationCenter.default.publisher(for: .navigateToTab)) { note in
            if let tab = note.object as? SidebarTab {
                selectedTab = tab
            }
        }
    }

    @ViewBuilder
    private func detailView(for tab: SidebarTab) -> some View {
        switch tab {
        case .status:
            StatusView(
                processManager: processManager,
                healthMonitor: healthMonitor
            )
        case .pair:
            PairView()
        case .permissions:
            PermissionsView(permissionState: permissionState)
        case .logs:
            LogsView(processManager: processManager)
        case .doctor:
            DoctorView()
        case .settings:
            SettingsView(
                processManager: processManager,
                checkForUpdates: checkForUpdates,
                apiClient: makeAPIClient()
            )
        }
    }
}

extension MainWindowView {
    /// Construct an API client for the local server if a token is available.
    private func makeAPIClient() -> MacAPIClient? {
        let dataDir = NSString("~/.config/oppi").expandingTildeInPath
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir) else { return nil }
        return MacAPIClient(baseURL: URL(string: "https://localhost:7749")!, token: token)
    }
}

// MARK: - Sidebar tabs

enum SidebarTab: String, CaseIterable, Identifiable {
    case status
    case pair
    case permissions
    case logs
    case doctor
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: "Status"
        case .pair: "Pair"
        case .permissions: "Permissions"
        case .logs: "Logs"
        case .doctor: "Doctor"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .status: "heart.text.square"
        case .pair: "qrcode"
        case .permissions: "lock.shield"
        case .logs: "doc.text"
        case .doctor: "stethoscope"
        case .settings: "gear"
        }
    }
}
