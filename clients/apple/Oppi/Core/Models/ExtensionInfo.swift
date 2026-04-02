import Foundation

/// Host extension metadata from `GET /extensions`.
///
/// The server returns oppi first-party extensions (ask, spawn_agent) and
/// pi host extensions from `~/.pi/agent/extensions` and project-local
/// `.pi/extensions`.
struct ExtensionInfo: Codable, Identifiable, Sendable, Equatable {
    let name: String
    let path: String
    let kind: String    // "file" | "directory" | "built-in"
    let source: String? // "oppi" | "pi" — nil treated as "pi" for back-compat

    var id: String { name }

    var isOppi: Bool {
        source == "oppi"
    }

    var locationLabel: String {
        if isOppi { return "oppi" }
        if path.contains("/.pi/extensions/") { return ".pi/extensions" }
        return "~/.pi/agent/extensions"
    }

    var subtitle: String {
        if isOppi { return "built-in" }
        return "\(locationLabel) \u{00B7} \(kind)"
    }
}
