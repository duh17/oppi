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

    /// `lineBeforeCursor` is the cursor row's text left of the cursor, as the
    /// terminal drew it. Nothing after the cursor counts: a prompt that echoes
    /// what was typed (`Password: hunter2`) is no longer a prompt.
    static func matches(lineBeforeCursor: String, atShellPrompt: Bool) -> Bool {
        guard !atShellPrompt else { return false }
        var line = Substring(lineBeforeCursor)
        while let last = line.last, last.isWhitespace { line = line.dropLast() }
        guard line.last == ":" else { return false }
        // Split the text before the colon into words: `[sudo]`, `for`, and
        // `duh@host's` all become tokens to ignore.
        let words = line.dropLast().lowercased().split { !$0.isLetter && !$0.isNumber }
        return words.contains { secretWords.contains($0) }
    }
}
