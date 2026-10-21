import Foundation

/// Herdr as a multiplexer.
///
/// The host's own terminal already runs Herdr, so a folder opens *inside* that
/// client: over the terminal's side exec channel Oppi asks Herdr for its
/// snapshot, then focuses the workspace that already has a pane in the folder,
/// or creates one there. A chat's git worktree is opened with `herdr worktree
/// open`, so Herdr shows it as the worktree it is. The program is never typed
/// into, and the same terminal keeps serving every folder on that host.
struct HerdrMultiplexer: SSHTerminalMultiplexer {
    /// Herdr opens folders in the host's own terminal, not in one of its own.
    let placement = SSHTerminalMultiplexerPlacement.hostTerminal

    /// Herdr's CLI takes real paths: `~` is the login shell's syntax, not an
    /// argument, so read the host's own home before turning `~/x` into `/x`.
    static let homeCommand = "sh -c 'printf %s \"$HOME\"'"

    func openInHostTerminal(_ target: SSHTerminalFolderTarget, on channel: SSHTerminalChannel) async throws {
        let home = String(decoding: try await channel.run(Self.homeCommand).output, as: UTF8.self)
        guard let folder = Self.absoluteFolder(target.folder, home: home) else {
            throw SSHTerminalMultiplexerFailure.noHomeFolder
        }
        let snapshot = try await Self.snapshot(on: channel)
        for command in try Self.commands(
            folder: folder,
            label: target.label,
            isWorktree: target.isWorktree,
            snapshot: snapshot
        ) {
            try HerdrRemote.check(try await channel.run(command))
        }
    }

    /// Herdr's snapshot, with one short retry: the client attached moments ago on
    /// this same connection, so its socket server may still be starting. A Herdr
    /// that is genuinely not there fails both times and reaches the person as a
    /// notice over the terminal.
    static func snapshot(on channel: SSHTerminalChannel) async throws -> HerdrSnapshot {
        do {
            return try HerdrRemote.snapshot(from: try await channel.run(HerdrRemote.snapshotCommand))
        } catch HerdrRemoteError.notInstalled {
            throw HerdrRemoteError.notInstalled
        } catch {
            try? await Task.sleep(for: .milliseconds(700))
            return try HerdrRemote.snapshot(from: try await channel.run(HerdrRemote.snapshotCommand))
        }
    }

    /// The folder as Herdr's CLI takes it. `~` and `~/x` are built from the
    /// host's own `$HOME`; an absolute folder is already that. Nil when the home
    /// folder did not arrive, since a guessed home would open the wrong place.
    static func absoluteFolder(_ folder: String, home: String) -> String? {
        let value = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = home.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, base.hasPrefix("/") else { return nil }
        let trimmedBase = base.hasSuffix("/") && base.count > 1 ? String(base.dropLast()) : base
        // "~/x" keeps its own slash, so the root home folder must not add one.
        let root = trimmedBase == "/" ? "" : trimmedBase
        if value == "~" { return trimmedBase }
        if value.hasPrefix("~/") { return root + String(value.dropFirst(1)) }
        if value.hasPrefix("/") { return value }
        return nil
    }

    /// The CLI calls that land in `folder`, in order: focus the Herdr workspace
    /// that already has a pane there, else create a workspace (or open the git
    /// worktree as one) and focus it. Each command is one word for the remote
    /// login shell, with the folder and label octal-escaped; Herdr's own IDs are
    /// validated before they are sent back (`HerdrRemote.focusCommand`), so a
    /// hostile snapshot cannot inject shell syntax either.
    ///
    /// Focusing moves the Herdr session's focus, which every client attached to
    /// the same Herdr session follows — that is what makes the folder appear on
    /// this device and anywhere else Herdr is attached.
    static func commands(
        folder: String,
        label: String,
        isWorktree: Bool,
        snapshot: HerdrSnapshot
    ) throws -> [String] {
        if let workspace = snapshot.workspace(withPaneIn: folder) {
            guard let focus = HerdrRemote.focusCommand(.workspace(workspace.workspaceID)) else {
                throw HerdrRemoteError.unusableID
            }
            return [focus]
        }
        let name = workspaceLabel(label, folder: folder)
        let create = isWorktree
            ? "exec herdr worktree open --path \"$p\" --label \"$l\" --focus"
            : "exec herdr workspace create --cwd \"$p\" --label \"$l\" --focus"
        let script = SSHTerminalRemoteShell.assign("p", folder)
            + " " + SSHTerminalRemoteShell.assign("l", name)
            + " " + create
        return [SSHTerminalRemoteShell.word(script)]
    }

    /// What Herdr calls the workspace it opens: the Oppi workspace (and its
    /// worktree), or the folder's own name when the caller had none.
    static func workspaceLabel(_ label: String, folder: String) -> String {
        let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { return value }
        return folder.split(separator: "/").last.map(String.init) ?? folder
    }
}
