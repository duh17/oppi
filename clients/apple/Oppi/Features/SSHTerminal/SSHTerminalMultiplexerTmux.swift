import Foundation

/// tmux as a multiplexer.
///
/// A folder gets a terminal of its own — the registry's `(profile, folder)`
/// identity, as any folder terminal has — and that terminal attaches the
/// folder's tmux session, creating it there the first time (`tmux new -A`). The
/// session outlives the connection, so tapping Terminal here again after a
/// disconnect lands back where the work was.
struct TmuxMultiplexer: SSHTerminalMultiplexer {
    let name = "tmux"

    func opening(_ target: SSHTerminalFolderTarget) -> SSHTerminalMultiplexerOpening? {
        folderCommand(for: target).map { .folderTerminal(command: $0) }
    }

    func folderCommand(for target: SSHTerminalFolderTarget) -> String? {
        guard let folder = SSHTerminalRemoteShell.folderWord(target.folder) else { return nil }
        let session = Self.sessionName(label: target.label, folder: target.folder)
        // Both values reach the host as octal escapes and are only ever read
        // back through "$p" and "$s", so neither can be shell code. `cd` first,
        // then attach with no `-c`: tmux expands `#{}` and `#()` in its own
        // arguments, so a folder or label holding a `#` would otherwise be read
        // as a format, and a folder it cannot enter would quietly start the
        // session in the home folder. A new session starts in this client's
        // working directory, which is the folder by then.
        let script = SSHTerminalRemoteShell.assign("p", expression: folder)
            + " " + SSHTerminalRemoteShell.assign("s", session)
            + " cd \"$p\" || { printf \"oppi: %s: no such folder\\n\" \"$p\" >&2; exit 1; };"
            + " exec tmux new -A -s \"$s\""
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

    /// tmux reads `.` and `:` as target syntax (`.`, `:`, `session:window`) and
    /// `#` as the start of a format, so a name cannot carry one unescaped: `.`
    /// and `:` become `-`, and `#` is doubled, which is how tmux asks for a
    /// literal one. Control characters become `-`; spaces and non-ASCII stay,
    /// because the name is a label someone reads.
    ///
    /// tmux stores a doubled backslash for one it is given (0.9.5 and 3.8 both
    /// do), which is only cosmetic: the same label is looked up the same way, so
    /// a session is still found again after a disconnect.
    static func sanitized(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if scalar == "." || scalar == ":" || CharacterSet.controlCharacters.contains(scalar) {
                scalars.append("-")
            } else if scalar == "#" {
                scalars.append(contentsOf: "##".unicodeScalars)
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
