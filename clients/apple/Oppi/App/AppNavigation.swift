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

    /// Programmatic navigation path for the workspace tab.
    /// Set externally (e.g. by QuickSessionSheet) to deep-link to a session.
    var workspacePath = NavigationPath()

    /// Draft text pre-filled by π actions from outside a chat session (e.g. file browser).
    /// Consumed once by QuickSessionSheet, then cleared.
    var pendingQuickSessionDraft: String?

    // MARK: - Quick Session Handoff
    //
    // These properties form a produce-once / consume-once handoff between
    // QuickSessionSheet (producer) and ContentView + ChatView (consumers).
    //
    // Flow:
    // 1. QuickSessionSheet sets `pendingQuickSessionNav` (atomic intent)
    // 2. QuickSessionSheet calls dismiss()
    // 3. ContentView.onDismiss reads nav, extracts message/images, builds path
    // 4. ChatView.task(id: sessionId) reads message/images, auto-sends

    /// Atomic navigation intent from QuickSessionSheet.
    /// Bundles target workspace, session ID, and optional auto-send data.
    /// Set before dismiss; consumed in ContentView.onDismiss.
    var pendingQuickSessionNav: QuickSessionNav?

    /// Message to auto-send when the quick session's ChatView opens.
    /// Extracted from `pendingQuickSessionNav` by ContentView.onDismiss.
    /// Consumed once by ChatView, then cleared.
    var pendingQuickSessionMessage: String?

    /// Attachments to auto-send when the quick session message opens.
    /// Extracted from `pendingQuickSessionNav` by ContentView.onDismiss.
    var pendingQuickSessionAttachments: [PendingAttachment]?

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
            guard let self,
                  case .quickSessionDraft(let draft) = SelectedTextPiRouterPolicy.route(
                    request: request,
                    context: .nonChat
                  ) else { return }
            self.pendingQuickSessionDraft = draft
            self.showQuickSession = true
        }
    }
}

/// Atomic navigation intent for quick session deep-link.
///
/// Bundles everything needed to navigate to a session and optionally
/// auto-send a message. Set as a single write by QuickSessionSheet,
/// consumed as a single read by ContentView.onDismiss.
struct QuickSessionNav {
    let target: WorkspaceNavTarget
    let sessionId: String
    let autoSendMessage: String?
    let autoSendAttachments: [PendingAttachment]?

    init(target: WorkspaceNavTarget, sessionId: String, autoSendMessage: String? = nil, autoSendAttachments: [PendingAttachment]? = nil) {
        self.target = target
        self.sessionId = sessionId
        self.autoSendMessage = autoSendMessage
        self.autoSendAttachments = autoSendAttachments
    }

    var autoSendImages: [PendingImage]? {
        autoSendAttachments?.compactMap { attachment in
            guard attachment.source == .image,
                  let thumbnail = attachment.thumbnail,
                  let imageAttachment = attachment.imageAttachment else { return nil }
            return PendingImage(id: attachment.id, thumbnail: thumbnail, attachment: imageAttachment)
        }
    }
}

enum AppTab: Hashable {
    case workspaces
    case server
    case settings
}
