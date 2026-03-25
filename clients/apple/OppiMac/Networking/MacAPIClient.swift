import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.chenda.OppiMac", category: "MacAPIClient")

/// Thin REST client for the local Oppi server.
///
/// Handles health checks and server info. Accepts self-signed TLS certificates
/// from the local server since the Mac app manages the server process directly.
final class MacAPIClient: Sendable {

    let baseURL: URL
    private let token: String
    private let session: URLSession

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15

        // Accept self-signed certs from the local server.
        let delegate = SelfSignedTrustDelegate()
        self.session = URLSession(
            configuration: config,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    /// Read the owner token from the server's config file.
    ///
    /// Path: `~/.config/oppi/config.json` → `.ownerToken`
    static func readOwnerToken(dataDir: String? = nil) -> String? {
        let dir = dataDir ?? NSString("~/.config/oppi").expandingTildeInPath
        let configPath = (dir as NSString).appendingPathComponent("config.json")

        guard let data = FileManager.default.contents(atPath: configPath) else {
            logger.debug("Config file not found at \(configPath)")
            return nil
        }

        struct ConfigFile: Decodable {
            let token: String?
            let ownerToken: String?
        }

        do {
            let config = try JSONDecoder().decode(ConfigFile.self, from: data)
            return config.token ?? config.ownerToken
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
        addAuth(&request)

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
        let url = baseURL.appendingPathComponent("server/info")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addAuth(&request)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }
            return parseServerInfo(data)
        } catch {
            logger.debug("Server info fetch failed: \(error.localizedDescription)")
            return nil
        }
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
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addAuth(&request)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }
            let decoder = JSONDecoder()
            return try decoder.decode(ServerStats.self, from: data)
        } catch {
            logger.debug("Stats fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Daily detail

    /// Fetch `GET /server/stats/daily/:date?tz=N`. Returns parsed daily detail or nil.
    nonisolated func fetchDailyDetail(date: String) async -> DailyDetail? {
        let tz = TimeZone.current.secondsFromGMT() / 60
        let url = baseURL
            .appendingPathComponent("server/stats/daily/\(date)")
            .appending(queryItems: [URLQueryItem(name: "tz", value: "\(tz)")])
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addAuth(&request)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode(DailyDetail.self, from: data)
        } catch {
            logger.debug("Daily detail fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Private

    private nonisolated func addAuth(_ request: inout URLRequest) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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

// MARK: - Self-signed TLS trust

/// URLSession delegate that accepts self-signed certificates from the local server.
///
/// The Mac app manages the server process and knows the server uses self-signed TLS.
/// In production, this should pin the specific certificate fingerprint.
private final class SelfSignedTrustDelegate: NSObject, URLSessionDelegate, Sendable {

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }

        // Accept any certificate from localhost / 127.0.0.1.
        // For remote servers, we'd pin the certificate fingerprint.
        let host = challenge.protectionSpace.host
        if host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") {
            return (.useCredential, URLCredential(trust: serverTrust))
        }

        return (.performDefaultHandling, nil)
    }
}
