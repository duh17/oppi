import Foundation
import Testing
@testable import Oppi

/// Which saved Run on Connect commands are multiplexers, and where a folder
/// opens in each one.
@Suite("SSH terminal multiplexer detection")
@MainActor
struct SSHTerminalMultiplexerDetectionTests {
    @Test func theFirstWordNamesTheMultiplexer() {
        let herdr = [
            "herdr", "  herdr  ", "herdr --attach", "herdr\n",
            "/Users/duh/.local/bin/herdr", "herdr\tworkspace",
        ]
        for command in herdr {
            #expect(SSHTerminalMultiplexerKind.detected(in: command) == .herdr, "\(command)")
        }
        for command in ["tmux", "tmux new -A -s main", "/opt/homebrew/bin/tmux new -A -s main"] {
            #expect(SSHTerminalMultiplexerKind.detected(in: command) == .tmux, "\(command)")
        }
    }

    @Test func anythingElseIsAPlainLoginShell() {
        // A login shell, another program, a different program whose name merely
        // starts with one, and a first word this device cannot see behind a
        // quote: all keep the plain folder shell.
        for command in [nil, "", "   ", "sh -l", "htop", "herdr2", "tmuxinator new", "'herdr'", "\"tmux\"", "# herdr"] {
            #expect(SSHTerminalMultiplexerKind.detected(in: command) == nil, "\(command ?? "nil")")
        }
    }

    @Test func eachMultiplexerSaysWhereItsFoldersOpen() {
        #expect(SSHTerminalMultiplexerKind.herdr.placement == .hostTerminal)
        #expect(SSHTerminalMultiplexerKind.tmux.placement == .folderTerminal)
        // The implementation agrees with the kind it came from, so the entry
        // point decides placement and execution the same way.
        #expect(SSHTerminalMultiplexerKind.herdr.multiplexer.placement == .hostTerminal)
        #expect(SSHTerminalMultiplexerKind.tmux.multiplexer.placement == .folderTerminal)
        #expect(SSHTerminalMultiplexerKind.herdr.name == "Herdr")
        #expect(SSHTerminalMultiplexerKind.tmux.name == "tmux")
    }
}

/// Herdr's plan for a folder: focus the workspace that already has a pane
/// there, otherwise create one (or open the git worktree as one).
@Suite("Herdr folder plan")
@MainActor
struct HerdrMultiplexerTests {
    /// One snapshot envelope, as `herdr api snapshot` prints it.
    static let snapshotJSON = """
    {"id":"cli:api:snapshot","result":{"snapshot":\
    {"workspaces":[],"tabs":[],"agents":[],"panes":[]}}}
    """

    private func snapshot(
        workspaces: [(id: String, label: String, focused: Bool)] = [],
        panes: [(id: String, workspace: String, cwd: String)] = []
    ) throws -> HerdrSnapshot {
        let workspaceJSON = workspaces.map { workspace in
            """
            {"workspace_id":"\(workspace.id)","label":"\(workspace.label)","focused":\(workspace.focused)}
            """
        }.joined(separator: ",")
        let paneJSON = panes.map { pane in
            """
            {"pane_id":"\(pane.id)","workspace_id":"\(pane.workspace)","cwd":"\(pane.cwd)"}
            """
        }.joined(separator: ",")
        let json = """
        {"workspaces":[\(workspaceJSON)],"tabs":[],"agents":[],"panes":[\(paneJSON)]}
        """
        return try JSONDecoder().decode(HerdrSnapshot.self, from: Data(json.utf8))
    }

    @Test func aWorkspaceWithAPaneInTheFolderIsOnlyFocused() throws {
        let snapshot = try snapshot(
            workspaces: [("w1", "oppi", false), ("w2", "scratch", true)],
            panes: [("w1:p1", "w1", "/Users/chen/oppi"), ("w2:p2", "w2", "/Users/chen/scratch")]
        )
        let commands = try HerdrMultiplexer.commands(
            folder: "/Users/chen/oppi", label: "oppi", isWorktree: false,
            matching: ["/Users/chen/oppi"], snapshot: snapshot
        )
        #expect(commands == ["herdr workspace focus w1"])
    }

    @Test func aWorktreeWithAPaneThereIsOnlyFocused() throws {
        // The worktree is already open in Herdr: focusing it is all that is left,
        // and opening it again would be a second workspace for one folder.
        let snapshot = try snapshot(
            workspaces: [("w3", "oppi · fix-x", true)],
            panes: [("w3:p1", "w3", "/Users/chen/oppi-fix-x")]
        )
        let commands = try HerdrMultiplexer.commands(
            folder: "/Users/chen/oppi-fix-x", label: "oppi · fix-x", isWorktree: true,
            matching: ["/Users/chen/oppi-fix-x"], snapshot: snapshot
        )
        #expect(commands == ["herdr workspace focus w3"])
    }

    @Test func theFocusedWorkspaceWinsWhenSeveralHaveTheFolder() throws {
        let snapshot = try snapshot(
            workspaces: [("w1", "oppi", false), ("w2", "oppi copy", true)],
            panes: [("w1:p1", "w1", "/Users/chen/oppi"), ("w2:p2", "w2", "/Users/chen/oppi")]
        )
        #expect(
            try HerdrMultiplexer.commands(
                folder: "/Users/chen/oppi", label: "oppi", isWorktree: false,
                matching: ["/Users/chen/oppi"], snapshot: snapshot
            ) == ["herdr workspace focus w2"]
        )
    }

    @Test func aSubfolderIsNotTheFolder() throws {
        // A pane one level down is a different place to work, so the folder gets
        // its own workspace instead of borrowing that one.
        let snapshot = try snapshot(
            workspaces: [("w1", "oppi", true)],
            panes: [("w1:p1", "w1", "/Users/chen/oppi")]
        )
        let commands = try HerdrMultiplexer.commands(
            folder: "/Users/chen/oppi/Sources", label: "oppi", isWorktree: false,
            matching: ["/Users/chen/oppi/Sources"], snapshot: snapshot
        )
        #expect(commands.count == 1)
        #expect(commands[0].contains("herdr workspace create --cwd"))
    }

    @Test func aFolderWithNoPaneGetsAWorkspaceCreatedInIt() throws {
        let snapshot = try snapshot(
            workspaces: [("w1", "scratch", true)],
            panes: [("w1:p1", "w1", "/Users/chen/scratch")]
        )
        let folder = "/Users/chen/oppi"
        let commands = try HerdrMultiplexer.commands(
            folder: folder, label: "oppi", isWorktree: false, matching: [folder], snapshot: snapshot
        )
        let command = try #require(commands.first)
        #expect(commands.count == 1)
        // One word for the remote login shell, with the folder and label as
        // octal escapes it never parses.
        #expect(command.hasPrefix("sh -c '"))
        #expect(command.hasSuffix("'"))
        #expect(command.contains("herdr workspace create --cwd \"$p\" --label \"$l\" --focus"))
        #expect(command.contains(SSHTerminalRemoteShell.octalEncoded(folder)))
        #expect(command.contains(SSHTerminalRemoteShell.octalEncoded("oppi")))
        #expect(!command.contains(folder), "the folder must not be literal shell text")
    }

    @Test func aWorktreeIsOpenedAsAWorktree() throws {
        let snapshot = try snapshot(workspaces: [("w1", "scratch", true)], panes: [])
        let folder = "/Users/chen/oppi-fix-x"
        let commands = try HerdrMultiplexer.commands(
            folder: folder, label: "oppi · fix-x", isWorktree: true, matching: [folder], snapshot: snapshot
        )
        let command = try #require(commands.first)
        #expect(command.contains("herdr worktree open --path \"$p\" --label \"$l\" --focus"))
        #expect(!command.contains("workspace create"))
        #expect(command.contains(SSHTerminalRemoteShell.octalEncoded(folder)))
        #expect(command.contains(SSHTerminalRemoteShell.octalEncoded("oppi · fix-x")))
    }

    @Test func aSymlinkedFolderMatchesThePathTheHostReports() throws {
        // The workspace says `/tmp/oppi`; the host's filesystem (and so Herdr's
        // pane) says `/private/tmp/oppi`. Both spellings are the folder, so the
        // workspace that already has it is focused instead of a second one.
        let snapshot = try snapshot(
            workspaces: [("w1", "oppi", false)],
            panes: [("w1:p1", "w1", "/private/tmp/oppi")]
        )
        let commands = try HerdrMultiplexer.commands(
            folder: "/tmp/oppi", label: "oppi", isWorktree: false,
            matching: ["/tmp/oppi", "/private/tmp/oppi"], snapshot: snapshot
        )
        #expect(commands == ["herdr workspace focus w1"])
    }

    @Test func aTrailingSlashIsStillTheSameFolder() throws {
        for pane in ["/Users/chen/oppi/", "/Users/chen/oppi"] {
            let snapshot = try snapshot(
                workspaces: [("w1", "oppi", true)],
                panes: [("w1:p1", "w1", pane)]
            )
            #expect(
                try HerdrMultiplexer.commands(
                    folder: "/Users/chen/oppi", label: "oppi", isWorktree: false,
                    matching: ["/Users/chen/oppi"], snapshot: snapshot
                ) == ["herdr workspace focus w1"],
                "\(pane)"
            )
        }
        // The root folder keeps its only slash.
        #expect(HerdrSnapshot.comparablePath("/") == "/")
        #expect(HerdrSnapshot.comparablePath("/a/b/") == "/a/b")
        #expect(HerdrSnapshot.comparablePath("  /a/b  ") == "/a/b")
    }

    @Test func theLookupReadsTheHomeAndThePhysicalFolder() throws {
        let lookup = try HerdrMultiplexer.parse(SSHExecResult(
            output: Data("""
            oppi-home /Users/chen
            oppi-cwd /private/tmp/oppi
            \(Self.snapshotJSON)

            """.utf8),
            errorOutput: Data(),
            exitStatus: 0
        ))
        #expect(lookup.home == "/Users/chen")
        #expect(lookup.physicalFolder == "/private/tmp/oppi")
        #expect(lookup.snapshot == (try snapshot(workspaces: [], panes: [])))
    }

    @Test func aMissingFolderHasNoPhysicalPath() throws {
        // `cd` failed, so nothing can match and Herdr's create reports it.
        let lookup = try HerdrMultiplexer.parse(SSHExecResult(
            output: Data("oppi-home /Users/chen\noppi-cwd\n\(Self.snapshotJSON)\n".utf8),
            errorOutput: Data(),
            exitStatus: 0
        ))
        #expect(lookup.physicalFolder == nil)
    }

    @Test func aHerdrRefusalKeepsItsOwnMessage() {
        // A Herdr that is not running or refuses answers with its own error, and
        // that message is what the notice shows.
        let refused = SSHExecResult(
            output: Data(#"{"error":{"message":"herdr server is not running"}}"#.utf8),
            errorOutput: Data(),
            exitStatus: 1
        )
        #expect(throws: HerdrRemoteError.rejected("herdr server is not running")) {
            try HerdrMultiplexer.parse(refused)
        }
        let missing = SSHExecResult(output: Data(), errorOutput: Data(), exitStatus: 127)
        #expect(throws: HerdrRemoteError.notInstalled) { try HerdrMultiplexer.parse(missing) }
    }

    @Test func aNamespaceWithoutANameIsCalledAfterItsFolder() throws {
        #expect(HerdrMultiplexer.workspaceLabel("  ", folder: "/Users/chen/oppi") == "oppi")
        #expect(HerdrMultiplexer.workspaceLabel("", folder: "~/workspace/oppi") == "oppi")
        #expect(HerdrMultiplexer.workspaceLabel(" oppi · fix-x ", folder: "/x") == "oppi · fix-x")
    }

    @Test func anIDOppiWillNotSendBackIsRefused() throws {
        // Herdr's IDs are its own; a hostile snapshot cannot smuggle shell syntax
        // through the focus command.
        let json = """
        {"workspaces":[{"workspace_id":"w1; rm -rf /","label":"x","focused":true}],
         "tabs":[],"agents":[],
         "panes":[{"pane_id":"p","workspace_id":"w1; rm -rf /","cwd":"/Users/chen/oppi"}]}
        """
        let snapshot = try JSONDecoder().decode(HerdrSnapshot.self, from: Data(json.utf8))
        #expect(throws: HerdrRemoteError.unusableID) {
            try HerdrMultiplexer.commands(
                folder: "/Users/chen/oppi", label: "oppi", isWorktree: false,
                matching: ["/Users/chen/oppi"], snapshot: snapshot
            )
        }
    }

    @Test func aTildeFolderBecomesTheHostsOwnAbsolutePath() {
        // Herdr takes a path, not shell syntax: `~` is expanded from the host's
        // home that was read over SSH, never from this device's home.
        #expect(
            HerdrMultiplexer.absoluteFolder("~/workspace/oppi", home: "/Users/chen")
                == "/Users/chen/workspace/oppi"
        )
        #expect(HerdrMultiplexer.absoluteFolder("~", home: "/Users/chen") == "/Users/chen")
        #expect(HerdrMultiplexer.absoluteFolder("~/x", home: "/Users/chen/") == "/Users/chen/x")
        #expect(HerdrMultiplexer.absoluteFolder("/opt/x", home: "/Users/chen") == "/opt/x")
        #expect(HerdrMultiplexer.absoluteFolder("~/x", home: "/") == "/x")
        // No home, no guess: a wrong home opens the wrong folder.
        #expect(HerdrMultiplexer.absoluteFolder("~/x", home: "") == nil)
        #expect(HerdrMultiplexer.absoluteFolder("~/x", home: "relative/home") == nil)
        #expect(HerdrMultiplexer.absoluteFolder("relative/x", home: "/Users/chen") == nil)
        // The lookup is one word, quoted for the remote login shell.
        let lookup = try? #require(HerdrMultiplexer.lookupCommand(folder: "~/workspace/oppi"))
        #expect(lookup?.hasPrefix("sh -c '") == true)
        #expect(lookup?.contains("p=\"$HOME\"/\"$(printf \"") == true)
        #expect(lookup?.contains("pwd -P") == true)
        #expect(lookup?.contains("exec herdr api snapshot") == true)
        // A relative folder has nothing to look up.
        #expect(HerdrMultiplexer.lookupCommand(folder: "relative/x") == nil)
    }
}

/// tmux's session name and attach command for one folder.
@Suite("tmux folder session")
@MainActor
struct TmuxMultiplexerTests {
    private func target(_ folder: String, label: String = "oppi", isWorktree: Bool = false) -> SSHTerminalFolderTarget {
        SSHTerminalFolderTarget(serverHost: "mac-studio", folder: folder, label: label, isWorktree: isWorktree)
    }

    @Test func theSessionIsNamedAfterTheWorkspaceAndItsFolder() {
        let name = TmuxMultiplexer.sessionName(label: "oppi · fix-x", folder: "/Users/chen/oppi-fix-x")
        #expect(name.hasPrefix("oppi · fix-x-"))
        // Six hex digits: stable for this folder, and different for another.
        #expect(name.count == "oppi · fix-x-".count + 6)
        #expect(name == TmuxMultiplexer.sessionName(label: "oppi · fix-x", folder: "/Users/chen/oppi-fix-x"))
        #expect(name != TmuxMultiplexer.sessionName(label: "oppi · fix-x", folder: "/Users/chen/oppi"))
        // Two workspaces with the same name never share a session.
        #expect(
            TmuxMultiplexer.sessionName(label: "oppi", folder: "/one/oppi")
                != TmuxMultiplexer.sessionName(label: "oppi", folder: "/two/oppi")
        )
        // A caller with no name still gets a session.
        #expect(TmuxMultiplexer.sessionName(label: "  ", folder: "/Users/chen/oppi").hasPrefix("oppi-"))
    }

    @Test func aSessionNameCannotCarryTmuxTargetSyntax() {
        for label in ["oppi.v2", "a:b", "w1:0.1", "release/2.0:next", "two\nlines", "\u{7}bell"] {
            let name = TmuxMultiplexer.sessionName(label: label, folder: "/x")
            #expect(!name.contains("."), "\(label)")
            #expect(!name.contains(":"), "\(label)")
            #expect(name.hasSuffix("-" + TmuxMultiplexer.folderHash("/x")))
        }
        #expect(TmuxMultiplexer.sanitized("app.v2:main") == "app-v2-main")
        #expect(TmuxMultiplexer.sanitized("  spaced   name  ") == "spaced name")
        #expect(TmuxMultiplexer.sanitized("日本語 worktree") == "日本語 worktree")
        #expect(TmuxMultiplexer.sanitized(String(repeating: "a", count: 80)).count == 48)
    }

    @Test func theCommandAttachesTheFoldersSessionStartedInIt() throws {
        let command = try #require(TmuxMultiplexer().folderCommand(for: target("~/workspace/oppi")))
        #expect(command.hasPrefix("sh -c '"))
        #expect(command.hasSuffix("'"))
        // `new -A`: create the session in the folder the first time, attach it
        // after that, so the work is still there after a disconnect.
        #expect(command.contains("exec tmux new -A -s \"$s\" -c \"$p\""))
        // `~` is the host's home, built from the host's own `$HOME`.
        #expect(command.contains("p=\"$HOME\"/\"$(printf \""))
        #expect(!command.contains(NSHomeDirectory()))
        #expect(command.contains(SSHTerminalRemoteShell.octalEncoded(TmuxMultiplexer.sessionName(
            label: "oppi", folder: "~/workspace/oppi"
        ))))
    }

    @Test func aRelativeFolderHasNoCommand() {
        // A relative folder resolves against the server's working directory, so
        // there is nothing to attach a session to.
        #expect(TmuxMultiplexer().folderCommand(for: target("relative/path")) == nil)
    }

    @Test func absoluteFoldersTravelAsEscapedBytes() throws {
        let folder = "/tmp/日本語 with space"
        let command = try #require(TmuxMultiplexer().folderCommand(for: target(folder, label: "oppi")))
        #expect(command.contains(SSHTerminalRemoteShell.octalEncoded(folder)))
        #expect(!command.contains(folder))
    }
}

/// The invariant every command here depends on: the word an exec channel runs is
/// plain single-quoted text a login shell — fish included — cannot break out of,
/// whatever the server supplied.
@Suite("SSH terminal multiplexer quoting")
@MainActor
struct SSHTerminalMultiplexerQuotingTests {
    private static let hostile = [
        "/tmp/x';touch /tmp/PWN;#",
        "/tmp/quote'inside",
        "/tmp/back\\slash",
        "/tmp/double\\\\backslash",
        "/tmp/escaped\\'quote",
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
        "/tmp/ trailing space ",
        "/",
        "~",
    ]

    private func assertSafeWord(_ command: String, _ hint: String) throws {
        #expect(command.hasPrefix("sh -c '"), "\(hint)")
        #expect(command.hasSuffix("'"), "\(hint)")
        let word = String(command.dropFirst("sh -c '".count).dropLast())
        #expect(!word.contains("'"), "\(hint): a quote can close the outer word")
        #expect(!word.contains("\\'"), "\(hint): fish reads an escaped quote")
        #expect(!word.contains("\\\\"), "\(hint): a double backslash is an escape")
    }

    private func snapshot() throws -> HerdrSnapshot {
        try JSONDecoder().decode(
            HerdrSnapshot.self,
            from: Data(#"{"workspaces":[],"tabs":[],"agents":[],"panes":[]}"#.utf8)
        )
    }

    @Test func everyGeneratedCommandIsOneSafeWord() throws {
        let snapshot = try snapshot()
        for folder in Self.hostile {
            // A folder's surrounding whitespace is trimmed the way the server
            // resolves a mount, so that is the value the command must carry.
            let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = SSHTerminalFolderTarget(
                serverHost: "mac-studio", folder: folder, label: folder, isWorktree: false
            )
            try assertSafeWord(SSHTerminalFolderCommand.command(folder: folder), "plain \(folder)")
            if let command = TmuxMultiplexer().folderCommand(for: target) {
                try assertSafeWord(command, "tmux \(folder)")
                // `~` travels as the host's own home, not as the character.
                if trimmed == "~" {
                    #expect(command.contains("p=\"$HOME\"/\"$(printf \""), "tmux \(folder)")
                } else {
                    #expect(command.contains(SSHTerminalRemoteShell.octalEncoded(trimmed)), "tmux \(folder)")
                }
            }
            if let lookup = HerdrMultiplexer.lookupCommand(folder: folder) {
                try assertSafeWord(lookup, "herdr lookup \(folder)")
                if trimmed != "~" {
                    #expect(
                        lookup.contains(SSHTerminalRemoteShell.octalEncoded(trimmed)),
                        "herdr lookup \(folder)"
                    )
                }
            }
            let absolute = folder.hasPrefix("/") ? folder : "/Users/chen/oppi"
            let plans = [
                try HerdrMultiplexer.commands(
                    folder: absolute, label: folder, isWorktree: false,
                    matching: [absolute], snapshot: snapshot
                ),
                try HerdrMultiplexer.commands(
                    folder: absolute, label: folder, isWorktree: true,
                    matching: [absolute], snapshot: snapshot
                ),
            ]
            for (index, plan) in plans.enumerated() {
                let command = try #require(plan.first)
                try assertSafeWord(command, "herdr \(index) \(folder)")
                #expect(command.contains(SSHTerminalRemoteShell.octalEncoded(trimmed)), "herdr \(index) \(folder)")
                #expect(!command.contains(folder) || folder == "/", "herdr \(index) \(folder)")
            }
        }
    }

    @Test func theFolderEncoderIsExact() {
        // Three octal digits per byte, then the sentinel that keeps command
        // substitution from eating a trailing newline.
        #expect(SSHTerminalRemoteShell.octalEncoded("/A") == "\\057\\101\\170")
        #expect(SSHTerminalRemoteShell.octalEncoded("") == "\\170")
        #expect(SSHTerminalRemoteShell.octalEncoded("日") == "\\346\\227\\245\\170")
        // A rebuilt value is trimmed with `${p%x}`; the sentinel is not the value.
        #expect(SSHTerminalRemoteShell.assign("p", "/A") == "p=\"$(printf \"\\057\\101\\170\")\"; p=\"${p%x}\";")
    }
}
