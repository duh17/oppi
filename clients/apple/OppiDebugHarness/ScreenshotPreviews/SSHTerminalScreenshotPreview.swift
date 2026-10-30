#if DEBUG
import SwiftUI
import UIKit

/// Which OSC 7501 report this preview feeds through the real terminal engine.
enum SSHTerminalScreenshotStatus: String {
    case none, blocked
}

/// The real terminal surface over an in-memory connection: a Herdr-like
/// screen in the grid, and `herdr api snapshot` answered with one blocked agent
/// so the toolbar overview and its badge render, beside two saved machines:
/// `mac-mini` with a working agent and `build box`, which cannot be reached.
/// The host runs Rex too, with a pane waiting on a permission, so the Rex
/// Sessions button and its sheet render beside Herdr's. `status: .blocked`
/// also feeds real OSC 7501 bytes through libghostty.
struct SSHTerminalScreenshotPreview: View {
    var status: SSHTerminalScreenshotStatus = .none
    var hostLabel: String = "chen@mac-studio"
    private let themeID: ThemeID
    @State private var channel = try? SSHTerminalChannel()
    /// A server-scoped connection, as the app root injects, so the input bar
    /// claims the shared dictation manager and shows its mic.
    @State private var connection: ServerConnection = {
        let connection = ServerConnection()
        connection.setPreviewServerId("preview-server")
        return connection
    }()

    init(
        status: SSHTerminalScreenshotStatus = .none,
        hostLabel: String = "chen@mac-studio"
    ) {
        self.status = status
        self.hostLabel = hostLabel
        let themeID: ThemeID = ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] == "light"
            ? .light : .dark
        self.themeID = themeID
        ThemeRuntimeState.setThemeID(themeID)
    }

    var body: some View {
        Group {
            if let channel {
                // The terminal at the root of a router stack, the way the app pushes it.
                SSHTerminalPreviewHost(
                    channel: channel,
                    hostLabel: hostLabel,
                    themeID: themeID,
                    connection: connection
                )
                .task { play(on: channel) }
            }
        }
        .ignoresSafeArea()
        .environment(connection)
        .environment(\.themeID, themeID)
        .environment(\.theme, themeID.appTheme)
        // As the app root does: materials and popovers follow the theme, not
        // whatever appearance the simulator was left in.
        .preferredColorScheme(themeID.preferredColorScheme)
        .accessibilityIdentifier("screenshot.ready")
    }

    private func play(on channel: SSHTerminalChannel) {
        guard !channel.connected else { return }
        // Echo what the composer and key strip send, escaped, so a driven run
        // (OPPI_UI_VALIDATE_TAPS) shows the bytes that reached the "PTY".
        // The default preview is a Herdr client, which starts in direct
        // typing. Status variants run a login shell, so only the root record
        // can pick the input mode.
        channel.opened(PreviewConnection { [weak channel] bytes in
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
        }, command: status == .none ? "herdr" : nil)
        let esc = "\u{1b}["
        let screen = switch status {
        case .none: herdrScreen(esc)
        case .blocked: statusScreen(esc)
        }
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

    private func statusScreen(_ esc: String) -> String {
        "\(esc)2J\(esc)H Allow running rg?  Yes  No  Always\r\n"
    }

    private func statusReports(_ status: SSHTerminalScreenshotStatus) -> Data {
        switch status {
        case .none:
            return Data()
        case .blocked:
            return osc("state=blocked:kind=permission:app=pi:msg=\(b64("Allow running rg in the repo?"))")
        }
    }

    private func osc(_ body: String) -> Data { Data("\u{1b}]7501;\(body)\u{1b}\\".utf8) }

    private func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
}

private struct SSHTerminalPreviewHost: UIViewControllerRepresentable {
    let channel: SSHTerminalChannel
    let hostLabel: String
    let themeID: ThemeID
    let connection: ServerConnection

    func makeUIViewController(context: Context) -> RouterNavigationController {
        let terminal = SSHTerminalViewController(
            channel: channel,
            reconnect: {},
            editHost: {},
            hostLabel: hostLabel,
            composerConnection: connection
        )
        let style: UIUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
        terminal.overrideUserInterfaceStyle = style
        let navigation = RouterNavigationController(rootViewController: terminal)
        navigation.interfaceStyle = { style }
        return navigation
    }

    func updateUIViewController(_ controller: RouterNavigationController, context: Context) {}
}

private actor PreviewConnection: SSHTerminalConnection {
    let echo: @MainActor (Data) -> Void
    init(echo: @escaping @MainActor (Data) -> Void) {
        self.echo = echo
    }

    func send(_ bytes: Data) async throws { await echo(bytes) }
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}
    func checkAlive() async throws {}
    nonisolated func close() {}
    func cancel() async {}

    func run(_ command: String, input: Data) async throws -> SSHExecResult {
        if command == "sh -s" { // a keybinding file read: none here, so defaults
            return SSHExecResult(output: Data(), errorOutput: Data("No such file".utf8), exitStatus: 1)
        }
        if command == HerdrRemote.machinesCommand {
            let machines = #"[{"id":"aa11","label":"mac-mini","enabled":true},{"id":"bb22","label":"build box","enabled":true}]"#
            return SSHExecResult(output: Data(machines.utf8), errorOutput: Data(), exitStatus: 0)
        }
        if command == HerdrRemote.snapshotCommand(machine: "aa11") {
            let json = #"{"result":{"snapshot":{"workspaces":[{"workspace_id":"w1","label":"tools","focused":true}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"1"}],"agents":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","agent":"pi","agent_status":"working","focused":true,"terminal_title_stripped":"Adding skill frontmatter"}]}}}"#
            return SSHExecResult(output: Data(json.utf8), errorOutput: Data(), exitStatus: 0)
        }
        if command == HerdrRemote.snapshotCommand(machine: "bb22") {
            return SSHExecResult(output: Data(), errorOutput: Data("ssh: connect to host build port 22: Operation timed out".utf8), exitStatus: 255)
        }
        if command == RexRemote.command {
            // A focus answers `{}`; the snapshot script gets two sessions: a
            // Claude waiting on a permission and a working pi in one, a shell
            // that never reported in a second window.
            guard String(decoding: input, as: UTF8.self) == RexRemote.snapshotScript else {
                return SSHExecResult(output: Data("{}".utf8), errorOutput: Data(), exitStatus: 0)
            }
            let json = #"{"sessions":[{"session_id":"session:01a18a26-6620-76be-b529-4d9ad2b36c63","label":"oppi","active_window_id":"window:01a18a26-6645-713c-97f1-2f1058c8c82f","windows":[{"window_id":"window:01a18a26-6645-713c-97f1-2f1058c8c82f","label":"agents","focused_block_id":"block:01a18a26-6620-78ba-80d4-4e8caa018b37","blocks":[{"block_id":"block:01a18a26-6620-78ba-80d4-4e8caa018b37","label":"shell","title":"Fixing the build","program_status":[{"effective_app":"claude","state":"working"},{"id":"bash","effective_app":"claude","state":"blocked","kind":"permission","msg":"Run rm -rf build?"}]},{"block_id":"block:01a18a7e-911a-721b-a50b-14dfc0cc62ca","label":"shell","title":"Adding skill frontmatter","program_status":[{"effective_app":"pi","state":"working"}]}]},{"window_id":"window:01a18a26-6645-713c-97f1-2f1058c8c830","label":"logs","focused_block_id":"block:01a18a7e-911a-721b-a50b-14dfc0cc62cb","blocks":[{"block_id":"block:01a18a7e-911a-721b-a50b-14dfc0cc62cb","label":"shell","title":"tail -f server.log","program_status":{}}]}]},{"session_id":"session:01a18a26-6620-76be-b529-4d9ad2b36c64","label":"dotfiles","active_window_id":"window:01a18a26-6645-713c-97f1-2f1058c8c831","windows":[{"window_id":"window:01a18a26-6645-713c-97f1-2f1058c8c831","label":"main","focused_block_id":"block:01a18a7e-911a-721b-a50b-14dfc0cc62cc","blocks":[{"block_id":"block:01a18a7e-911a-721b-a50b-14dfc0cc62cc","label":"shell","title":"Ready","program_status":[{"effective_app":"codex","state":"idle"}]}]}]}]}"#
            return SSHExecResult(output: Data(json.utf8), errorOutput: Data(), exitStatus: 0)
        }
        let json = #"{"result":{"snapshot":{"workspaces":[{"workspace_id":"w1","label":"dotfiles","focused":true},{"workspace_id":"w2","label":"oppi","focused":false}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"1"},{"tab_id":"w2:t1","workspace_id":"w2","label":"1"}],"agents":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","agent":"pi","agent_status":"blocked","focused":true,"terminal_title_stripped":"Allow running rg?"},{"pane_id":"w2:p1","workspace_id":"w2","tab_id":"w2:t1","agent":"claude","agent_status":"working","focused":false,"terminal_title_stripped":"Fixing the build"},{"pane_id":"w2:p2","workspace_id":"w2","tab_id":"w2:t1","agent":"grok","agent_status":"done","focused":false,"terminal_title_stripped":"Summarized the diff"},{"pane_id":"w2:p3","workspace_id":"w2","tab_id":"w2:t1","agent":"codex","agent_status":"idle","focused":false,"terminal_title_stripped":"Ready"}]}}}"#
        return SSHExecResult(output: Data(json.utf8), errorOutput: Data(), exitStatus: 0)
    }
}
#endif
