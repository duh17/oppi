import Foundation

/// A feature the server owner switches off for every device (`features` in `/server/info`,
/// Server Settings → Features). Plain Pi (chat, sessions and files) has no switch. The server
/// switch says whether a feature exists on that server; a device Experiment only hides one
/// that is unfinished (`dev/architecture-client.md`, "Server features and Experiments").
enum ServerFeature: String, CaseIterable, Sendable {
    case agents, schedules, skills, extensions, mcp, terminal, rex, herdr, godotPane, browserPane

    /// The switch's row title in Server Settings → Features.
    var title: String {
        switch self {
        case .agents: String(localized: "Agents")
        case .schedules: String(localized: "Schedules")
        case .skills: String(localized: "Skills")
        case .extensions: String(localized: "Extensions")
        case .mcp: String(localized: "MCP Servers")
        case .terminal: String(localized: "Terminal")
        case .rex: String(localized: "Rex")
        case .herdr: String(localized: "Herdr")
        case .godotPane: String(localized: "Godot Pane")
        case .browserPane: String(localized: "Web Pages in Panes")
        }
    }
}
