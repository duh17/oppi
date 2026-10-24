import Foundation
import GhosttyVt

/// Which input the terminal offers. An agent TUI gets Oppi's chat bar (edit,
/// dictate, attach, send as one prompt); a shell gets direct terminal typing.
enum SSHTerminalInputMode: Equatable {
    case chat
    case terminal
}

/// Picks the input mode and key strip from what the host declares: the
/// program's own OSC 7501 report. Oppi never inspects the host's process table
/// to guess, and a Herdr client gets direct typing whatever its panes run;
/// the chat bar is one tap away on the terminal keyboard's bar.
enum SSHTerminalAgentDetection {
    /// OSC 7501 `app` ids of coding agents. An id also matches by its first
    /// `-`/`_`/`.` segment, so `claude-code` reads as `claude`.
    static let agentApps: Set<String> = [
        "pi", "claude", "codex", "opencode", "gemini", "amp", "aider", "goose",
        "crush", "droid", "cursor-agent", "qwen", "kimi", "copilot", "kilo", "grok",
    ]

    /// The OSC 7501 root. Nil means nothing has decided; the terminal view
    /// treats that as direct typing. The view controller's `inputMode` owns the
    /// manual override.
    static func mode(root: SSHTerminalProgramStatusStore.Record?, app: String) -> SSHTerminalInputMode? {
        agentApp(root: root, app: app) != nil ? .chat : nil
    }

    /// Whose key bindings the strips offer: the reporting agent, or the shell.
    static func keymapProgram(root: SSHTerminalProgramStatusStore.Record?, app: String) -> String {
        agentApp(root: root, app: app) ?? "shell"
    }

    /// The agent named by the root record when its app is a coding agent and
    /// its state is a real program state. A shell app, a cleared root, or any
    /// other app (terraform, brew) gives nil: a permission prompt there is
    /// answered in the terminal.
    static func agentApp(root: SSHTerminalProgramStatusStore.Record?, app: String) -> String? {
        guard let root else { return nil }
        switch root.state {
        case GHOSTTY_PROGRAM_STATUS_STATE_IDLE, GHOSTTY_PROGRAM_STATUS_STATE_WORKING,
             GHOSTTY_PROGRAM_STATUS_STATE_DONE, GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED,
             GHOSTTY_PROGRAM_STATUS_STATE_ERROR:
            break
        default:
            return nil
        }
        let names = [app, root.app].map(normalizedApp).filter { !$0.isEmpty }
        guard !names.contains(where: isShellApp) else { return nil }
        return names.lazy.compactMap(agentName).first
    }

    static func normalizedApp(_ app: String) -> String {
        var name = app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasPrefix("-") { name.removeFirst() }
        return name
    }

    /// The `agentApps` entry an app id names, whole or by its first segment.
    static func agentName(_ app: String) -> String? {
        let name = normalizedApp(app)
        guard !name.isEmpty else { return nil }
        if agentApps.contains(name) { return name }
        let head = name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." }).first.map(String.init) ?? name
        return head != name && agentApps.contains(head) ? head : nil
    }

    static func isShellApp(_ app: String) -> Bool {
        let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh", "shell", "tmux", "screen"]
        return shells.contains(normalizedApp(app))
    }
}
