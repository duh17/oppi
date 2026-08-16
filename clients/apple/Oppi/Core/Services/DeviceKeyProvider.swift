import CryptoKit
import Foundation

/// Loads or creates the device signing key exactly once per process.
///
/// The private key material is non-exportable when the Secure Enclave is
/// available and otherwise Keychain-sealed. It is never persisted alongside the
/// server credential — `DeviceKeyStore` owns it solely.
final class DeviceKeyProvider: @unchecked Sendable {
    static let shared = DeviceKeyProvider()

    private let lock = NSLock()
    private var cached: (any DeviceKey)?

    func loadOrCreate() throws -> any DeviceKey {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let container = try CrossProcessFileLock.appGroupContainer(
            identifier: SharedConstants.appGroupIdentifier
        )
        let key = try DeviceKeyStore.loadOrCreateShared(
            storage: KeychainDeviceKeyStorage(),
            useEnclave: { SecureEnclave.isAvailable },
            lockContainer: container
        )
        cached = key
        return key
    }
}
