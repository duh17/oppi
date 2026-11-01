import Foundation
import LocalAuthentication
import Synchronization
@testable import Oppi

/// A keychain a test owns: one dictionary in memory, so nothing a test saves
/// reaches the app's real Keychain, and no two tests share an item. The one
/// implementation the SSH tests use (`SSHCredentialStoring`).
final class MemoryKeychain: SSHCredentialStoring, @unchecked Sendable {
    private let items = Mutex<[String: Data]>([:])

    func load(account: String, requirePresence: Bool, authenticationContext: LAContext?) throws -> Data? {
        items.withLock { $0[account] }
    }

    func save(_ data: Data, account: String, requirePresence: Bool) throws {
        items.withLock { $0[account] = data }
    }

    func delete(account: String) throws { items.withLock { $0[account] = nil } }
}
