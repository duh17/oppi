import Foundation

/// Host extension metadata from `GET /extensions`.
///
/// Extensions are discovered on the server from `~/.pi/agent/extensions` and
/// can be selected in explicit workspace extension mode.
struct ExtensionInfo: Codable, Identifiable, Sendable, Equatable {
    let name: String
    let path: String
    let kind: String    // "file" | "directory"

    var id: String { name }
}
