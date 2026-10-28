import Foundation

extension AppRootEnvironment {
    /// The name of the paired server the active connection is on, for a page's
    /// "Applies to every device on <server>" sentence.
    @MainActor
    var activeServerName: String {
        coordinator.activeConnection.currentServerId
            .flatMap { coordinator.serverStore.server(for: $0)?.name } ?? "this server"
    }
}
