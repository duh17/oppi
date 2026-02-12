import Foundation

/// Persists the preferred thinking level per model id.
///
/// This enables model-specific defaults (e.g. fast model -> off, deep model -> high)
/// that are restored when the user switches models.
enum ThinkingLevelMemory {
    private static let defaultsKey = "dev.chenda.PiRemote.thinkingLevelByModel"

    static func level(for model: String?) -> ThinkingLevel? {
        guard let model = normalizedModelID(model) else { return nil }
        guard let raw = storedMap()[model] else { return nil }
        return ThinkingLevel(rawValue: raw)
    }

    static func set(_ level: ThinkingLevel, for model: String?) {
        guard let model = normalizedModelID(model) else { return }
        var map = storedMap()
        map[model] = level.rawValue
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }

    private static func storedMap() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    private static func normalizedModelID(_ model: String?) -> String? {
        guard let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
