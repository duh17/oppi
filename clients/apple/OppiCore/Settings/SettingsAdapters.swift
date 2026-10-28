import Foundation

/// Why an adapter could not read or write a setting. Adapters normalize every
/// failure to one of these so `SettingsStore` has one place that maps them to
/// a `SettingValue`.
enum SettingsError: Error, Equatable, Sendable {
    /// The setting cannot be reached now: no server, no connection.
    case unavailable(String)
    /// The server rejected a write made against an older revision.
    case revisionConflict
    /// The value could not be encoded or decoded for its storage.
    case invalidStoredValue(String)
    /// The storage refused the change; the text is what to show.
    case rejected(String)

    var reason: String {
        switch self {
        case .unavailable(let reason), .invalidStoredValue(let reason), .rejected(let reason): reason
        case .revisionConflict: String(localized: "Changed on another device; showing the latest.")
        }
    }
}

// MARK: - Device

/// Reads and writes a device setting through its `UserDefaults` key: the key an
/// `AppPreferenceStore` preference already uses, so the preference's own
/// accessors and this adapter see the same value. The stored form is what the
/// preference stores (a raw string, a number, a boolean), not a JSON blob.
struct DeviceAdapter {
    var defaults: UserDefaults = .standard

    /// The stored value, or the declaration's default when nothing is stored or
    /// what is stored no longer decodes.
    func read<Value>(_ declaration: SettingDeclaration<Value>) throws -> Value {
        try requireSupported(declaration)
        guard let stored = defaults.object(forKey: declaration.key) else { return declaration.default }
        return (try? Self.decode(Value.self, from: stored)) ?? declaration.default
    }

    func write<Value>(_ declaration: SettingDeclaration<Value>, _ value: Value) throws {
        try requireSupported(declaration)
        defaults.set(try Self.encode(value), forKey: declaration.key)
    }

    /// Per-server device values are keyed by server; no slice declares one yet.
    private func requireSupported<Value>(_ declaration: SettingDeclaration<Value>) throws {
        guard case .device(let perServer) = declaration.storage, !perServer else {
            throw SettingsError.unavailable(String(localized: "This setting is not stored on this device."))
        }
    }

    /// `UserDefaults` property-list form of `value`: the same scalar a
    /// preference's setter stores.
    private static func encode<Value: Encodable>(_ value: Value) throws -> Any {
        do {
            let data = try JSONEncoder().encode([value])
            guard let array = try JSONSerialization.jsonObject(with: data) as? [Any], let scalar = array.first else {
                throw SettingsError.invalidStoredValue(String(localized: "The value cannot be stored."))
            }
            return scalar
        } catch let error as SettingsError {
            throw error
        } catch {
            throw SettingsError.invalidStoredValue(error.localizedDescription)
        }
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from stored: Any) throws -> Value {
        guard JSONSerialization.isValidJSONObject([stored]) else {
            throw SettingsError.invalidStoredValue(String(localized: "The stored value is not readable."))
        }
        let data = try JSONSerialization.data(withJSONObject: [stored])
        return try JSONDecoder().decode([Value].self, from: data)[0]
    }
}

// MARK: - Server

/// One server settings document: the route's JSON fields and its revision.
/// `revision` is `nil` for a route that does not revision its document.
struct SettingsServerDocument: Equatable, Sendable {
    var fields: [String: JSONValue]
    var revision: Int?

    init(fields: [String: JSONValue], revision: Int? = nil) {
        self.fields = fields
        self.revision = revision
    }
}

/// How the app talks to a server's settings routes. The iOS client implements
/// it over `APIClient`; a test implements it with a fake.
protocol SettingsServerTransport: Sendable {
    func loadSettings(_ endpoint: SettingEndpoint) async throws -> SettingsServerDocument
    /// Writes `fields` (only the fields being changed) to the route. With a
    /// `baseRevision` the server rejects a stale write; the transport throws
    /// `SettingsError.revisionConflict` for that rejection.
    func saveSettings(
        _ endpoint: SettingEndpoint,
        fields: [String: JSONValue],
        baseRevision: Int?
    ) async throws -> SettingsServerDocument
}

/// Reads and writes a server setting as one field of its route's document.
struct ServerAdapter: Sendable {
    /// The transport for one paired server, or `nil` when it cannot be reached.
    var transport: @Sendable @MainActor (_ serverId: String) async -> (any SettingsServerTransport)?

    init(transport: @escaping @Sendable @MainActor (_ serverId: String) async -> (any SettingsServerTransport)?) {
        self.transport = transport
    }

    func load(_ endpoint: SettingEndpoint, serverId: String) async throws -> SettingsServerDocument {
        try await resolved(serverId).loadSettings(endpoint)
    }

    /// Writes one field. `baseRevision` is sent only when the route revisions
    /// its document and the last document carried a revision; a route without
    /// revisions has no conflict path.
    func save<Value>(
        _ declaration: SettingDeclaration<Value>,
        _ value: Value,
        endpoint: SettingEndpoint,
        revisioned: Bool,
        baseRevision: Int?,
        serverId: String
    ) async throws -> SettingsServerDocument {
        let fields = [declaration.key: try Self.encode(value)]
        return try await resolved(serverId).saveSettings(
            endpoint,
            fields: fields,
            baseRevision: revisioned ? baseRevision : nil
        )
    }

    /// The declaration's value in `document`, or its default when the document
    /// has no such field.
    static func value<Value>(of declaration: SettingDeclaration<Value>, in document: SettingsServerDocument) -> Value {
        guard let field = document.fields[declaration.key], field != .null,
              let data = try? JSONEncoder().encode(field),
              let value = try? JSONDecoder().decode(Value.self, from: data) else {
            return declaration.default
        }
        return value
    }

    private func resolved(_ serverId: String) async throws -> any SettingsServerTransport {
        guard let transport = await transport(serverId) else {
            throw SettingsError.unavailable(String(localized: "The server is not reachable."))
        }
        return transport
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode([value]))
                .arrayValue?.first ?? .null
        } catch {
            throw SettingsError.invalidStoredValue(error.localizedDescription)
        }
    }
}
