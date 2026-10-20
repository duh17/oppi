import UIKit

/// Shows Quick Session over the app root: `AppRootViewController` calls
/// `update()` from its `updateProperties()`, so the reads here (external
/// requests, the launch phase, onboarding, `showQuickSession`) re-run it.
///
/// It presents a request from the Control widget, App Intents, or Shortcuts
/// (`QuickSessionTrigger`) once the shell is up, mounts Quick Session's
/// controller above the root's content while `showQuickSession` is set, and on
/// dismissal saves the draft, opens the session a launch created, and gives
/// VoiceOver focus back to the control that opened it.
@MainActor
final class QuickSessionPresentation {
    private let root: AppRootEnvironment
    /// The controller Quick Session is a child of; its view holds Quick Session's.
    private weak var host: UIViewController?
    /// Last external Quick Session request presented or dropped; each is handled at most once.
    private var handledRequestID = 0
    private var launchAccessibilityElement: AnyObject?
    /// The launch control VoiceOver returns to once Quick Session is gone.
    private var accessibilityElementToRestore: AnyObject?
    private(set) var controller: QuickSessionViewController?

    init(root: AppRootEnvironment, host: UIViewController) {
        self.root = root
        self.host = host
    }

    private var navigation: AppNavigation { root.navigation }

    func update() {
        presentRequestIfPossible(QuickSessionTrigger.shared.presentationRequestID)
        if navigation.showQuickSession {
            mount()
        } else {
            unmount()
        }
    }

    private func presentRequestIfPossible(_ requestID: Int) {
        guard requestID > handledRequestID else { return }
        guard navigation.launchPhase == .ready, !navigation.showOnboarding else { return }
        handledRequestID = requestID
        // A Quick Session the user already opened wins. Drop the request, so a start
        // (possibly a Live Voice call) never opens later on its own.
        guard !navigation.showQuickSession else {
            _ = QuickSessionTrigger.shared.consumePendingStart()
            return
        }
        QuickSessionTrigger.shared.isPresented = true
        navigation.presentQuickSession(
            QuickSessionTrigger.shared.consumePendingStart() ?? QuickSessionStart(),
            from: .intent
        )
    }

    private func mount() {
        guard controller == nil, let host else { return }
        // Before Quick Session takes VoiceOver focus.
        captureLaunchAccessibilityElement()
        let controller = QuickSessionViewController(root: root) { [weak self] in self?.dismiss() }
        self.controller = controller
        host.addChild(controller)
        controller.view.frame = host.view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(controller.view)
        controller.didMove(toParent: host)
    }

    private func unmount() {
        guard let controller else { return }
        self.controller = nil
        controller.tearDown()
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()

        // An embedded overlay has no presentation controller to restore focus.
        // Return VoiceOver to the exact launch button it focused before
        // Quick Session appeared; sending a nil argument would let the system guess.
        // The hop is for order: this runs inside the root's update pass, which
        // un-hides the content from VoiceOver only after this returns.
        if let element = accessibilityElementToRestore {
            accessibilityElementToRestore = nil
            DispatchQueue.main.async {
                UIAccessibility.post(notification: .screenChanged, argument: element)
            }
        }
    }

    private func dismiss() {
        guard navigation.showQuickSession else { return }
        // A launch opens its new chat instead; VoiceOver goes there.
        accessibilityElementToRestore = navigation.pendingQuickSessionNav == nil
            ? launchAccessibilityElement
            : nil
        launchAccessibilityElement = nil
        root.composerDraftStore.saveQuickSessionLifecycleFallback()
        navigation.pendingQuickSessionStart = nil
        navigation.showQuickSession = false
        QuickSessionTrigger.shared.isPresented = false
        Task { @MainActor in
            await completePendingNavigation()
        }
    }

    private func captureLaunchAccessibilityElement() {
        guard let focusedElement = UIAccessibility.focusedElement(using: .notificationVoiceOver),
              let identifiedElement = focusedElement as? UIAccessibilityIdentification,
              let identifier = identifiedElement.accessibilityIdentifier,
              ["workspace.quickSession.start", "agents.detail.launch"].contains(identifier) else {
            launchAccessibilityElement = nil
            return
        }
        launchAccessibilityElement = focusedElement as AnyObject
    }

    private func completePendingNavigation() async {
        guard let pending = navigation.pendingQuickSessionNav else { return }
        let coordinator = root.coordinator

        // A session started in a locked workspace or server opens only after
        // device authentication. On cancel the unsent message waits in that
        // session's composer instead of riding along to the next chat opened.
        let lockTarget = ScopedLockService.shared.sessionTarget(
            serverId: pending.target.serverId,
            sessionId: pending.sessionId,
            workspaceId: pending.target.workspace.id
        )
        guard await ScopedLockService.shared.authorize(lockTarget) else {
            navigation.pendingQuickSessionNav = nil
            if let message = pending.autoSendMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
               !message.isEmpty,
               let key = ComposerDraftKey(
                   serverID: pending.target.serverId,
                   workspaceID: pending.target.workspace.id,
                   sessionID: pending.sessionId
               ) {
                root.composerDraftStore.setDraft(
                    ComposerDraftPayload(text: message, repoPointers: [], attachments: []),
                    for: key
                )
            }
            return
        }

        // Switch server FIRST so coordinator.activeConnection (and all
        // environment-injected stores) reflect the target server by the time
        // ChatViewController renders. Without this, cross-server quick sessions can
        // capture the OLD connection in the chat's session entry.
        guard await coordinator.switchToServerReady(pending.target.serverId) else {
            return
        }
        navigation.pendingQuickSessionNav = nil

        // Keep the existing send path intact. ChatViewController will upload any pending
        // local attachments and dispatch the message through the focused stream.
        navigation.pendingQuickSessionMessage = pending.autoSendMessage
        navigation.pendingQuickSessionAttachments = pending.autoSendAttachments
        navigation.pendingLiveVoiceSessionId = pending.startsLiveVoice ? pending.sessionId : nil

        // Quick Session is just "new session from here". Preserve the current
        // compact stack, or select the session detail column on iPad.
        navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(
                serverId: pending.target.serverId,
                sessionId: pending.sessionId
            ),
            workspace: pending.target
        )
    }
}
