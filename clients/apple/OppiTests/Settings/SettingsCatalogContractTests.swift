import Foundation
import Testing
@testable import Oppi

/// The catalog's server-backed declarations against `protocol/settings.json`,
/// the list of settings the server owns (the server's own test holds its
/// registry to the same file). A declaration that disagrees with the server on
/// where a setting lives, whether it is revisioned, or which field it is would
/// save to the wrong place or fight the server's 409s.
@Suite("Settings catalog contract")
struct SettingsCatalogContractTests {
    private struct Row: Decodable {
        let key: String
        let scope: String
        let storage: String
        let type: String
        let revisioned: Bool?
    }

    private struct Registry: Decodable {
        let settings: [Row]
    }

    private static func rows() throws -> [Row] {
        try JSONDecoder().decode(Registry.self, from: ProtocolFixtures.data("settings.json")).settings
    }

    /// The row a declaration's storage points at, and the scope and storage that row must have.
    private static func expectation(of storage: SettingStorage) -> (key: String, scope: String, storage: String)? {
        switch storage {
        case .device: nil
        case .server(let endpoint, _): (endpoint.registryKey, "server", "config")
        case .piOwned(let endpoint, _): (endpoint.registryKey, "server", "pi")
        case .workspace(let field): ("workspace.\(field)", "workspace", "workspace")
        case .deviceOnServer(_, let field): (field, "device", "push-registration")
        }
    }

    @Test("Every server-backed declaration has a row with its scope, and its field is one of the row's")
    func everyServerBackedDeclarationHasAMatchingRow() throws {
        let rows = try Self.rows()
        let serverBacked = SettingsCatalog.all.filter { Self.expectation(of: $0.storage) != nil }
        #expect(!serverBacked.isEmpty)

        for descriptor in serverBacked {
            let expected = try #require(Self.expectation(of: descriptor.storage))
            let row = try #require(rows.first { $0.key == expected.key }, "\(descriptor.id): protocol/settings.json has no row \(expected.key)")
            #expect(row.scope == expected.scope, "\(descriptor.id): the server scopes \(row.key) as \(row.scope)")
            // A route's document is an object; the declaration's key must be one of its fields.
            if case .server = descriptor.storage, row.type.hasPrefix("{") {
                let fields = Set(row.type.matches(of: /(\w+)\??:/).map { String($0.1) })
                #expect(fields.contains(descriptor.key), "\(descriptor.id): \(descriptor.key) is not a field of \(row.type)")
            }
        }
    }

    @Test("A declaration is revisioned exactly when the server revisions the setting")
    func revisionedFlagMatchesTheServer() throws {
        let rows = try Self.rows()
        for descriptor in SettingsCatalog.all {
            guard case .server(let endpoint, let revisioned) = descriptor.storage else { continue }
            let row = try #require(rows.first { $0.key == endpoint.registryKey })
            let serverRevisioned = try #require(row.revisioned, "\(row.key) has no revisioned flag")
            #expect(revisioned == serverRevisioned, "\(descriptor.id): declared revisioned \(revisioned), the server says \(serverRevisioned)")
        }
    }

    @Test("Every endpoint the client knows has a row in the server's list")
    func everyEndpointHasARow() throws {
        let keys = Set(try Self.rows().map(\.key))
        for endpoint in SettingEndpoint.allCases {
            #expect(keys.contains(endpoint.registryKey), "\(endpoint.path) has no row \(endpoint.registryKey)")
        }
    }
}
