import Foundation

/// Recognizes a secret prompt from the terminal's own text so the grid can ask
/// the keyboard for secure entry. There is no flag for this in libghostty, so
/// the row left of the cursor is matched against what prompts actually print:
/// a line that ends in a colon and names a password, passphrase, or PIN as a
/// whole word.
///
///   `Password:`                          `su`, `ssh`, `mysql`
///   `[sudo] password for duh:`           `sudo`
///   `duh@host's password:`               `ssh`
///   `Enter passphrase for key '/x/id':`  `ssh-agent`
///   `Passphrase:` `PIN:`                 `gpg`, LUKS, smartcards
///   `│ Password:`                        a Herdr pane's border
///
/// Only the live screen is matched, and never while libghostty says the cursor
/// is at the shell's own input (OSC 133), where `echo Password:` is a command
/// being typed rather than a secret. One-time codes (`Verification code:`)
/// stay on the ordinary keyboard: they are read out and retyped, and secure
/// entry would only get in the way.
enum SSHTerminalPasswordPrompt {
    /// Words that name a secret. Whole words only, so `spin:` and `shipping:`
    /// are not prompts.
    private static let secretWords: Set<Substring> = ["password", "passphrase", "pin"]

    /// What prompts that echo one mark per key (`sudo-rs` with `pwfeedback`,
    /// `sudo -S`, some `ssh` builds) print after the prompt. They are the
    /// secret, not part of the prompt, so they never decide the match.
    private static let echoes: Set<Character> = ["*", "\u{2022}", "\u{25CF}"]

    /// The prompt a line is asking for a secret at, or nil. `lineBeforeCursor`
    /// is the cursor row's text left of the cursor, as the terminal drew it,
    /// trimmed of trailing spaces and of the mark a prompt echoes for each key
    /// typed. Nothing after the cursor that is not such an echo counts: a
    /// prompt that echoes what was typed (`Password: hunter2`) is no longer a
    /// prompt.
    static func prompt(inLineBeforeCursor lineBeforeCursor: String, atShellPrompt: Bool) -> String? {
        guard !atShellPrompt else { return nil }
        let text = trimmingEcho(lineBeforeCursor)
        guard text.last == ":" else { return nil }
        // Split the text before the colon into words: `[sudo]`, `for`, and
        // `duh@host's` all become tokens to ignore.
        let words = text.dropLast().lowercased().split { !$0.isLetter && !$0.isNumber }
        guard words.contains(where: { secretWords.contains($0) }) else { return nil }
        return String(text)
    }

    static func matches(lineBeforeCursor: String, atShellPrompt: Bool) -> Bool {
        prompt(inLineBeforeCursor: lineBeforeCursor, atShellPrompt: atShellPrompt) != nil
    }

    /// `line` without trailing whitespace or echoed key marks. The same trim
    /// keeps a latched prompt matching while the secret is typed into it.
    static func trimmingEcho(_ line: String) -> Substring {
        var text = Substring(line)
        while let last = text.last, last.isWhitespace || echoes.contains(last) { text = text.dropLast() }
        return text
    }
}
