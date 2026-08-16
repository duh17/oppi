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

    func migrateIfNeeded(_ server: PairedServer) async -> PairedServer {
        guard server.deviceCredential == nil, server.token.hasPrefix("dt_"), server.baseURL != nil else {
            return server
        }
        do {
            let key = try deviceKeyProvider()
            let publicKey = key.publicKey
            let response = try await clientFactory(server.credentials).migrateDevice(
                deviceName: server.name,
                devicePublicKey: publicKey
            )
            var migrated = server
            migrated.deviceCredential = response.deviceCredential
            migrated.token = ""
            try persist(migrated)
            return migrated
        } catch {
            logger.debug("HTTPS device migration deferred: \\(error.localizedDescription, privacy: .public)")
            return server
        }
    }
}
