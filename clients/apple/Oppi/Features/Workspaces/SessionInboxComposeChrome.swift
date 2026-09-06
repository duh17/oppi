import Foundation

/// All Sessions bottom-bar compose cluster. Search stays leading; dictation
/// and compose sit together on the trailing edge.
enum SessionInboxComposeChrome {
    /// Mic is a one-tap path into Quick Session. Hide it when compose creates
    /// a workspace session instead, or when now-playing already owns the bar.
    static func showsDictationShortcut(
        voiceInputEnabled: Bool,
        hasSelectedWorkspace: Bool,
        hasActivePlayback: Bool
    ) -> Bool {
        voiceInputEnabled && !hasSelectedWorkspace && !hasActivePlayback
    }
}
