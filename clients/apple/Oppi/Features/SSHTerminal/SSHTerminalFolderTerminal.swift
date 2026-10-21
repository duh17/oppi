import Foundation
import UIKit

/// A login shell on a saved host, started in one folder.
///
/// This is the "Open Terminal here" terminal. It is not the host's own
/// terminal: the host may run a Run on Connect command (Herdr, tmux), and that
/// terminal keeps running. A folder terminal always starts the person's login
/// shell in the folder, so nothing is typed into a program that is already
/// running there.
struct SSHTerminalFolderTarget: Equatable {
    /// The paired server's host, which is matched against the saved SSH hosts.
    let serverHost: String
    /// Absolute host folder. A relative or empty path never starts a shell.
    let folder: String

    var isUsable: Bool {
        SSHTerminalFolderCommand.isUsablePath(folder)
            && !serverHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the bar, the … menu header, and the host list call this terminal:
    /// the folder as the server stores it. It is a remote path, so this device's
    /// home — and any `~` shortening from it — would name a different folder.
    var folderLabel: String { folder }
}

extension SSHTerminalFolderTarget {
    /// A workspace's folder for "Open Terminal here", or nil when it has none a
    /// shell can start in. A sandbox workspace runs inside its sandbox, so its
    /// mount is not a folder on the host; a relative mount resolves against the
    /// server's working directory, which this device cannot know.
    static func workspace(_ workspace: Workspace) -> String? {
        guard workspace.runtime != .sandbox else { return nil }
        let mount = workspace.hostMount?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return SSHTerminalFolderCommand.isUsablePath(mount) ? mount : nil
    }
}

/// Which saved SSH host serves a paired server's workspace.
enum SSHTerminalHostMatch {
    /// Host names compare the way a tailnet reports them: case-insensitive, a
    /// trailing dot ignored, and a short name (`mac-studio`) matching the same
    /// machine's FQDN (`mac-studio.tail1234.ts.net`).
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalize(lhs)
        let right = normalize(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        let leftIsName = left.contains(".")
        let rightIsName = right.contains(".")
        // Two names must be equal; only a bare short name and a name can match.
        guard leftIsName != rightIsName else { return false }
        let short = leftIsName ? right : left
        let name = leftIsName ? left : right
        guard !short.isEmpty, !short.contains(":") else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: true).first.map(String.init) == short
    }

    static func normalize(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    /// The saved host to open a folder terminal on, best first: an exact host
    /// name beats a short name matched against its FQDN, and within one kind a
    /// host with no Run on Connect beats one with a command, then the order
    /// they were saved in.
    static func bestMatch(in profiles: [SSHTerminalProfile], serverHost: String) -> SSHTerminalProfile? {
        let server = normalize(serverHost)
        guard !server.isEmpty else { return nil }
        var exact: [SSHTerminalProfile] = []
        var byName: [SSHTerminalProfile] = []
        for profile in profiles where profile.isConfigured {
            let host = normalize(profile.host)
            guard !host.isEmpty else { continue }
            if host == server {
                exact.append(profile)
            } else if matches(host, server) {
                byName.append(profile)
            }
        }
        let candidates = exact.isEmpty ? byName : exact
        guard !candidates.isEmpty else { return nil }
        return candidates.first(where: hasNoStartupCommand) ?? candidates.first
    }

    private static func hasNoStartupCommand(_ profile: SSHTerminalProfile) -> Bool {
        profile.startupCommand?.isEmpty ?? true
    }
}

/// Where a workspace screen's Terminal opens, or why it cannot.
enum SSHTerminalFolderResolution: Equatable {
    case folder(String)
    /// The workspace names no host folder this device can use.
    case noFolder
    /// The lookup failed for a reason worth showing instead of guessing.
    case failure(String)
}

/// Resolves the folder a workspace screen's Terminal opens: the workspace's
/// root, or the session's own worktree root when it has one.
@MainActor
enum SSHTerminalFolderResolve {
    static func folder(
        workspace: Workspace,
        worktreeId: String?,
        apiClient: APIClient?
    ) async -> SSHTerminalFolderResolution {
        let root = workspace.hostMount?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let worktreeId, worktreeId != WorkspaceWorktree.mainId, let apiClient else {
            return root.isEmpty ? .noFolder : .folder(root)
        }
        do {
            let worktrees = try await apiClient.listWorkspaceWorktrees(workspaceId: workspace.id)
            return resolution(worktreeId: worktreeId, root: root, worktrees: worktrees, lookupError: nil)
        } catch {
            return resolution(worktreeId: worktreeId, root: root, worktrees: [], lookupError: error)
        }
    }

    /// The decision, apart from the request: a server without the worktree route
    /// (404) still runs the session in the workspace root, but any other failure
    /// is shown rather than silently opening a terminal in the wrong folder.
    nonisolated static func resolution(
        worktreeId: String?,
        root: String,
        worktrees: [WorkspaceWorktree],
        lookupError: (any Error)?
    ) -> SSHTerminalFolderResolution {
        let resolvedRoot = root.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback: SSHTerminalFolderResolution = resolvedRoot.isEmpty ? .noFolder : .folder(resolvedRoot)
        guard let worktreeId, worktreeId != WorkspaceWorktree.mainId else { return fallback }
        if let lookupError {
            guard isUnsupportedRoute(lookupError) else {
                return .failure(failureMessage(lookupError))
            }
            return fallback
        }
        let path = worktrees.first { $0.id == worktreeId }?.path
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? fallback : .folder(path)
    }

    /// An older server (or a sandbox workspace) has no worktree route: 404 or a
    /// "not supported" answer means the workspace root is still where sessions
    /// of that workspace run.
    nonisolated static func isUnsupportedRoute(_ error: any Error) -> Bool {
        if let apiError = error as? APIError, case .server(let status, _) = apiError {
            return status == 404
        }
        return false
    }

    nonisolated private static func failureMessage(_ error: any Error) -> String {
        String(localized: "Oppi could not look up this session's worktree folder: \(error.localizedDescription)")
    }
}

/// The two entry points (a workspace, a chat) open a folder terminal here.
@MainActor
enum SSHTerminalFolderEntry {
    /// Opens the folder terminal for `target`, or the Add Host form prefilled
    /// with the server's host when no saved host serves it. Returns false when
    /// SSH Terminal is off, so its entry points stay hidden.
    @discardableResult
    static func open(
        _ target: SSHTerminalFolderTarget,
        from presenter: UIViewController,
        missingReason: SSHTerminalFolderFailure = .noFolder
    ) -> Bool {
        guard AppPreferences.Experiments.sshTerminalEnabled else { return false }
        guard target.isUsable else {
            present(target, failure: missingReason, from: presenter)
            return true
        }
        let profiles = SSHTerminalProfileStore().load()
        if let profile = SSHTerminalHostMatch.bestMatch(in: profiles, serverHost: target.serverHost) {
            Router.push(SSHTerminalFolderViewController(profile: profile, target: target), from: presenter)
        } else {
            // Add Host, with the server's host filled in and nothing invented
            // for the username. Saving it continues into the folder terminal.
            Router.push(
                SSHTerminalSetupViewController(profileID: nil, host: target.serverHost, folderTerminal: target),
                from: presenter
            )
        }
        return true
    }

    /// Failure copy for an entry point that cannot name a folder or a host.
    enum SSHTerminalFolderFailure {
        case noFolder
        case unknownWorkspace
        case lookupFailed(String)

        var message: String {
            switch self {
            case .noFolder:
                String(localized: "This workspace has no host folder Oppi can open a terminal in. A sandbox workspace runs inside its sandbox, and a folder relative to the server's working directory cannot be resolved here.")
            case .unknownWorkspace:
                String(localized: "Oppi has not loaded this workspace yet. Open the workspace once, then try again.")
            case .lookupFailed(let reason):
                reason
            }
        }
    }

    private static func present(
        _ target: SSHTerminalFolderTarget,
        failure: SSHTerminalFolderFailure,
        from presenter: UIViewController
    ) {
        let alert = UIAlertController(title: String(localized: "Cannot Open Terminal"), message: failure.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        Router.topPresenter(from: presenter).present(alert, animated: true)
    }
}
