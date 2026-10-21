import Foundation

/// tmux as a multiplexer.
///
/// A folder gets a terminal of its own — the registry's `(profile, folder)`
/// identity, as any folder terminal has — and that terminal attaches the
/// folder's tmux session, creating it in the folder the first time (`tmux new
/// -A`). The session outlives the connection, so tapping Terminal here again
/// after a disconnect lands back where the work was.
struct TmuxMultiplexer: SSHTerminalMultiplexer {
    /// tmux opens folders in a terminal of its own.
    let placement = SSHTerminalMultiplexerPlacement.folderTerminal

    func folderCommand(for target: SSHTerminalFolderTarget) -> String? {
        guard let folder = SSHTerminalRemoteShell.folderWord(target.folder) else { return nil }
        let session = Self.sessionName(label: target.label, folder: target.folder)
        // Both values reach the host as octal escapes and are only ever read
        // back through "$p" and "$s", so neither can be shell code.
        let script = SSHTerminalRemoteShell.assign("p", expression: folder)
            + " " + SSHTerminalRemoteShell.assign("s", session)
            + " exec tmux new -A -s \"$s\" -c \"$p\""
        return SSHTerminalRemoteShell.word(script)
    }

    /// The session a folder opens, as someone reads it in `tmux ls`: the Oppi
    /// workspace (and its worktree) plus the folder's own short hash.
    ///
    /// The hash is what keeps two workspaces that share a name — two checkouts
    /// of `oppi`, say — out of each other's session, since `tmux new -A` would
    /// otherwise attach a session that was started in the other folder. It is
    /// stable across launches, unlike `hashValue`, so the same folder always
    /// finds the same session.
    static func sessionName(label: String, folder: String) -> String {
        let name = sanitized(label)
        return "\(name.isEmpty ? "oppi" : name)-\(folderHash(folder))"
    }

    /// tmux reads `.` and `:` as target syntax (`.`, `:`, `session:window`), so
    /// neither can appear in a session name. Control characters go too; spaces
    /// and non-ASCII stay, because the name is a label someone reads.
    static func sanitized(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if scalar == "." || scalar == ":" || CharacterSet.controlCharacters.contains(scalar) {
                scalars.append("-")
            } else {
                scalars.append(scalar)
            }
        }
        let collapsed = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.trimmingCharacters(in: .whitespaces).prefix(48))
            .trimmingCharacters(in: .whitespaces)
    }

    /// FNV-1a over the folder's UTF-8 bytes, as six hex digits: stable for a
    /// folder across launches and devices.
    static func folderHash(_ folder: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in folder.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%06x", UInt32(truncatingIfNeeded: hash) & 0x00ff_ffff)
    }
}
