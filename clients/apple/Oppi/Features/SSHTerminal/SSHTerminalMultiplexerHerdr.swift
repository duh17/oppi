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

    /// What one side command reports: the host's home folder, the folder as the
    /// host's own filesystem spells it, and Herdr's snapshot.
    struct Lookup: Equatable {
        let home: String
        /// The folder's physical path (`pwd -P`), or nil when it is not there.
        let physicalFolder: String?
        let snapshot: HerdrSnapshot
    }

    func openInHostTerminal(_ target: SSHTerminalFolderTarget, on channel: SSHTerminalChannel) async throws {
        let lookup = try await Self.lookup(folder: target.folder, on: channel)
        guard let folder = Self.absoluteFolder(target.folder, home: lookup.home) else {
            throw SSHTerminalMultiplexerFailure.noHomeFolder
        }
        var matching = [folder]
        if let physical = lookup.physicalFolder { matching.append(physical) }
        for command in try Self.commands(
            folder: folder,
            label: target.label,
            isWorktree: target.isWorktree,
            matching: matching,
            snapshot: lookup.snapshot
        ) {
            try HerdrRemote.check(try await channel.run(command))
        }
    }

    /// One exec channel for the whole lookup: the host's `$HOME`, the folder's
    /// physical path, then the snapshot.
    ///
    /// Herdr's CLI takes paths, not shell syntax, so `~` is expanded here from
    /// the host's own home. `pwd -P` gives the path the host's filesystem
    /// reports, which is what Herdr puts on a pane: a mount reached through a
    /// symlink (`/tmp` on macOS, a linked home) then matches its own workspace
    /// instead of opening a second one. A folder that is not there has no
    /// physical path, so nothing matches and Herdr's create fails with its own
    /// message.
    static func lookupCommand(folder: String) -> String? {
        guard let word = SSHTerminalRemoteShell.folderWord(folder) else { return nil }
        let script = SSHTerminalRemoteShell.assign("p", expression: word)
            + " printf \"oppi-home %s\\n\" \"$HOME\";"
            + " if cd \"$p\" 2>/dev/null; then printf \"oppi-cwd %s\\n\" \"$(pwd -P)\";"
            + " else printf \"oppi-cwd\\n\"; fi;"
            + " exec \(HerdrRemote.snapshotCommand)"
        return SSHTerminalRemoteShell.word(script)
    }

    /// Herdr's snapshot and the folder's physical path, with one short retry: the
    /// client attached moments ago on this same connection, so its socket server
    /// may still be starting. A Herdr that is genuinely not there fails both
    /// times and reaches the person as a notice over the terminal.
    static func lookup(folder: String, on channel: SSHTerminalChannel) async throws -> Lookup {
        guard let command = lookupCommand(folder: folder) else {
            throw SSHTerminalMultiplexerFailure.unusableFolder
        }
        do {
            return try parse(try await channel.run(command))
        } catch HerdrRemoteError.notInstalled {
            throw HerdrRemoteError.notInstalled
        } catch {
            try? await Task.sleep(for: .milliseconds(700))
            return try parse(try await channel.run(command))
        }
    }

    /// Reads the two header lines, then hands the rest to `HerdrRemote` as the
    /// snapshot it is.
    static func parse(_ result: SSHExecResult) throws -> Lookup {
        // A Herdr that is missing or refused comes back through here first, so
        // its message survives instead of reading as an unreadable snapshot.
        try HerdrRemote.check(result)
        let text = String(decoding: result.output, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let jsonStart = lines.firstIndex(where: { $0.hasPrefix("{") }) else {
            throw HerdrRemoteError.unreadable
        }
        let header = lines[..<jsonStart]
        guard let home = header.first(where: { $0.hasPrefix("oppi-home ") })?
            .dropFirst("oppi-home ".count) else {
            throw SSHTerminalMultiplexerFailure.noHomeFolder
        }
        let physical = header.first(where: { $0.hasPrefix("oppi-cwd") })
            .map { $0.dropFirst("oppi-cwd".count).trimmingCharacters(in: .whitespaces) }
        let snapshot = try HerdrRemote.snapshot(from: SSHExecResult(
            output: Data(lines[jsonStart...].joined(separator: "\n").utf8),
            errorOutput: result.errorOutput,
            exitStatus: result.exitStatus
        ))
        return Lookup(
            home: String(home),
            physicalFolder: physical.flatMap { $0.isEmpty ? nil : String($0) },
            snapshot: snapshot
        )
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
    /// that already has a pane in any spelling of the folder (`matching`: its
    /// logical path and its physical one), else create a workspace (or open the
    /// git worktree as one) and focus it. Each command is one word for the
    /// remote login shell, with the folder and label octal-escaped; Herdr's own
    /// IDs are validated before they are sent back (`HerdrRemote.focusCommand`),
    /// so a hostile snapshot cannot inject shell syntax either.
    ///
    /// Focusing moves the Herdr session's focus, which every client attached to
    /// the same Herdr session follows — that is what makes the folder appear on
    /// this device and anywhere else Herdr is attached.
    static func commands(
        folder: String,
        label: String,
        isWorktree: Bool,
        matching: [String],
        snapshot: HerdrSnapshot
    ) throws -> [String] {
        if let workspace = snapshot.workspace(withPaneInAny: matching) {
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
