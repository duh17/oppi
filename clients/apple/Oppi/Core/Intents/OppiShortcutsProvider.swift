import AppIntents

/// Registers Oppi's App Shortcuts with the system.
///
/// These appear automatically in:
/// - Spotlight search (type "Start session in Oppi")
/// - Siri ("Hey Siri, start a session in Oppi")
/// - Shortcuts app (as pre-configured actions)
/// - Action Button set to a Shortcut
struct OppiShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // One tap or phrase to talk to Pi. To choose the Agent and workspace that answer,
        // add the New Session action to a Shortcut and set its Mode to Live Voice.
        AppShortcut(
            intent: StartQuickSessionIntent(mode: .liveVoice),
            phrases: [
                "Talk to \(.applicationName)",
                "Call \(.applicationName)",
                "Start Live Voice in \(.applicationName)",
            ],
            shortTitle: "Live Voice",
            systemImageName: "waveform"
        )

        // One tile per mode: Message, Dictation, Live Voice.
        AppShortcut(
            intent: StartQuickSessionIntent(),
            phrases: [
                "New \(\.$mode) in \(.applicationName)",
                "Open \(.applicationName) in \(\.$mode)",
            ],
            shortTitle: "New Session",
            systemImageName: "plus.message"
        )

        AppShortcut(
            intent: StartOppiSessionIntent(),
            phrases: [
                "Start a session in \(.applicationName)",
                "Open a session in \(.applicationName)",
                "New session in \(.applicationName)",
                "Start a session in \(.applicationName) in \(\.$workspace)",
                "Open a session in \(.applicationName) in \(\.$workspace)",
                "New session in \(.applicationName) in \(\.$workspace)",
            ],
            shortTitle: "Start Session",
            systemImageName: "plus.message"
        )

        AppShortcut(
            intent: AskOppiIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Send to \(.applicationName)",
                "Tell \(.applicationName)",
            ],
            shortTitle: "Ask Pi",
            systemImageName: "paperplane"
        )
    }
}
