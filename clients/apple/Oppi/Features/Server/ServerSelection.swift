/// Pure logic for multi-server selection, extracted for testability.
///
/// Used by `ServerView` to resolve which `PairedServer` to display
/// and to build task identities for data reloading.
enum ServerSelection {
    /// Resolve the selected server by ID, falling back to the first server.
    ///
    /// - Returns: The server matching `selectedId`, or the first server
    ///   if the ID is nil or doesn't match any server.
    static func resolve(selectedId: String?, from servers: [PairedServer]) -> PairedServer? {
        if let selectedId, let match = servers.first(where: { $0.id == selectedId }) {
            return match
        }
        return servers.first
    }

    /// Build a combined task identity string from server ID and range.
    ///
    /// Used as `.task(id:)` key so SwiftUI re-fetches data when either
    /// the selected server or the time range changes.
    static func taskIdentity(selectedId: String?, range: Int) -> String {
        "\(selectedId ?? "")-\(range)"
    }
}
