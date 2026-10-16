import SwiftUI
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

    private func presentCommitDetail(sha: String, request: ChatTimelineDestinationRequest) {
        let view = TimelineCommitDetailHost(
            workspaceId: request.workspaceId,
            commit: GitCommitSummary(sha: sha, message: "", date: "")
        )
        .withServerScopedEnvironment(connection)
        .environment(\.reviewCommentSelectionScope, request.reviewCommentSelectionScope)

        Router.present(
            presentation: .largeViewer(for: request.sourceView.traitCollection).inNavigation(),
            from: request.presenter
        ) { view }
    }

    private func presentWorkspaceFile(for pill: UserMessagePathPill, request: ChatTimelineDestinationRequest) {
        guard connection.apiClient != nil else { return }

        let view = TimelineFileViewerHost(content: fileContent(for: pill, request: request))
            .withServerScopedEnvironment(connection)
            .environment(\.reviewCommentSelectionScope, request.reviewCommentSelectionScope)

        Router.present(
            presentation: .largeViewer(for: request.sourceView.traitCollection).inNavigation(),
            from: request.presenter
        ) { view }
    }

    /// Upload pills open the session-origin copy the server materialized in
    /// the session's checkout. Review and repo pills open the workspace file in
    /// the session's checkout, so Edit writes where the agent works.
    func fileContent(
        for pill: UserMessagePathPill,
        request: ChatTimelineDestinationRequest
    ) -> FileBrowserContentView {
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
        return FileBrowserContentView(
            workspaceId: request.workspaceId,
            worktreeId: source == .workspaceFile ? sessionWorktreeId : nil,
            serverId: request.serverId,
            filePath: pill.path,
            fileName: pill.label,
            source: source,
            sessionId: request.sessionId,
            fileSize: nil
        )
    }
}

/// The path-pill file viewer at the root of its router navigation controller.
/// Back closes the viewer: `dismiss()` does nothing at a navigation root.
private struct TimelineFileViewerHost: View {
    let content: FileBrowserContentView
    @Environment(\.screenNavigator) private var navigator

    var body: some View {
        var content = content
        content.onBackNavigation = navigator.finish
        return content
    }
}

/// The commit viewer at the root of its router navigation controller
/// (`.inNavigation()`); a chat started from it pushes onto the same stack.
struct TimelineCommitDetailHost: View {
    let workspaceId: String
    let commit: GitCommitSummary
    var testingQuickActionDestination: QuickActionSessionNavDestination? = nil
    @Environment(\.screenNavigator) private var navigator
    /// The viewer runs its own chat stack inside the modal. A `ChatView` pushed
    /// here must not take the app's pending quick-session message (it would
    /// send it into this session) or change the app's split state underneath,
    /// so it gets a navigation of its own.
    @State private var modalNavigation = AppNavigation()

    var body: some View {
        CommitDetailView(
            workspaceId: workspaceId,
            commit: commit,
            testingQuickActionDestination: testingQuickActionDestination
        )
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: navigator.finish) {
                    Label(
                        FullScreenViewerNavigationChrome.DismissMode.modal.accessibilityLabel,
                        systemImage: FullScreenViewerNavigationChrome.DismissMode.modal.systemImageName
                    )
                }
                .accessibilityIdentifier("chat.commit-detail.dismiss")
            }
        }
        .environment(modalNavigation)
    }
}
