import AppIntents

/// Registers Oppi's App Shortcuts with the system.
///
/// These appear automatically in:
/// - Spotlight search (type "New Oppi Session")
/// - Siri ("Hey Siri, new Oppi session")
/// - Shortcuts app (as pre-configured actions)
/// - Action Button settings (under the app's shortcuts)
struct OppiShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartQuickSessionIntent(),
            phrases: [
                "New session in \(.applicationName)",
                "Start a session in \(.applicationName)",
                "New \(.applicationName) session",
            ],
            shortTitle: "New Session",
            systemImageName: "plus.message"
        )

        AppShortcut(
            intent: AskOppiIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Send to \(.applicationName)",
                "Tell \(.applicationName)",
            ],
            shortTitle: "Ask Oppi",
            systemImageName: "paperplane"
        )
    }
}
