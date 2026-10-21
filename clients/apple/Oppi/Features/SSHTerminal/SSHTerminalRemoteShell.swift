import Foundation

/// Builds the one command word an SSH exec channel runs.
///
/// The SSH server hands that word to the account's *login* shell — fish, zsh,
/// or bash — before `sh` ever sees the script. fish treats `\'` inside single
/// quotes as an escaped quote, so a path quoted that way can close the word and
/// run commands on the host.
///
/// So every word built here is plain single-quoted text that contains no `'`,
/// no `\'`, and no `\\`. Each value that comes from the server — a folder, a
/// workspace name — travels as an octal escape per UTF-8 byte, and the inner
/// `sh` rebuilds it with `printf`, where quoting is ordinary POSIX. A value is
/// therefore never a word the login shell parses, whatever it holds: quotes,
/// `$()`, backticks, spaces, newlines, or non-ASCII.
enum SSHTerminalRemoteShell {
    /// Command substitution strips trailing newlines. A rebuilt value ends with
    /// this byte, and `${name%x}` removes it, so a value that ends in a newline
    /// keeps it. `sh`'s `printf` reads exactly three octal digits after a
    /// backslash — a fourth would be literal text — and the next escape always
    /// starts with its own backslash, so the boundary is unambiguous.
    static let sentinel = "x"

    /// `\NNN` (exactly three octal digits) for every UTF-8 byte, then the
    /// sentinel. The result has no `'`, so it is safe inside the outer
    /// single-quoted word.
    static func octalEncoded(_ value: String) -> String {
        var result = ""
        for byte in Array(value.utf8) {
            result += String(format: "\\%03o", byte)
        }
        return result + String(format: "\\%03o", sentinel.utf8.first ?? 0x78)
    }

    /// The `printf` word that rebuilds `value` inside the inner `sh`, sentinel
    /// still attached.
    static func decodedWord(_ value: String) -> String {
        "\"$(printf \"\(octalEncoded(value))\")\""
    }

    /// The `sh` word for a remote folder: `~` and `~/x` are built from the
    /// host's own `$HOME`, never from this device's home, which is a different
    /// folder on a different machine. Nil when the folder is neither absolute
    /// nor `~`-relative: a relative folder resolves against a working directory
    /// this device cannot know.
    static func folderWord(_ folder: String) -> String? {
        let value = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "~" { return "\"$HOME\"/" + decodedWord("") }
        if value.hasPrefix("~/") { return "\"$HOME\"/" + decodedWord(String(value.dropFirst(2))) }
        if value.hasPrefix("/") { return decodedWord(value) }
        return nil
    }

    /// A `sh` assignment that rebuilds `value` byte for byte, sentinel removed:
    /// `p="$(printf …)"; p="${p%x}";`.
    static func assign(_ name: String, _ value: String) -> String {
        assign(name, expression: decodedWord(value))
    }

    /// The same assignment for a word already built — a folder's `$HOME` form,
    /// for one, whose sentinel is still the last byte.
    static func assign(_ name: String, expression: String) -> String {
        precondition(isIdentifier(name), "a shell variable name must be an identifier")
        return "\(name)=\(expression); \(name)=\"${\(name)%\(sentinel)}\";"
    }

    /// The command word an exec channel runs: `sh` and `script` as one argument.
    static func word(_ script: String) -> String {
        // The one place the outer-word invariant is enforced. `assert` catches a
        // generator that stops escaping during development; the encoders above
        // are what keep it true in a release build.
        assert(!script.contains("'"), "an exec word must not contain a quote")
        assert(!script.contains("\\\\"), "an exec word must not contain a double backslash")
        return "sh -c '\(script)'"
    }

    private static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !name.isEmpty else { return false }
        let head = CharacterSet.letters.union(CharacterSet(charactersIn: "_"))
        let tail = head.union(CharacterSet.decimalDigits)
        return head.contains(first) && name.unicodeScalars.dropFirst().allSatisfy(tail.contains)
    }
}
