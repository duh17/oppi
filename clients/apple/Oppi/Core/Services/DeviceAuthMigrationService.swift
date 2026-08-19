import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "DeviceAuthMigration")
extension APIClient: DeviceAuthMigrationTransport {}

protocol DeviceAuthMigrationTransport: Sendable {
    func migrateDevice(deviceName: String?, devicePublicKey: DevicePublicKey) async throws -> PairDeviceResponse
}

/// Transparently upgrades a stored dt_ credential on the ordinary HTTPS route.
/// If HTTPS is unavailable, the original credential remains untouched.
@MainActor
final class DeviceAuthMigrationService {
    private let deviceKeyProvider: () throws -> any DeviceKey
    private let clientFactory: (ServerCredentials) -> any DeviceAuthMigrationTransport
    private let persist: (PairedServer) throws -> Void
    private var failedMigrateTokens: Set<String> = []

    init(
        deviceKeyProvider: @escaping () throws -> any DeviceKey = {
            try DeviceKeyProvider.shared.loadOrCreate()
        },
        clientFactory: @escaping (ServerCredentials) -> any DeviceAuthMigrationTransport = { credentials in
            guard let baseURL = credentials.baseURL else {
                return APIClient(environment: OppiClientEnvironment(
                    baseURL: URL(string: "https://invalid.local") ?? URL(fileURLWithPath: "/"),
                    bearerToken: credentials.token
                ))
            }
            return APIClient(environment: OppiClientEnvironment(
                baseURL: baseURL,
                bearerToken: credentials.token,
                pinnedCertificateFingerprint: credentials.tlsCertFingerprint
            ))
        },
        persist: @escaping (PairedServer) throws -> Void
    ) {
        self.deviceKeyProvider = deviceKeyProvider
        self.clientFactory = clientFactory
        self.persist = persist
    }

    func migrateIfNeeded(_ server: PairedServer, force: Bool = false) async -> PairedServer {
        guard server.deviceCredential == nil, server.token.hasPrefix("dt_"), server.baseURL != nil else {
            return server
        }
#if DEBUG
        // E2E injects the harness dt_ as the live token. Migrating it revokes
        // that token, then later session calls fail closed with unknown_token.
        if ProcessInfo.processInfo.environment["OPPI_E2E_DEVICE_TOKEN"] == server.token {
            return server
        }
#endif
        let failureKey = Self.failureKey(for: server)
        if !force, failedMigrateTokens.contains(failureKey) {
            return server
        }
        let key: any DeviceKey
        do {
            key = try deviceKeyProvider()
        } catch {
            // No migrate POST happened. Do not cache: a later pass can load the key.
            logger.debug("HTTPS device migration key load deferred: \(error.localizedDescription, privacy: .public)")
            return server
        }
        let response: PairDeviceResponse
        do {
            response = try await clientFactory(server.credentials).migrateDevice(
                deviceName: server.name,
                devicePublicKey: key.publicKey
            )
        } catch {
            if Self.shouldCacheFailure(error) {
                failedMigrateTokens.insert(failureKey)
            }
            logger.debug("HTTPS device migration deferred: \(error.localizedDescription, privacy: .public)")
            return server
        }
        guard let deviceCredential = response.deviceCredential else {
            // A dt_-only or otherwise incomplete replacement must not wipe
            // the stored token. Leave the pairing usable until a later pass.
            failedMigrateTokens.insert(failureKey)
            return server
        }
        var migrated = server
        migrated.deviceCredential = deviceCredential
        migrated.token = ""
        do {
            try persist(migrated)
            failedMigrateTokens.remove(failureKey)
            return migrated
        } catch {
            // The idempotent POST already succeeded. Do not cache: a later
            // pass must retry so the replacement can be written.
            logger.debug("HTTPS device migration persist deferred: \(error.localizedDescription, privacy: .public)")
            return server
        }
    }

    private static func failureKey(for server: PairedServer) -> String {
        "\(server.id)\0\(server.token)"
    }

    /// Cache only un-migratable leftover responses. Transient reachability
    /// and retryable 4xx (408/425/429) must retry on the next navigation pass.
    /// This set is process-lifetime only: a permanently un-migratable leftover
    /// still POSTs once per launch.
    private static func shouldCacheFailure(_ error: Error) -> Bool {
        if error is DeviceAuthError { return true }
        if let apiError = error as? APIError {
            switch apiError {
            case .server(let status, _), .codedServer(let status, _, _):
                return (400..<500).contains(status) && status != 408 && status != 425 && status != 429
            case .invalidResponse:
                return false
            }
        }
        return false
    }
}
