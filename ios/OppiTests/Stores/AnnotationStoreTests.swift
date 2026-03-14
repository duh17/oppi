import Foundation
import Testing
@testable import Oppi

@Suite("AnnotationStore", .serialized)
struct AnnotationStoreTests {

    // MARK: - Initial state

    @Test @MainActor func initialStateIsEmpty() {
        let store = AnnotationStore(workspaceId: "w1", path: "src/main.ts")
        #expect(store.annotations.isEmpty)
        #expect(store.isLoading == false)
        #expect(store.error == nil)
        #expect(store.totalCount == 0)
    }

    // MARK: - Derived counts

    @Test func derivedCountsMatchAnnotations() async {
        let store = await loadStore(resolutions: [.pending, .pending, .accepted, .rejected])
        await MainActor.run {
            #expect(store.pendingCount == 2)
            #expect(store.acceptedCount == 1)
            #expect(store.rejectedCount == 1)
            #expect(store.totalCount == 4)
            #expect(store.allResolved == false)
        }
    }

    @Test func allResolvedWhenNoPending() async {
        let store = await loadStore(resolutions: [.accepted, .rejected])
        await MainActor.run {
            #expect(store.allResolved == true)
        }
    }

    @Test @MainActor func allResolvedFalseWhenEmpty() {
        let store = AnnotationStore(workspaceId: "w1", path: "a.ts")
        #expect(store.allResolved == false)
    }

    // MARK: - annotationsByLine grouping

    @Test func annotationsByLineGroupsCorrectly() async {
        let store = await loadStoreWithAnnotations([
            annotationJSON(id: "a1", startLine: 10),
            annotationJSON(id: "a2", startLine: 10),
            annotationJSON(id: "a3", startLine: 42),
            annotationJSON(id: "a4", side: "file", startLine: nil),
        ])

        await MainActor.run {
            let byLine = store.annotationsByLine
            #expect(byLine[10]?.count == 2)
            #expect(byLine[42]?.count == 1)
            #expect(byLine[-1]?.count == 1, "File-level annotations group under -1")
        }
    }

    @Test func annotationsForLineReturnsCorrectSubset() async {
        let store = await loadStoreWithAnnotations([
            annotationJSON(id: "a1", startLine: 5),
            annotationJSON(id: "a2", startLine: 5),
            annotationJSON(id: "a3", startLine: 20),
        ])

        await MainActor.run {
            #expect(store.annotations(forLine: 5).count == 2)
            #expect(store.annotations(forLine: 20).count == 1)
            #expect(store.annotations(forLine: 99).isEmpty)
        }
    }

    // MARK: - setOffline

    @Test @MainActor func setOfflineSetsError() {
        let store = AnnotationStore(workspaceId: "w1", path: "a.ts")
        store.setOffline()
        #expect(store.error == "Server is offline")
    }

    // MARK: - Load

    @Test func loadPopulatesAnnotations() async {
        let client = makeMockClient()
        defer { TestURLProtocol.handler = nil }

        TestURLProtocol.handler = { _ in
            mockJSON("""
            {
                "workspaceId": "w1",
                "annotations": [
                    \(self.annotationJSON(id: "a1", severity: "error")),
                    \(self.annotationJSON(id: "a2", severity: "warn"))
                ]
            }
            """)
        }

        let store = await MainActor.run { AnnotationStore(workspaceId: "w1", path: "src/main.ts") }
        await store.load(api: client)

        await MainActor.run {
            #expect(store.annotations.count == 2)
            #expect(store.annotations[0].id == "a1")
            #expect(store.annotations[0].severity == .error)
            #expect(store.isLoading == false)
            #expect(store.error == nil)
        }
    }

    @Test func loadSetsErrorOnFailure() async {
        let client = makeMockClient()
        defer { TestURLProtocol.handler = nil }

        TestURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let store = await MainActor.run { AnnotationStore(workspaceId: "w1", path: "a.ts") }
        await store.load(api: client)

        await MainActor.run {
            #expect(store.annotations.isEmpty)
            #expect(store.error != nil)
            #expect(store.isLoading == false)
        }
    }

    // MARK: - Resolve

    @Test func resolveUpdatesAnnotationInPlace() async {
        let store = await loadStoreWithAnnotations([
            annotationJSON(id: "a1", resolution: "pending"),
            annotationJSON(id: "a2", resolution: "pending"),
        ])
        let client = makeMockClient()
        defer { TestURLProtocol.handler = nil }

        TestURLProtocol.handler = { _ in
            mockJSON("""
            {"annotation": \(self.annotationJSON(id: "a1", resolution: "accepted"))}
            """)
        }

        await store.resolve(annotationId: "a1", resolution: .accepted, api: client)

        await MainActor.run {
            #expect(store.annotations[0].resolution == .accepted)
            #expect(store.annotations[1].resolution == .pending, "Other annotations unchanged")
            #expect(store.acceptedCount == 1)
            #expect(store.pendingCount == 1)
        }
    }

    // MARK: - Delete

    @Test func deleteRemovesAnnotation() async {
        let store = await loadStoreWithAnnotations([
            annotationJSON(id: "a1"),
            annotationJSON(id: "a2"),
        ])
        let client = makeMockClient()
        defer { TestURLProtocol.handler = nil }

        TestURLProtocol.handler = { _ in
            mockJSON("""
            {"deleted": true}
            """)
        }

        await store.delete(annotationId: "a1", api: client)

        await MainActor.run {
            #expect(store.annotations.count == 1)
            #expect(store.annotations[0].id == "a2")
        }
    }

    // MARK: - Model properties

    @Test func annotationAuthorProperties() {
        #expect(AnnotationAuthor.agent.isAgent == true)
        #expect(AnnotationAuthor.agent.isHuman == false)
        #expect(AnnotationAuthor.human.isHuman == true)
        #expect(AnnotationAuthor.human.displayLabel == "You")
        #expect(AnnotationAuthor.agent.displayLabel == "Agent")
    }

    @Test func annotationSeverityProperties() {
        #expect(AnnotationSeverity.error.displayLabel == "Error")
        #expect(AnnotationSeverity.warn.displayLabel == "Warning")
        #expect(AnnotationSeverity.info.displayLabel == "Info")
        #expect(AnnotationSeverity.error.iconName == "exclamationmark.triangle.fill")
    }

    @Test func annotationResolutionProperties() {
        #expect(AnnotationResolution.pending.isPending == true)
        #expect(AnnotationResolution.pending.isResolved == false)
        #expect(AnnotationResolution.accepted.isPending == false)
        #expect(AnnotationResolution.accepted.isResolved == true)
        #expect(AnnotationResolution.rejected.isResolved == true)
    }

    // MARK: - Helpers

    private func loadStore(resolutions: [AnnotationResolution]) async -> AnnotationStore {
        let jsons = resolutions.enumerated().map { i, res in
            annotationJSON(id: "a\(i)", resolution: res.rawValue)
        }
        return await loadStoreWithAnnotations(jsons)
    }

    private func loadStoreWithAnnotations(_ fragments: [String]) async -> AnnotationStore {
        let store = await MainActor.run { AnnotationStore(workspaceId: "w1", path: "src/main.ts") }
        let client = makeMockClient()

        let joined = fragments.joined(separator: ",\n")
        TestURLProtocol.handler = { _ in
            mockJSON("""
            {"workspaceId": "w1", "annotations": [\(joined)]}
            """)
        }

        await store.load(api: client)
        TestURLProtocol.handler = nil
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
        side: String = "new",
        startLine: Int? = 42,
        severity: String = "warn",
        resolution: String = "pending"
    ) -> String {
        let startLineJSON = startLine.map { "\($0)" } ?? "null"
        return """
        {
            "id": "\(id)",
            "workspaceId": "w1",
            "path": "\(file)",
            "side": "\(side)",
            "startLine": \(startLineJSON),
            "endLine": null,
            "body": "Test annotation body",
            "author": "agent",
            "sessionId": "s1",
            "severity": "\(severity)",
            "resolution": "\(resolution)",
            "createdAt": 1000,
            "updatedAt": 1000
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
