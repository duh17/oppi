import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.chenda.OppiMac", category: "ServerHealthMonitor")

/// Polls the local server's health and info endpoints.
///
/// During startup: polls every 2 seconds (max 30 attempts).
/// While running: polls every 30 seconds.
/// On 3 consecutive failures while running: triggers restart.
@MainActor @Observable
final class ServerHealthMonitor {

    // MARK: - Types

    struct ServerInfo: Sendable, Equatable {
        let version: String
        let serverURL: String
        let uptime: String?
        let name: String?
    }

    // MARK: - Public state

    private(set) var isHealthy = false
    private(set) var serverInfo: ServerInfo?
    private(set) var piCLIVersion: String?

    // MARK: - Configuration

    private static let startupPollInterval: TimeInterval = 2
    private static let runningPollInterval: TimeInterval = 30
    private static let maxStartupAttempts = 30
    private static let consecutiveFailuresForRestart = 3

    // MARK: - Private

    private var pollingTask: Task<Void, Never>?
    private(set) var consecutiveFailures = 0
    private weak var apiClient: MacAPIClient?
    private weak var processManager: ServerProcessManager?

    // MARK: - Lifecycle

    /// Start monitoring a server managed by the given process manager.
    ///
    /// Creates a `MacAPIClient` for the given base URL and begins polling.
    func startMonitoring(
        baseURL: URL,
        token: String,
        processManager: ServerProcessManager
    ) {
        stopMonitoring()
        self.processManager = processManager

        let client = MacAPIClient(baseURL: baseURL, token: token)
        self.apiClient = client
        consecutiveFailures = 0
        isHealthy = false

        pollingTask = Task { [weak self] in
            await self?.startupPoll(client: client)
        }
    }

    /// Stop all polling.
    func stopMonitoring() {
        pollingTask?.cancel()
        pollingTask = nil
        isHealthy = false
        serverInfo = nil
        consecutiveFailures = 0
    }

    /// Check the pi CLI version by spawning `pi --version`.
    func checkPiCLIVersion() {
        Task.detached {
            var version: String?
            if let piPath = await ProcessRunner.which("pi") {
                version = await ProcessRunner.version(piPath)
            }
            await MainActor.run { [weak self] in
                self?.piCLIVersion = version
            }
        }
    }

    // MARK: - Polling loops

    private func startupPoll(client: MacAPIClient) async {
        logger.info("Starting health polling (startup mode, every \(Self.startupPollInterval)s)")

        for attempt in 1...Self.maxStartupAttempts {
            guard !Task.isCancelled else { return }

            let healthy = await checkHealth(client: client)
            if healthy {
                logger.info("Server healthy after \(attempt) startup poll(s)")
                processManager?.markRunning()
                await runningPoll(client: client)
                return
            }

            try? await Task.sleep(for: .seconds(Self.startupPollInterval))
        }

        logger.error("Server did not become healthy after \(Self.maxStartupAttempts) attempts")
    }

    private func runningPoll(client: MacAPIClient) async {
        logger.info("Switching to running poll (every \(Self.runningPollInterval)s)")

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.runningPollInterval))
            guard !Task.isCancelled else { return }

            let healthy = await checkHealth(client: client)
            if healthy {
                consecutiveFailures = 0
                // Recover state after crash auto-restart — startupPoll already
                // exited, but the process manager may still be in .starting/.failed.
                processManager?.markRunning()
                await fetchServerInfo(client: client)
            } else {
                consecutiveFailures += 1
                logger.warning("Health check failed (\(self.consecutiveFailures) consecutive)")

                if consecutiveFailures >= Self.consecutiveFailuresForRestart {
                    logger.error("Triggering restart after \(self.consecutiveFailures) consecutive health check failures")
                    consecutiveFailures = 0
                    await processManager?.restart()
                    // Re-enter startup polling to wait for the restarted server
                    // instead of exiting the loop (which leaves no one to call markRunning).
                    await startupPoll(client: client)
                    return
                }
            }
        }
    }

    // MARK: - Health + info checks

    private func checkHealth(client: MacAPIClient) async -> Bool {
        let result = await client.checkHealth()
        isHealthy = result
        return result
    }

    private func fetchServerInfo(client: MacAPIClient) async {
        guard let info = await client.fetchServerInfo() else { return }
        serverInfo = info
    }


}
