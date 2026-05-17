import Foundation

/// Status for a host path entered during workspace setup.
struct HostPathStatus: Decodable, Sendable, Equatable {
    let path: String
    let resolvedPath: String
    let exists: Bool
    let isDirectory: Bool
    let isFile: Bool
    let issue: String?
    let message: String?

    var isValidWorkspaceDirectory: Bool {
        exists && isDirectory && issue == nil
    }

    var userMessage: String {
        switch issue {
        case "missing":
            return "Path doesn’t exist"
        case "not_directory":
            return "Path is not a directory"
        case "inaccessible":
            return "Path is not accessible"
        default:
            return message ?? "Path is not valid"
        }
    }
}

/// Result from explicit host folder creation.
struct HostPathCreateResult: Decodable, Sendable, Equatable {
    let created: Bool
    let status: HostPathStatus
}

/// One host path completion candidate.
struct HostPathCompletion: Decodable, Identifiable, Sendable, Equatable {
    let path: String
    let name: String

    var id: String { path }
}

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
