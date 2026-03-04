import Foundation

/// A project directory discovered on the host server.
///
/// Matches the server's `HostDirectory` type from `GET /host/directories`.
struct HostDirectory: Decodable, Identifiable, Sendable, Equatable {
    /// Display path (with ~ prefix, e.g. "~/workspace/oppi").
    let path: String
    /// Directory name (e.g. "oppi").
    let name: String
    /// Has .git directory.
    let isGitRepo: Bool
    /// Primary git remote URL (normalized), if any.
    let gitRemote: String?
    /// Has AGENTS.md (pi/Claude Code project config).
    let hasAgentsMd: Bool
    /// Detected project type based on manifest files (e.g. "node", "swift", "go").
    let projectType: String?
    /// Primary language hint (e.g. "TypeScript", "Swift", "Go").
    let language: String?

    var id: String { path }

    /// SF Symbol name for project type.
    var projectTypeIcon: String {
        switch projectType {
        case "node": return "n.square"
        case "swift", "xcodegen": return "swift"
        case "go": return "g.square"
        case "rust": return "r.square"
        case "python": return "p.square"
        case "ruby": return "r.square"
        case "gradle", "maven": return "j.square"
        case "elixir": return "e.square"
        case "make": return "m.square"
        default: return "folder"
        }
    }
}
