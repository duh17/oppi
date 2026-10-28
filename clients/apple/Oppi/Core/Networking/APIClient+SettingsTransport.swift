import Foundation

/// `SettingsServerTransport` over the server's settings routes. Each route is
/// one case: it turns the route's typed response into the document the
/// settings store reads, and the store's field changes into the route's update.
extension APIClient: SettingsServerTransport {
    func loadSettings(_ endpoint: SettingEndpoint) async throws -> SettingsServerDocument {
        switch endpoint {
        case .autoTitle:
            return try await getAutoTitleConfig().settingsDocument
        }
    }

    func saveSettings(
        _ endpoint: SettingEndpoint,
        fields: [String: JSONValue],
        baseRevision: Int?
    ) async throws -> SettingsServerDocument {
        switch endpoint {
        case .autoTitle:
            do {
                return try await setAutoTitleConfig(
                    enabled: fields["enabled"]?.boolValue,
                    model: fields["model"]?.stringValue,
                    baseRevision: baseRevision
                ).settingsDocument
            } catch let APIError.codedServer(status, _, code) where status == 409 && code == "revision_conflict" {
                throw SettingsError.revisionConflict
            }
        }
    }
}

private extension APIClient.AutoTitleConfig {
    var settingsDocument: SettingsServerDocument {
        SettingsServerDocument(
            fields: ["enabled": .bool(enabled), "model": model.map(JSONValue.string) ?? .null],
            revision: revision
        )
    }
}
