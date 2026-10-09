#if DEBUG
import SwiftUI

/// Which OSC 7501 reports this preview feeds through the real terminal engine.
enum SSHTerminalScreenshotStatus: String {
    case none, working, blocked, done, error, idle, tree, sequence, detail
}

/// The real terminal surface over an in-memory connection: a Herdr-like
/// screen in the grid, and `herdr api snapshot` answered with one blocked agent
/// so the toolbar overview and its badge render. Status variants also feed
/// real OSC 7501 bytes through libghostty.
struct SSHTerminalScreenshotPreview: View {
    var status: SSHTerminalScreenshotStatus = .none
    var hostLabel: String = "chen@mac-studio"
    @Environment(\.themeID) private var themeID
    @State private var channel = try? SSHTerminalChannel()
    /// A server-scoped connection, as the app root injects, so the input bar
    /// claims the shared dictation manager and shows its mic.
    @State private var connection: ServerConnection = {
        let connection = ServerConnection()
        connection.setPreviewServerId("preview-server")
        return connection
    }()

    var body: some View {
        NavigationStack {
            if let channel {
                SSHTerminalView(channel: channel, reconnect: {}, editHost: {}, hostLabel: hostLabel)
                    .environment(\.presentProgramStatusDetail, status == .detail)
                    .task { await play(on: channel) }
            }
        }
        .environment(connection)
        // As the app root does: materials and popovers follow the theme, not
        // whatever appearance the simulator was left in.
        .preferredColorScheme(themeID.preferredColorScheme)
        .accessibilityIdentifier("screenshot.ready")
    }

    private func play(on channel: SSHTerminalChannel) async {
        if status == .sequence {
            await playSequence(on: channel)
            return
        }
        playOnce(on: channel)
    }

    private func playOnce(on channel: SSHTerminalChannel) {
        guard !channel.connected else { return }
        // Echo what the composer and key strip send, escaped, so a driven run
        // (OPPI_UI_VALIDATE_TAPS) shows the bytes that reached the "PTY".
        channel.opened(PreviewConnection(status: status) { [weak channel] bytes in
            let shown = String(decoding: bytes, as: UTF8.self).unicodeScalars.map { scalar -> String in
                switch scalar.value {
                case 0x1b: "\\e"
                case 0x0d: "\\r"
                case 0x0a: "\\n"
                case 0..<0x20: "^" + String(UnicodeScalar(UInt8(scalar.value + 0x40)))
                default: String(scalar)
                }
            }.joined()
            channel?.event(.data(Data("\r\nsent: \(shown)".utf8)))
        }, command: "herdr")
        let esc = "\u{1b}["
        let screen = status == .none ? herdrScreen(esc) : statusScreen(esc)
        var bytes = Data(screen.utf8)
        bytes.append(statusReports(status))
        channel.event(.data(bytes))
    }

    private func herdrScreen(_ esc: String) -> String {
        [
            "\(esc)2J\(esc)H",
            "\(esc)38;5;3m\u{25d0} \(esc)1mdotfiles\(esc)0m                     \(esc)2mtab 1\(esc)0m\r\n",
            "\(esc)38;5;3m\u{25d0} 1 needs you\(esc)0m\r\n",
            "\(esc)38;5;4m\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\(esc)0m\r\n\r\n",
            "\(esc)48;5;236m can you tidy the ssh terminal header \(esc)0m\r\n\r\n",
            "\(esc)3;38;5;67mThe header has a status row and a warning\r\nthat duplicate the toolbar. Let me check.\(esc)0m\r\n\r\n",
            "\(esc)42;30m[bash]\(esc)0m rg -n networkChanged Oppi/\r\n\r\n",
            "Allow running \(esc)1mrg\(esc)0m?  \(esc)7m Yes \(esc)0m  No  Always\r\n\r\n",
            "\(esc)38;5;5m\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\(esc)0m\r\n",
            "\(esc)2m$0.146 \u{2502} 1.9%/1.0M \u{2502} mac-studio\(esc)0m",
        ].joined()
    }

    private func statusScreen(_ esc: String, step: SSHTerminalScreenshotStatus? = nil) -> String {
        let line: String = switch step ?? status {
        case .none, .sequence: ""
        case .working: "pi: installing updates"
        case .blocked: "Allow running rg?  Yes  No  Always"
        case .done: "Upgraded 12 packages"
        case .error: "rsync failed"
        case .idle: "ready"
        case .tree, .detail: "deploy: eu-west is waiting for approval"
        }
        return "\(esc)2J\(esc)H \(line)\r\n"
    }

    private func statusReports(_ status: SSHTerminalScreenshotStatus) -> Data {
        switch status {
        case .none:
            return Data()
        case .working:
            return osc("state=working:app=pi:msg=\(b64("Installing updates"))")
        case .blocked:
            return osc("state=blocked:kind=permission:app=pi:msg=\(b64("Allow running rg in the repo?"))")
        case .done:
            return osc("state=done:app=pi:msg=\(b64("Upgraded 12 packages"))")
        case .error:
            return osc("state=error:app=pi:msg=\(b64("rsync failed"))")
        case .idle:
            return osc("state=idle:app=pi:msg=\(b64("Ready"))")
        case .tree, .detail:
            return osc("state=working:app=deploy:msg=\(b64("Deploying v2.4.1"))")
                + osc("state=blocked:kind=permission:id=eu-west:title=\(b64("EU West")):msg=\(b64("Approve deploy to eu-west?"))")
        case .sequence:
            return Data()
        }
    }

    private func playSequence(on channel: SSHTerminalChannel) async {
        guard !channel.connected else { return }
        channel.opened(PreviewConnection(status: .working) { _ in }, command: "herdr")
        let steps: [(Double, SSHTerminalScreenshotStatus)] = [
            (0.6, .working), (2.0, .blocked), (2.0, .working), (2.4, .done), (2.6, .working), (1.6, .error), (4.0, .idle),
        ]
        for (delay, step) in steps {
            try? await Task.sleep(for: .seconds(delay))
            var bytes = Data(statusScreen("\u{1b}[", step: step).utf8)
            bytes.append(statusReports(step))
            channel.event(.data(bytes))
        }
    }

    private func osc(_ body: String) -> Data { Data("\u{1b}]7501;\(body)\u{1b}\\".utf8) }

    private func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
}

private actor PreviewConnection: SSHTerminalConnection {
    let status: SSHTerminalScreenshotStatus
    let echo: @MainActor (Data) -> Void
    init(status: SSHTerminalScreenshotStatus = .none, echo: @escaping @MainActor (Data) -> Void) {
        self.status = status
        self.echo = echo
    }
    func send(_ bytes: Data) async throws { await echo(bytes) }
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}
    func checkAlive() async throws {}
    func cancel() async {}

    func run(_ command: String, input: Data) async throws -> SSHExecResult {
        if input == Data(SSHTerminalForeground.probeScript.utf8) {
            // Status variants report through OSC 7501, so the probe stays a shell
            // and cannot hide that the root record decided the input mode.
            // The default preview is a Herdr client whose focused pane runs pi.
            let ps = status == .none
                ? "t 101 100 ttys002 Ss -fish\nt 102 101 ttys002 S+ herdr\na 200 100 ?? S sh\na 100 99 ?? S sshd-session: preview\n"
                : "t 101 100 ttys002 Ss -fish\na 200 100 ?? S sh\na 100 99 ?? S sshd-session: preview\n"
            return SSHExecResult(output: Data(ps.utf8), errorOutput: Data(), exitStatus: 0)
        }
        if command == "sh -s" { // a keybinding file read: none here, so defaults
            return SSHExecResult(output: Data(), errorOutput: Data("No such file".utf8), exitStatus: 1)
        }
        let json = #"{"result":{"snapshot":{"workspaces":[{"workspace_id":"w1","label":"dotfiles","focused":true},{"workspace_id":"w2","label":"oppi","focused":false}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"1"},{"tab_id":"w2:t1","workspace_id":"w2","label":"1"}],"agents":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","agent":"pi","agent_status":"blocked","focused":true,"terminal_title_stripped":"Allow running rg?"},{"pane_id":"w2:p1","workspace_id":"w2","tab_id":"w2:t1","agent":"claude","agent_status":"working","focused":false,"terminal_title_stripped":"Fixing the build"}]}}}"#
        return SSHExecResult(output: Data(json.utf8), errorOutput: Data(), exitStatus: 0)
    }
}
#endif
