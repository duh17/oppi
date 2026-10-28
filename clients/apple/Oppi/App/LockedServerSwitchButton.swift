import UIKit

/// On a locked server's cover: switch to another paired server instead of
/// unlocking this one. A locked target server asks first. Hidden while this
/// is the only paired server.
@MainActor
final class LockedServerSwitchButton: UIButton {
    private let root: AppRootEnvironment

    init(root: AppRootEnvironment) {
        self.root = root
        super.init(frame: .zero)
        accessibilityIdentifier = "scopedLock.switchServer"
        showsMenuAsPrimaryAction = true
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
        configuration.baseForegroundColor = UIColor(palette.blue)
        self.configuration = configuration

        menu = UIMenu(children: others.map { server in
            UIAction(
                title: server.name,
                image: UIImage(systemName: server.resolvedBadgeIcon.symbolName)
            ) { [weak self] _ in self?.switchTo(server) }
        })
    }

    private func switchTo(_ server: PairedServer) {
        let coordinator = root.coordinator
        let perform: @MainActor () -> Void = {
            guard coordinator.restoreActiveServer(server.id) else { return }
            Task { await coordinator.prepareSelectedServerShell(for: server) }
        }
        if ScopedLockService.shared.gate(.server(server.id), onUnlock: perform) {
            perform()
        }
    }
}
