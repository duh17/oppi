import Foundation
import Observation

/// Pane-owned composer draft, attachments, and dictation. Retiling must not
/// move this state onto a different pane identity.
@MainActor
@Observable
final class MacSessionComposerState {
    var draft: String
    var pendingAttachments: [MacPendingAttachment] {
        didSet {
            MacPastedAttachmentFileStore.removeOwned(in: oldValue, notIn: pendingAttachments)
            pastedFileLifetime.replace(with: pendingAttachments)
        }
    }
    private(set) var extensionSessionId: String?

    func bindExtensionSession(_ sessionId: String) {
        extensionSessionId = sessionId
    }

    private(set) var composerActionGeneration: UInt = 0

    func beginComposerAction() -> UInt {
        composerActionGeneration
    }

    func invalidateComposerActions() {
        composerActionGeneration &+= 1
    }

    func isCurrentComposerAction(_ generation: UInt) -> Bool {
        composerActionGeneration == generation
    }

    func applyExtensionText(_ text: String, sessionId: String) {
        guard extensionSessionId == sessionId, !text.isEmpty else { return }
        // Handoff is not submission, and must not overwrite work typed locally.
        // Cancel live dictation before changing its base to prevent a late ASR
        // update from replacing the handed-off text. Also revoke outer Stop/
        // Send/Cancel completions that are already awaiting final text.
        invalidateComposerActions()
        dictation.resetForSessionChange()
        draft = draft.isEmpty ? text : draft + "\n\n" + text
    }

    func applyStoppedDictationDraftIfCurrent(
        generation: UInt,
        originatingSessionID: String?,
        currentSessionID: String?
    ) -> Bool {
        guard isCurrentComposerAction(generation),
              let originatingSessionID,
              originatingSessionID == currentSessionID else {
            return false
        }
        draft = dictation.composedDraft
        return true
    }

    var localError: String?
    var submissionGate = MacComposerSubmissionGate()
    let dictation: MacComposerDictationController
    /// First-responder state of the composer text view, not `KeybindingFocus`.
    /// The store defaults focus to `.composer` even when nothing is typing.
    var isComposerFirstResponder = false
    /// AppKit keyboard transfer for pane shortcuts. Each pane has private
    /// `FocusState`, so deck outline can move without resigning the old text view.
    private(set) var keyboardOwnershipGeneration: UInt = 0
    private(set) var wantsKeyboardOwnership = false

    @ObservationIgnored
    private let pastedFileLifetime = MacPastedAttachmentLifetime()

    init(
        initialDraft: String = "",
        initialAttachments: [MacPendingAttachment] = [],
        dictation: MacComposerDictationController = MacComposerDictationController()
    ) {
        draft = initialDraft
        pendingAttachments = initialAttachments
        localError = nil
        self.dictation = dictation
        pastedFileLifetime.replace(with: initialAttachments)
    }

    func resetForSessionChange() {
        invalidateComposerActions()
        extensionSessionId = nil
        localError = nil
        draft = ""
        pendingAttachments = []
        submissionGate.reset()
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

    deinit {
        Task { @MainActor [dictation] in
            dictation.resetForSessionChange()
        }
    }
}

enum MacComposerActionLayout: Equatable {
    case wide
    case compact
    case minimum

    static let minimumPaneWidth: CGFloat = 320
    static let compactPaneWidth: CGFloat = 360
    static let widePaneWidth: CGFloat = 520
    static let horizontalContentInset: CGFloat = 24

    static func resolve(paneWidth: CGFloat) -> Self {
        if paneWidth >= widePaneWidth { return .wide }
        if paneWidth >= compactPaneWidth { return .compact }
        return .minimum
    }

    var minimumContentWidth: CGFloat {
        switch self {
        case .wide:
            Self.widePaneWidth - Self.horizontalContentInset
        case .compact:
            Self.compactPaneWidth - Self.horizontalContentInset
        case .minimum:
            Self.minimumPaneWidth - Self.horizontalContentInset
        }
    }
}

enum MacComposerPaneKeyboardRouting {
    static func installsCommandReturn(isActivePane: Bool) -> Bool {
        isActivePane
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
    var workspaceId: String? {
        didSet {
            guard oldValue != workspaceId else { return }
            worktreeId = nil
            _ = worktreeListing.beginLoad(workspaceId: workspaceId)
        }
    }
    var worktreeId: String?
    var agentId: String?
    var errorMessage: String?
    private(set) var pendingLaunchAttempt: MacQuickSessionLaunchAttempt?
    let worktreeListing = MacQuickSessionWorktreeListing()

    func reset() {
        workspaceId = nil
        worktreeId = nil
        agentId = nil
        errorMessage = nil
        pendingLaunchAttempt = nil
        _ = worktreeListing.beginLoad(workspaceId: nil)
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

/// Workspace-scoped worktree list for an empty Quick Session pane.
/// A late list from workspace A must not paint or resolve workspace B.
@MainActor
@Observable
final class MacQuickSessionWorktreeListing {
    private(set) var workspaceId: String?
    private(set) var worktrees: [WorkspaceWorktree] = []
    private(set) var isLoading = false
    private var generation: UInt = 0

    @discardableResult
    func beginLoad(workspaceId: String?) -> UInt {
        generation &+= 1
        self.workspaceId = workspaceId
        worktrees = []
        isLoading = workspaceId != nil
        return generation
    }

    func applySuccess(
        workspaceId: String,
        generation: UInt,
        worktrees: [WorkspaceWorktree]
    ) {
        guard isCurrent(workspaceId: workspaceId, generation: generation) else { return }
        self.worktrees = worktrees
        isLoading = false
    }

    /// Explicit checkout wins over an empty, failed, or foreign list.
    func launchWorktreeId(selectedId: String?) -> String {
        if let selectedId {
            let trimmed = selectedId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return QuickSessionWorktreePickerPolicy.resolvedWorktreeId(
            selectedId: selectedId,
            worktrees: worktrees
        )
    }

    private func isCurrent(workspaceId: String, generation: UInt) -> Bool {
        !Task.isCancelled
            && self.generation == generation
            && self.workspaceId == workspaceId
    }
}
