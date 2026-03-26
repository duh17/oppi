import Foundation
import Testing
@testable import Oppi

// swiftlint:disable force_unwrapping

@Suite("ServerSelection")
struct ServerSelectionTests {

    // MARK: - Resolve

    @Test func resolveWithNoServersReturnsNil() {
        let result = ServerSelection.resolve(selectedId: nil, from: [])
        #expect(result == nil)
    }

    @Test func resolveWithNoSelectionReturnsFirst() {
        let servers = makeServers("sha256:aaa", "sha256:bbb")
        let result = ServerSelection.resolve(selectedId: nil, from: servers)
        #expect(result?.id == "sha256:aaa")
    }

    @Test func resolveWithValidSelectionReturnsMatch() {
        let servers = makeServers("sha256:aaa", "sha256:bbb")
        let result = ServerSelection.resolve(selectedId: "sha256:bbb", from: servers)
        #expect(result?.id == "sha256:bbb")
    }

    @Test func resolveWithStaleSelectionFallsBackToFirst() {
        let servers = makeServers("sha256:aaa", "sha256:bbb")
        let result = ServerSelection.resolve(selectedId: "sha256:gone", from: servers)
        #expect(result?.id == "sha256:aaa")
    }

    @Test func resolveSingleServerNoSelection() {
        let servers = makeServers("sha256:only")
        let result = ServerSelection.resolve(selectedId: nil, from: servers)
        #expect(result?.id == "sha256:only")
    }

    @Test func resolveSingleServerWithMatchingSelection() {
        let servers = makeServers("sha256:only")
        let result = ServerSelection.resolve(selectedId: "sha256:only", from: servers)
        #expect(result?.id == "sha256:only")
    }

    @Test func resolveUsesArrayOrderNotSortOrder() {
        // Array has "second" first even though its sortOrder is 1
        let servers = [
            makeServer(id: "sha256:second", sortOrder: 1),
            makeServer(id: "sha256:first", sortOrder: 0),
        ]
        let result = ServerSelection.resolve(selectedId: nil, from: servers)
        #expect(result?.id == "sha256:second")
    }

    @Test func resolveEmptyStringSelectionFallsBackToFirst() {
        let servers = makeServers("sha256:aaa")
        let result = ServerSelection.resolve(selectedId: "", from: servers)
        #expect(result?.id == "sha256:aaa")
    }

    // MARK: - Task Identity

    @Test func taskIdentityIncludesServerAndRange() {
        let id = ServerSelection.taskIdentity(selectedId: "sha256:aaa", range: 7)
        #expect(id == "sha256:aaa-7")
    }

    @Test func taskIdentityNilServerUsesEmpty() {
        let id = ServerSelection.taskIdentity(selectedId: nil, range: 30)
        #expect(id == "-30")
    }

    @Test func taskIdentityDiffersAcrossRanges() {
        let a = ServerSelection.taskIdentity(selectedId: "sha256:x", range: 7)
        let b = ServerSelection.taskIdentity(selectedId: "sha256:x", range: 30)
        #expect(a != b)
    }

    @Test func taskIdentityDiffersAcrossServers() {
        let a = ServerSelection.taskIdentity(selectedId: "sha256:aaa", range: 7)
        let b = ServerSelection.taskIdentity(selectedId: "sha256:bbb", range: 7)
        #expect(a != b)
    }

    // MARK: - Helpers

    private func makeServer(id: String, sortOrder: Int = 0) -> PairedServer {
        PairedServer(
            from: ServerCredentials(
                host: "host.local",
                port: 7749,
                token: "sk_test",
                name: "Server",
                serverFingerprint: id
            ),
            sortOrder: sortOrder
        )!
    }

    private func makeServers(_ ids: String...) -> [PairedServer] {
        ids.enumerated().map { index, id in
            PairedServer(
                from: ServerCredentials(
                    host: "host-\(index).local",
                    port: 7749,
                    token: "sk_test",
                    name: "Server \(index)",
                    serverFingerprint: id
                ),
                sortOrder: index
            )!
        }
    }
}
