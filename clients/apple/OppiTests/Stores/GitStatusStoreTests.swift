import Foundation
import Testing
@testable import Oppi

/// Tests for GitStatusStore state management.
///
/// Uses TestURLProtocol to mock API responses instead of hitting a real server.
@Suite("GitStatusStore")
@MainActor
struct GitStatusStoreTests {

    // MARK: - Initial state

    @Test func initialStateIsEmpty() {
        let store = GitStatusStore()
        #expect(store.gitStatus == nil)
        #expect(store.isLoading == false)
        #expect(store.workspaceId == nil)
    }

    // MARK: - handleGitStatusPush

    @Test func pushUpdatesStatusForMatchingWorkspace() {
        let store = GitStatusStore()
        store.loadInitial(workspaceId: "ws-1", apiClient: makeMockAPIClient(), gitStatusEnabled: false)

        let status = makeGitStatus(branch: "main", dirtyCount: 3)
        store.handleGitStatusPush(workspaceId: "ws-1", status: status)

        #expect(store.gitStatus?.branch == "main")
        #expect(store.gitStatus?.dirtyCount == 3)
    }

    @Test func pushIgnoresStatusForDifferentWorkspace() {
        let store = GitStatusStore()
        store.loadInitial(workspaceId: "ws-1", apiClient: makeMockAPIClient(), gitStatusEnabled: false)

        let status = makeGitStatus(branch: "feature", dirtyCount: 5)
        store.handleGitStatusPush(workspaceId: "ws-OTHER", status: status)

        #expect(store.gitStatus == nil, "Should ignore push for a different workspace")
    }

    @Test func pushOverwritesPreviousStatus() {
        let store = GitStatusStore()
        store.loadInitial(workspaceId: "ws-1", apiClient: makeMockAPIClient(), gitStatusEnabled: false)

        store.handleGitStatusPush(workspaceId: "ws-1", status: makeGitStatus(branch: "main", dirtyCount: 1))
        #expect(store.gitStatus?.dirtyCount == 1)

        store.handleGitStatusPush(workspaceId: "ws-1", status: makeGitStatus(branch: "main", dirtyCount: 5))
        #expect(store.gitStatus?.dirtyCount == 5)
    }

    @Test func pushBeforeWorkspaceIdSetIsIgnored() {
        let store = GitStatusStore()
        // No loadInitial called — workspaceId is nil
        let status = makeGitStatus(branch: "main", dirtyCount: 1)
        store.handleGitStatusPush(workspaceId: "ws-1", status: status)
        #expect(store.gitStatus == nil)
    }

    // MARK: - loadInitial with gitStatusEnabled=false

    @Test func loadInitialWithDisabledGitSetsWorkspaceButNilStatus() {
        let store = GitStatusStore()
        store.loadInitial(workspaceId: "ws-1", apiClient: makeMockAPIClient(), gitStatusEnabled: false)

        #expect(store.workspaceId == "ws-1")
        #expect(store.gitStatus == nil)
        #expect(store.isLoading == false)
    }

    // MARK: - reset

    @Test func resetClearsAllState() {
        let store = GitStatusStore()
        store.loadInitial(workspaceId: "ws-1", apiClient: makeMockAPIClient(), gitStatusEnabled: false)
        store.handleGitStatusPush(workspaceId: "ws-1", status: makeGitStatus(branch: "main", dirtyCount: 1))

        store.reset()

        #expect(store.gitStatus == nil)
        #expect(store.workspaceId == nil)
        #expect(store.isLoading == false)
    }

    @Test func pushAfterResetIsIgnored() {
        let store = GitStatusStore()
        store.loadInitial(workspaceId: "ws-1", apiClient: makeMockAPIClient(), gitStatusEnabled: false)
        store.reset()

        store.handleGitStatusPush(workspaceId: "ws-1", status: makeGitStatus(branch: "main", dirtyCount: 1))
        #expect(store.gitStatus == nil, "Push after reset should be ignored (workspaceId is nil)")
    }

    // MARK: - Workspace switch

    @Test func switchingWorkspaceIgnoresOldPushes() {
        let store = GitStatusStore()
        store.loadInitial(workspaceId: "ws-1", apiClient: makeMockAPIClient(), gitStatusEnabled: false)

        // Switch to ws-2
        store.loadInitial(workspaceId: "ws-2", apiClient: makeMockAPIClient(), gitStatusEnabled: false)

        // Old ws-1 push arrives late
        store.handleGitStatusPush(workspaceId: "ws-1", status: makeGitStatus(branch: "old", dirtyCount: 99))
        #expect(store.gitStatus == nil, "Push for old workspace should be ignored after switch")
        #expect(store.workspaceId == "ws-2")
    }

    @Test func switchingWorkspaceClearsStaleGitStatus() {
        let store = GitStatusStore()
        store.loadInitial(workspaceId: "ws-1", apiClient: makeMockAPIClient(), gitStatusEnabled: false)
        store.handleGitStatusPush(workspaceId: "ws-1", status: makeGitStatus(branch: "main", dirtyCount: 5))
        #expect(store.gitStatus != nil)

        // Switch to ws-2 with git enabled — stale ws-1 status should be cleared immediately
        store.loadInitial(workspaceId: "ws-2", apiClient: makeMockAPIClient(), gitStatusEnabled: true)
        #expect(store.gitStatus == nil, "Stale status from previous workspace should be cleared on switch")
    }

    @Test func reloadingSameWorkspacePreservesStatus() {
        let store = GitStatusStore()
        store.loadInitial(workspaceId: "ws-1", apiClient: makeMockAPIClient(), gitStatusEnabled: false)
        store.handleGitStatusPush(workspaceId: "ws-1", status: makeGitStatus(branch: "main", dirtyCount: 5))
        #expect(store.gitStatus?.dirtyCount == 5)

        // Reload same workspace — should keep existing status (avoid flash)
        store.loadInitial(workspaceId: "ws-1", apiClient: makeMockAPIClient(), gitStatusEnabled: true)
        #expect(store.gitStatus?.dirtyCount == 5, "Same workspace reload should preserve existing status")
    }

    // MARK: - Helpers

    private func makeMockAPIClient() -> APIClient {
        // Create an APIClient with a mock URLSession that won't actually make requests
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "http://localhost:1234")!, // swiftlint:disable:this force_unwrapping
            token: "test-token",
            configuration: config
        )
    }

    private func makeGitStatus(branch: String, dirtyCount: Int) -> GitStatus {
        GitStatus(
            isGitRepo: true,
            branch: branch,
            headSha: "abc1234",
            ahead: 0,
            behind: 0,
            dirtyCount: dirtyCount,
            untrackedCount: 0,
            stagedCount: 0,
            files: [],
            totalFiles: dirtyCount,
            addedLines: 0,
            removedLines: 0,
            stashCount: 0,
            lastCommitMessage: "test commit",
            lastCommitDate: nil,
            recentCommits: []
        )
    }
}
