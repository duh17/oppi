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
        case .oppiDocsPrompt, .oppiCliPrompt:
            let data = try await get(endpoint.rawValue)
            return try JSONDecoder().decode(RevisionedEnabled.self, from: data).settingsDocument
        case .durableSessions:
            return try await durableSessionsSettings().settingsDocument
        case .features:
            return try await serverFeatures().settingsDocument
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
        case .oppiDocsPrompt, .oppiCliPrompt:
            guard let enabled = fields["enabled"]?.boolValue else {
                throw SettingsError.invalidStoredValue(String(localized: "A prompt hint needs an on or off value."))
            }
            do {
                let data = try await put(
                    endpoint.rawValue,
                    body: EnabledSettingWrite(enabled: enabled, baseRevision: baseRevision)
                )
                return try JSONDecoder().decode(RevisionedEnabled.self, from: data).settingsDocument
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
        case .features:
            var switches: [String: Bool] = [:]
            for (name, value) in fields {
                guard let on = value.boolValue else {
                    throw SettingsError.invalidStoredValue(String(localized: "A feature switch needs an on or off value."))
                }
                switches[name] = on
            }
            return try await saveServerFeatures(switches).settingsDocument
        }
    }

    /// Every feature switch of the server (`GET /server/features`), by `ServerFeature` raw value.
    func serverFeatures() async throws -> [String: Bool] {
        let data = try await get(SettingEndpoint.features.rawValue)
        return try JSONDecoder().decode([String: Bool].self, from: data)
    }

    /// Saves the named switches; the server answers every switch and tells apps
    /// (`features_changed`).
    func saveServerFeatures(_ switches: [String: Bool]) async throws -> [String: Bool] {
        let data = try await put(SettingEndpoint.features.rawValue, body: switches)
        return try JSONDecoder().decode([String: Bool].self, from: data)
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

/// A config-stored on/off setting as its route answers it: the prompt hints.
private struct RevisionedEnabled: Decodable {
    let enabled: Bool
    let revision: Int

    var settingsDocument: SettingsServerDocument {
        SettingsServerDocument(fields: ["enabled": .bool(enabled)], revision: revision)
    }
}

private extension Dictionary where Key == String, Value == Bool {
    var settingsDocument: SettingsServerDocument {
        SettingsServerDocument(fields: mapValues { .bool($0) })
    }
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
