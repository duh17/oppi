import Foundation

extension APIClient {
    func fetchServerMetrics(range: ServerMetricsRange) async throws -> ServerMetricsSnapshot {
        let data = try await get("/server/metrics?range=\(range.rawValue)")
        return try JSONDecoder().decode(ServerMetricsSnapshot.self, from: data)
    }

    func serverMetricsEnabled() async throws -> Bool {
        let data = try await get("/server/metrics/settings")
        return try JSONDecoder().decode(ServerMetricsSettings.self, from: data).enabled
    }

    /// Persists `serverMetrics.enabled`; the server starts or stops sampling now.
    @discardableResult
    func setServerMetricsEnabled(_ enabled: Bool) async throws -> Bool {
        let data = try await put("/server/metrics/settings", body: ServerMetricsSettings(enabled: enabled))
        return try JSONDecoder().decode(ServerMetricsSettings.self, from: data).enabled
    }
}

private struct ServerMetricsSettings: Codable {
    let enabled: Bool
}
