import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Mac remote server store")
struct MacRemoteServerStoreTests {

    @Test func normalizesRemoteServerURLs() throws {
        let url = try MacRemoteServerStore.normalizedURL(from: "Example.COM:7749/path?token=secret#frag")

        #expect(url.absoluteString == "https://example.com:7749/path")
    }

    @Test func rejectsUnsupportedSchemes() {
        #expect(throws: MacRemoteServerStoreError.unsupportedScheme) {
            _ = try MacRemoteServerStore.normalizedURL(from: "ftp://example.com")
        }
    }

    @Test func savesAndReloadsRemoteServers() throws {
        let defaults = try makeDefaults()
        let store = MacRemoteServerStore(defaults: defaults)

        store.add(nickname: "Home", urlText: "https://remote.example.com:7749")

        let reloaded = MacRemoteServerStore(defaults: defaults)
        #expect(reloaded.servers.count == 1)
        #expect(reloaded.servers.first?.displayName == "Home")
        #expect(reloaded.servers.first?.url.absoluteString == "https://remote.example.com:7749")
    }

    @Test func rejectsDuplicateRemoteServerURLs() throws {
        let defaults = try makeDefaults()
        let store = MacRemoteServerStore(defaults: defaults)

        store.add(nickname: "One", urlText: "remote.example.com")
        store.add(nickname: "Two", urlText: "https://remote.example.com")

        #expect(store.servers.count == 1)
        #expect(store.lastError == MacRemoteServerStoreError.duplicateURL.localizedDescription)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "OppiMacTests.remoteServers.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw RemoteStoreTestError.defaultsUnavailable
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private enum RemoteStoreTestError: Error {
    case defaultsUnavailable
}
