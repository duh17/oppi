import Foundation
import Testing
@testable import Oppi

/// Tests for `ServerStore` CRUD operations.
///
/// Uses a test-scoped `ServerStore` for each test, but note that Keychain
/// operations are real (process-scoped). We clean up after ourselves.
@Suite("ServerStore", .serialized)
@MainActor
struct ServerStoreTests {

    // MARK: - Add / Update

    @Test func addServerFromCredentials() {
        let store = makeCleanStore()
        defer { cleanupKeychain(store) }

        let server = store.addOrUpdate(from: makeCredentials(fp: "sha256:add-test"))
        #expect(server != nil)
        #expect(store.servers.count == 1)
        #expect(store.servers[0].name == "test-host")
        #expect(store.servers[0].id == "sha256:add-test")
    }

    @Test func addServerWithoutFingerprintReturnsNil() {
        let store = makeCleanStore()
        let server = store.addOrUpdate(from: ServerCredentials(
            host: "localhost", port: 7749, token: "sk_t", name: "local"
        ))
        #expect(server == nil)
        #expect(store.servers.isEmpty)
    }

    @Test func addServerAssignsIncrementingSortOrder() {
        let store = makeCleanStore()
        defer { cleanupKeychain(store) }

        store.addOrUpdate(from: makeCredentials(fp: "sha256:first"))
        store.addOrUpdate(from: makeCredentials(fp: "sha256:second"))
        #expect(store.servers[0].sortOrder == 0)
        #expect(store.servers[1].sortOrder == 1)
    }

    @Test func rePairUpdatesCredentialsPreservesMetadata() {
        let store = makeCleanStore()
        defer { cleanupKeychain(store) }

        // Initial pair
        _ = store.addOrUpdate(from: ServerCredentials(
            host: "old-host.local", port: 7749, token: "sk_old", name: "studio",
            serverFingerprint: "sha256:repair-test"
        ))
        let originalAddedAt = store.servers[0].addedAt

        // Re-pair with same fingerprint, new credentials
        _ = store.addOrUpdate(from: ServerCredentials(
            host: "new-host.ts.net", port: 8080, token: "sk_new", name: "studio-v2",
            serverFingerprint: "sha256:repair-test"
        ))

        #expect(store.servers.count == 1)
        #expect(store.servers[0].host == "new-host.ts.net")
        #expect(store.servers[0].port == 8080)
        #expect(store.servers[0].token == "sk_new")
        // Preserved
        #expect(store.servers[0].addedAt == originalAddedAt)
        #expect(store.servers[0].sortOrder == 0)
    }

    // MARK: - Remove

    @Test func removeServer() {
        let store = makeCleanStore()
        defer { cleanupKeychain(store) }

        store.addOrUpdate(from: makeCredentials(fp: "sha256:remove-a"))
        store.addOrUpdate(from: makeCredentials(fp: "sha256:remove-b"))
        #expect(store.servers.count == 2)

        store.remove(id: "sha256:remove-a")
        #expect(store.servers.count == 1)
        #expect(store.servers[0].id == "sha256:remove-b")
    }

    @Test func removeNonexistentServerIsNoOp() {
        let store = makeCleanStore()
        store.remove(id: "sha256:doesnt-exist")
        #expect(store.servers.isEmpty)
    }

    // MARK: - Rename

    @Test func renameServer() {
        let store = makeCleanStore()
        defer { cleanupKeychain(store) }

        store.addOrUpdate(from: makeCredentials(fp: "sha256:rename-test"))
        store.rename(id: "sha256:rename-test", to: "New Name")
        #expect(store.servers[0].name == "New Name")
    }

    @Test func renameNonexistentServerIsNoOp() {
        let store = makeCleanStore()
        store.rename(id: "sha256:ghost", to: "Nope")
        #expect(store.servers.isEmpty)
    }

    // MARK: - Lookups

    @Test func lookupById() {
        let store = makeCleanStore()
        defer { cleanupKeychain(store) }

        store.addOrUpdate(from: makeCredentials(fp: "sha256:lookup-test"))
        #expect(store.server(for: "sha256:lookup-test") != nil)
        #expect(store.server(for: "sha256:nope") == nil)
    }

    @Test func lookupByHostPort() {
        let store = makeCleanStore()
        defer { cleanupKeychain(store) }

        store.addOrUpdate(from: ServerCredentials(
            host: "studio.ts.net", port: 7749, token: "sk_t", name: "studio",
            serverFingerprint: "sha256:hostport-test"
        ))

        #expect(store.server(forHost: "studio.ts.net", port: 7749) != nil)
        #expect(store.server(forHost: "studio.ts.net", port: 9999) == nil)
        #expect(store.server(forHost: "mini.ts.net", port: 7749) == nil)
    }

    // MARK: - Helpers

    private func makeCleanStore() -> ServerStore {
        // Clear any leftover state from previous test runs.
        // Must purge both UserDefaults index AND Keychain entries,
        // otherwise the Keychain discovery fallback finds leaked
        // entries from other test suites (ConnectionCoordinatorTests).
        UserDefaults.standard.removeObject(forKey: "pairedServerIds")
        KeychainService.deleteAllServers()
        return ServerStore()
    }

    private func makeCredentials(fp: String) -> ServerCredentials {
        ServerCredentials(
            host: "test-host", port: 7749, token: "sk_test",
            name: "test-host", serverFingerprint: fp
        )
    }

    private func cleanupKeychain(_ store: ServerStore) {
        for server in store.servers {
            KeychainService.deleteServer(id: server.id)
        }
        UserDefaults.standard.removeObject(forKey: "pairedServerIds")
    }
}
