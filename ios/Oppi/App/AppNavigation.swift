import SwiftUI

/// Navigation state for the app.
@MainActor @Observable
final class AppNavigation {
    var selectedTab: AppTab = .workspaces
    var showOnboarding: Bool = true
    var showWhatsNew: Bool = false

    /// Set after a fresh pairing when the server had no workspaces.
    /// WorkspaceHomeView consumes this to auto-present workspace creation.
    var shouldGuideWorkspaceCreation: Bool = false

    /// When set, the Quick Session sheet is presented over the current view.
    var showQuickSession: Bool = false

    /// Set by QuickSessionSheet after session creation. ContentView observes
    /// this and presents a full-screen ChatView for the new session.
    var pendingChatSessionId: String?

    /// Programmatic navigation path for the workspace tab.
    /// Set externally (e.g. by QuickSessionSheet) to deep-link to a session.
    var workspacePath = NavigationPath()

    /// Message to auto-send when a quick session's ChatView opens.
    /// Consumed once by ChatView, then cleared.
    var pendingQuickSessionMessage: String?

    /// Images to attach when auto-sending the quick session message.
    var pendingQuickSessionImages: [PendingImage]?

    /// Draft text pre-filled by π actions from outside a chat session (e.g. file browser).
    /// Consumed once by QuickSessionSheet, then cleared.
    var pendingQuickSessionDraft: String?

    /// Pending navigation from QuickSessionSheet.
    /// Set before sheet dismiss; consumed in onDismiss to do the two-step nav push.
    var pendingQuickSessionNav: QuickSessionNav?
}

/// Navigation payload for quick session deep-link.
struct QuickSessionNav {
    let target: WorkspaceNavTarget
    let sessionId: String
}

enum AppTab: Hashable {
    case workspaces
    case settings
}
