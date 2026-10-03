#if DEBUG
import SwiftUI

/// The real terminal surface over an in-memory connection: a Herdr-like
/// screen in the grid, and `herdr api snapshot` answered with one blocked agent
/// so the toolbar overview and its badge render.
struct SSHTerminalScreenshotPreview: View {
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
                SSHTerminalView(channel: channel, reconnect: {}, editHost: {})
                    .task { play(on: channel) }
            }
        }
        .environment(connection)
        .accessibilityIdentifier("screenshot.ready")
    }

    private func play(on channel: SSHTerminalChannel) {
        guard !channel.connected else { return }
        // Echo what the composer and key strip send, escaped, so a driven run
        // (OPPI_UI_VALIDATE_TAPS) shows the bytes that reached the "PTY".
        channel.opened(PreviewConnection { [weak channel] bytes in
            let shown = String(decoding: bytes, as: UTF8.self).unicodeScalars.map { scalar -> String in
                switch scalar.value {
                case 0x1b: "\\e"
                case 0x0d: "\\r"
                case 0x0a: "\\n"
                case 0..<0x20: "^" + String(UnicodeScalar(scalar.value + 0x40)!)
                default: String(scalar)
                }
            }.joined()
            channel?.event(.data(Data("\r\nsent: \(shown)".utf8)))
        }, command: "herdr")
        let esc = "\u{1b}["
        let screen = [
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
        channel.event(.data(Data(screen.utf8)))
    }
}

private actor PreviewConnection: SSHTerminalConnection {
    let echo: @MainActor (Data) -> Void
    init(echo: @escaping @MainActor (Data) -> Void) { self.echo = echo }
    func send(_ bytes: Data) async throws { await echo(bytes) }
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}
    func checkAlive() async throws {}
    func cancel() async {}

    func run(_ command: String) async throws -> SSHExecResult {
        let json = #"{"result":{"snapshot":{"workspaces":[{"workspace_id":"w1","label":"dotfiles","focused":true},{"workspace_id":"w2","label":"oppi","focused":false}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"1"},{"tab_id":"w2:t1","workspace_id":"w2","label":"1"}],"agents":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","agent":"pi","agent_status":"blocked","focused":true,"terminal_title_stripped":"Allow running rg?"},{"pane_id":"w2:p1","workspace_id":"w2","tab_id":"w2:t1","agent":"claude","agent_status":"working","focused":false,"terminal_title_stripped":"Fixing the build"}]}}}"#
        return SSHExecResult(output: Data(json.utf8), errorOutput: Data(), exitStatus: 0)
    }
}
#endif
