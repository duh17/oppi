import SwiftUI
import UIKit

/// Chat composition's builder and presenter for destinations the timeline requests.
///
/// The timeline raises a typed `ChatTimelineDestinationRequest`; this type owns the app-service
/// environment those screens need and the presentation policy. The environment sets are the
/// ones the timeline assembled before this moved: the commit detail sheet gets the full
/// connection store set plus a fresh `AppNavigation` and empty `QuickCommentTemplateStore`;
/// file viewers get the API client, audio player, and session store.
@MainActor
struct ChatTimelineDestinationPresenter {
    let connection: ServerConnection
    let audioPlayer: AudioPlayerService
    let composerDraftStore: ComposerDraftStore?

    func open(_ request: ChatTimelineDestinationRequest) {
        switch request.destination {
        case .commitDetail(let sha):
            presentCommitDetail(sha: sha, request: request)
        case .workspaceFile(let pill):
            presentWorkspaceFile(for: pill, request: request)
        }
    }

    private func presentCommitDetail(sha: String, request: ChatTimelineDestinationRequest) {
        let presenter = request.presenter
        let commit = GitCommitSummary(sha: sha, message: "", date: "")
        let view = TimelineCommitDetailHost(
            workspaceId: request.workspaceId,
            commit: commit,
            onDismiss: { [weak presenter] in
                presenter?.dismiss(animated: true)
            },
            composerDraftStore: composerDraftStore
        )
        .environment(\.apiClient, connection.apiClient)
        .environment(connection)
        .environment(connection.chatState)
        .environment(connection.sessionStore)
        .environment(connection.audioPlayer)
        .environment(connection.gitStatusStore)
        .environment(connection.fileIndexStore)
        .environment(connection.messageQueueStore)
        .environment(connection.askRequestStore)
        .environment(AppNavigation())
        .environment(QuickCommentTemplateStore(templates: []))
        .environment(\.reviewCommentSelectionScope, request.reviewCommentSelectionScope)

        let host = UIHostingController(rootView: view)
        FullScreenViewerPresentationPolicy.configureLargePresentation(
            host,
            traitCollection: request.sourceView.traitCollection
        )
        presenter.present(host, animated: true)
    }

    private func presentWorkspaceFile(for pill: UserMessagePathPill, request: ChatTimelineDestinationRequest) {
        guard let apiClient = connection.apiClient else { return }

        let view = fileContent(for: pill, request: request)
            .environment(\.apiClient, apiClient)
            .environment(audioPlayer)
            .environment(connection.sessionStore)
            .environment(\.reviewCommentSelectionScope, request.reviewCommentSelectionScope)

        let host = UIHostingController(rootView: view)
        let navigation = UINavigationController(rootViewController: host)
        FullScreenViewerPresentationPolicy.configureLargePresentation(
            navigation,
            traitCollection: request.sourceView.traitCollection
        )
        request.presenter.present(navigation, animated: true)
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

struct TimelineCommitDetailHost: View {
    let workspaceId: String
    let commit: GitCommitSummary
    let onDismiss: () -> Void
    var composerDraftStore: ComposerDraftStore? = nil
    var testingQuickActionDestination: QuickActionSessionNavDestination? = nil

    var body: some View {
        NavigationStack {
            CommitDetailView(
                workspaceId: workspaceId,
                commit: commit,
                testingQuickActionDestination: testingQuickActionDestination
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onDismiss) {
                        Image(systemName: FullScreenViewerNavigationChrome.DismissMode.modal.systemImageName)
                    }
                    .accessibilityLabel(FullScreenViewerNavigationChrome.DismissMode.modal.accessibilityLabel)
                    .accessibilityIdentifier("chat.commit-detail.dismiss")
                }
            }
        }
        .environment(\.composerDraftStore, composerDraftStore)
        .modifier(TimelineCommitThemeEnvironment())
    }
}

struct TimelineCommitThemeEnvironment: ViewModifier {
    @State private var themeID = ThemeRuntimeState.currentThemeID()

    func body(content: Content) -> some View {
        content
            .environment(\.theme, themeID.appTheme)
            .environment(\.themeID, themeID)
            .onReceive(NotificationCenter.default.publisher(for: .oppiThemeDidChange)) { _ in
                themeID = ThemeRuntimeState.currentThemeID()
            }
    }
}
