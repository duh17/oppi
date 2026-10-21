import UIKit

/// Starts a session from a review surface's quick action and shows its chat on
/// that surface's server and navigation. The chat's context bar, a commit, and
/// a changed file differ only in the API call that creates the session and in
/// what their new chat attaches; this owns the in-flight guard, the progress
/// title, the store upsert, the push, and the failure alert.
@MainActor
struct WorkspaceQuickActionLauncher {
    let connection: ServerConnection
    let apiClient: APIClient?
    let navigation: AppNavigation
    let workspaceId: String
    /// New Session's worktree; a commit is not tied to one.
    var worktreeId: String?
    /// A template launch's context session; a commit has none.
    var selectedSessionId: String?
    /// The screen showing the surface: it hosts the push and gets the alert.
    let presenter: UIViewController
    /// The surface's in-flight state, which also disables its actions.
    let isLaunching: () -> Bool
    let setProgress: (String?) -> Void
    /// A surface that pushes through its own navigator passes one; the rest
    /// push onto the presenter.
    var push: ((ChatViewController) -> Void)?

    /// New Session. `destination` attaches the surface's file or commit.
    @discardableResult
    func startEmptySession(
        _ destination: @escaping (Session) -> QuickActionSessionNavDestination
    ) async -> Bool {
        await launch(String(localized: "Starting new session…")) { api in
            let session = try await api.createWorkspaceSession(
                workspaceId: workspaceId,
                worktreeId: worktreeId
            ).session
            return (session, destination(session))
        }
    }

    /// A prompt template over `paths`.
    @discardableResult
    func createSession(
        option: WorkspaceQuickActionOption,
        paths: [String],
        commitSha: String? = nil
    ) async -> Bool {
        await launch(option.progressTitle) { api in
            let response = try await api.createWorkspaceQuickActionSession(
                workspaceId: workspaceId,
                paths: paths,
                selectedSessionId: selectedSessionId,
                worktreeId: worktreeId,
                commitSha: commitSha,
                promptTemplateName: option.promptTemplateName
            )
            return (response.session, QuickActionSessionNavDestination(
                id: response.session.id,
                inputText: response.visiblePrompt,
                filePaths: response.filePaths,
                fileDisplayPrefix: option.title
            ))
        }
    }

    /// Pushes a chat for a destination another path already has. A surface
    /// inside a chat keeps that chat's `AppNavigation`, so its chat leaves the
    /// app's alone.
    func showChat(_ destination: QuickActionSessionNavDestination) {
        let chat = ChatViewController(
            sessionId: destination.id,
            connection: connection,
            navigation: navigation,
            apiClient: apiClient,
            workspaceIdHint: workspaceId,
            initialInputText: destination.inputText,
            initialPendingFiles: destination.pendingFileReferences
        )
        if let root = HostFactory.root(near: presenter) {
            chat.traitOverrides.appRootEnvironment = root
        }
        if let push {
            push(chat)
        } else {
            Router.push(chat, from: presenter)
        }
    }

    private func launch(
        _ progressTitle: String,
        create: (APIClient) async throws -> (Session, QuickActionSessionNavDestination)
    ) async -> Bool {
        guard !isLaunching() else { return false }
        guard let apiClient else {
            WorkspaceQuickActionMenu.presentLaunchError(String(localized: "Server is offline."), from: presenter)
            return false
        }
        setProgress(progressTitle)
        defer { setProgress(nil) }
        do {
            let (session, destination) = try await create(apiClient)
            connection.sessionStore.upsert(session)
            showChat(destination)
            return true
        } catch {
            WorkspaceQuickActionMenu.presentLaunchError(error.localizedDescription, from: presenter)
            return false
        }
    }
}
