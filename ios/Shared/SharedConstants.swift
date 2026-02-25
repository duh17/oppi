import Foundation

/// Constants shared between the main app and widget extensions.
///
/// Lives in the Shared target so both `Oppi` and `OppiActivityExtension`
/// can reference the same identifiers without import cycles.
enum SharedConstants {
    /// App Group identifier used for shared UserDefaults and Keychain access.
    ///
    /// Must match `APP_GROUP_IDENTIFIER` in project.yml and the
    /// `com.apple.security.application-groups` entitlement in both targets.
    static let appGroupIdentifier = "group.oppi"

    /// Shared UserDefaults suite for data visible to both app and extensions.
    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    /// UserDefaults key for the ordered list of paired server IDs.
    static let pairedServerIdsKey = "pairedServerIds"

    /// Keychain service name. Must match across app and extension so
    /// items stored by the main app are readable from Live Activity intents.
    static let keychainService = "dev.chenda.Oppi"

    /// Keychain access group. Uses the App Group identifier so items
    /// are shared between the main app and widget extensions.
    static let keychainAccessGroup = appGroupIdentifier

    /// Keychain account prefix for paired server entries.
    static let serverAccountPrefix = "server-"
}
