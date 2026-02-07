import Foundation

/// Lightweight state snapshot persisted on background for launch restoration.
///
/// Saved to UserDefaults (not Keychain — no secrets).
/// Schema-versioned so we can migrate or discard on changes.
struct RestorationState: Codable {
    static let schemaVersion = 1
    static let key = "dev.chenda.PiRemote.restoration"

    let version: Int
    let activeSessionId: String?
    let selectedTab: String  // "sessions", "settings"
    let composerDraft: String?
    let timestamp: Date

    // MARK: - Save

    @MainActor
    static func save(from connection: ServerConnection, navigation: AppNavigation) {
        let state = RestorationState(
            version: schemaVersion,
            activeSessionId: connection.sessionStore.activeSessionId,
            selectedTab: navigation.selectedTab.rawString,
            composerDraft: connection.composerDraft,
            timestamp: Date()
        )

        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: - Load

    /// Load restoration state if fresh enough (< 1 hour old) and schema matches.
    static func load() -> RestorationState? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(RestorationState.self, from: data),
              state.version == schemaVersion,
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
        case .sessions: return "sessions"
        case .settings: return "settings"
        }
    }

    init(rawString: String) {
        switch rawString {
        case "settings": self = .settings
        default: self = .sessions
        }
    }
}
