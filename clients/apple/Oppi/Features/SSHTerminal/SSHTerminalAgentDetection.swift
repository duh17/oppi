import Foundation
import Observation

/// Which input the terminal offers. An agent TUI gets Oppi's chat bar (edit,
/// dictate, attach, send as one prompt); a shell gets direct terminal typing.
enum SSHTerminalInputMode: Equatable {
    case chat
    case terminal
}

/// What runs in the foreground of this connection's PTY, read with `ps` over
/// a side exec channel. The PTY's tty is found through the shared per-connection
/// `sshd` process: it is the probe's nearest `sshd` ancestor, and the PTY's
/// shell or command is its only child with a tty.
enum SSHTerminalForeground: Equatable, Sendable {
    case shell
    case agent(String)
    /// A Herdr client: the focused Herdr pane decides.
    case herdr

    /// Process names of coding-agent CLIs. Linux truncates names to 15 bytes.
    static let agentNames: Set<String> = [
        "pi", "claude", "codex", "opencode", "gemini", "amp", "aider", "goose",
        "crush", "droid", "cursor-agent", "qwen", "kimi", "copilot", "kilo", "grok",
    ]

    /// Sent on stdin to `sh -s`, so no shell quoting crosses the login shell.
    /// Prints tty processes (`t`) and the probe's ancestors (`a`), not the
    /// whole process table.
    static let probeScript = """
    ps -U "$(id -u)" -o pid= -o ppid= -o tty= -o stat= -o comm= | awk -v self="$$" '
    { parent[$1] = $2; line[$1] = $0 }
    $3 !~ /^(\\?+|-)$/ { print "t " $0 }
    END { for (pid = self; pid in parent && pid > 1; pid = parent[pid]) print "a " line[pid] }'

    """
    static let probeCommand = "sh -s"

    struct Process: Equatable {
        let pid: Int
        let parent: Int
        let tty: String
        let foreground: Bool
        /// Executable name: no directory and no login-shell dash.
        let name: String
    }

    /// Nil when the output does not identify this connection's PTY.
    init?(probeOutput: String) {
        var ancestors = [Process]()
        var ttyProcesses = [Process]()
        for line in probeOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6, let pid = Int(fields[1]), let parent = Int(fields[2]) else { continue }
            var name = fields[5].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("-") { name.removeFirst() }
            // macOS prints a path (argv[0]); sshd may show a title after a colon.
            name = String(name.split(separator: "/").last ?? "")
            let process = Process(pid: pid, parent: parent, tty: String(fields[3]),
                                  foreground: fields[4].contains("+"), name: name)
            switch fields[0] {
            case "a": ancestors.append(process)
            case "t": ttyProcesses.append(process)
            default: continue
            }
        }
        guard let sshd = ancestors.first(where: { $0.name.hasPrefix("sshd") }),
              let tty = ttyProcesses.first(where: { $0.parent == sshd.pid })?.tty else { return nil }
        let names = ttyProcesses.filter { $0.tty == tty && $0.foreground }.map(\.name)
        if names.contains("herdr") {
            self = .herdr
        } else if let agent = names.first(where: { Self.agentNames.contains($0) }) {
            self = .agent(agent)
        } else {
            self = .shell
        }
    }
}

/// Polls the PTY's foreground process while connected. A failed probe keeps
/// the last answer; a host whose `ps` output cannot be read stays a shell.
@MainActor @Observable
final class SSHTerminalAgentDetector {
    private(set) var foreground: SSHTerminalForeground?

    func run(on channel: SSHTerminalChannel) async {
        foreground = nil
        let script = Data(SSHTerminalForeground.probeScript.utf8)
        while !Task.isCancelled, channel.connected {
            if let result = try? await channel.run(SSHTerminalForeground.probeCommand, input: script),
               result.exitStatus == 0 {
                foreground = SSHTerminalForeground(probeOutput: String(decoding: result.output, as: UTF8.self)) ?? .shell
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Chat for an agent, or for a Herdr client whose focused pane runs one.
    /// Nil until the first probe answers.
    func mode(herdr: HerdrSnapshot?) -> SSHTerminalInputMode? { Self.mode(for: foreground, herdr: herdr) }

    static func mode(for foreground: SSHTerminalForeground?, herdr: HerdrSnapshot?) -> SSHTerminalInputMode? {
        switch foreground {
        case nil: nil
        case .shell: .terminal
        case .agent: .chat
        case .herdr: herdr?.focusedAgent == nil ? .terminal : .chat
        }
    }
}
