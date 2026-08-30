import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OppiMac", category: "MacAPIClient")

/// Thin REST client for the local Oppi server.
///
/// Health attach stays on HTTPS because `/health` is unauthenticated.
/// Authenticated owner calls use the Unix socket; `sk_` must not go over HTTPS.
final class MacAPIClient: Sendable {

    let baseURL: URL
    let socketPath: String
    private let token: String
    private let session: URLSession
    private let transport: any MacLocalHTTPPerforming

    init(
        baseURL: URL,
        token: String,
        socketPath: String = MacLocalAPISocket.path(
            dataDir: NSString("~/.config/oppi").expandingTildeInPath
        ),
        timeoutIntervalForRequest: TimeInterval = 10,
        timeoutIntervalForResource: TimeInterval = 15,
        transport: (any MacLocalHTTPPerforming)? = nil
    ) {
        self.baseURL = baseURL
        self.token = token
        self.socketPath = socketPath

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutIntervalForRequest
        config.timeoutIntervalForResource = timeoutIntervalForResource

        // Accept self-signed certs from the local server for unauthenticated health.
        let delegate = LocalServerTrustDelegate()
        self.session = URLSession(
            configuration: config,
            delegate: delegate,
            delegateQueue: nil
        )
        self.transport = transport ?? MacUnixSocketHTTPClient(
            socketPath: socketPath,
            timeout: timeoutIntervalForRequest
        )
    }

    /// Read the owner token from the server's config file.
    ///
    /// Path: `~/.config/oppi/config.json` → `.token`
    static func readOwnerToken(dataDir: String? = nil) -> String? {
        readLocalConfig(dataDir: dataDir)?.token
    }

    /// Number of paired client device tokens stored in the local server config.
    static func pairedClientCount(dataDir: String? = nil) -> Int {
        readLocalConfig(dataDir: dataDir)?.authDeviceTokens?.count ?? 0
    }

    /// Whether at least one client device has completed invite pairing.
    static func hasPairedClients(dataDir: String? = nil) -> Bool {
        pairedClientCount(dataDir: dataDir) > 0
    }

    private static func readLocalConfig(dataDir: String? = nil) -> ConfigFile? {
        let dir = dataDir ?? NSString("~/.config/oppi").expandingTildeInPath
        let configPath = (dir as NSString).appendingPathComponent("config.json")

        guard let data = FileManager.default.contents(atPath: configPath) else {
            logger.debug("Config file not found at \(configPath)")
            return nil
        }

        do {
            return try JSONDecoder().decode(ConfigFile.self, from: data)
        } catch {
            logger.error("Failed to parse config.json: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Health

    /// Check `GET /health`. Returns `true` if the server responds with 2xx.
    nonisolated func checkHealth() async -> Bool {
        let url = baseURL.appendingPathComponent("health")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            logger.debug("Health check failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Server info

    /// Fetch `GET /server/info`. Returns parsed server info or nil.
    nonisolated func fetchServerInfo() async -> ServerHealthMonitor.ServerInfo? {
        guard let data = await socketData(path: "/server/info") else { return nil }
        return parseServerInfo(data)
    }

    // MARK: - Stats

    /// Fetch `GET /server/stats?range=N`. Returns parsed stats or nil on error.
    nonisolated func fetchStats(range: Int = 7) async -> ServerStats? {
        var components = URLComponents(url: baseURL.appendingPathComponent("server/stats"),
                                       resolvingAgainstBaseURL: false)
        let tz = TimeZone.current.secondsFromGMT() / 60
        components?.queryItems = [
            URLQueryItem(name: "range", value: "\(range)"),
            URLQueryItem(name: "tz", value: "\(tz)"),
        ]

        guard let url = components?.url else { return nil }
        let path = "/server/stats?\(url.query ?? "")"
        guard let data = await socketData(path: path) else { return nil }
        do {
            return try JSONDecoder().decode(ServerStats.self, from: data)
        } catch {
            logger.debug("Stats fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Daily detail

    /// Fetch `GET /server/stats/daily/:date?tz=N`. Returns parsed daily detail or nil.
    nonisolated func fetchDailyDetail(date: String) async -> DailyDetail? {
        let tz = TimeZone.current.secondsFromGMT() / 60
        let path = "/server/stats/daily/\(date)?tz=\(tz)"
        guard let data = await socketData(path: path) else { return nil }
        do {
            return try JSONDecoder().decode(DailyDetail.self, from: data)
        } catch {
            logger.debug("Daily detail fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Private

    private nonisolated func socketData(path: String) async -> Data? {
        do {
            let response = try await transport.perform(
                macLocalAuthenticatedRequest(method: "GET", path: path, token: token)
            )
            guard (200..<300).contains(response.statusCode) else {
                logger.debug("Local socket GET \(path) failed: \(response.statusCode)")
                return nil
            }
            return response.body
        } catch {
            logger.debug("Local socket GET \(path) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Parse raw JSON into a ``ServerHealthMonitor/ServerInfo``.
    ///
    /// Internal (not private) so tests can validate uptime formatting
    /// and field fallback logic without hitting the network.
    nonisolated func parseServerInfo(_ data: Data) -> ServerHealthMonitor.ServerInfo? {
        struct InfoResponse: Decodable {
            let version: String?
            let serverUrl: String?
            let uptime: Double?
            let name: String?
        }

        do {
            let info = try JSONDecoder().decode(InfoResponse.self, from: data)
            let uptimeString: String? = info.uptime.map { seconds in
                let hours = Int(seconds) / 3600
                let minutes = (Int(seconds) % 3600) / 60
                if hours >= 24 {
                    return "\(hours / 24)d \(hours % 24)h"
                } else if hours > 0 {
                    return "\(hours)h \(minutes)m"
                } else {
                    return "\(minutes)m"
                }
            }

            return ServerHealthMonitor.ServerInfo(
                version: info.version ?? "unknown",
                serverURL: info.serverUrl ?? baseURL.absoluteString,
                uptime: uptimeString,
                name: info.name
            )
        } catch {
            logger.debug("Failed to parse server info: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Config models

private struct ConfigFile: Decodable {
    let token: String?
    let authDeviceTokens: [String]?
}
