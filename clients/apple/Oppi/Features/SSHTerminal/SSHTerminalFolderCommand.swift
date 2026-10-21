import Foundation

/// The remote command for a folder terminal ("Open Terminal here").
///
/// The command is the single word an SSH exec channel runs, so it is the
/// *remote login shell* that parses it before `sh` ever sees the script. That
/// shell may be fish, zsh, or bash. `SSHTerminalRemoteShell` owns that quoting
/// rule; this type builds the script the plain folder shell runs in it.
enum SSHTerminalFolderCommand {
    /// Whether this is a folder a folder terminal can start in: an absolute
    /// path, the server's `~` form, or `~` itself. A relative path resolves
    /// against the server's working directory, which this device cannot know.
    static func isUsablePath(_ path: String) -> Bool {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\0") else { return false }
        return value == "~" || value.hasPrefix("~/") || value.hasPrefix("/")
    }

    /// The script `sh -c` runs, before it is quoted into one word: change
    /// directory, say so and exit non-zero when the folder is missing — never
    /// opening a shell somewhere else — and then replace itself with the login
    /// shell on the TTY.
    ///
    /// `~` is expanded by the remote `sh` from `$HOME`, not by this device and
    /// not from the iOS container, which has a different home. Surrounding
    /// whitespace, including a trailing newline, is trimmed the way the server
    /// resolves a workspace mount (`resolveHostPath`), so the folder that opens is
    /// the folder the workspace names.
    static func script(folder: String) -> String {
        let value = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        // A NUL cannot survive a shell word or a path; refuse rather than let a
        // shell truncate the folder at it.
        guard !folder.contains("\0") else {
            return "printf \"oppi: %s: invalid folder\\n\" >&2; exit 1"
        }
        guard let target = SSHTerminalRemoteShell.folderWord(value) else {
            // Nothing to change to: report it and end instead of guessing.
            return SSHTerminalRemoteShell.assign("p", value)
                + " printf \"oppi: %s: not an absolute folder\\n\" \"$p\" >&2; exit 1"
        }
        return SSHTerminalRemoteShell.assign("p", expression: target)
            + " cd \"$p\" || { printf \"oppi: %s: no such folder\\n\" \"$p\" >&2; exit 1; };"
            + " exec \"${SHELL:-/bin/sh}\" -l"
    }

    /// The SSH exec command, the analog of `ssh -t host 'command'`: `sh` and the
    /// script as one argument.
    static func command(folder: String) -> String {
        SSHTerminalRemoteShell.word(script(folder: folder))
    }
}
