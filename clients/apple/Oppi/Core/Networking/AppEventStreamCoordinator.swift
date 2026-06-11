import Foundation

/// Coordinates the global app event stream for one server connection.
///
/// This is separate from `SessionStreamCoordinator`: it owns no per-session
/// continuations and routes only app/store events through `handleAppEvent(_:)`.
@MainActor
final class AppEventStreamCoordinator {
    private var consumptionTask: Task<Void, Never>?
    private var client: AppEventStreamClient?
    private var streamURL: URL?

    var isRunning: Bool {
        guard let consumptionTask else { return false }
        return !consumptionTask.isCancelled
    }

    func start(
        connection: ServerConnection,
        client nextClient: AppEventStreamClient,
        streamURL nextURL: URL
    ) {
        if isRunning, streamURL == nextURL {
            return
        }

        disconnect()
        client = nextClient
        streamURL = nextURL
        let stream = nextClient.connect()

        consumptionTask = Task { @MainActor [weak self, weak connection] in
            for await event in stream {
                guard let connection, !Task.isCancelled else { break }
                if case .connected(_, let snapshotRequired) = event, snapshotRequired {
                    await connection.refreshSessionList(force: true)
                }
                connection.handleAppEvent(event)
            }
            self?.consumptionTask = nil
        }
    }

    func disconnect() {
        consumptionTask?.cancel()
        consumptionTask = nil
        client?.disconnect()
        client = nil
        streamURL = nil
    }
}
