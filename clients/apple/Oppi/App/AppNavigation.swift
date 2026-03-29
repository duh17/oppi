import SwiftUI

/// Launch resolution phase — gates UI until credentials + cache are checked.
///
/// Prevents the flash of wrong content on cold launch (onboarding screen
/// briefly visible for paired users, empty workspace list before cache loads).
enum AppLaunchPhase: Sendable {
    /// Credential check + cache load in progress. UI shows blank canvas.
    case resolving
    /// Launch resolved. `showOnboarding` is authoritative.
    case ready
}

/// Navigation state for the app.
@MainActor @Observable
final class AppNavigation {
    var selectedTab: AppTab = .workspaces
    var showOnboarding: Bool = true
    var showWhatsNew: Bool = false

    /// Launch phase gate. While `.resolving`, ContentView shows a blank
    /// canvas instead of onboarding or the workspace list.
    var launchPhase: AppLaunchPhase = .resolving

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
    /// Set before sheet dismiss; consumed in onDismiss to push the workspace target.
    var pendingQuickSessionNav: QuickSessionNav?

    /// Session ID to navigate to after a quick session workspace push.
    /// Set in onDismiss alongside the workspace path push. Consumed by
    /// WorkspaceDetailView once it appears, avoiding the fragile two-step
    /// path push that races with navigationDestination registration.
    var quickSessionPendingSessionId: String?

    // MARK: - Pi Quick Actions

    /// Creates a pi quick-action router that routes to the quick session sheet.
    ///
    /// This is the canonical router for all non-chat surfaces (file browser,
    /// review diffs, skill files, commit diffs, etc.). Chat views create their
    /// own router that sends to the active session's composer instead.
    ///
    /// Injected at the `ContentView` root via `.environment()` so most views
    /// pick it up automatically. Views that present sheets may need to
    /// re-inject it since SwiftUI environment doesn't always propagate
    /// through nested sheet boundaries.
    func makeQuickSessionPiRouter() -> SelectedTextPiActionRouter {
        SelectedTextPiActionRouter { [weak self] request in
            guard let self else { return }
            self.pendingQuickSessionDraft = SelectedTextPiPromptFormatter.composeDraftAddition(for: request)
            self.showQuickSession = true
        }
    }
}

/// Navigation payload for quick session deep-link.
struct QuickSessionNav {
    let target: WorkspaceNavTarget
    let sessionId: String
}

enum AppTab: Hashable {
    case workspaces
    case server
    case settings
}
