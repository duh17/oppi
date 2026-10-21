import Foundation

/// The remote command for a folder terminal ("Open Terminal here").
///
/// The command is the single word an SSH exec channel runs, so it is the
/// *remote login shell* that parses it before `sh` ever sees the script. That
/// shell may be fish, zsh, or bash, and fish treats `\'` inside single quotes as
/// an escaped quote: a path quoted that way can close the word and run commands
/// on the host.
///
/// So the outer word is plain single-quoted text that contains no `'`, no `\'`,
/// and no `\\`. Every byte of the path travels to the inner `sh` as an octal
/// escape and `printf` rebuilds it there, where quoting is ordinary POSIX. The
/// folder is therefore never a word the login shell parses, whatever it holds:
/// quotes, `$()`, backticks, spaces, newlines, or non-ASCII.
enum SSHTerminalFolderCommand {
    /// Command substitution strips trailing newlines, so the encoded value ends
    /// with a byte the script removes with `${p%x}`. A folder that really ends
    /// in a newline then survives exactly.
    private static let sentinel = "x"

    /// `\NNN` (exactly three octal digits) for every UTF-8 byte, then the
    /// sentinel. Three digits are what `sh`'s `printf` reads after a backslash —
    /// a fourth digit would be literal text — and the next escape always starts
    /// with its own backslash, so the boundary is unambiguous. The result has no
    /// `'`, so it is safe inside the outer single-quoted word.
    static func octalEncoded(_ value: String) -> String {
        var result = ""
        for byte in Array(value.utf8) {
            result += String(format: "\\%03o", byte)
        }
        return result + String(format: "\\%03o", sentinel.utf8.first ?? 0x78)
    }

    /// Whether this is a folder a folder terminal can start in: an absolute
    /// path, the server's `~` form, or `~` itself. A relative path resolves
    /// against the server's working directory, which this device cannot know.
    static func isUsablePath(_ path: String) -> Bool {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\0") else { return false }
        return value == "~" || value.hasPrefix("~/") || value.hasPrefix("/")
    }

    /// The `printf` that rebuilds `value` inside the inner `sh`.
    private static func decoded(_ value: String) -> String {
        "\"$(printf \"\(octalEncoded(value))\")\""
    }

    /// The script `sh -c` runs, before it is quoted into one word: change
    /// directory, say so and exit non-zero when the folder is missing — never
    /// opening a shell somewhere else — and then replace itself with the login
    /// shell on the TTY.
    ///
    /// `~` is expanded by the remote `sh` from `$HOME`, not by this device and
    /// not from the iOS container, which has a different home. Surrounding
    /// whitespace is trimmed the way the server resolves a workspace mount
    /// (`resolveHostPath`), so the folder that opens is the folder the workspace
    /// names.
    static func script(folder: String) -> String {
        let value = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        // A NUL cannot survive a shell word or a path; refuse rather than let a
        // shell truncate the folder at it.
        guard !folder.contains("\0") else {
            return "printf \"oppi: %s: invalid folder\\n\" >&2; exit 1"
        }
        let target: String
        if value == "~" {
            target = "\"$HOME\"/\(decoded(""))"
        } else if value.hasPrefix("~/") {
            target = "\"$HOME\"/\(decoded(String(value.dropFirst(2))))"
        } else if value.hasPrefix("/") {
            target = decoded(value)
        } else {
            // Nothing to change to: report it and end instead of guessing.
            return "p=\(decoded(value)); p=\"${p%x}\";"
                + " printf \"oppi: %s: not an absolute folder\\n\" \"$p\" >&2; exit 1"
        }
        return "p=\(target); p=\"${p%x}\"; cd \"$p\" ||"
            + " { printf \"oppi: %s: no such folder\\n\" \"$p\" >&2; exit 1; };"
            + " exec \"${SHELL:-/bin/sh}\" -l"
    }

    /// The SSH exec command, the analog of `ssh -t host 'command'`: `sh` and the
    /// script as one argument.
    static func command(folder: String) -> String {
        let script = script(folder: folder)
        // The invariant the octal encoding buys: nothing in the script can close
        // the outer word or be read as an escape by fish.
        assert(!script.contains("'"), "a folder script must not contain a quote")
        assert(!script.contains("\\\\"), "a folder script must not contain a double backslash")
        return "sh -c '\(script)'"
    }
}
