import UIKit

/// Chat composition's builder and presenter for destinations the timeline requests.
///
/// The timeline raises a typed `ChatTimelineDestinationRequest`; this type picks the screen
/// and its presentation. The router hosts it with the app root services. The chat's own
/// server connection is presenter-local: its scoped stores override the active server's.
@MainActor
struct ChatTimelineDestinationPresenter {
    let connection: ServerConnection

    func open(_ request: ChatTimelineDestinationRequest) {
        switch request.destination {
        case .commitDetail(let sha):
            presentCommitDetail(sha: sha, request: request)
        case .workspaceFile(let pill):
            presentWorkspaceFile(for: pill, request: request)
        }
    }

    /// The commit viewer at the root of its router navigation controller; a
    /// chat started from it pushes onto the same stack.
    private func presentCommitDetail(sha: String, request: ChatTimelineDestinationRequest) {
        let viewer = Self.commitViewer(
            workspaceId: request.workspaceId,
            sha: sha,
            reviewCommentSelectionScope: request.reviewCommentSelectionScope,
            connection: connection
        )
        Router.present(
            viewer,
            presentation: .largeViewer(for: request.sourceView.traitCollection).inNavigation(),
            from: request.presenter,
            theme: HostFactory.root(near: request.presenter)?.themeStore,
            onDismiss: nil
        )
    }

    /// The viewer runs its own chat stack inside the modal. A `ChatViewController`
    /// pushed there must not take the app's pending quick-session message (it
    /// would send it into this session) or change the app's split state
    /// underneath, so it gets a navigation of its own.
    static func commitViewer(
        workspaceId: String,
        sha: String,
        reviewCommentSelectionScope: ReviewCommentSelectionScope?,
        connection: ServerConnection
    ) -> CommitDetailViewController {
        let viewer = CommitDetailViewController(
            configuration: .init(
                workspaceId: workspaceId,
                commit: GitCommitSummary(sha: sha, message: "", date: ""),
                reviewCommentSelectionScope: reviewCommentSelectionScope,
                closeAccessibilityIdentifier: "chat.commit-detail.dismiss"
            ),
            connection: connection,
            apiClient: connection.apiClient,
            navigation: AppNavigation()
        )
        viewer.onClose = { [weak viewer] in
            guard let viewer else { return }
            Router.finish(viewer)
        }
        return viewer
    }

    /// The file viewer at the root of a router navigation controller; its
    /// Back closes the modal.
    private func presentWorkspaceFile(for pill: UserMessagePathPill, request: ChatTimelineDestinationRequest) {
        guard connection.apiClient != nil else { return }
        var configuration = fileContent(for: pill, request: request)
        configuration.reviewCommentSelectionScope = request.reviewCommentSelectionScope
        let viewer = FileViewerViewController(configuration: configuration, services: .init(connection: connection))
        Router.present(
            viewer,
            presentation: .largeViewer(for: request.sourceView.traitCollection).inNavigation(),
            from: request.presenter,
            theme: HostFactory.root(near: request.presenter)?.themeStore,
            onDismiss: nil
        )
    }

    /// Upload pills open the session-origin copy the server materialized in
    /// the session's checkout. Review and repo pills open the workspace file in
    /// the session's checkout, so Edit writes where the agent works.
    func fileContent(
        for pill: UserMessagePathPill,
        request: ChatTimelineDestinationRequest
    ) -> FileViewerViewController.Configuration {
        let source: FileBrowserContentSource
        if MarkdownWikiLinkRewriter.resolvedHostPath(pill.path) != nil {
            source = .hostFile
        } else if pill.kind == .uploadedFile {
            source = .sessionFile(sessionId: request.sessionId)
        } else {
            source = .workspaceFile
        }
        let session = connection.sessionStore.session(id: request.sessionId)
        let sessionWorktreeId = session?.workspaceId == request.workspaceId ? session?.worktreeId : nil
        return FileViewerViewController.Configuration(
            workspaceId: request.workspaceId,
            worktreeId: source == .workspaceFile ? sessionWorktreeId : nil,
            serverId: request.serverId,
            filePath: pill.path,
            fileName: pill.label,
            source: source,
            sessionId: request.sessionId
        )
    }
}
