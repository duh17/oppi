import Foundation

/// Workspace-relative markdown image fetch using the same checkout rules as
/// wiki-link file lookup.
///
/// Chat timeline images still go through `APIClient.fetchWorkspaceFile` (the
/// workspace raw endpoint), never session raw. A missing or foreign source
/// session lists main (`nil`). A non-main worktree 404 then retries main so a
/// gitignored file can still load.
enum WorkspaceMarkdownImageFileLookup {
    typealias FetchWorkspaceFile = @Sendable (
        _ workspaceID: String,
        _ path: String,
        _ worktreeId: String?
    ) async throws -> Data

    static func fetch(
        workspaceID: String,
        path: String,
        sourceSessionResolved: Bool,
        sourceSessionWorktreeID: String?,
        fetchWorkspaceFile: FetchWorkspaceFile
    ) async throws -> Data {
        let firstCheckout = WorkspaceWikiLinkFileLookupPolicy.firstCheckout(
            sourceSessionResolved: sourceSessionResolved,
            sourceSessionWorktreeID: sourceSessionWorktreeID
        )
        do {
            return try await fetchWorkspaceFile(workspaceID, path, firstCheckout)
        } catch {
            let shouldRetryMain = WorkspaceWikiLinkFileLookupPolicy.isDeterministicAbsence(error)
                && WorkspaceWikiLinkFileLookupPolicy.shouldFallBackToMainCheckout(
                    worktreeID: firstCheckout,
                    outcome: .absent
                )
            guard shouldRetryMain else { throw error }
            return try await fetchWorkspaceFile(workspaceID, path, nil)
        }
    }
}
