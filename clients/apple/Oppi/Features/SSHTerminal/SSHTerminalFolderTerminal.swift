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

    /// What the bar, the … menu header, and the host list call this terminal.
    var folderLabel: String { (folder as NSString).abbreviatingWithTildeInPath }
}

/// The remote command for a folder terminal.
enum SSHTerminalFolderCommand {
    /// One POSIX shell word. An inner quote closes the quotes, escapes itself,
    /// and reopens them (`'` becomes `'\''`), which fish, zsh, and bash all read
    /// back as the same character.
    static func shellWord(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The `cd` argument for a host folder: an absolute path as one quoted
    /// word, or `$HOME` plus the quoted remainder for the `~` form the server
    /// stores workspace folders in. A relative path resolves against the
    /// server's working directory, which this device cannot know, so it has no
    /// terminal here.
    static func cdArgument(_ folder: String) -> String? {
        let path = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.contains("\n"), !path.contains("\0") else { return nil }
        if path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") { return "\"$HOME\"/" + shellWord(String(path.dropFirst(2))) }
        guard path.hasPrefix("/") else { return nil }
        return shellWord(path)
    }

    /// Whether this is a folder a folder terminal can start in.
    static func isUsablePath(_ path: String) -> Bool { cdArgument(path) != nil }

    /// The SSH exec command (the analog of `ssh -t host 'command'`): `sh -c`
    /// receives the script as one quoted word, so the user's login shell (fish
    /// included) only sees `sh` and an argument and never parses the path.
    static func command(folder: String) -> String {
        "sh -c " + shellWord(script(folder: folder))
    }

    /// The script `sh -c` runs, before it is quoted into one word: change
    /// directory, say so and exit non-zero when the folder is missing — never
    /// opening a shell somewhere else — and then replace itself with the login
    /// shell on the TTY.
    static func script(folder: String) -> String {
        let path = shellWord(folder)
        guard let target = cdArgument(folder) else {
            return "printf 'oppi: %s: not an absolute folder\\n' \(path) >&2; exit 1"
        }
        return "cd \(target) || { printf 'oppi: %s: no such folder\\n' \(path) >&2; exit 1; };"
            + " exec \"${SHELL:-/bin/sh}\" -l"
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

    /// The saved host to open a folder terminal on. Several matches prefer a
    /// host with no Run on Connect, since that one is the plain machine, then
    /// the first saved one.
    static func bestMatch(in profiles: [SSHTerminalProfile], serverHost: String) -> SSHTerminalProfile? {
        let candidates = profiles.filter { $0.isConfigured && matches($0.host, serverHost) }
        guard !candidates.isEmpty else { return nil }
        return candidates.first { $0.startupCommand == nil || $0.startupCommand?.isEmpty == true }
            ?? candidates.first
    }
}

/// Resolves the folder a workspace screen's Terminal opens: the workspace's
/// root, or the session's own worktree root when it has one.
@MainActor
enum SSHTerminalFolderResolve {
    static func folder(workspace: Workspace, worktreeId: String?, apiClient: APIClient?) async -> String? {
        let root = workspace.hostMount?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let worktreeId, worktreeId != WorkspaceWorktree.mainId, let apiClient else {
            return root.isEmpty ? nil : root
        }
        // The worktree route is best effort (older servers lack it); the
        // workspace root is still the folder such a session runs in.
        let worktrees = (try? await apiClient.listWorkspaceWorktrees(workspaceId: workspace.id)) ?? []
        let path = worktrees.first { $0.id == worktreeId }?.path
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? (root.isEmpty ? nil : root) : path
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

        var message: String {
            switch self {
            case .noFolder:
                String(localized: "This workspace has no host folder Oppi can open a terminal in. A sandbox workspace runs inside its sandbox, and a folder relative to the server's working directory cannot be resolved here.")
            case .unknownWorkspace:
                String(localized: "Oppi has not loaded this workspace yet. Open the workspace once, then try again.")
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
