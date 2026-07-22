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
    private var generation: UInt64 = 0
    private let refreshSnapshot: (ServerConnection) async -> Void

    init(
        refreshSnapshot: @escaping (ServerConnection) async -> Void = { connection in
            await connection.refreshSessionList(force: true)
        }
    ) {
        self.refreshSnapshot = refreshSnapshot
    }

    var isRunning: Bool {
        guard let consumptionTask else { return false }
        return !consumptionTask.isCancelled
    }

    func isCurrentClient(_ candidate: AppEventStreamClient) -> Bool {
        client === candidate
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
        generation &+= 1
        let activeGeneration = generation
        client = nextClient
        streamURL = nextURL
        let stream = nextClient.connect()
        connection.setAppEventStreamTransportState(.connecting)

        consumptionTask = Task { @MainActor [weak self, weak connection] in
            for await event in stream {
                guard let self,
                      let connection,
                      self.generation == activeGeneration,
                      !Task.isCancelled else { break }
                if case .connected(_, let snapshotRequired) = event {
                    connection.setAppEventStreamTransportState(.connected)
                    if snapshotRequired {
                        await self.refreshSnapshot(connection)
                        guard self.generation == activeGeneration, !Task.isCancelled else { break }
                    }
                }
                connection.handleAppEvent(event)
            }
            guard let self, self.generation == activeGeneration else { return }
            self.consumptionTask = nil
            connection?.setAppEventStreamTransportState(.disconnected)
        }
    }

    func disconnect() {
        generation &+= 1
        consumptionTask?.cancel()
        consumptionTask = nil
        client?.disconnect()
        client = nil
        streamURL = nil
    }
}
