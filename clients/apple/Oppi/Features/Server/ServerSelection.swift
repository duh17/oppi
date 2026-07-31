/// Pure logic for multi-server selection, extracted for testability.
///
/// Used by `ServerView` to resolve which `PairedServer` to display
/// and to build task identities for data reloading.
enum ServerRouteModePresentation {
    static func options(
        for authorization: SignedTransportAuthorization,
        httpScheme: ServerScheme? = .https
    ) -> [PairedServerRouteMode] {
        var modes: [PairedServerRouteMode] = [.automatic]
        if authorization.contains(.https), httpScheme == .https {
            modes.append(.httpsOnly)
        }
        if authorization.contains(.iroh) {
            modes.append(.irohOnly)
        }
        return modes
    }

    static func label(for mode: PairedServerRouteMode) -> String {
        switch mode {
        case .automatic:
            "Automatic"
        case .httpsOnly:
            "HTTPS Only"
        case .irohOnly:
            "Iroh Only"
        }
    }

    static func description(for mode: PairedServerRouteMode) -> String {
        switch mode {
        case .automatic:
            "Uses LAN or paired HTTPS first, with Iroh fallback."
        case .httpsOnly:
            "Uses verified LAN or paired HTTPS only."
        case .irohOnly:
            "Uses Iroh only."
        }
    }
}

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

    /// Build a task identity for server-scoped metadata loads.
    ///
    /// Used for server info and provider/configuration fetches that should only
    /// reload when the selected server changes.
    static func metadataTaskIdentity(selectedId: String?) -> String {
        selectedId ?? ""
    }

    /// Build a combined task identity string from server ID and range.
    ///
    /// Used as `.task(id:)` key so SwiftUI re-fetches stats when either
    /// the selected server or the time range changes.
    static func taskIdentity(selectedId: String?, range: Int) -> String {
        "\(selectedId ?? "")-\(range)"
    }
}
