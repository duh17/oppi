import Foundation

/// Persisted defaults for the Quick Session sheet.
///
/// Stores the last-used workspace, model, and thinking level so the sheet
/// opens pre-configured to the user's most recent choices.
enum QuickSessionDefaults {
    private static let prefix = "\(AppIdentifiers.subsystem).quickSession"

    private static let lastWorkspaceIdKey = "\(prefix).lastWorkspaceId"
    private static let lastModelIdKey = "\(prefix).lastModelId"
    private static let lastThinkingLevelKey = "\(prefix).lastThinkingLevel"

    // MARK: - Workspace

    static var lastWorkspaceId: String? {
        UserDefaults.standard.string(forKey: lastWorkspaceIdKey)
    }

    static func saveWorkspaceId(_ id: String) {
        UserDefaults.standard.set(id, forKey: lastWorkspaceIdKey)
    }

    // MARK: - Model

    static var lastModelId: String? {
        UserDefaults.standard.string(forKey: lastModelIdKey)
    }

    static func saveModelId(_ id: String) {
        UserDefaults.standard.set(id, forKey: lastModelIdKey)
    }

    // MARK: - Thinking Level

    static var lastThinkingLevel: ThinkingLevel {
        guard let raw = UserDefaults.standard.string(forKey: lastThinkingLevelKey),
              let level = ThinkingLevel(rawValue: raw)
        else {
            return .medium
        }
        return level
    }

    static func saveThinkingLevel(_ level: ThinkingLevel) {
        UserDefaults.standard.set(level.rawValue, forKey: lastThinkingLevelKey)
    }
}
