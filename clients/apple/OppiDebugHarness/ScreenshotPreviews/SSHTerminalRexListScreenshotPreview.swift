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

    /// The tasks feeding the fake terminals this preview opened.
    private final class Consumers {
        var tasks: [Task<Void, Never>] = []
        deinit { tasks.forEach { $0.cancel() } }
    }

    private let consumers: Consumers

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
        // The list is made with the factory that opens its sessions, so the
        // factory reaches the list through a reference set once it exists.
        weak var listRef: SSHTerminalHostListViewController?
        let consumers = Consumers()
        let list = SSHTerminalHostListViewController(makeFollower: { profile in
            let follower = SSHTerminalRexFollower(
                profile: profile, promptsAutomatically: false, standIn: RexPreviewStreamHost()
            )
            follower.monitor.openPane = { pane in
                Task { @MainActor in
                    guard let list = listRef, let channel = try? SSHTerminalChannel() else { return }
                    if let task = await SSHTerminalPreviewController.playRexSession(on: channel) { consumers.tasks.append(task) }
                    Router.push(SSHTerminalViewController(
                        channel: channel, reconnect: {}, editHost: {}, hostLabel: "chen@mac-studio \u{00B7} \(pane.label)"
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
        self.consumers = consumers
        super.init(
            root: root,
            themeStore: themeStore,
            content: PreviewHost.screenStack(root: root) { list }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
#endif
