import Foundation
import Testing
@testable import Oppi

@Suite("SSH terminal folder terminal")
struct SSHTerminalFolderTerminalTests {
    /// POSIX single-quote unquoting of one shell word: inside quotes every
    /// character is literal, a quote ends the run, and `\'` outside quotes is a
    /// literal quote (the `'\''` idiom). Used to prove the command carries the
    /// path and the script through unchanged, which a `$`, a space, or a quote
    /// would otherwise break.
    private func unquote(_ word: String) -> String? {
        var result = ""
        var quoted = false
        var characters = Array(word)
        var index = 0
        guard characters.first == "'" else { return nil }
        while index < characters.count {
            let character = characters[index]
            if character == "'" {
                quoted.toggle()
            } else if character == "\\", !quoted {
                index += 1
                guard index < characters.count, characters[index] == "'" else { return nil }
                result.append("'")
            } else if quoted {
                result.append(character)
            } else {
                // Anything outside quotes would be parsed by the login shell.
                return nil
            }
            index += 1
        }
        return quoted ? nil : result
    }

    @Test func aPlainPathBecomesOneQuotedWord() {
        #expect(SSHTerminalFolderCommand.shellWord("/Users/chen/oppi") == "'/Users/chen/oppi'")
        #expect(SSHTerminalFolderCommand.shellWord("a b") == "'a b'")
        #expect(SSHTerminalFolderCommand.shellWord("$HOME") == "'$HOME'")
        #expect(SSHTerminalFolderCommand.shellWord("日本語") == "'日本語'")
        // A quote closes, escapes itself, and reopens.
        #expect(SSHTerminalFolderCommand.shellWord("it's") == "'it'\\''s'")
    }

    @Test func theCommandCarriesThePathAndScriptThroughUnchanged() throws {
        for folder in [
            "/Users/chen/workspace/oppi",
            "/Users/chen/My Projects/it's $HOME/日本/ü",
            "/tmp/$(touch pwned) `id` ; rm -rf ~",
            "/tmp/a*b?[c]|d>e<f&g#h",
        ] {
            let command = SSHTerminalFolderCommand.command(folder: folder)
            #expect(command.hasPrefix("sh -c '"))
            let word = String(command.dropFirst("sh -c ".count))
            #expect(try #require(unquote(word)) == SSHTerminalFolderCommand.script(folder: folder))
            // The raw path is never a bare word in the command.
            if folder.contains(" ") || folder.contains("'") || folder.contains("$") {
                #expect(!command.contains(" \(folder)"))
            }
        }
    }

    @Test func theScriptChangesFolderThenStartsTheLoginShell() throws {
        let script = SSHTerminalFolderCommand.script(folder: "/Users/chen/oppi")
        let cd = try #require(script.range(of: "cd '/Users/chen/oppi'"))
        let exec = try #require(script.range(of: "exec \"${SHELL:-/bin/sh}\" -l"))
        #expect(cd.lowerBound < exec.lowerBound)
        // The login shell is the remote's, and a host that sets no SHELL still
        // gets a shell.
        #expect(script.contains("${SHELL:-/bin/sh}"))
    }

    @Test func aMissingFolderIsReportedInsteadOfOpeningAShellElsewhere() {
        let script = SSHTerminalFolderCommand.script(folder: "/nope/missing")
        // One printf naming the folder, on stderr, then a non-zero exit: the
        // terminal shows that line and the shell never starts elsewhere.
        #expect(script.contains("printf 'oppi: %s: no such folder\\n' '/nope/missing' >&2"))
        #expect(script.contains("exit 1"))
        #expect(script.range(of: "||") != nil)
    }

    @Test func anAbsoluteOrHomeFolderIsUsable() {
        #expect(SSHTerminalFolderCommand.isUsablePath("/Users/chen/code"))
        // The server stores workspace folders in the `~` form.
        #expect(SSHTerminalFolderCommand.isUsablePath("~/workspace/oppi"))
        #expect(SSHTerminalFolderCommand.isUsablePath("~"))
        // A relative folder resolves against the server's working directory,
        // which this device cannot know.
        #expect(!SSHTerminalFolderCommand.isUsablePath("code"))
        #expect(!SSHTerminalFolderCommand.isUsablePath(""))
        // A newline would end the line a shell reads; refuse rather than quote.
        #expect(!SSHTerminalFolderCommand.isUsablePath("/a\nb"))
        #expect(SSHTerminalFolderTarget(serverHost: "mac-studio.ts.net", folder: "~/code").isUsable)
        #expect(!SSHTerminalFolderTarget(serverHost: "", folder: "/Users/chen").isUsable)
        #expect(SSHTerminalFolderTarget(serverHost: "mac-studio", folder: "/Users/chen").isUsable)
    }

    @Test func theHomeFolderIsExpandedByTheRemoteShellNotCopied() {
        // `~` is expanded by the remote `sh`, so the folder the workspace names
        // is the folder the shell starts in, whoever the remote user is.
        #expect(SSHTerminalFolderCommand.cdArgument("~/workspace/oppi") == "\"$HOME\"/'workspace/oppi'")
        #expect(SSHTerminalFolderCommand.cdArgument("~/my files/it's") == "\"$HOME\"/'my files/it'\\''s'")
        #expect(SSHTerminalFolderCommand.cdArgument("~") == "\"$HOME\"")
        #expect(SSHTerminalFolderCommand.cdArgument("/Users/chen/oppi") == "'/Users/chen/oppi'")
        #expect(SSHTerminalFolderCommand.cdArgument("relative/path") == nil)
        #expect(SSHTerminalFolderCommand.script(folder: "~/workspace/oppi").hasPrefix("cd \"$HOME\"/'workspace/oppi' || "))
    }

    @Test func theTerminalLabelShortensTheHomeFolder() {
        let target = SSHTerminalFolderTarget(serverHost: "mac-studio", folder: NSHomeDirectory() + "/workspace/oppi")
        #expect(target.folderLabel.hasPrefix("~/"))
    }
}

@Suite("SSH terminal host match")
struct SSHTerminalHostMatchTests {
    @Test func hostNamesCompareWithoutCaseOrATrailingDot() {
        #expect(SSHTerminalHostMatch.matches("Mac-Studio.TS.NET", "mac-studio.ts.net"))
        #expect(SSHTerminalHostMatch.matches("mac-studio.ts.net.", "mac-studio.ts.net"))
        #expect(SSHTerminalHostMatch.matches(" mac-studio ", "MAC-STUDIO"))
        #expect(!SSHTerminalHostMatch.matches("mac-mini", "mac-studio"))
        #expect(!SSHTerminalHostMatch.matches("", "mac-studio"))
    }

    @Test func aTailnetShortNameMatchesItsFQDN() {
        #expect(SSHTerminalHostMatch.matches("mac-studio", "mac-studio.tail1234.ts.net"))
        #expect(SSHTerminalHostMatch.matches("mac-studio.tail1234.ts.net", "mac-studio"))
        #expect(SSHTerminalHostMatch.matches("mac-studio", "MAC-STUDIO.tail1234.ts.net."))
        // A label, not a substring, and two full names must be equal.
        #expect(!SSHTerminalHostMatch.matches("studio", "mac-studio.tail1234.ts.net"))
        #expect(!SSHTerminalHostMatch.matches("mac-studio.local", "mac-studio.tail1234.ts.net"))
    }

    private func profile(_ host: String, startup: String? = nil) -> SSHTerminalProfile {
        SSHTerminalProfile(host: host, username: "chen", startupCommand: startup)
    }

    @Test func theHostWithNoRunOnConnectWinsThenTheFirstSavedOne() {
        let withCommand = profile("mac-studio.tail1234.ts.net", startup: "herdr")
        let plain = profile("Mac-Studio", startup: nil)
        let other = profile("mac-mini", startup: nil)
        #expect(
            SSHTerminalHostMatch.bestMatch(
                in: [withCommand, plain, other], serverHost: "mac-studio.tail1234.ts.net"
            )?.id == plain.id
        )
        // Two Run on Connect hosts: the first saved one.
        let second = profile("mac-studio", startup: "tmux new -A -s main")
        #expect(
            SSHTerminalHostMatch.bestMatch(
                in: [withCommand, second, other], serverHost: "mac-studio.tail1234.ts.net"
            )?.id == withCommand.id
        )
    }

    @Test func noSavedHostServingTheServerIsNoMatch() {
        #expect(SSHTerminalHostMatch.bestMatch(in: [profile("mac-mini")], serverHost: "mac-studio.ts.net") == nil)
        // An unconfigured host (no username) cannot serve a folder terminal.
        let unconfigured = SSHTerminalProfile(host: "mac-studio.ts.net")
        #expect(SSHTerminalHostMatch.bestMatch(in: [unconfigured], serverHost: "mac-studio.ts.net") == nil)
    }
}
