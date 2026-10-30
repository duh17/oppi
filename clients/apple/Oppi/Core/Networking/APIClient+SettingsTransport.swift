import Foundation

/// `SettingsServerTransport` over the server's settings routes. Each route is
/// one case: it turns the route's typed response into the document the
/// settings store reads, and the store's field changes into the route's update.
extension APIClient: SettingsServerTransport {
    func loadSettings(_ endpoint: SettingEndpoint) async throws -> SettingsServerDocument {
        switch endpoint {
        case .serverMetrics:
            return try await serverMetricsSettings().settingsDocument
        case .mobileOutputGuide:
            return try await getMobileOutputGuideConfiguration().settingsDocument
        case .durableSessions:
            return try await durableSessionsSettings().settingsDocument
        }
    }

    func saveSettings(
        _ endpoint: SettingEndpoint,
        fields: [String: JSONValue],
        baseRevision: Int?
    ) async throws -> SettingsServerDocument {
        switch endpoint {
        case .serverMetrics:
            guard let enabled = fields["enabled"]?.boolValue else {
                throw SettingsError.invalidStoredValue(String(localized: "Server Metrics needs an on or off value."))
            }
            do {
                return try await saveServerMetricsSettings(enabled: enabled, baseRevision: baseRevision).settingsDocument
            } catch let APIError.codedServer(status, _, code) where status == 409 && code == "revision_conflict" {
                throw SettingsError.revisionConflict
            }
        case .mobileOutputGuide:
            guard let enabled = fields["enabled"]?.boolValue else {
                throw SettingsError.invalidStoredValue(String(localized: "The Mobile Output Guide needs an on or off value."))
            }
            // The server requires the revision this write is based on.
            guard let baseRevision else {
                throw SettingsError.rejected(String(localized: "The Mobile Output Guide has not loaded yet. Pull to refresh and try again."))
            }
            do {
                return try await setMobileOutputGuideConfiguration(enabled: enabled, baseRevision: baseRevision).settingsDocument
            } catch let APIError.codedServer(status, _, code) where status == 409 && code == "revision_conflict" {
                throw SettingsError.revisionConflict
            }
        case .durableSessions:
            guard let enabled = fields["enabled"]?.boolValue else {
                throw SettingsError.invalidStoredValue(String(localized: "Durable Sessions needs an on or off value."))
            }
            do {
                return try await saveDurableSessionsSettings(enabled: enabled, baseRevision: baseRevision).settingsDocument
            } catch let APIError.codedServer(status, _, code) where status == 409 && code == "revision_conflict" {
                throw SettingsError.revisionConflict
            }
        }
    }

    /// `experimental.serverDurable` as the running server applies it, and the revision that saved it.
    struct DurableSessionsSettings: Decodable, Sendable {
        let enabled: Bool
        let revision: Int
    }

    func durableSessionsSettings() async throws -> DurableSessionsSettings {
        let data = try await get(SettingEndpoint.durableSessions.rawValue)
        return try JSONDecoder().decode(DurableSessionsSettings.self, from: data)
    }

    /// Saves Durable Sessions; the server applies it to new sessions at once. A stale
    /// `baseRevision` is refused with 409 `revision_conflict`.
    func saveDurableSessionsSettings(enabled: Bool, baseRevision: Int?) async throws -> DurableSessionsSettings {
        let data = try await put(
            SettingEndpoint.durableSessions.rawValue,
            body: EnabledSettingWrite(enabled: enabled, baseRevision: baseRevision)
        )
        return try JSONDecoder().decode(DurableSessionsSettings.self, from: data)
    }
}

private struct EnabledSettingWrite: Encodable {
    let enabled: Bool
    let baseRevision: Int?
}

private extension APIClient.DurableSessionsSettings {
    var settingsDocument: SettingsServerDocument {
        SettingsServerDocument(fields: ["enabled": .bool(enabled)], revision: revision)
    }
}

private extension MobileOutputGuideConfiguration {
    var settingsDocument: SettingsServerDocument {
        SettingsServerDocument(fields: ["enabled": .bool(enabled)], revision: revision)
    }
}

private extension APIClient.ServerMetricsSettings {
    var settingsDocument: SettingsServerDocument {
        SettingsServerDocument(fields: ["enabled": .bool(enabled)], revision: revision)
    }
}
