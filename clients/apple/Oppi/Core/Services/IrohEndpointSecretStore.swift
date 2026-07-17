import Foundation
import IrohLib

/// Persists the local Iroh endpoint identity outside Codable app state.
enum IrohEndpointSecretStore {
    static func loadOrCreateSecretBytes() throws -> Data {
        try KeychainService.loadOrCreateIrohEndpointSecret {
            SecretKey.generate().toBytes()
        }
    }
}
