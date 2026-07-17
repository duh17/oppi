import Foundation

/// Canonical bearer header construction for every authenticated HTTP and
/// WebSocket request, including requests sent to the Iroh loopback proxy.
enum ServerAuthorization {
    static func headerValue(token: String) -> String {
        "Bearer \(token)"
    }

    static func apply(token: String, to request: inout URLRequest) {
        request.setValue(headerValue(token: token), forHTTPHeaderField: "Authorization")
    }
}

/// Builds a transport-aware API client for short-lived processes such as App
/// Intents. Iroh managers and their loopback listeners are always shut down
/// before the operation returns; normal app UI uses ConnectionCoordinator
/// ownership instead.
enum ServerTransportAPIClient {
    static func withClient<Result: Sendable>(
        for server: PairedServer,
        operation: @Sendable (APIClient) async throws -> Result
    ) async throws -> Result {
        switch try IrohTransportPolicy.select(credentials: server.credentials) {
        case .http:
            guard let baseURL = server.baseURL else {
                throw IrohTransportError.protocolViolation("HTTP transport has no base URL")
            }
            let client = APIClient(
                baseURL: baseURL,
                token: server.token,
                tlsCertFingerprint: server.tlsCertFingerprint
            )
            return try await operation(client)

        case .iroh(let metadata):
            let manager = IrohConnectionManager(iroh: metadata)
            do {
                let baseURL = try await manager.startProxy(token: server.token)
                let client = APIClient(baseURL: baseURL, token: server.token)
                let result = try await operation(client)
                await manager.shutdown()
                return result
            } catch {
                await manager.shutdown()
                throw error
            }
        }
    }
}
