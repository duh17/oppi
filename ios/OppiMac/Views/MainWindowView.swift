import SwiftUI

struct MainWindowView: View {

    let processManager: ServerProcessManager
    let healthMonitor: ServerHealthMonitor
    let permissionState: TCCPermissionState

    @State private var selectedTab: SidebarTab? = .status

    var body: some View {
        NavigationSplitView {
            List(SidebarTab.allCases, selection: $selectedTab) { tab in
                Label(tab.title, systemImage: tab.icon)
            }
            .navigationTitle("Oppi")
        } detail: {
            if let tab = selectedTab {
                detailView(for: tab)
            } else {
                Text("Select an item")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    @ViewBuilder
    private func detailView(for tab: SidebarTab) -> some View {
        switch tab {
        case .status:
            StatusPlaceholderView(
                processManager: processManager,
                healthMonitor: healthMonitor
            )
        case .pair:
            Text("Pair view — coming soon")
                .foregroundStyle(.secondary)
        case .permissions:
            PermissionsView(permissionState: permissionState)
        case .logs:
            LogsView(processManager: processManager)
        case .settings:
            Text("Settings — coming soon")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Sidebar tabs

enum SidebarTab: String, CaseIterable, Identifiable {
    case status
    case pair
    case permissions
    case logs
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: "Status"
        case .pair: "Pair"
        case .permissions: "Permissions"
        case .logs: "Logs"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .status: "heart.text.square"
        case .pair: "qrcode"
        case .permissions: "lock.shield"
        case .logs: "doc.text"
        case .settings: "gear"
        }
    }
}
