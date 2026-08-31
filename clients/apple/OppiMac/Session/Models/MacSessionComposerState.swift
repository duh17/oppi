import Foundation
import Observation

/// Pane-owned composer draft, attachments, and dictation. Retiling must not
/// move this state onto a different pane identity.
@MainActor
@Observable
final class MacSessionComposerState {
    var draft: String
    var pendingAttachments: [MacPendingAttachment]
    let dictation: MacComposerDictationController
    /// First-responder state of the composer text view, not `KeybindingFocus`.
    /// The store defaults focus to `.composer` even when nothing is typing.
    var isComposerFirstResponder = false
    /// AppKit keyboard transfer for pane shortcuts. Each pane has private
    /// `FocusState`, so deck outline can move without resigning the old text view.
    private(set) var keyboardOwnershipGeneration: UInt = 0
    private(set) var wantsKeyboardOwnership = false

    init(
        draft: String = "",
        pendingAttachments: [MacPendingAttachment] = [],
        dictation: MacComposerDictationController = MacComposerDictationController()
    ) {
        self.draft = draft
        self.pendingAttachments = pendingAttachments
        self.dictation = dictation
    }

    func resetForSessionChange() {
        draft = ""
        pendingAttachments = []
        isComposerFirstResponder = false
        wantsKeyboardOwnership = false
        dictation.resetForSessionChange()
    }

    func resignKeyboardOwnership() {
        wantsKeyboardOwnership = false
        isComposerFirstResponder = false
        keyboardOwnershipGeneration &+= 1
    }

    func claimKeyboardOwnership() {
        wantsKeyboardOwnership = true
        keyboardOwnershipGeneration &+= 1
    }
}

/// Frozen server request fields and key for one logical Quick Session launch.
/// Both plain Pi and saved-Agent retries must replay this exact value.
struct MacQuickSessionLaunchAttempt: Equatable, Sendable {
    let request: QuickSessionLaunchRequest
    let plan: QuickSessionLaunchPlan
    let idempotencyKey: String
}

/// Workspace / worktree / Agent pickers for an empty Quick Session pane.
@MainActor
@Observable
final class MacQuickSessionPaneState {
    var workspaceId: String?
    var worktreeId: String?
    var agentId: String?
    var errorMessage: String?
    private(set) var pendingLaunchAttempt: MacQuickSessionLaunchAttempt?

    func reset() {
        workspaceId = nil
        worktreeId = nil
        agentId = nil
        errorMessage = nil
        pendingLaunchAttempt = nil
    }

    /// Reuses one frozen launch while the visible request is unchanged. Editing
    /// any request field explicitly starts a new logical launch with a new key.
    func launchAttempt(
        for request: QuickSessionLaunchRequest
    ) -> Result<MacQuickSessionLaunchAttempt, QuickSessionLaunchValidationError> {
        if let pendingLaunchAttempt, pendingLaunchAttempt.request == request {
            return .success(pendingLaunchAttempt)
        }
        return QuickSessionLaunchRouting.plan(for: request).map { plan in
            let attempt = MacQuickSessionLaunchAttempt(
                request: request,
                plan: plan,
                idempotencyKey: "mac-quick-session-\(UUID().uuidString)"
            )
            pendingLaunchAttempt = attempt
            return attempt
        }
    }

    func markLaunchSucceeded(idempotencyKey: String) {
        guard pendingLaunchAttempt?.idempotencyKey == idempotencyKey else { return }
        pendingLaunchAttempt = nil
    }
}
