#if DEBUG
import UIKit

/// A locked server's cover over the shell, with its Switch Server button and
/// menu (`SCREENSHOT_SCREEN=locked-server-cover`). Two paired servers, so the
/// button lists the other one, and the cover's own server is left out.
final class LockedServerCoverPreviewController: PreviewRootController {
    init() {
        let coordinator = Self.makeCoordinator()
        let root = AppRootEnvironment.preview(coordinator: coordinator)
        super.init(
            root: root,
            themeStore: root.themeStore,
            content: PreviewHost.screenStack(root: root) {
                ShellRouteScreens.serverLockCover(serverId: Self.lockedServerId, root: root)
            }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private static let lockedServerId = "sha256:locked-cover-preview"

    private static func makeCoordinator() -> ConnectionCoordinator {
        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        let servers = [pairedServer(lockedServerId, name: "mac-studio", badge: .macStudio),
                       pairedServer("sha256:locked-cover-preview-mini", name: "mac-mini", badge: .macMini)]
        coordinator.serverStore.replaceServersForPreview(servers)
        _ = coordinator.switchToServer(servers[0])
        return coordinator
    }

    private static func pairedServer(_ fingerprint: String, name: String, badge: ServerBadgeIcon) -> PairedServer {
        guard var server = PairedServer(from: ServerCredentials(
            host: "\(name).local",
            port: 7749,
            token: "sk_preview",
            name: name,
            scheme: .https,
            serverFingerprint: fingerprint,
            tlsCertFingerprint: "\(fingerprint)-leaf"
        )) else {
            preconditionFailure("locked cover preview server")
        }
        server.badgeIcon = badge
        return server
    }
}
#endif
