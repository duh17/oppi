import Foundation

/// A file reference queued for sending alongside a message.
///
/// Created when the user selects a file from `@` autocomplete.
/// Displayed as a pill in the composer. On send, each reference
/// is injected as `@path` at the start of the message text.
struct PendingFileReference: Identifiable, Sendable, Equatable {
    let path: String
    let isDirectory: Bool

    var id: String { path }

    var displayName: String {
        let normalized = isDirectory && path.hasSuffix("/") ? String(path.dropLast()) : path
        return normalized.split(separator: "/").last.map(String.init) ?? normalized
    }
}
