#if DEBUG
import UIKit

/// A stand-in connection to a fake Rex host: every stream the monitor opens
/// is a new `RexFakeHost.preview()`, as a new SSH exec channel is a new
/// bridge to Rex.
@MainActor
final class RexPreviewStreamHost: RexStreamHost {
    private(set) var hosts: [RexFakeHost] = []
    var isConnected: Bool { true }

    func openStream(command: String, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream {
        guard command == RexBridge.command else { throw SSHConnectionError.notConnected }
        let host = RexFakeHost.preview()
        hosts.append(host)
        return host.open(sink: sink)
    }
}

/// `SCREENSHOT_SCREEN=ssh-terminal-rex-list`: the Terminal tab over two saved
/// hosts, a plain one and a Rex one (`rexHostID`). The Rex host's sessions
/// come from a fake Rex (`RexFakeHost.preview()`: two sessions, one with a
/// pane waiting on a permission), and a tap on a session opens a fake Rex
/// session terminal, as the real tab opens the host's own.
final class SSHTerminalRexListPreviewController: PreviewRootController {
    static let rexHostID = UUID(uuid: (0x5E, 0x5E, 0x5E, 0x5E, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 1))

    private var consumers: [Task<Void, Never>] = []

    init() {
        if ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] == "light" {
            ScreenshotVolatileDefaults.applyTheme(.light)
        } else {
            ScreenshotVolatileDefaults.applyDarkTheme(true)
        }
        // Argument-domain values only: no persistent defaults and no Keychain are written.
        let catalog = SSHTerminalCatalog(profiles: [
            SSHTerminalProfile(
                id: Self.rexHostID, host: "mac-studio.local", username: "chen", opensRexSessions: true
            ),
            SSHTerminalProfile(host: "devbox.local", port: 2222, username: "dev", authentication: .deviceKey),
        ])
        var values: [String: Any] = [:]
        values[SSHTerminalProfileStore.catalogKey] = try? JSONEncoder().encode(catalog)
        ScreenshotVolatileDefaults.apply(values)

        let themeStore = ThemeStore()
        let root = AppRootEnvironment.preview(
            coordinator: ConnectionCoordinator(serverStore: ServerStore()),
            themeStore: themeStore
        )
        let list = SSHTerminalHostListViewController()
        super.init(
            root: root,
            themeStore: themeStore,
            content: PreviewHost.screenStack(root: root) { list }
        )
        list.makeFollower = { [weak self, weak list] profile in
            let follower = SSHTerminalRexFollower(
                profile: profile, promptsAutomatically: false, standIn: RexPreviewStreamHost()
            )
            follower.monitor.openPane = { pane in
                Task { @MainActor in
                    guard let self, let list, let channel = try? SSHTerminalChannel() else { return }
                    if let task = await SSHTerminalPreviewController.playRexSession(on: channel) { self.consumers.append(task) }
                    Router.push(SSHTerminalViewController(
                        channel: channel, reconnect: {}, editHost: {}, hostLabel: "chen@mac-studio \u{00B7} \(pane.label)"
                    ), from: list)
                }
            }
            return follower
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        consumers.forEach { $0.cancel() }
    }
}
#endif
