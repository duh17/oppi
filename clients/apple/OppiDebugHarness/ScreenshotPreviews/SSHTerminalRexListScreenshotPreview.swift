#if DEBUG
import UIKit

/// A stand-in connection to a fake Rex host: every stream the monitor opens
/// is a new connection to the same `world` (the preview's by default), as a
/// new SSH exec channel is a new bridge to Rex.
@MainActor
final class RexPreviewStreamHost: RexStreamHost {
    private(set) var hosts: [RexFakeHost] = []
    let world: RexFakeWorld
    var isConnected: Bool { true }

    init(world: RexFakeWorld = .preview()) { self.world = world }

    func openStream(command: String, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream {
        guard command == RexBridge.command else { throw SSHConnectionError.notConnected }
        let host = world.host()
        hosts.append(host)
        return host.open(sink: sink)
    }

    /// The fake host has no Rex CLI (`RexBridge.statusCommand`); the bridge is its way in.
    func run(_ command: String, input: Data) async throws -> SSHExecResult {
        throw SSHConnectionError.commandRequestRejected
    }
}

/// `SCREENSHOT_SCREEN=ssh-terminal-rex-list`: the Terminal tab over two saved
/// hosts, a plain one and a Rex one (`rexHostID`). The Rex host's sessions
/// come from a fake Rex (`RexFakeHost.preview()`: two sessions, one with a
/// pane waiting on a permission), and a tap on a session opens a fake Rex
/// session terminal, as the real tab opens the host's own.
final class SSHTerminalRexListPreviewController: PreviewRootController {
    static let rexHostID = UUID(uuid: (0x5E, 0x5E, 0x5E, 0x5E, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 1))

    /// The tasks feeding the fake terminals a list opened. The list's follower
    /// factory holds it, so the tasks live as long as the list.
    private final class Consumers {
        var tasks: [Task<Void, Never>] = []
        deinit { tasks.forEach { $0.cancel() } }
    }

    init() {
        if ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] == "light" {
            ScreenshotVolatileDefaults.applyTheme(.light)
        } else {
            ScreenshotVolatileDefaults.applyDarkTheme(true)
        }
        let themeStore = ThemeStore()
        let root = AppRootEnvironment.preview(
            coordinator: ConnectionCoordinator(serverStore: ServerStore()),
            themeStore: themeStore
        )
        let list = Self.makeList(hosts: [
            SSHTerminalProfile(
                id: Self.rexHostID, host: "mac-studio.invalid", username: "alex", opensRexSessions: true
            ),
            SSHTerminalProfile(host: "devbox.invalid", port: 2222, username: "dev", authentication: .deviceKey),
        ])
        super.init(
            root: root,
            themeStore: themeStore,
            content: PreviewHost.screenStack(root: root) { list }
        )
    }

    /// The Terminal page over `hosts` (saved in the argument domain only: no
    /// persistent defaults and no Keychain are written), each host's Rex the
    /// fake one, off the tailnet. A tapped session opens a fake Rex session
    /// terminal pushed over the list, as the real page opens the host's own.
    /// `fixedMode` is the page's (the Rex pane passes `.rex`).
    static func makeList(
        hosts: [SSHTerminalProfile], fixedMode: SSHTerminalPageMode? = nil
    ) -> SSHTerminalHostListViewController {
        var values: [String: Any] = [:]
        values[SSHTerminalProfileStore.catalogKey] = try? JSONEncoder().encode(SSHTerminalCatalog(profiles: hosts))
        ScreenshotVolatileDefaults.apply(values)
        // The list is made with the factory that opens its sessions, so the
        // factory reaches the list through a reference set once it exists.
        weak var listRef: SSHTerminalHostListViewController?
        let consumers = Consumers()
        let list = SSHTerminalHostListViewController(fixedMode: fixedMode, makeFollower: { profile in
            let follower = SSHTerminalRexFollower(
                profile: profile, promptsAutomatically: false, standIn: RexPreviewStreamHost()
            )
            follower.monitor.openPane = { pane in
                Task { @MainActor in
                    guard let list = listRef, let channel = try? SSHTerminalChannel() else { return }
                    if let task = await SSHTerminalPreviewController.playRexSession(on: channel) { consumers.tasks.append(task) }
                    Router.push(SSHTerminalViewController(
                        channel: channel, reconnect: {}, editHost: {}, hostLabel: "alex@mac-studio \u{00B7} \(pane.label)"
                    ), from: list)
                }
            }
            return follower
        }, tailnetRex: RexTailnetSection(
            // Off the tailnet whatever the machine running it is on, so the
            // saved host's Rex section is the whole Rex list.
            store: RexDirectStore(defaults: UserDefaults(suiteName: "rex-list-preview-tailnet") ?? .standard), reach: { .none }
        ), startsTailnet: {})
        listRef = list
        return list
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
#endif
