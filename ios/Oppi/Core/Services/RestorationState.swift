import Foundation

/// Lightweight state snapshot persisted on background for launch restoration.
///
/// Saved to UserDefaults (not Keychain — no secrets).
/// Schema-versioned so we can migrate or discard on changes.
struct RestorationState: Codable {
    static let schemaVersion = 2
    static let key = "\(AppIdentifiers.subsystem).restoration"

    let version: Int
    let activeSessionId: String?
    /// Server fingerprint of the active server when backgrounded.
    let activeServerId: String?
    let selectedTab: String  // "workspaces", "settings"
    let composerDraft: String?
    /// ID of the topmost visible chat item when the app was backgrounded.
    let scrollAnchorItemId: String?
    /// Whether the user was scrolled to the bottom of the chat timeline.
    /// `nil` treated as `true` for backward compatibility with v1 states.
    let wasNearBottom: Bool?
    let timestamp: Date

    // MARK: - Save

    @MainActor
    static func save(from connection: ServerConnection, coordinator: ConnectionCoordinator, navigation: AppNavigation) {
        let state = RestorationState(
            version: schemaVersion,
            activeSessionId: connection.sessionStore.activeSessionId,
            activeServerId: coordinator.activeServerId,
            selectedTab: navigation.selectedTab.rawString,
            composerDraft: connection.composerDraft,
            scrollAnchorItemId: connection.scrollAnchorItemId,
            wasNearBottom: connection.scrollWasNearBottom,
            timestamp: Date()
        )

        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: - Load

    /// Load restoration state if fresh enough (< 1 hour old).
    /// Accepts both v1 (no activeServerId) and v2 schemas.
    static func load() -> RestorationState? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(RestorationState.self, from: data),
              state.version >= 1 && state.version <= schemaVersion,
              Date().timeIntervalSince(state.timestamp) < 3600  // 1 hour freshness
        else {
            return nil
        }
        return state
    }

    // MARK: - Clear

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - AppTab serialization

extension AppTab {
    var rawString: String {
        switch self {
        case .workspaces: return "workspaces"
        case .settings: return "settings"
        }
    }

    init(rawString: String) {
        switch rawString {
        case "settings":
            self = .settings
        default:
            self = .workspaces
        }
    }
}
