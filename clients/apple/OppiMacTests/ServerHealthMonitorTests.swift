import Testing
import Foundation
@testable import Oppi

@Suite("ServerHealthMonitor")
@MainActor
struct ServerHealthMonitorTests {

    // MARK: - stopMonitoring

    @Test func stopMonitoringResetsAllState() {
        let monitor = ServerHealthMonitor()
        let pm = ServerProcessManager()
        pm._setStateForTesting(.running)

        monitor.startMonitoring(
            baseURL: URL(string: "https://localhost:9999")!,
            token: "test-token",
            processManager: pm
        )

        monitor.stopMonitoring()

        #expect(!monitor.isHealthy)
        #expect(monitor.serverInfo == nil)
        #expect(monitor.consecutiveFailures == 0)
    }

    @Test func stopMonitoringIsIdempotent() {
        let monitor = ServerHealthMonitor()

        monitor.stopMonitoring()
        monitor.stopMonitoring()

        #expect(!monitor.isHealthy)
    }

    // MARK: - startMonitoring resets prior state

    @Test func startMonitoringResetsState() {
        let monitor = ServerHealthMonitor()
        let pm = ServerProcessManager()

        // Start once.
        monitor.startMonitoring(
            baseURL: URL(string: "https://localhost:9999")!,
            token: "tok1",
            processManager: pm
        )

        // Start again — should reset.
        monitor.startMonitoring(
            baseURL: URL(string: "https://localhost:8888")!,
            token: "tok2",
            processManager: pm
        )

        #expect(!monitor.isHealthy)
        #expect(monitor.serverInfo == nil)
        #expect(monitor.consecutiveFailures == 0)
    }

    // MARK: - startMonitoring against live server

    @Test func startMonitoringAgainstLiveServer() async throws {
        // The dev machine has a running server — use it to test the full poll cycle.
        let monitor = ServerHealthMonitor()
        let pm = ServerProcessManager()
        pm._setStateForTesting(.starting)

        let dataDir = NSString("~/.config/oppi").expandingTildeInPath
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir) else {
            return // skip if no config
        }

        monitor.startMonitoring(
            baseURL: URL(string: "https://localhost:7749")!,
            token: token,
            processManager: pm
        )

        // Wait for the startup poll to detect the healthy server.
        for _ in 0..<15 {
            try await Task.sleep(for: .milliseconds(500))
            if monitor.isHealthy { break }
        }

        #expect(monitor.isHealthy)
        #expect(pm.state == .running, "Health monitor should have called markRunning()")

        monitor.stopMonitoring()
    }

    // MARK: - ServerInfo equality

    @Test func serverInfoEquality() {
        let a = ServerHealthMonitor.ServerInfo(
            version: "1.0.0", serverURL: "https://localhost:7749",
            uptime: "2h 30m", name: "test"
        )
        let b = ServerHealthMonitor.ServerInfo(
            version: "1.0.0", serverURL: "https://localhost:7749",
            uptime: "2h 30m", name: "test"
        )
        let c = ServerHealthMonitor.ServerInfo(
            version: "2.0.0", serverURL: "https://localhost:7749",
            uptime: nil, name: nil
        )

        #expect(a == b)
        #expect(a != c)
    }

    @Test func serverInfoWithNilFields() {
        let info = ServerHealthMonitor.ServerInfo(
            version: "1.0", serverURL: "url", uptime: nil, name: nil
        )
        #expect(info.uptime == nil)
        #expect(info.name == nil)
    }
}
