import Foundation
import OSLog

private let macServerLifecycleLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "OppiMac",
    category: "MacServerLifecycle"
)

enum MacServerStartupPlan: Equatable, Sendable {
    case attachHealthyServer
    case waitForLaunchAgent
    case spawnChildProcess
}

@MainActor
enum MacServerLifecycle {
    static var defaultBaseURL: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "localhost"
        components.port = 7749
        return components.url
    }

    static let launchAgentPlistPaths = [
        "~/Library/LaunchAgents/dev.chaosdonkey.oppi.plist",
        "~/Library/LaunchAgents/dev.chenda.oppi.plist",
    ].map { NSString(string: $0).expandingTildeInPath }

    static func startupPlan(
        launchAgentInstalled: Bool,
        healthCheckSucceeded: Bool
    ) -> MacServerStartupPlan {
        if healthCheckSucceeded {
            return .attachHealthyServer
        }
        if launchAgentInstalled {
            return .waitForLaunchAgent
        }
        return .spawnChildProcess
    }

    static func launchAgentInstalled(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        launchAgentPlistPaths.contains(where: fileExists)
    }

    @discardableResult
    static func startOrAttachFromLocalConfig(
        processManager: ServerProcessManager,
        healthMonitor: ServerHealthMonitor,
        sessionMonitor: MacSessionMonitor? = nil,
        allowKillingExistingServer: Bool
    ) async -> Bool {
        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir),
              let baseURL = defaultBaseURL else {
            return false
        }

        let client = MacAPIClient(baseURL: baseURL, token: token)
        await startOrAttach(
            processManager: processManager,
            healthMonitor: healthMonitor,
            sessionMonitor: sessionMonitor,
            baseURL: baseURL,
            token: token,
            client: client,
            allowKillingExistingServer: allowKillingExistingServer
        )
        return true
    }

    static func restartFromLocalConfig(
        processManager: ServerProcessManager,
        healthMonitor: ServerHealthMonitor,
        sessionMonitor: MacSessionMonitor? = nil,
        allowKillingExistingServer: Bool
    ) async {
        if processManager.processOwner == .externalProcess, launchAgentInstalled() {
            do {
                try await runServerCommand("restart")
            } catch {
                processManager.markFailed(error.localizedDescription)
                return
            }
        } else {
            await processManager.stop()
        }

        await startOrAttachFromLocalConfig(
            processManager: processManager,
            healthMonitor: healthMonitor,
            sessionMonitor: sessionMonitor,
            allowKillingExistingServer: allowKillingExistingServer
        )
    }

    static func stopFromLocalConfig(
        processManager: ServerProcessManager,
        healthMonitor: ServerHealthMonitor,
        sessionMonitor: MacSessionMonitor? = nil
    ) async {
        healthMonitor.stopMonitoring()
        sessionMonitor?.stopPolling()

        if processManager.processOwner == .externalProcess, launchAgentInstalled() {
            do {
                try await runServerCommand("stop")
            } catch {
                processManager.markFailed(error.localizedDescription)
                return
            }
        } else {
            await processManager.stop()
            return
        }

        processManager.detachExternalServer()
    }

    static func startOrAttach(
        processManager: ServerProcessManager,
        healthMonitor: ServerHealthMonitor,
        sessionMonitor: MacSessionMonitor? = nil,
        baseURL: URL,
        token: String,
        client: MacAPIClient,
        allowKillingExistingServer: Bool
    ) async {
        let launchdInstalled = launchAgentInstalled()
        let probe = MacAPIClient(
            baseURL: baseURL,
            token: token,
            timeoutIntervalForRequest: 1,
            timeoutIntervalForResource: 2
        )
        let healthy = await probe.checkHealth()
        let plan = startupPlan(
            launchAgentInstalled: launchdInstalled,
            healthCheckSucceeded: healthy
        )

        switch plan {
        case .attachHealthyServer:
            macServerLifecycleLogger.info("Attaching to healthy local server")
            processManager.markRunning()
            startMonitoring(
                healthMonitor: healthMonitor,
                sessionMonitor: sessionMonitor,
                baseURL: baseURL,
                token: token,
                client: client,
                processManager: processManager
            )

        case .waitForLaunchAgent:
            macServerLifecycleLogger.info("LaunchAgent installed; waiting for local server health")
            startMonitoring(
                healthMonitor: healthMonitor,
                sessionMonitor: sessionMonitor,
                baseURL: baseURL,
                token: token,
                client: client,
                processManager: processManager
            )

        case .spawnChildProcess:
            macServerLifecycleLogger.info("Starting Mac app-managed server child process")
            if allowKillingExistingServer {
                ServerProcessManager.killExistingServer()
            }
            processManager.startWithDefaults()
            startMonitoring(
                healthMonitor: healthMonitor,
                sessionMonitor: sessionMonitor,
                baseURL: baseURL,
                token: token,
                client: client,
                processManager: processManager
            )
        }
    }

    private static func runServerCommand(_ action: String) async throws {
        ServerProcessManager.seedServerRuntimeIfNeeded()
        guard let runtimePath = ServerProcessManager.resolveRuntimePath() else {
            throw MacServerLifecycleError.runtimeUnavailable(ServerProcessManager.runtimeFailureReason())
        }
        guard let cliPath = ServerProcessManager.resolveServerCLIPath() else {
            throw MacServerLifecycleError.cliNotFound
        }

        var environment = ProcessRunner.augmentedEnvironment
        environment["OPPI_DATA_DIR"] = ServerProcessManager.serverDataDir
        environment["OPPI_RUNTIME_BIN"] = runtimePath

        let result = try await ProcessRunner.runCapturingStderr(
            executable: runtimePath,
            arguments: [cliPath, "server", action],
            environment: environment
        )
        guard result.exitCode == 0 else {
            throw MacServerLifecycleError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    private static func startMonitoring(
        healthMonitor: ServerHealthMonitor,
        sessionMonitor: MacSessionMonitor?,
        baseURL: URL,
        token: String,
        client: MacAPIClient,
        processManager: ServerProcessManager
    ) {
        healthMonitor.startMonitoring(
            baseURL: baseURL,
            token: token,
            processManager: processManager
        )
        healthMonitor.checkPiCLIVersion()
        sessionMonitor?.startPolling(client: client)
    }
}

enum MacServerLifecycleError: LocalizedError {
    case runtimeUnavailable(String)
    case cliNotFound
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable(let message): message
        case .cliNotFound: "Server CLI not found"
        case .commandFailed(let message): message
        }
    }
}
