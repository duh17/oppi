import Foundation

extension APIClient {
    func fetchServerMetrics(range: ServerMetricsRange) async throws -> ServerMetricsSnapshot {
        let data = try await get("/server/metrics?range=\(range.rawValue)")
        return try JSONDecoder().decode(ServerMetricsSnapshot.self, from: data)
    }

    /// `serverMetrics.enabled` and the revision that saved it.
    struct ServerMetricsSettings: Decodable, Sendable {
        let enabled: Bool
        /// Counts saves on the server; absent from servers that predate revisions.
        let revision: Int?
    }

    func serverMetricsSettings() async throws -> ServerMetricsSettings {
        let data = try await get("/server/metrics/settings")
        return try JSONDecoder().decode(ServerMetricsSettings.self, from: data)
    }

    func serverMetricsEnabled() async throws -> Bool {
        try await serverMetricsSettings().enabled
    }

    /// Persists `serverMetrics.enabled`; the server starts or stops sampling now. With
    /// `baseRevision`, the server refuses the save (409 `revision_conflict`) when the setting
    /// changed since that revision.
    func saveServerMetricsSettings(enabled: Bool, baseRevision: Int? = nil) async throws -> ServerMetricsSettings {
        let data = try await put(
            "/server/metrics/settings",
            body: ServerMetricsWriteRequest(enabled: enabled, baseRevision: baseRevision)
        )
        return try JSONDecoder().decode(ServerMetricsSettings.self, from: data)
    }

    @discardableResult
    func setServerMetricsEnabled(_ enabled: Bool, baseRevision: Int? = nil) async throws -> Bool {
        try await saveServerMetricsSettings(enabled: enabled, baseRevision: baseRevision).enabled
    }
}

private struct ServerMetricsWriteRequest: Encodable {
    let enabled: Bool
    let baseRevision: Int?
}
