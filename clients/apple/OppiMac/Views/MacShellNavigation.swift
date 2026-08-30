import Foundation
import SwiftUI

struct MacSelectedSessionTarget: Equatable, Sendable {
    let workspaceId: String
    let sessionId: String
    let summary: SessionSummary

    var routeScope: SessionRouteScope {
        if summary.control != nil {
            return .control
        }
        return .workspace(workspaceId)
    }

    static func == (lhs: MacSelectedSessionTarget, rhs: MacSelectedSessionTarget) -> Bool {
        lhs.workspaceId == rhs.workspaceId && lhs.sessionId == rhs.sessionId
    }

    static func from(session: Session) -> MacSelectedSessionTarget? {
        let summary = SessionSummary(from: session)
        if summary.control != nil {
            return MacSelectedSessionTarget(
                workspaceId: session.workspaceId ?? "",
                sessionId: session.id,
                summary: summary
            )
        }
        guard let workspaceId = session.workspaceId, !workspaceId.isEmpty else {
            return nil
        }
        return MacSelectedSessionTarget(
            workspaceId: workspaceId,
            sessionId: session.id,
            summary: summary
        )
    }
}

/// Destinations in the Mac desktop shell.
///
/// `sessionHome` is the launch destination and the sidebar Home row.
/// The visible sidebar is Mail-like source list: Home, then the iPad
/// destinations, Workspaces as a disclosure group, then Settings.
/// Home content uses the shared iPad inbox grouping: Your Turn, Working,
/// then stopped-by-day.
enum MacSidebarSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case sessionHome
    case agents
    case schedules
    case skills
    case extensions
    case workspaces
    case settings

    static let defaultSection: Self = .sessionHome
    static let primaryDestinations: [Self] = [
        .agents, .schedules, .skills, .extensions, .workspaces,
    ]
    static let pinnedDestinations: [Self] = [.settings]
    static let sidebarDestinations = [Self.sessionHome] + primaryDestinations + pinnedDestinations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessionHome: "Sessions"
        case .agents: "Agents"
        case .schedules: "Schedules"
        case .skills: "Skills"
        case .extensions: "Extensions"
        case .workspaces: "Workspaces"
        case .settings: "App Settings"
        }
    }

    var icon: String {
        switch self {
        case .sessionHome: "bubble.left.and.bubble.right"
        case .agents: "person.crop.circle"
        case .schedules: "clock"
        case .skills: "sparkles.rectangle.stack"
        case .extensions: "shippingbox"
        case .workspaces: "folder"
        case .settings: "gear"
        }
    }

    var isDisclosure: Bool {
        self == .workspaces
    }
}

/// Session whose card is actually on screen. Last-selected is not visible
/// after leaving Home or tearing down the main window.
enum MacAttentionVisibleSession {
    static func id(
        section: MacSidebarSection,
        selectedSessionID: String?,
        isMainWindowPresented: Bool
    ) -> String? {
        guard isMainWindowPresented, section == .sessionHome else {
            return nil
        }
        guard let selectedSessionID, !selectedSessionID.isEmpty else {
            return nil
        }
        return selectedSessionID
    }
}

/// Bound into `MainWindowView`'s `NavigationSplitView`.
/// `.all` keeps the destination source list visible on a wide window.
/// The system sidebar toggle can still collapse it after launch.
enum MacShellColumnVisibility {
    static let launch: NavigationSplitViewVisibility = .all
}

/// Sidebar Home row. Selects `sessionHome`, the launch destination.
enum MacSidebarHomeAffordance: String, CaseIterable, Identifiable, Hashable, Sendable {
    case home

    var id: String { rawValue }

    var destination: MacSidebarSection { .sessionHome }

    var title: String { "Home" }

    var icon: String { "house" }
}

/// Source-list selection: a destination section, or a workspace folder id.
///
/// Folder rows tag the workspace id so the clicked folder gets the system
/// highlight instead of All Workspaces. Launch still highlights Home.
enum MacSidebarSelection: Hashable, Sendable {
    case section(MacSidebarSection)
    case workspace(String)

    static func from(section: MacSidebarSection, workspaceID: String?) -> Self {
        if section == .workspaces, let workspaceID {
            return .workspace(workspaceID)
        }
        return .section(section)
    }

    /// Choosing a folder opens Workspaces on that id. Choosing All
    /// Workspaces clears the folder id. Other destinations keep it.
    func applied(
        to _: MacSidebarSection,
        workspaceID: String?
    ) -> (MacSidebarSection, String?) {
        switch self {
        case .section(let next):
            return (next, next == .workspaces ? nil : workspaceID)
        case .workspace(let id):
            return (.workspaces, id)
        }
    }
}

/// Host administration lives under App Settings rather than in the app sidebar.
enum MacSettingsPane: String, CaseIterable, Identifiable, Hashable, Sendable {
    case app
    case pairing
    case permissions
    case localServer
    case stats
    case remoteServers
    case logs
    case doctor

    static let hostToolPanes: [Self] = [
        .pairing, .permissions, .localServer, .stats, .remoteServers, .logs, .doctor,
    ]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: "General"
        case .pairing: "Pairing"
        case .permissions: "Permissions"
        case .localServer: "Local Server"
        case .stats: "Stats"
        case .remoteServers: "Remote Servers"
        case .logs: "Logs"
        case .doctor: "Doctor"
        }
    }

    var icon: String {
        switch self {
        case .app: "gear"
        case .pairing: "qrcode"
        case .permissions: "lock.shield"
        case .localServer: "server.rack"
        case .stats: "chart.bar"
        case .remoteServers: "network"
        case .logs: "doc.text"
        case .doctor: "stethoscope"
        }
    }
}

extension Notification.Name {
    static let revealMacHostTool = Notification.Name("Oppi.revealMacHostTool")
}

/// Menu bar extra opens App Settings host tools without a URL.
enum MacHostToolReveal {
    static func selection(for pane: MacSettingsPane) -> (section: MacSidebarSection, pane: MacSettingsPane) {
        (.settings, pane)
    }

    static func pane(from notification: Notification) -> MacSettingsPane? {
        notification.object as? MacSettingsPane
    }
}

/// Compact menu-bar line from live `/server/stats`. Nil until a fetch arrives.
enum MenuBarStatsSummary {
    static func line(from stats: ServerStats?) -> String? {
        guard let stats else { return nil }
        let sessions = stats.totals.sessions
        let sessionWord = sessions == 1 ? "session" : "sessions"
        return "\(sessions) \(sessionWord) \u{00B7} \(SessionFormatting.costString(stats.totals.cost))"
    }
}
