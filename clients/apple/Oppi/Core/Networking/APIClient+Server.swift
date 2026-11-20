import Foundation

// MARK: - Server update, usage, themes, push

extension APIClient {
    /// Start an exact-version npm update of a globally installed oppi-server.
    func startServerUpdate(version: String) async throws -> ServerInfo.UpdateInfo {
        struct Body: Encodable {
            let version: String
        }
        return try await post("/server/update", body: Body(version: version), as: ServerInfo.UpdateInfo.self)
    }

    /// Client timezone offset in minutes (e.g. PDT = -420).
    /// Sent to the server so daily/hourly buckets align with the user's local time.
    private static var tzOffsetMinutes: Int {
        TimeZone.current.secondsFromGMT() / 60
    }

    /// Fetch server stats for the given range.
    func fetchStats(range: UsageRange = .week) async throws -> ServerStats {
        try await get("/server/stats?range=\(range.rawValue)&tz=\(Self.tzOffsetMinutes)", as: ServerStats.self)
    }

    /// Fetch hourly breakdown for a specific day.
    func fetchDailyDetail(date: String) async throws -> DailyDetail {
        try await get("/server/stats/daily/\(date)?tz=\(Self.tzOffsetMinutes)", as: DailyDetail.self)
    }

    /// Fetch normalized provider quota windows (Codex, xAI, …) from the server.
    func fetchProviderQuotas() async throws -> ProviderQuotasInfo {
        try await get("/server/provider-quotas", as: ProviderQuotasInfo.self)
    }

    /// List available custom themes on the server.
    func listThemes() async throws -> [RemoteThemeSummary] {
        struct Response: Decodable { let themes: [RemoteThemeSummary] }
        return try await get("/themes", as: Response.self).themes
    }

    /// Fetch a full theme by name.
    func getTheme(name: String) async throws -> RemoteTheme {
        struct Response: Decodable { let theme: RemoteTheme }
        return try await get("/themes/\(name)", as: Response.self).theme
    }

    /// Give the server this device's push key and relay send token (protocol/push/spec.md, section 5).
    func putPushRegistration(_ registration: PushRegistrationRequest) async throws -> PushRegistrationResponse {
        try await put("/me/push-registration", body: registration, as: PushRegistrationResponse.self)
    }

    /// The server forgets this device's push key and send token.
    func deletePushRegistration() async throws {
        _ = try await delete("/me/push-registration")
    }
}

// MARK: - Diagnostics

extension APIClient {
    /// Upload raw MetricKit payloads for backend trend dashboards.
    func uploadMetricKitPayload(request body: MetricKitUploadRequest) async throws {
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else { return }
        _ = try await postBackgroundUpload("/telemetry/metrickit", body: body)
    }

    /// Sorted-keys encoder for telemetry uploads: the same event always
    /// encodes to the same bytes, whatever the dictionary insertion order.
    static let telemetryEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    /// Upload catalog events; the caller (`TelemetryEventUploader`) owns the
    /// diagnostics gate. Throws unless the server answers 2xx. The response counts
    /// events the server refused, by reason; it is `nil` when a 2xx body cannot be
    /// read, which must not read as a failed upload: the accepted events are stored.
    func uploadTelemetryEvents(request body: TelemetryEventUploadRequest) async throws -> TelemetryEventUploadResponse? {
        let data = try await postBackgroundUpload(
            "/telemetry/events",
            body: body,
            encoder: Self.telemetryEncoder
        )
        return try? JSONDecoder().decode(TelemetryEventUploadResponse.self, from: data)
    }

    func uploadClientLogs(request body: ClientLogUploadRequest) async throws {
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else { return }
        _ = try await postBackgroundUpload(
            "/telemetry/client-logs",
            body: body,
            encoder: Self.telemetryEncoder
        )
    }

    /// POST for telemetry and log uploads. A failed upload is no evidence about the route, so it
    /// never feeds route availability; the uploader's own retry policy owns the failure.
    private func postBackgroundUpload<T: Encodable>(
        _ path: String,
        body: T,
        encoder: JSONEncoder? = nil
    ) async throws -> Data {
        let (data, response) = try await request("POST", path: path, body: body, encoder: encoder, reportsAvailability: false)
        try checkStatus(response, data: data)
        return data
    }
}
