import Foundation
import Testing
@testable import Oppi

/// GitStatusStore keeps each checkout's status apart, says when one is still
/// on its way or failed, and fetches tracked checkouts again on reconnect.
@Suite("GitStatusStore")
@MainActor
struct GitStatusStoreTests {

    // MARK: - Pushes

    @Test func pushUpdatesATrackedCheckoutOnly() {
        let store = GitStatusStore()
        store.loadInitial(workspaceId: "ws-1", apiClient: nil, gitStatusEnabled: true)

        store.handleGitStatusPush(workspaceId: "ws-1", status: makeGitStatus(branch: "main", dirtyCount: 3))
        store.handleGitStatusPush(workspaceId: "ws-OTHER", status: makeGitStatus(branch: "other", dirtyCount: 5))

        #expect(store.status(workspaceId: "ws-1", worktreeId: nil)?.dirtyCount == 3)
        #expect(store.status(workspaceId: "ws-OTHER", worktreeId: nil) == nil, "No screen tracks that workspace")
        #expect(!store.tracks(workspaceId: "ws-OTHER", worktreeId: nil))
    }

    // MARK: - Checkouts side by side

    /// The owner's stuck Git pane: a chat loading its own checkout after a
    /// pinned Git pane loaded another took the store from the pane, which then
    /// read "Loading Git status…" forever. Each checkout keeps its own status.
    @Test func aLaterCheckoutDoesNotTakeAnEarlierOnesStatus() async {
        let store = GitStatusStore()
        store.loadInitial(workspaceId: "ws-1", worktreeId: nil, apiClient: StubFetcher(), gitStatusEnabled: true)
        store.loadInitial(workspaceId: "ws-1", worktreeId: "wt-feature", apiClient: StubFetcher(), gitStatusEnabled: true)
        store.loadInitial(workspaceId: "ws-2", worktreeId: nil, apiClient: StubFetcher(), gitStatusEnabled: true)
        await settle(store, [("ws-1", nil), ("ws-1", "wt-feature"), ("ws-2", nil)])

        #expect(store.status(workspaceId: "ws-1", worktreeId: nil)?.branch == "ws-1/main")
        #expect(store.status(workspaceId: "ws-1", worktreeId: WorkspaceWorktree.mainId)?.branch == "ws-1/main",
                "nil and the main worktree's id are the same checkout")
        #expect(store.status(workspaceId: "ws-1", worktreeId: "wt-feature")?.branch == "ws-1/wt-feature")
        #expect(store.status(workspaceId: "ws-2", worktreeId: nil)?.branch == "ws-2/main")
    }

    // MARK: - Awaiting, failure, retry

    @Test func awaitingUntilLoadedThenNotAwaiting() async {
        let store = GitStatusStore()
        #expect(store.isAwaitingStatus(workspaceId: "ws-1", worktreeId: nil), "Not asked for yet")
        store.loadInitial(workspaceId: "ws-1", apiClient: StubFetcher(), gitStatusEnabled: true)
        #expect(store.isAwaitingStatus(workspaceId: "ws-1", worktreeId: nil), "First fetch in flight")
        await settle(store, [("ws-1", nil)])
        #expect(!store.isAwaitingStatus(workspaceId: "ws-1", worktreeId: nil))
        #expect(store.loadError(workspaceId: "ws-1", worktreeId: nil) == nil)
    }

    /// A failed first fetch ends the wait with its reason (the panel's Retry),
    /// and the retry's success clears it.
    @Test func aFailedFetchReportsItsErrorAndARetryClearsIt() async {
        let store = GitStatusStore()
        store.loadInitial(workspaceId: "ws-1", apiClient: StubFetcher(fails: true), gitStatusEnabled: true)
        await settle(store, [("ws-1", nil)])
        #expect(store.status(workspaceId: "ws-1", worktreeId: nil) == nil)
        #expect(store.loadError(workspaceId: "ws-1", worktreeId: nil) != nil, "Failed, not loading forever")

        store.loadInitial(workspaceId: "ws-1", apiClient: StubFetcher(), gitStatusEnabled: true)
        #expect(store.loadError(workspaceId: "ws-1", worktreeId: nil) == nil, "Retrying reads as loading again")
        await settle(store, [("ws-1", nil)])
        #expect(store.status(workspaceId: "ws-1", worktreeId: nil)?.branch == "ws-1/main")
        #expect(store.loadError(workspaceId: "ws-1", worktreeId: nil) == nil)
    }

    /// A Git pane restored before the connection has a client stays on its way,
    /// and the event stream's connect fetches it.
    @Test func aCheckoutAskedForWithoutAClientLoadsOnConnect() async {
        let store = GitStatusStore()
        store.loadInitial(workspaceId: "ws-1", worktreeId: "wt-feature", apiClient: nil, gitStatusEnabled: true)
        #expect(store.isAwaitingStatus(workspaceId: "ws-1", worktreeId: "wt-feature"))
        #expect(store.loadError(workspaceId: "ws-1", worktreeId: "wt-feature") == nil)

        store.refreshTracked(apiClient: StubFetcher())
        await settle(store, [("ws-1", "wt-feature")])
        #expect(store.status(workspaceId: "ws-1", worktreeId: "wt-feature")?.branch == "ws-1/wt-feature")
    }

    /// A reconnect fetches every tracked checkout again: pushes sent while the
    /// stream was down are lost.
    @Test func refreshTrackedFetchesEveryTrackedCheckout() async {
        let store = GitStatusStore()
        store.loadInitial(workspaceId: "ws-1", apiClient: nil, gitStatusEnabled: true)
        store.loadInitial(workspaceId: "ws-2", apiClient: nil, gitStatusEnabled: true)
        store.loadInitial(workspaceId: "ws-off", apiClient: nil, gitStatusEnabled: false)
        store.handleGitStatusPush(workspaceId: "ws-1", status: makeGitStatus(branch: "stale", dirtyCount: 9))

        store.refreshTracked(apiClient: StubFetcher())
        await settle(store, [("ws-1", nil), ("ws-2", nil)])
        #expect(store.status(workspaceId: "ws-1", worktreeId: nil)?.branch == "ws-1/main")
        #expect(store.status(workspaceId: "ws-2", worktreeId: nil)?.branch == "ws-2/main")
        #expect(store.status(workspaceId: "ws-off", worktreeId: nil) == nil, "Git status off stays off")
    }

    // MARK: - Disabled and invalidation

    @Test func disabledGitIsTrackedWithNoStatusAndNotAwaiting() {
        let store = GitStatusStore()
        store.loadInitial(workspaceId: "ws-1", apiClient: StubFetcher(), gitStatusEnabled: false)
        #expect(store.tracks(workspaceId: "ws-1", worktreeId: nil))
        #expect(store.status(workspaceId: "ws-1", worktreeId: nil) == nil)
        #expect(!store.isAwaitingStatus(workspaceId: "ws-1", worktreeId: nil))
    }

    @Test func invalidationKeepsTheShownStatusWhenRefreshCannotStart() {
        let store = GitStatusStore()
        store.loadInitial(workspaceId: "ws-1", apiClient: nil, gitStatusEnabled: true)
        store.handleGitStatusPush(workspaceId: "ws-1", status: makeGitStatus(branch: "main", dirtyCount: 3))

        store.invalidate(workspaceId: "ws-1")

        #expect(store.status(workspaceId: "ws-1", worktreeId: nil)?.dirtyCount == 3, "Invalidation should not blank the bar")
        #expect(!store.isAwaitingStatus(workspaceId: "ws-1", worktreeId: nil))
    }

    @Test func invalidationWithDisabledGitClearsTheShownStatus() {
        let store = GitStatusStore()
        store.loadInitial(workspaceId: "ws-1", apiClient: nil, gitStatusEnabled: true)
        store.handleGitStatusPush(workspaceId: "ws-1", status: makeGitStatus(branch: "main", dirtyCount: 3))

        store.invalidate(workspaceId: "ws-1", gitStatusEnabled: false)

        #expect(store.status(workspaceId: "ws-1", worktreeId: nil) == nil)
    }

    @Test func reloadingACheckoutKeepsItsStatusWhileFetching() {
        let store = GitStatusStore()
        store.loadInitial(workspaceId: "ws-1", apiClient: nil, gitStatusEnabled: true)
        store.handleGitStatusPush(workspaceId: "ws-1", status: makeGitStatus(branch: "main", dirtyCount: 5))

        store.loadInitial(workspaceId: "ws-1", apiClient: StubFetcher(), gitStatusEnabled: true)
        #expect(store.status(workspaceId: "ws-1", worktreeId: nil)?.dirtyCount == 5, "No flash while it refetches")
        #expect(!store.isAwaitingStatus(workspaceId: "ws-1", worktreeId: nil))
    }

    // MARK: - Helpers

    /// Waits until none of `checkouts` is still fetching.
    private func settle(_ store: GitStatusStore, _ checkouts: [(String, String?)]) async {
        for _ in 0..<200 {
            let busy = checkouts.contains { workspaceId, worktreeId in
                store.status(workspaceId: workspaceId, worktreeId: worktreeId) == nil
                    && store.loadError(workspaceId: workspaceId, worktreeId: worktreeId) == nil
            }
            if !busy { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The store's fetches did not settle")
    }

    /// Answers each checkout with a branch named after it, or fails, without a URLSession.
    private struct StubFetcher: WorkspaceGitStatusFetching {
        var fails = false

        struct Failure: Error {}

        func getGitStatus(workspaceId: String, worktreeId: String?) async throws -> GitStatus {
            if fails { throw Failure() }
            return GitStatus(
                isGitRepo: true, branch: "\(workspaceId)/\(worktreeId ?? "nil")", headSha: "abc1234",
                ahead: 0, behind: 0, dirtyCount: 0, untrackedCount: 0, stagedCount: 0, files: [], totalFiles: 0,
                addedLines: 0, removedLines: 0, stashCount: 0, lastCommitMessage: nil, lastCommitDate: nil, recentCommits: []
            )
        }
    }

    private func makeGitStatus(branch: String, dirtyCount: Int) -> GitStatus {
        GitStatus(
            isGitRepo: true, branch: branch, headSha: "abc1234", ahead: 0, behind: 0, dirtyCount: dirtyCount,
            untrackedCount: 0, stagedCount: 0, files: [], totalFiles: dirtyCount, addedLines: 0, removedLines: 0,
            stashCount: 0, lastCommitMessage: "test commit", lastCommitDate: nil, recentCommits: []
        )
    }
}
