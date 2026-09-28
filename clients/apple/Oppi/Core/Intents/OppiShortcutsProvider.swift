import AppIntents

/// Registers Oppi's App Shortcuts with the system.
///
/// These appear automatically in:
/// - Spotlight search (type "Start session in Oppi")
/// - Siri ("Hey Siri, start a session in Oppi")
/// - Shortcuts app (as pre-configured actions)
struct OppiShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
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
