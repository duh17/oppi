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

enum WorkspaceNavigationPresentation: Sendable, Equatable {
    case stack
    case split
}

/// Detail-column target for the regular-width workspace split shell.
///
/// The sidebar alternates between the workspace list and the selected
/// workspace's session list. The wide detail pane hosts chat, files, or utility
/// views. Compact width keeps using `workspacePath` pushes.
enum WorkspaceSplitDetailTarget: Hashable {
    case session(WorkspaceSessionNavTarget)
    case fileBrowser(FileBrowserNavTarget)
    case linkedFile(WorkspaceLinkedFileNavTarget)
    case workspaceConfiguration(WorkspaceNavTarget)
    case utility(WorkspaceUtilityNavTarget)
}

/// Navigation state for the app.
@MainActor @Observable
final class AppNavigation {
    var selectedTab: AppTab = .workspaces
    var showOnboarding: Bool = true
    var showWhatsNew: Bool = false

    /// Current workspace navigation shell. Compact width keeps the existing
    /// push stack; regular width selects workspace/session columns directly.
    var workspaceNavigationPresentation: WorkspaceNavigationPresentation = .stack

    /// Selection backing the regular-width split shell.
    var splitSelectedWorkspace: WorkspaceNavTarget?
    var splitDetailTarget: WorkspaceSplitDetailTarget?

    /// Navigation path owned by the regular-width detail column.
    ///
    /// Keeps detail-only pushes, such as file browser directory drilling, out of
    /// the workspace sidebar/content stack.
    var splitDetailPath = NavigationPath()

    /// Backward-compatible session selection facade for existing tests and call sites.
    var splitSelectedSession: WorkspaceSessionNavTarget? {
        get {
            guard case .session(let target) = splitDetailTarget else { return nil }
            return target
        }
        set {
            if let newValue {
                splitDetailTarget = .session(newValue)
                splitDetailPath = NavigationPath()
            } else if case .session = splitDetailTarget {
                splitDetailTarget = nil
                splitDetailPath = NavigationPath()
            }
        }
    }

    /// Column visibility backing the regular-width split shell. The system
    /// sidebar affordance and edge gestures update this binding, so iPad users
    /// can reveal or hide workspace/session columns without custom chrome.
    var splitColumnVisibility: NavigationSplitViewVisibility = .automatic

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

    func setWorkspaceNavigationPresentation(_ presentation: WorkspaceNavigationPresentation) {
        guard workspaceNavigationPresentation != presentation else { return }
        let preservedStackPath = presentation == .stack ? stackPathForCurrentSplitSelection() : nil
        workspaceNavigationPresentation = presentation
        switch presentation {
        case .stack:
            if let preservedStackPath {
                workspacePath = preservedStackPath
            }
            splitSelectedWorkspace = nil
            splitDetailTarget = nil
            splitDetailPath = NavigationPath()
            splitColumnVisibility = .automatic
        case .split:
            workspacePath = NavigationPath()
            splitDetailPath = NavigationPath()
            splitColumnVisibility = .all
        }
    }

    func openWorkspace(_ target: WorkspaceNavTarget) {
        selectedTab = .workspaces
        switch workspaceNavigationPresentation {
        case .stack:
            workspacePath.append(target)
        case .split:
            splitSelectedWorkspace = target
            splitDetailTarget = nil
            splitDetailPath = NavigationPath()
            splitColumnVisibility = .all
        }
    }

    func openWorkspaceSession(_ target: WorkspaceSessionNavTarget, workspace: WorkspaceNavTarget? = nil) {
        selectedTab = .workspaces
        switch workspaceNavigationPresentation {
        case .stack:
            workspacePath.append(target)
        case .split:
            if let workspace {
                splitSelectedWorkspace = workspace
            }
            splitDetailTarget = .session(target)
            splitDetailPath = NavigationPath()
            splitColumnVisibility = .detailOnly
        }
    }

    func openWorkspaceFileBrowser(_ target: FileBrowserNavTarget, workspace: WorkspaceNavTarget? = nil) {
        selectedTab = .workspaces
        switch workspaceNavigationPresentation {
        case .stack:
            workspacePath.append(target)
        case .split:
            if let workspace {
                splitSelectedWorkspace = workspace
            }
            splitDetailTarget = .fileBrowser(target)
            splitDetailPath = NavigationPath()
            splitColumnVisibility = .detailOnly
        }
    }

    func openWorkspaceLinkedFile(_ target: WorkspaceLinkedFileNavTarget, workspace: WorkspaceNavTarget? = nil) {
        selectedTab = .workspaces
        switch workspaceNavigationPresentation {
        case .stack:
            workspacePath.append(target)
        case .split:
            if let workspace {
                splitSelectedWorkspace = workspace
            }
            if splitDetailTarget == nil {
                splitDetailTarget = .linkedFile(target)
                splitDetailPath = NavigationPath()
            } else {
                splitDetailPath.append(target)
            }
            splitColumnVisibility = .detailOnly
        }
    }

    func openWorkspaceUtility(_ target: WorkspaceUtilityNavTarget) {
        selectedTab = .workspaces
        switch workspaceNavigationPresentation {
        case .stack:
            workspacePath.append(target)
        case .split:
            splitDetailTarget = .utility(target)
            splitDetailPath = NavigationPath()
            splitColumnVisibility = .all
        }
    }

    func openWorkspaceConfiguration(_ target: WorkspaceNavTarget) {
        selectedTab = .workspaces
        switch workspaceNavigationPresentation {
        case .stack:
            workspacePath.append(target)
        case .split:
            splitSelectedWorkspace = target
            splitDetailTarget = .workspaceConfiguration(target)
            splitDetailPath = NavigationPath()
            splitColumnVisibility = .all
        }
    }

    func showWorkspaceListInSplitSidebar() {
        guard workspaceNavigationPresentation == .split else { return }
        selectedTab = .workspaces
        splitSelectedWorkspace = nil
        workspacePath = NavigationPath()
        splitColumnVisibility = .all
    }

    func completeWorkspaceConfiguration(_ target: WorkspaceNavTarget) {
        guard workspaceNavigationPresentation == .split else { return }
        guard splitDetailTarget == .workspaceConfiguration(target) else { return }
        splitDetailTarget = nil
        splitDetailPath = NavigationPath()
    }

    func clearWorkspaceSelections() {
        workspacePath = NavigationPath()
        splitSelectedWorkspace = nil
        splitDetailTarget = nil
        splitDetailPath = NavigationPath()
        splitColumnVisibility = workspaceNavigationPresentation == .split ? .all : .automatic
    }

    /// Replace the workspace stack with a session destination in one state write.
    ///
    /// Avoid clearing the path and appending in separate writes: SwiftUI may
    /// briefly re-appear the previous chat view during the intermediate empty
    /// stack, and that old view can steal the focused session stream back.
    func setWorkspaceSessionPath(serverId: String, sessionId: String) {
        let target = WorkspaceSessionNavTarget(serverId: serverId, sessionId: sessionId)
        switch workspaceNavigationPresentation {
        case .stack:
            workspacePath = Self.workspaceSessionPath(serverId: serverId, sessionId: sessionId)
        case .split:
            splitDetailTarget = .session(target)
            splitDetailPath = NavigationPath()
            splitColumnVisibility = .detailOnly
        }
    }

    static func workspaceSessionPath(serverId: String, sessionId: String) -> NavigationPath {
        var path = NavigationPath()
        path.append(WorkspaceSessionNavTarget(serverId: serverId, sessionId: sessionId))
        return path
    }

    /// Pending workspace creation deep-link payload.
    /// Consumed once by WorkspaceHomeView, then cleared.
    var pendingWorkspaceDeepLink: WorkspaceDeepLink.Payload?

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

    // MARK: - Legacy Shell Routing

    /// Routes legacy tab selections into the Workspaces-primary navigation stack.
    ///
    /// Older persisted state and a few compatibility call sites can still set
    /// `.server` or `.settings`. Those are no longer primary app roots; they
    /// become utility destinations under `WorkspaceHomeView` and the selected
    /// tab resets to `.workspaces`.
    @discardableResult
    func routeLegacySelectedTabIfNeeded() -> WorkspaceUtilityNavTarget? {
        guard !showOnboarding else { return nil }
        guard case .ready = launchPhase else { return nil }

        let target: WorkspaceUtilityNavTarget
        switch selectedTab {
        case .workspaces:
            return nil
        case .server:
            target = .manageServers
        case .settings:
            target = .appSettings
        }

        switch workspaceNavigationPresentation {
        case .stack:
            workspacePath = NavigationPath()
            workspacePath.append(target)
        case .split:
            splitDetailTarget = .utility(target)
            splitDetailPath = NavigationPath()
        }
        selectedTab = .workspaces
        return target
    }

    private func stackPathForCurrentSplitSelection() -> NavigationPath? {
        var path = NavigationPath()

        switch splitDetailTarget {
        case .session(let target):
            path.append(target)
        case .fileBrowser(let target):
            if let workspace = splitSelectedWorkspace {
                path.append(workspace)
                path.append(target)
            }
        case .linkedFile(let target):
            path.append(target)
        case .workspaceConfiguration(let target):
            path.append(target)
        case .utility(let target):
            path.append(target)
        case nil:
            if let workspace = splitSelectedWorkspace {
                path.append(workspace)
            }
        }

        return path.count > 0 ? path : nil
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
