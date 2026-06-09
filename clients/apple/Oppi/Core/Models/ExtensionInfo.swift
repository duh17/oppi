import Foundation

/// Host extension metadata from `GET /extensions`.
///
/// The server returns Oppi first-party extensions and Pi extensions resolved
/// from auto-discovered directories plus installed
/// packages/settings paths.
struct ExtensionInfo: Codable, Identifiable, Sendable, Equatable {
    let name: String
    let path: String
    let kind: String    // "file" | "directory" | "built-in"
    let source: String // "oppi" | "pi"

    var id: String { name }

    var isOppi: Bool {
        source == "oppi"
    }

    var locationLabel: String {
        if isOppi { return "oppi" }
        if path.contains("/.pi/extensions/") { return ".pi/extensions" }
        if path.contains("/.pi/agent/extensions/") { return "~/.pi/agent/extensions" }
        if path.contains("/.pi/git/") { return ".pi/git (package)" }
        if path.contains("/.pi/agent/git/") { return "~/.pi/agent/git (package)" }
        if path.contains("/.pi/npm/") { return ".pi/npm (package)" }
        if path.contains("/node_modules/") { return "npm package" }
        return "pi package/local path"
    }

    var subtitle: String {
        if isOppi { return "built-in" }
        return "\(locationLabel) \u{00B7} \(kind)"
    }
}
