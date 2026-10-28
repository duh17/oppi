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

    /// Persists `serverMetrics.enabled`; the server starts or stops sampling now. With
    /// `baseRevision`, the server refuses the save (409 `revision_conflict`) when the setting
    /// changed since that revision.
    @discardableResult
    func setServerMetricsEnabled(_ enabled: Bool, baseRevision: Int? = nil) async throws -> Bool {
        let data = try await put(
            "/server/metrics/settings",
            body: ServerMetricsWriteRequest(enabled: enabled, baseRevision: baseRevision)
        )
        return try JSONDecoder().decode(ServerMetricsSettings.self, from: data).enabled
    }
}

private struct ServerMetricsSettings: Decodable {
    let enabled: Bool
    /// Counts saves on the server; absent from servers that predate revisions.
    let revision: Int?
}

private struct ServerMetricsWriteRequest: Encodable {
    let enabled: Bool
    let baseRevision: Int?
}
