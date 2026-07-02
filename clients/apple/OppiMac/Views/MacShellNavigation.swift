import Foundation

struct MacSelectedSessionTarget: Equatable, Sendable {
    let workspaceId: String
    let sessionId: String
    let summary: SessionSummary

    static func == (lhs: MacSelectedSessionTarget, rhs: MacSelectedSessionTarget) -> Bool {
        lhs.workspaceId == rhs.workspaceId && lhs.sessionId == rhs.sessionId
    }
}

/// Top-level areas in the Mac desktop client shell.
///
/// Pairing is intentionally a companion-device action, not a prerequisite for
/// using the Mac app. The Mac app can run/attach to the local server by itself,
/// and later attach additional remote servers.
enum MacSidebarSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case workspaces
    case sessions
    case localServer
    case remoteServers
    case pairDevices
    case permissions
    case logs
    case doctor
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspaces: "Workspaces"
        case .sessions: "Sessions"
        case .localServer: "Local Server"
        case .remoteServers: "Remote Servers"
        case .pairDevices: "Pair Devices"
        case .permissions: "Permissions"
        case .logs: "Logs"
        case .doctor: "Doctor"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .workspaces: "folder"
        case .sessions: "bubble.left.and.bubble.right"
        case .localServer: "server.rack"
        case .remoteServers: "network"
        case .pairDevices: "qrcode"
        case .permissions: "lock.shield"
        case .logs: "doc.text"
        case .doctor: "stethoscope"
        case .settings: "gear"
        }
    }

    var group: MacSidebarGroup {
        switch self {
        case .workspaces, .sessions:
            return .client
        case .localServer, .remoteServers:
            return .servers
        case .pairDevices, .permissions, .logs, .doctor, .settings:
            return .tools
        }
    }
}

enum MacSidebarGroup: String, CaseIterable, Identifiable, Hashable, Sendable {
    case client
    case servers
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .client: "Client"
        case .servers: "Servers"
        case .tools: "Tools"
        }
    }
}
