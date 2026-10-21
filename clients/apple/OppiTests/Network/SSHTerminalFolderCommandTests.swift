import Foundation
import Testing
@testable import Oppi

/// The remote command for a folder terminal, quoted so no login shell can read
/// the folder as code.
@Suite("SSH terminal folder command")
struct SSHTerminalFolderCommandTests {
    private func word(_ folder: String) -> String {
        let command = SSHTerminalFolderCommand.command(folder: folder)
        #expect(command.hasPrefix("sh -c '"))
        #expect(command.hasSuffix("'"))
        return String(command.dropFirst("sh -c '".count).dropLast())
    }

    /// The three sequences fish reads specially inside single quotes. A word
    /// that has none of them cannot be closed early or escape a byte.
    private func assertSafeWord(_ word: String) {
        #expect(!word.contains("'"), "the outer word must not contain a quote")
        #expect(!word.contains("\\'"), "the outer word must not contain an escaped quote")
        #expect(!word.contains("\\\\"), "the outer word must not contain a double backslash")
    }

    @Test func theOuterWordCarriesNoQuoteOrEscapeSequence() {
        // The payload the review reproduced: fish turned the old `'\''` quoting
        // into an escaped quote, closed the word, and ran `touch`.
        let hostile = [
            "/tmp/x';touch /tmp/PWN;#",
            "/tmp/quote'inside",
            "/tmp/back\\slash",
            "/tmp/double\\\\backslash",
            "/tmp/dollar$(touch /tmp/PWN)",
            "/tmp/backtick`touch /tmp/PWN`",
            "/tmp/semi;touch /tmp/PWN;#",
            "/tmp/and&&touch /tmp/PWN",
            "/tmp/redirect>out",
            "/tmp/star*glob?[x]",
            "/tmp/-leading-dash",
            "/tmp/line\nbreak",
            "/tmp/dquote\"inside",
            "/tmp/日本語 フォルダ",
            "/tmp/trailing x",
            "/tmp/space at end ",
            "/",
            "~",
            "~/my files",
            "~/quote's",
            "relative/path",
            "",
        ]
        for folder in hostile {
            assertSafeWord(word(folder))
        }
    }

    @Test func everyByteOfTheFolderBecomesAnOctalEscape() {
        // `/A` is 057 101, then the sentinel 170 that keeps command substitution
        // from eating a trailing newline.
        #expect(SSHTerminalRemoteShell.octalEncoded("/A") == "\\057\\101\\170")
        #expect(SSHTerminalRemoteShell.octalEncoded("") == "\\170")
        // Non-ASCII travels as UTF-8 bytes, not as characters a shell must decode.
        #expect(SSHTerminalRemoteShell.octalEncoded("日") == "\\346\\227\\245\\170")
        // Exactly three digits per byte: a fourth would be read as text.
        #expect(SSHTerminalRemoteShell.octalEncoded("x").hasSuffix("\\170"))
        for value in ["'", "\\", "$", "`", "\n", " ", "-", "日"] {
            assertSafeWord(word("/tmp/\(value)"))
        }
    }

    @Test func theScriptChangesFolderThenStartsTheLoginShell() throws {
        let script = word("/Users/chen/oppi")
        #expect(script.contains("p=\"$(printf \"\\057\\125\\163\\145\\162\\163"))
        // The sentinel is stripped, so a folder that ends in a newline stays exact.
        #expect(script.contains("p=\"${p%x}\""))
        let cd = try #require(script.range(of: "cd \"$p\""))
        let exec = try #require(script.range(of: "exec \"${SHELL:-/bin/sh}\" -l"))
        #expect(cd.lowerBound < exec.lowerBound)
    }

    @Test func surroundingWhitespaceIsTrimmedTheWayTheServerResolvesIt() {
        // The server trims a workspace mount, so a folder written with a trailing
        // newline opens the trimmed folder rather than a name with a newline in it.
        let trailingNewline = word("/tmp/oppi\n")
        let clean = word("/tmp/oppi")
        #expect(trailingNewline == clean)
        #expect(!trailingNewline.contains("\\012"))
        // Interior newlines are real path bytes and stay.
        #expect(word("/tmp/two\nlines").contains("\\012"))
    }

    @Test func aMissingFolderIsReportedInsteadOfOpeningAShellElsewhere() {
        let script = word("/nope/missing")
        #expect(script.contains("printf \"oppi: %s: no such folder\\n\" \"$p\" >&2; exit 1"))
        // Nothing else can follow: the shell exits instead of using another folder.
        #expect(!script.contains("cd \"$HOME\""))
    }

    @Test func theHomeFormIsExpandedByTheRemoteShell() throws {
        // `~` is the host's home, so the folder is built from the remote `$HOME`
        // and never from this device's container.
        let script = word("~/my files")
        #expect(script.contains("p=\"$HOME\"/\"$(printf \""))
        #expect(script.contains("p=\"${p%x}\""))
        let bare = word("~")
        #expect(bare.contains("p=\"$HOME\"/\"$(printf \"\\170\")\""))
        // The iOS home path never travels in the command.
        #expect(!script.contains(NSHomeDirectory()))
    }

    @Test func aFolderWithANulByteIsRefused() {
        // A NUL would truncate the path wherever a shell or syscall sees it.
        let script = word("/tmp/a\0b")
        #expect(script.contains("invalid folder"))
        #expect(!script.contains("exec \"${SHELL"))
        #expect(!SSHTerminalFolderCommand.isUsablePath("/tmp/a\0b"))
    }

    @Test func aRelativeOrEmptyFolderIsRefused() {
        for folder in ["", "   ", "relative/path", "./here", "../up"] {
            let script = word(folder)
            #expect(script.contains("not an absolute folder"))
            #expect(!script.contains("exec \"${SHELL"))
        }
        #expect(!SSHTerminalFolderCommand.isUsablePath(""))
        #expect(!SSHTerminalFolderCommand.isUsablePath("relative/path"))
        #expect(SSHTerminalFolderCommand.isUsablePath("/Users/chen"))
        #expect(SSHTerminalFolderCommand.isUsablePath("~/code"))
        #expect(SSHTerminalFolderCommand.isUsablePath("~"))
    }

    @Test func aFolderIsShownAsTheServerStoresIt() {
        // A remote path: shortening `~` from this device's home names a different
        // folder on the host.
        let target = SSHTerminalFolderTarget(serverHost: "mac-studio", folder: "~/workspace/oppi")
        #expect(target.folderLabel == "~/workspace/oppi")
    }
}
