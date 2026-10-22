#if DEBUG
import SwiftUI
import UIKit

/// Which OSC 7501 reports (or, for `notification`, which OSC 777) this preview
/// feeds through the real terminal engine.
enum SSHTerminalScreenshotStatus: String {
    case none, working, blocked, done, error, idle, tree, sequence, detail, notification
    /// Real Kitty graphics escape sequences: a direct RGBA picture and a PNG,
    /// sent the way `kitten icat` or an agent's image output sends them.
    case kitty
    /// Real OSC 9;4 progress reports, with and without an OSC 7501 status.
    case progressSet, progressIndeterminate, progressError, progressErrorNoPercent, progressPause, progressWithStatus
    /// Three open terminals in a private registry, so the bottom bar's
    /// switcher shows and its menu lists them. Tap `sshTerminal.switcher`.
    case switcher

    var progressReport: String? {
        switch self {
        case .progressSet, .progressWithStatus: "1;40"
        case .progressIndeterminate: "3"
        case .progressError: "2;70"
        case .progressErrorNoPercent: "2"
        case .progressPause: "4;60"
        default: nil
        }
    }
}

/// The real terminal surface over an in-memory connection: a Herdr-like
/// screen in the grid, and `herdr api snapshot` answered with one blocked agent
/// so the toolbar overview and its badge render. Status variants also feed
/// real OSC 7501 bytes through libghostty.
struct SSHTerminalScreenshotPreview: View {
    var status: SSHTerminalScreenshotStatus = .none
    var hostLabel: String = "chen@mac-studio"
    private let themeID: ThemeID
    @State private var channel = try? SSHTerminalChannel()
    /// The switcher variant's registry and the session standing for the terminal on screen.
    @State private var fixture: SSHTerminalSwitcherPreviewFixture?
    /// A server-scoped connection, as the app root injects, so the input bar
    /// claims the shared dictation manager and shows its mic.
    @State private var connection: ServerConnection = {
        let connection = ServerConnection()
        connection.setPreviewServerId("preview-server")
        return connection
    }()

    init(status: SSHTerminalScreenshotStatus = .none, hostLabel: String = "chen@mac-studio") {
        self.status = status
        self.hostLabel = hostLabel
        let themeID: ThemeID = ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] == "light"
            ? .light : .dark
        self.themeID = themeID
        _fixture = State(initialValue: status == .switcher ? SSHTerminalSwitcherPreviewFixture() : nil)
        ThemeRuntimeState.setThemeID(themeID)
    }

    var body: some View {
        Group {
            if let channel {
                // The terminal at the root of a router stack, the way the app pushes it.
                SSHTerminalPreviewHost(
                    channel: channel,
                    status: status,
                    hostLabel: hostLabel,
                    themeID: themeID,
                    connection: connection,
                    session: fixture?.session
                )
                .task { await play(on: channel) }
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

    private func play(on channel: SSHTerminalChannel) async {
        if status == .switcher, let fixture {
            fixture.open(current: channel)
            return
        }
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
        // The default preview is a Herdr client whose focused pane runs pi.
        // Status variants run a login shell, so only the root record can
        // pick the input mode.
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
        }, command: status == .none ? "herdr" : nil)
        let esc = "\u{1b}["
        let screen = status == .none ? herdrScreen(esc) : statusScreen(esc)
        var bytes = Data(screen.utf8)
        bytes.append(statusReports(status))
        if status == .kitty { bytes.append(kittyPictures()) }
        channel.event(.data(bytes))
        keepProgressAlive(on: channel)
    }

    /// A program that shows progress keeps reporting it; a report not renewed
    /// goes stale after 15 seconds, as in Ghostty.
    private func keepProgressAlive(on channel: SSHTerminalChannel) {
        guard let report = status.progressReport else { return }
        let bytes = Data("\u{1b}]9;4;\(report)\u{1b}\\".utf8)
        channel.event(.data(bytes))
        Task { [weak channel] in
            while let channel, channel.connected {
                try? await Task.sleep(for: .seconds(5))
                channel.event(.data(bytes))
            }
        }
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
        case .switcher: "chen@mac-studio: login shell"
        case .progressSet, .progressIndeterminate, .progressError, .progressErrorNoPercent, .progressPause, .progressWithStatus:
            "$ cargo build --release"
        case .kitty: "$ kitten icat gradient.png"
        case .notification: "$ cargo test"
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
        case .sequence, .kitty, .switcher, .progressSet, .progressIndeterminate, .progressError, .progressErrorNoPercent, .progressPause:
            return Data()
        case .progressWithStatus:
            return osc("state=working:app=pi:msg=\(b64("Building"))")
        case .notification:
            return Data("\u{1b}]777;notify;cargo;All 214 tests passed\u{1b}\\".utf8)
        }
    }

    private func playSequence(on channel: SSHTerminalChannel) async {
        guard !channel.connected else { return }
        channel.opened(PreviewConnection(status: .working) { _ in })
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

    /// A 320x180 RGBA gradient placed over a 30x9 cell box, then the same
    /// picture as PNG over a smaller box, then a line of text under both.
    private func kittyPictures() -> Data {
        var output = Data()
        func place(imageID: Int, row: Int, columns: Int, rows: Int, png: Bool) {
            var control = "a=T,i=\(imageID),c=\(columns),r=\(rows)"
            var payload = [UInt8]()
            if png {
                control += ",f=100"
                payload = Self.pngBytes(width: 320, height: 180)
            } else {
                control += ",f=32,s=320,v=180"
                payload.reserveCapacity(320 * 180 * 4)
                for y in 0..<180 {
                    for x in 0..<320 {
                        payload += [UInt8(x * 255 / 320), UInt8(y * 255 / 180), 0xE0, 0xFF]
                    }
                }
            }
            let sequence = "\u{1b}[\(row);2H\u{1b}_G\(control);\(Data(payload).base64EncodedString())\u{1b}\\"
            output.append(Data(sequence.utf8))
        }
        place(imageID: 11, row: 2, columns: 30, rows: 9, png: false)
        place(imageID: 12, row: 13, columns: 20, rows: 6, png: true)
        output.append(Data("\u{1b}[20;2H\u{1b}[38;5;10mimages: direct RGBA above, PNG below\u{1b}[0m".utf8))
        return output
    }

    private static func pngBytes(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                pixels += [0xE0, UInt8(x * 255 / width), UInt8(y * 255 / height), 0xFF]
            }
        }
        let space = CGColorSpaceCreateDeviceRGB()
        let image = pixels.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        guard let image, let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        else { return [] }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return [] }
        return Array(data as Data)
    }

    private func osc(_ body: String) -> Data { Data("\u{1b}]7501;\(body)\u{1b}\\".utf8) }

    private func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
}

private struct SSHTerminalPreviewHost: UIViewControllerRepresentable {
    let channel: SSHTerminalChannel
    let status: SSHTerminalScreenshotStatus
    let hostLabel: String
    let themeID: ThemeID
    let connection: ServerConnection
    var session: SSHTerminalConnectSession?

    func makeUIViewController(context: Context) -> RouterNavigationController {
        let terminal = SSHTerminalViewController(
            channel: channel,
            reconnect: {},
            editHost: {},
            hostLabel: hostLabel,
            session: session,
            composerConnection: connection
        )
        terminal.presentsStatusDetailOnAppear = status == .detail
        let style: UIUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
        terminal.overrideUserInterfaceStyle = style
        let navigation = RouterNavigationController(rootViewController: terminal)
        navigation.interfaceStyle = { style }
        return navigation
    }

    func updateUIViewController(_ controller: RouterNavigationController, context: Context) {}
}

/// Three real terminals in a registry of their own: the studio's login shell
/// (on screen), a folder terminal on the same host, and a second host whose
/// program is blocked.
@MainActor
final class SSHTerminalSwitcherPreviewFixture {
    let registry = SSHTerminalRegistry(experimentEnabled: { true })
    let session: SSHTerminalConnectSession
    private var channels = [SSHTerminalChannel]()

    init() {
        // The screen closes a session's terminal when the experiment is off.
        ScreenshotVolatileDefaults.apply([AppPreferences.Experiments.sshTerminalKey: true])
        session = SSHTerminalConnectSession(registry: registry)
        session.showsTerminal = true
    }

    func open(current: SSHTerminalChannel) {
        guard channels.isEmpty else { return }
        let studio = SSHTerminalProfile(host: "mac-studio", username: "chen")
        let mini = SSHTerminalProfile(host: "mac-mini", username: "chen")
        func adopt(_ channel: SSHTerminalChannel, _ profile: SSHTerminalProfile, folder: String? = nil, line: String, extra: Data = Data()) {
            channel.opened(PreviewConnection { _ in })
            registry.adopt(channel, profile: profile, folder: folder, queue: SSHTerminalEventQueue())
            channel.event(.data(Data("\u{1b}[2J\u{1b}[H \(line)\r\n".utf8) + extra))
            channels.append(channel)
        }
        adopt(current, studio, line: "chen@mac-studio: login shell")
        if let folder = try? SSHTerminalChannel() {
            adopt(folder, studio, folder: "~/workspace/oppi", line: "chen@mac-studio ~/workspace/oppi")
        }
        if let blocked = try? SSHTerminalChannel() {
            let report = "\u{1b}]7501;state=blocked:kind=permission:app=pi:msg=\(Data("Allow running rg?".utf8).base64EncodedString())\u{1b}\\"
            adopt(blocked, mini, line: "chen@mac-mini: pi", extra: Data(report.utf8))
        }
        session.connectedProfile = studio
        session.channel = current
    }
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
    nonisolated func close() {}
    func cancel() async {}

    func run(_ command: String, input: Data) async throws -> SSHExecResult {
        if command == "sh -s" { // a keybinding file read: none here, so defaults
            return SSHExecResult(output: Data(), errorOutput: Data("No such file".utf8), exitStatus: 1)
        }
        let json = #"{"result":{"snapshot":{"workspaces":[{"workspace_id":"w1","label":"dotfiles","focused":true},{"workspace_id":"w2","label":"oppi","focused":false}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"1"},{"tab_id":"w2:t1","workspace_id":"w2","label":"1"}],"agents":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","agent":"pi","agent_status":"blocked","focused":true,"terminal_title_stripped":"Allow running rg?"},{"pane_id":"w2:p1","workspace_id":"w2","tab_id":"w2:t1","agent":"claude","agent_status":"working","focused":false,"terminal_title_stripped":"Fixing the build"},{"pane_id":"w2:p2","workspace_id":"w2","tab_id":"w2:t1","agent":"grok","agent_status":"done","focused":false,"terminal_title_stripped":"Summarized the diff"},{"pane_id":"w2:p3","workspace_id":"w2","tab_id":"w2:t1","agent":"codex","agent_status":"idle","focused":false,"terminal_title_stripped":"Ready"}]}}}"#
        return SSHExecResult(output: Data(json.utf8), errorOutput: Data(), exitStatus: 0)
    }
}
#endif
