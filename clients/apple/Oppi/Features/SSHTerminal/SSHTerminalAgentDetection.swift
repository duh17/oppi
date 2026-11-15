import Foundation
import GhosttyVt

/// Names the coding agent the host declares through the program's own OSC 7501
/// report, so the key strips offer that agent's bindings. Oppi never inspects
/// the host's process table to guess, and a report never changes where typing
/// goes. Herdr passes no pane's report through, so a Herdr
/// client keeps the shell's keys.
enum SSHTerminalAgentDetection {
    /// OSC 7501 `app` ids of coding agents. An id also matches by its first
    /// `-`/`_`/`.` segment, so `claude-code` reads as `claude`.
    static let agentApps = Set(agents.map(\.id))

    /// The agents in the order a picker lists them, with the names people
    /// call them by.
    static let agents: [(id: String, title: String)] = [
        ("pi", "pi"), ("claude", "Claude Code"), ("codex", "Codex"), ("opencode", "OpenCode"),
        ("gemini", "Gemini CLI"), ("amp", "Amp"), ("aider", "Aider"), ("goose", "Goose"),
        ("crush", "Crush"), ("droid", "Droid"), ("cursor-agent", "Cursor Agent"), ("qwen", "Qwen Code"),
        ("kimi", "Kimi"), ("copilot", "Copilot CLI"), ("kilo", "Kilo"), ("grok", "Grok"),
    ]

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

/// What a key the person placed on the bar reads as while a coding agent is
/// in front: the chat composer's Send for plain Return, and its Stop for the
/// key the agent's keymap binds to interrupt, while the agent works. Only the
/// look changes; the key sends the same bytes.
enum SSHTerminalAgentKeyRole: Equatable, Sendable {
    case send
    case stop
}

/// The agent state the bar's keys follow: whether the OSC 7501 root names a
/// coding agent (`SSHTerminalAgentDetection.agentApp`), whether it reports
/// `working`, and the agent's interrupt binding
/// (`SSHTerminalKeymap.interrupt(for:userFile:)`). Nothing here names an agent.
struct SSHTerminalAgentKeys: Equatable {
    /// No agent in front: every key draws as itself.
    static let none = Self(isAgent: false, working: false, interrupt: [])

    let isAgent: Bool
    let working: Bool
    let interrupt: [SSHTerminalKeyStroke]

    init(isAgent: Bool, working: Bool, interrupt: [SSHTerminalKeyStroke]) {
        self.isAgent = isAgent
        self.working = isAgent && working
        self.interrupt = interrupt
    }

    init(root: SSHTerminalProgramStatusStore.Record?, app: String, interrupt: [SSHTerminalKeyStroke]) {
        self.init(
            isAgent: SSHTerminalAgentDetection.agentApp(root: root, app: app) != nil,
            working: root?.state == GHOSTTY_PROGRAM_STATUS_STATE_WORKING,
            interrupt: interrupt
        )
    }

    /// The role of a key that sends `strokes`. Stop wins over Send for an
    /// agent that interrupts on Return.
    func role(for strokes: [SSHTerminalKeyStroke]) -> SSHTerminalAgentKeyRole? {
        guard isAgent, !strokes.isEmpty else { return nil }
        if working, Self.sameKeys(strokes, interrupt) { return .stop }
        if strokes.count == 1, strokes[0].key == GHOSTTY_KEY_ENTER, strokes[0].modifiers == 0 { return .send }
        return nil
    }

    /// The same keys pressed, whatever each side calls them.
    private static func sameKeys(_ one: [SSHTerminalKeyStroke], _ two: [SSHTerminalKeyStroke]) -> Bool {
        one.count == two.count && zip(one, two).allSatisfy { $0.key == $1.key && $0.modifiers == $1.modifiers }
    }
}
