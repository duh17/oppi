import Foundation

extension Notification.Name {
    /// Native AVKit fullscreen started from an inline player.
    static let workspaceMediaOverlayDidBegin = Notification.Name(
        "dev.chenda.oppi.workspaceMediaOverlay.didBegin"
    )
    /// Native AVKit fullscreen finished. Cancelled dismissals do not post this.
    static let workspaceMediaOverlayDidEnd = Notification.Name(
        "dev.chenda.oppi.workspaceMediaOverlay.didEnd"
    )
}

enum WorkspaceMediaOverlayDepthEvent: Equatable, Sendable {
    case begin
    case end
}

enum WorkspaceMediaOverlayPost {
    static func begin() {
        NotificationCenter.default.post(name: .workspaceMediaOverlayDidBegin, object: nil)
    }

    static func end() {
        NotificationCenter.default.post(name: .workspaceMediaOverlayDidEnd, object: nil)
    }
}

/// Keeps workspace navigation and the selected server stable while AVKit
/// fullscreen covers the workspace shell. Native fullscreen is a UIKit modal;
/// it must not pop the chat stack or flip compact/split shells. Picture in
/// Picture stays out of this freeze so the person can still navigate.
enum WorkspaceMediaOverlayNavigationPolicy {
    static func overlayDepth(
        after event: WorkspaceMediaOverlayDepthEvent,
        current: Int
    ) -> Int {
        switch event {
        case .begin:
            return current + 1
        case .end:
            return max(0, current - 1)
        }
    }

    static func isOverlayActive(depth: Int) -> Bool {
        depth > 0
    }

    static func effectivePresentation(
        measured: WorkspaceNavigationPresentation,
        overlayActive: Bool,
        frozen: WorkspaceNavigationPresentation
    ) -> WorkspaceNavigationPresentation {
        overlayActive ? frozen : measured
    }

    static func shouldApplyMeasuredPresentation(overlayActive: Bool) -> Bool {
        !overlayActive
    }

    /// Cancelled AVKit dismissals remain fullscreen, so the navigation freeze
    /// must stay in place until a committed dismissal.
    static func shouldEndOverlay(cancelled: Bool) -> Bool {
        !cancelled
    }

    static func shouldRestoreRoute(
        overlayActive: Bool,
        snapshotPathCount: Int,
        currentPathCount: Int
    ) -> Bool {
        overlayActive && currentPathCount < snapshotPathCount
    }

    static func shouldRestoreServer(
        snapshotServerId: String?,
        currentServerId: String?
    ) -> Bool {
        guard let snapshotServerId, !snapshotServerId.isEmpty else { return false }
        return snapshotServerId != currentServerId
    }
}
