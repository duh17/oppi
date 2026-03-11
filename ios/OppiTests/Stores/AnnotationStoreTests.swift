import Foundation
import Testing
@testable import Oppi

typealias AnnotationMockURLProtocol = TestURLProtocol

@Suite("AnnotationStore")
@MainActor
struct AnnotationStoreTests {

    // MARK: - Initial state

    @Test func initialStateIsEmpty() {
        let store = AnnotationStore(sessionId: "s1", workspaceId: "w1")
        #expect(store.annotations.isEmpty)
        #expect(store.isLoading == false)
        #expect(store.error == nil)
    }

    // MARK: - Derived counts

    @Test func pendingCountMatchesPendingAnnotations() async {
        let store = await loadStore(resolutions: ["pending", "pending", "accepted", "rejected"])
        #expect(store.pendingCount == 2)
    }

    @Test func acceptedCountMatchesAcceptedAnnotations() async {
        let store = await loadStore(resolutions: ["accepted", "accepted", "pending"])
        #expect(store.acceptedCount == 2)
    }

    @Test func rejectedCountMatchesRejectedAnnotations() async {
        let store = await loadStore(resolutions: ["rejected", "pending", "rejected", "rejected"])
        #expect(store.rejectedCount == 3)
    }

    @Test func allCountsZeroWhenEmpty() {
        let store = AnnotationStore(sessionId: "s1", workspaceId: "w1")
        #expect(store.pendingCount == 0)
        #expect(store.acceptedCount == 0)
        #expect(store.rejectedCount == 0)
    }

    // MARK: - annotationsByFile grouping

    @Test func annotationsByFileGroupsAndSortsByFilename() async {
        let store = await loadStoreWithAnnotations([
            annotationJSON(id: "a1", file: "src/z.ts"),
            annotationJSON(id: "a2", file: "src/a.ts"),
            annotationJSON(id: "a3", file: "src/z.ts"),
            annotationJSON(id: "a4", file: "src/m.ts"),
        ])

        let groups = store.annotationsByFile
        #expect(groups.count == 3)
        #expect(groups[0].file == "src/a.ts")
        #expect(groups[1].file == "src/m.ts")
        #expect(groups[2].file == "src/z.ts")
        #expect(groups[2].annotations.count == 2)
    }

    @Test func annotationsByFileEmptyWhenNoAnnotations() {
        let store = AnnotationStore(sessionId: "s1", workspaceId: "w1")
        #expect(store.annotationsByFile.isEmpty)
    }

    // MARK: - setOffline

    @Test func setOfflineSetsError() {
        let store = AnnotationStore(sessionId: "s1", workspaceId: "w1")
        store.setOffline()
        #expect(store.error == "Server is offline")
    }

    // MARK: - load

    @Test func loadPopulatesAnnotations() async {
        let store = AnnotationStore(sessionId: "s1", workspaceId: "w1")
        let client = makeMockClient()
        defer { AnnotationMockURLProtocol.handler = nil }

        AnnotationMockURLProtocol.handler = { _ in
            mockJSON("""
            {
                "annotations": [
                    \(annotationJSON(id: "a1", file: "f1.ts", severity: "error")),
                    \(annotationJSON(id: "a2", file: "f2.ts", severity: "warn"))
                ]
            }
            """)
        }

        await store.load(api: client)

        #expect(store.annotations.count == 2)
        #expect(store.annotations[0].id == "a1")
        #expect(store.annotations[1].id == "a2")
        #expect(store.isLoading == false)
        #expect(store.error == nil)
    }

    @Test func loadSetsErrorOnFailure() async {
        let store = AnnotationStore(sessionId: "s1", workspaceId: "w1")
        let client = makeMockClient()
        defer { AnnotationMockURLProtocol.handler = nil }

        AnnotationMockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        await store.load(api: client)

        #expect(store.annotations.isEmpty)
        #expect(store.error != nil)
        #expect(store.isLoading == false)
    }

    // MARK: - resolve

    @Test func resolveUpdatesAnnotationInPlace() async {
        let store = await loadStore(resolutions: ["pending", "pending"])
        let client = makeMockClient()
        defer { AnnotationMockURLProtocol.handler = nil }

        // Grab the actual ID assigned during load.
        let targetId = store.annotations[0].id

        AnnotationMockURLProtocol.handler = { _ in
            mockJSON("""
            {"annotation": \(annotationJSON(id: "\(targetId)", resolution: "accepted"))}
            """)
        }

        await store.resolve(annotationId: targetId, resolution: "accepted", api: client)

        #expect(store.annotations[0].isAccepted == true)
        #expect(store.annotations[1].isPending == true, "Other annotations unchanged")
        #expect(store.acceptedCount == 1)
        #expect(store.pendingCount == 1)
    }

    @Test func resolveIgnoresUnknownAnnotationId() async {
        let store = await loadStore(resolutions: ["pending"])
        let client = makeMockClient()
        defer { AnnotationMockURLProtocol.handler = nil }

        AnnotationMockURLProtocol.handler = { _ in
            mockJSON("""
            {"annotation": \(annotationJSON(id: "unknown", resolution: "accepted"))}
            """)
        }

        await store.resolve(annotationId: "unknown", resolution: "accepted", api: client)

        #expect(store.annotations.count == 1)
        #expect(store.annotations[0].isPending == true, "Original untouched")
    }

    // MARK: - addComment

    @Test func addCommentAppendsToAnnotation() async {
        let store = await loadStoreWithAnnotations([
            annotationJSON(id: "a1"),
        ])
        let client = makeMockClient()
        defer { AnnotationMockURLProtocol.handler = nil }

        let commentsBefore = store.annotations[0].comments.count

        AnnotationMockURLProtocol.handler = { _ in
            mockJSON("""
            {"comment": {"id": "c-new", "source": "human", "text": "looks good", "createdAt": 9999}}
            """)
        }

        await store.addComment(annotationId: "a1", text: "looks good", api: client)

        #expect(store.annotations[0].comments.count == commentsBefore + 1)
        let added = store.annotations[0].comments.last
        #expect(added?.id == "c-new")
        #expect(added?.isHuman == true)
    }

    @Test func addCommentIgnoresUnknownAnnotationId() async {
        let store = await loadStoreWithAnnotations([
            annotationJSON(id: "a1"),
        ])
        let client = makeMockClient()
        defer { AnnotationMockURLProtocol.handler = nil }

        let commentsBefore = store.annotations[0].comments.count

        AnnotationMockURLProtocol.handler = { _ in
            mockJSON("""
            {"comment": {"id": "c1", "source": "human", "text": "hi", "createdAt": 1}}
            """)
        }

        await store.addComment(annotationId: "nonexistent", text: "hi", api: client)

        #expect(store.annotations[0].comments.count == commentsBefore, "Original untouched")
    }

    // MARK: - Helpers

    /// Load a store with annotations at the given resolutions (auto-generates IDs).
    private func loadStore(resolutions: [String]) async -> AnnotationStore {
        let jsons = resolutions.enumerated().map { i, res in
            annotationJSON(id: "a\(i)", resolution: res)
        }
        return await loadStoreWithAnnotations(jsons)
    }

    /// Load a store with the given annotation JSON fragments.
    private func loadStoreWithAnnotations(_ fragments: [String]) async -> AnnotationStore {
        let store = AnnotationStore(sessionId: "s1", workspaceId: "w1")
        let client = makeMockClient()

        let joined = fragments.joined(separator: ",\n")
        AnnotationMockURLProtocol.handler = { _ in
            mockJSON("""
            {"annotations": [\(joined)]}
            """)
        }

        await store.load(api: client)
        AnnotationMockURLProtocol.handler = nil
        return store
    }

    private func makeMockClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "http://localhost:9999")!, // swiftlint:disable:this force_unwrapping
            token: "test-token",
            configuration: config
        )
    }

    private func annotationJSON(
        id: String = "a1",
        file: String = "src/main.ts",
        severity: String = "warn",
        resolution: String = "pending"
    ) -> String {
        """
        {
            "id": "\(id)",
            "file": "\(file)",
            "startLine": 1,
            "endLine": 10,
            "severity": "\(severity)",
            "codeSnippet": "const x = 1;",
            "comments": [],
            "resolution": "\(resolution)",
            "createdAt": 1000
        }
        """
    }
}

private func mockJSON(_ json: String) -> (Data, HTTPURLResponse) {
    let data = json.data(using: .utf8)! // swiftlint:disable:this force_unwrapping
    let response = HTTPURLResponse(
        url: URL(string: "http://localhost:9999")!, // swiftlint:disable:this force_unwrapping
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )! // swiftlint:disable:this force_unwrapping
    return (data, response)
}
