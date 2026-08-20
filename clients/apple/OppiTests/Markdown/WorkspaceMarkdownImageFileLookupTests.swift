import Foundation
import Testing
@testable import Oppi

@Suite("Workspace markdown image file lookup")
struct WorkspaceMarkdownImageFileLookupTests {
    @Test func resolvedWorktreeLoadsFromThatCheckoutAndDoesNotRetry() async throws {
        let recorder = FetchRecorder(resultsByWorktree: [
            "wt_feature": .success(Data([1, 2, 3])),
        ])

        let data = try await WorkspaceMarkdownImageFileLookup.fetch(
            workspaceID: "ws-1",
            path: "relative.png",
            sourceSessionResolved: true,
            sourceSessionWorktreeID: "wt_feature",
            fetchWorkspaceFile: recorder.fetch
        )

        #expect(data == Data([1, 2, 3]))
        #expect(recorder.calls == [
            .init(workspaceID: "ws-1", path: "relative.png", worktreeId: "wt_feature"),
        ])
    }

    @Test func worktree404FallsBackToMainCheckout() async throws {
        let recorder = FetchRecorder(resultsByWorktree: [
            "wt_feature": .failure(APIError.server(status: 404, message: "not found")),
            nil: .success(Data([9])),
        ])

        let data = try await WorkspaceMarkdownImageFileLookup.fetch(
            workspaceID: "ws-1",
            path: "relative.png",
            sourceSessionResolved: true,
            sourceSessionWorktreeID: "wt_feature",
            fetchWorkspaceFile: recorder.fetch
        )

        #expect(data == Data([9]))
        #expect(recorder.calls == [
            .init(workspaceID: "ws-1", path: "relative.png", worktreeId: "wt_feature"),
            .init(workspaceID: "ws-1", path: "relative.png", worktreeId: nil),
        ])
    }

    @Test func codedWorktree404FallsBackToMainCheckout() async throws {
        let recorder = FetchRecorder(resultsByWorktree: [
            "wt_feature": .failure(APIError.codedServer(
                status: 404,
                message: "not found",
                code: "not_found"
            )),
            nil: .success(Data([4])),
        ])

        let data = try await WorkspaceMarkdownImageFileLookup.fetch(
            workspaceID: "ws-1",
            path: "docs/chart.png",
            sourceSessionResolved: true,
            sourceSessionWorktreeID: "wt_feature",
            fetchWorkspaceFile: recorder.fetch
        )

        #expect(data == Data([4]))
        #expect(recorder.calls.map(\.worktreeId) == [Optional("wt_feature"), nil])
    }

    @Test func missingSourceSessionFetchesMainOnce() async throws {
        let recorder = FetchRecorder(resultsByWorktree: [
            nil: .success(Data([7])),
        ])

        let data = try await WorkspaceMarkdownImageFileLookup.fetch(
            workspaceID: "ws-1",
            path: "relative.png",
            sourceSessionResolved: false,
            sourceSessionWorktreeID: nil,
            fetchWorkspaceFile: recorder.fetch
        )

        #expect(data == Data([7]))
        #expect(recorder.calls.map(\.worktreeId) == [String?.none])
    }

    @Test func foreignSourceSessionFetchesMainOnce() async throws {
        let recorder = FetchRecorder(resultsByWorktree: [
            nil: .success(Data([8])),
        ])

        let data = try await WorkspaceMarkdownImageFileLookup.fetch(
            workspaceID: "ws-1",
            path: "relative.png",
            sourceSessionResolved: false,
            sourceSessionWorktreeID: "wt_other_workspace",
            fetchWorkspaceFile: recorder.fetch
        )

        #expect(data == Data([8]))
        #expect(recorder.calls.map(\.worktreeId) == [String?.none])
    }

    @Test func worktree500DoesNotFallBack() async {
        let recorder = FetchRecorder(resultsByWorktree: [
            "wt_feature": .failure(APIError.server(status: 500, message: "boom")),
            nil: .success(Data([1])),
        ])

        await #expect(throws: APIError.self) {
            try await WorkspaceMarkdownImageFileLookup.fetch(
                workspaceID: "ws-1",
                path: "relative.png",
                sourceSessionResolved: true,
                sourceSessionWorktreeID: "wt_feature",
                fetchWorkspaceFile: recorder.fetch
            )
        }
        #expect(recorder.calls.map(\.worktreeId) == ["wt_feature"])
    }

    @Test func timeoutDoesNotFallBack() async {
        let recorder = FetchRecorder(resultsByWorktree: [
            "wt_feature": .failure(URLError(.timedOut)),
            nil: .success(Data([1])),
        ])

        await #expect(throws: URLError.self) {
            try await WorkspaceMarkdownImageFileLookup.fetch(
                workspaceID: "ws-1",
                path: "relative.png",
                sourceSessionResolved: true,
                sourceSessionWorktreeID: "wt_feature",
                fetchWorkspaceFile: recorder.fetch
            )
        }
        #expect(recorder.calls.map(\.worktreeId) == ["wt_feature"])
    }

    @Test func mainCheckout404DoesNotRetry() async {
        let recorder = FetchRecorder(resultsByWorktree: [
            nil: .failure(APIError.server(status: 404, message: "not found")),
        ])

        await #expect(throws: APIError.self) {
            try await WorkspaceMarkdownImageFileLookup.fetch(
                workspaceID: "ws-1",
                path: "relative.png",
                sourceSessionResolved: true,
                sourceSessionWorktreeID: nil,
                fetchWorkspaceFile: recorder.fetch
            )
        }
        #expect(recorder.calls.map(\.worktreeId) == [String?.none])
    }

    @Test func explicitMainWorktree404DoesNotRetry() async {
        let recorder = FetchRecorder(resultsByWorktree: [
            "main": .failure(APIError.server(status: 404, message: "not found")),
            nil: .success(Data([1])),
        ])

        await #expect(throws: APIError.self) {
            try await WorkspaceMarkdownImageFileLookup.fetch(
                workspaceID: "ws-1",
                path: "relative.png",
                sourceSessionResolved: true,
                sourceSessionWorktreeID: "main",
                fetchWorkspaceFile: recorder.fetch
            )
        }
        #expect(recorder.calls.map(\.worktreeId) == ["main"])
    }

    @Test func worktree404ThenMain404PropagatesTheMainError() async {
        let recorder = FetchRecorder(resultsByWorktree: [
            "wt_feature": .failure(APIError.server(status: 404, message: "worktree missing")),
            nil: .failure(APIError.server(status: 404, message: "main missing")),
        ])

        do {
            _ = try await WorkspaceMarkdownImageFileLookup.fetch(
                workspaceID: "ws-1",
                path: "relative.png",
                sourceSessionResolved: true,
                sourceSessionWorktreeID: "wt_feature",
                fetchWorkspaceFile: recorder.fetch
            )
            Issue.record("Expected the main-checkout 404 to propagate")
        } catch let APIError.server(status, message) {
            #expect(status == 404)
            #expect(message == "main missing")
        } catch {
            Issue.record("Expected APIError.server, got \(error)")
        }
        #expect(recorder.calls.map(\.worktreeId) == [Optional("wt_feature"), nil])
    }
}

private final class FetchRecorder: @unchecked Sendable {
    struct Call: Equatable, Sendable {
        var workspaceID: String
        var path: String
        var worktreeId: String?
    }

    private let resultsByWorktree: [WorktreeKey: Result<Data, Error>]
    private(set) var calls: [Call] = []

    init(resultsByWorktree: [String?: Result<Data, Error>]) {
        var mapped: [WorktreeKey: Result<Data, Error>] = [:]
        for (worktreeId, result) in resultsByWorktree {
            mapped[WorktreeKey(worktreeId)] = result
        }
        self.resultsByWorktree = mapped
    }

    func fetch(workspaceID: String, path: String, worktreeId: String?) async throws -> Data {
        calls.append(Call(workspaceID: workspaceID, path: path, worktreeId: worktreeId))
        guard let result = resultsByWorktree[WorktreeKey(worktreeId)] else {
            Issue.record("Unexpected fetch worktreeId: \(String(describing: worktreeId))")
            throw APIError.invalidResponse
        }
        return try result.get()
    }
}

private struct WorktreeKey: Hashable {
    var worktreeId: String?

    init(_ worktreeId: String?) {
        self.worktreeId = worktreeId
    }
}
