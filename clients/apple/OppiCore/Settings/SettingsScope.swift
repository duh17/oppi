import Foundation

/// Where a setting is kept, which a page says only when it differs from what
/// the page as a whole says. Derived from a declaration's `SettingStorage` and
/// the current server or workspace name (`SettingsStore.scope(of:)`); a page
/// never builds one by hand.
enum SettingsScope: Hashable, Sendable {
    /// This device only.
    case device
    /// The server, for every device that uses it. The name is the server's.
    case server(String)
    /// One workspace. The name is the workspace's.
    case workspace(String)
    /// This device's own value, stored on the server. The name is the server's.
    case deviceOnServer(String)

    /// The one sentence a section shows when its scope is not its page's.
    var sentence: String {
        switch self {
        case .device: String(localized: "Saved on this device.")
        case .server(let name): String(localized: "Applies to every device on \(name).")
        case .workspace: String(localized: "Applies to this workspace.")
        case .deviceOnServer(let name): String(localized: "For this device, kept on \(name).")
        }
    }

    /// The footer a section shows: the scope sentence when the section's scope
    /// differs from the page's, then the section's own footer. A page that
    /// mixes scopes has no page scope (`nil`), so every section with a scope
    /// says it.
    static func footer(_ footer: String?, scope: SettingsScope?, pageScope: SettingsScope?) -> String? {
        guard let scope, scope != pageScope else { return footer }
        guard let footer, !footer.isEmpty else { return scope.sentence }
        return scope.sentence + " " + footer
    }
}
