import UIKit

// What the chat answers to the keyboard commands (`KeyboardCommand`). Each
// runs the owner its control runs: the bar's `runTopBarAction`, the composer's
// Stop (`stopTurn`) and focus request, the panel's close.

extension ChatViewController {
    /// Stop is offered whenever a turn runs and no stop is under way. That is
    /// deliberately broader than the composer's Stop button, which becomes
    /// Ignore while an Ask card is up: a keyboard has no second button, and
    /// stopping the turn behind an Ask is still what Cmd-. means.
    var canStopTurn: Bool {
        sessionManager.isBusy && !isStopping
    }

    /// The composer is hidden for a stopped session, which offers Resume instead.
    var canFocusComposer: Bool { !isStopped }

    /// A panel shows beside the chat (a compact width presents it as a
    /// sheet, which closes as any sheet does).
    var hasOpenSidePanel: Bool { activeSidePanel != nil }

    func closeSidePanel() {
        showSidePanel(nil)
    }

    func canRunTopBarAction(_ action: ChatTopBarAction) -> Bool {
        barItems.isAvailable(action)
    }

    /// Whether the panel `action` opens is open now.
    func isPaneOpen(_ action: ChatTopBarAction) -> Bool {
        switch action {
        case .files: model.isFilePanelVisible
        case .git: model.showGit
        case .outline: model.showOutline
        case .context: model.showContextInspector
        case .terminal: false
        }
    }
}
