import UIKit

/// On a locked server's cover: switch to another paired server instead of
/// unlocking this one. A locked target server asks first. Hidden while this
/// is the only paired server. `ServerSwitchMenu` owns the rows: each wears its
/// badge, this server is left out, and a choice asks for that server's lock.
@MainActor
final class LockedServerSwitchButton: UIButton {
    private let root: AppRootEnvironment

    init(root: AppRootEnvironment) {
        self.root = root
        super.init(frame: .zero)
        accessibilityIdentifier = "scopedLock.switchServer"
        showsMenuAsPrimaryAction = true
        // Read when it opens: a choice activates here, and the rows are current.
        menu = ServerSwitchMenu.menu { [root] in
            ServerSwitchMenu(
                coordinator: root.coordinator,
                currentServerId: nil,
                omitting: root.coordinator.activeServerId,
                activate: { [weak self] in self?.activate($0) }
            ).elements()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func updateProperties() {
        super.updateProperties()
        let coordinator = root.coordinator
        let others = coordinator.serverStore.servers.filter { $0.id != coordinator.activeServerId }
        isHidden = others.isEmpty

        let palette = root.themeStore.activeThemeID.palette
        var configuration = UIButton.Configuration.plain()
        configuration.title = String(localized: "Switch Server")
        configuration.image = UIImage(systemName: "arrow.left.arrow.right")
        configuration.imagePadding = 6
        configuration.baseForegroundColor = palette.ui.blue
        self.configuration = configuration
    }

    private func activate(_ server: PairedServer) {
        let coordinator = root.coordinator
        guard coordinator.restoreActiveServer(server.id) else { return }
        Task { await coordinator.prepareSelectedServerShell(for: server) }
    }
}
