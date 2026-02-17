import Foundation

/// Tracks recently-used model IDs so the picker can show them first.
///
/// Stored in UserDefaults — lightweight, survives app restarts.
/// Thread-safe via MainActor (all callers are UI-side).
@MainActor
enum RecentModels {
    private static let key = "RecentModelIDs"
    private static let maxRecent = 5

    /// Record a model as most-recently used.
    static func record(_ modelId: String) {
        var ids = load()
        ids.removeAll { $0 == modelId }
        ids.insert(modelId, at: 0)
        if ids.count > maxRecent {
            ids = Array(ids.prefix(maxRecent))
        }
        UserDefaults.standard.set(ids, forKey: key)
    }

    /// Load ordered list of recent model full IDs (most recent first).
    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }
}
