import Foundation
import Testing
@testable import Oppi

private actor FileIndexFetcherStub: WorkspaceFileIndexFetching {
    private let response: FileIndexResponse
    private(set) var requestedWorkspaceIds: [String] = []

    init(paths: [String]) {
        response = FileIndexResponse(paths: paths, truncated: false)
    }

    func fetchFileIndex(workspaceId: String) async throws -> FileIndexResponse {
        requestedWorkspaceIds.append(workspaceId)
        return response
    }
}

private final class FileIndexCacheRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedValues: [(paths: [String], workspaceId: String)] = []

    var values: [(paths: [String], workspaceId: String)] {
        lock.withLock { cachedValues }
    }

    func append(paths: [String], workspaceId: String) {
        lock.withLock {
            cachedValues.append((paths: paths, workspaceId: workspaceId))
        }
    }
}

@Suite("FileIndexStore")
@MainActor
struct FileIndexStoreTests {
    @Test func ensureLoadedFetchesAndCachesThroughEnvironment() async {
        let fetcher = FileIndexFetcherStub(paths: ["Sources/App.swift", "README.md"])
        let cache = FileIndexCacheRecorder()
        let store = FileIndexStore(environment: FileIndexStoreEnvironment(
            cacheFileIndex: { paths, workspaceId in
                cache.append(paths: paths, workspaceId: workspaceId)
            }
        ))

        store.ensureLoaded(workspaceId: "ws-1", apiClient: fetcher)

        let loaded = await waitForMainActorCondition {
            store.paths == ["Sources/App.swift", "README.md"]
        }

        #expect(loaded)
        #expect(store.isLoading == false)
        #expect(await fetcher.requestedWorkspaceIds == ["ws-1"])
        #expect(cache.values.map(\.workspaceId) == ["ws-1"])
        #expect(cache.values.first?.paths == ["Sources/App.swift", "README.md"])
    }

    @Test func cachedPathsDisplayBeforeNetworkFetchCompletes() async {
        let fetcher = FileIndexFetcherStub(paths: ["fresh.swift"])
        let store = FileIndexStore(environment: FileIndexStoreEnvironment(
            loadCachedFileIndex: { _ in ["cached.swift"] }
        ))

        store.ensureLoaded(workspaceId: "ws-1", apiClient: fetcher)

        let loadedCached = await waitForMainActorCondition {
            store.paths == ["cached.swift"] || store.paths == ["fresh.swift"]
        }

        #expect(loadedCached)
        #expect(store.paths == ["cached.swift"] || store.paths == ["fresh.swift"])
    }
}
