import Foundation
import IrohLib

/// Persists the local Iroh endpoint identity outside Codable app state.
enum IrohEndpointSecretStore {
    static func loadOrCreateSecretBytes() throws -> Data {
        try KeychainService.loadOrCreateIrohEndpointSecret {
            SecretKey.generate().toBytes()
        }
    }

    /// Derive the stable public node ID without binding an endpoint or dialing.
    static func clientNodeID() throws -> String {
        let secret = try SecretKey.fromBytes(bytes: loadOrCreateSecretBytes())
        return secret.public().description
    }
}
