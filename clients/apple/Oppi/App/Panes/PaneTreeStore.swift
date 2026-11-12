import Foundation

/// Where a window's pane tree lives between launches: UserDefaults, one
/// entry per scene session (`pane.layout.<persistentIdentifier>`), written
/// when the panes settle and dropped when the system discards the scene.
///
/// The newest tree is also kept under `pane.layout.latest`, which a discard
/// leaves alone: a scene that connects with no entry of its own (the system
/// discarded the old one, as it may on a force-quit from the app switcher)
/// restores it. That holds while the app has one scene; with several windows
/// it would copy one window's panes into another, so it is revisited when
/// scenes turn on.
struct PaneTreeStore {
    static let keyPrefix = "pane.layout."
    static let latestKey = "pane.layout.latest"
    /// Set while a restore mounts its screens, cleared once they have held a
    /// few seconds or the scene goes to the background. Still set at launch,
    /// the last restore may have crashed the app: the saved trees go.
    static let restoringKey = "pane.layout.restoring"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(forScene id: String) -> String { keyPrefix + id }

    /// The scene's own tree, else the newest one; nil when neither decodes.
    func load(scene id: String) -> PaneLayoutArchive? {
        let data = defaults.data(forKey: Self.key(forScene: id)) ?? defaults.data(forKey: Self.latestKey)
        return data.flatMap(PaneLayoutArchive.decode)
    }

    /// Saves `archive` for the scene; nil (nothing restorable) removes it.
    func save(_ archive: PaneLayoutArchive?, scene id: String) {
        guard let archive, let data = try? archive.encoded() else {
            defaults.removeObject(forKey: Self.key(forScene: id))
            defaults.removeObject(forKey: Self.latestKey)
            return
        }
        defaults.set(data, forKey: Self.key(forScene: id))
        defaults.set(data, forKey: Self.latestKey)
    }

    var lastRestoreWasInterrupted: Bool { defaults.bool(forKey: Self.restoringKey) }

    func markRestoring(_ restoring: Bool) {
        if restoring { defaults.set(true, forKey: Self.restoringKey) } else { defaults.removeObject(forKey: Self.restoringKey) }
    }

    /// Drops the scene's tree and the newest copy, after a restore that did
    /// not survive.
    func dropAfterInterruptedRestore(scene id: String) {
        defaults.removeObject(forKey: Self.key(forScene: id))
        defaults.removeObject(forKey: Self.latestKey)
        markRestoring(false)
    }

    /// The system discarded these scenes: their trees go.
    func discard(scenes ids: some Sequence<String>) {
        for id in ids {
            defaults.removeObject(forKey: Self.key(forScene: id))
        }
    }
}
