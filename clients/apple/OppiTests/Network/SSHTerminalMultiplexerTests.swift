import Foundation
import Testing
@testable import Oppi

/// Which saved Run on Connect commands are multiplexers, and how each one opens
/// a folder.
@Suite("SSH terminal multiplexer detection")
@MainActor
struct SSHTerminalMultiplexerDetectionTests {
    @Test func theFirstWordNamesTheMultiplexer() {
        let herdr = [
            "herdr", "  herdr  ", "herdr --attach", "herdr\n",
            "/Users/duh/.local/bin/herdr", "herdr\tworkspace",
            "herdr session attach main", "  herdr\tattach", "/opt/homebrew/bin/herdr",
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
        for command in [nil, "", "   ", "sh -l", "htop", "herdr2", "tmuxinator new", "'herdr'", "\"tmux\"", "# herdr", "herdrx", "echo herdr"] {
            #expect(SSHTerminalMultiplexerKind.detected(in: command) == nil, "\(command ?? "nil")")
        }
    }

    @Test func eachMultiplexerSaysHowItOpensAFolder() throws {
        let target = SSHTerminalFolderTarget(
            serverHost: "mac-studio", folder: "/Users/chen/oppi", label: "oppi"
        )
        for kind in SSHTerminalMultiplexerKind.allCases {
            switch kind.multiplexer.opening(target) {
            case .folderTerminal(let command)?:
                #expect(kind == .tmux, "only tmux needs a terminal of its own")
                #expect(command.hasPrefix("sh -c '"))
            case .inHostTerminal?:
                #expect(kind == .herdr, "only Herdr opens folders in its own terminal")
            case nil:
                Issue.record("\(kind) cannot open an absolute folder")
            }
        }
        #expect(SSHTerminalMultiplexerKind.herdr.multiplexer.name == "Herdr")
        #expect(SSHTerminalMultiplexerKind.tmux.multiplexer.name == "tmux")
        // A folder the host cannot open has no opening at all.
        let relative = SSHTerminalFolderTarget(serverHost: "mac-studio", folder: "relative/path")
        #expect(SSHTerminalMultiplexerKind.tmux.multiplexer.opening(relative) == nil)
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

    /// The focus call is one word for the remote login shell, with Herdr's ID
    /// escaped like every other value.
    private func assertFocus(_ commands: [String], id: String, _ hint: String) throws {
        let command = try #require(commands.first)
        #expect(commands.count == 1, "\(hint)")
        #expect(command.hasPrefix("sh -c '"), "\(hint)")
        #expect(command.contains("exec herdr workspace focus \"$i\""), "\(hint)")
        #expect(command.contains(SSHTerminalRemoteShell.octalEncoded(id)), "\(hint)")
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
        try assertFocus(commands, id: "w1", "an existing workspace")
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
        try assertFocus(commands, id: "w3", "an existing worktree")
    }

    @Test func theFocusedWorkspaceWinsWhenSeveralHaveTheFolder() throws {
        let snapshot = try snapshot(
            workspaces: [("w1", "oppi", false), ("w2", "oppi copy", true)],
            panes: [("w1:p1", "w1", "/Users/chen/oppi"), ("w2:p2", "w2", "/Users/chen/oppi")]
        )
        let commands = try HerdrMultiplexer.commands(
            folder: "/Users/chen/oppi", label: "oppi", isWorktree: false,
            matching: ["/Users/chen/oppi"], snapshot: snapshot
        )
        try assertFocus(commands, id: "w2", "the focused match")
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
        try assertFocus(commands, id: "w1", "a symlinked folder")
    }

    @Test func aTrailingSlashIsStillTheSameFolder() throws {
        for pane in ["/Users/chen/oppi/", "/Users/chen/oppi"] {
            let snapshot = try snapshot(
                workspaces: [("w1", "oppi", true)],
                panes: [("w1:p1", "w1", pane)]
            )
            let commands = try HerdrMultiplexer.commands(
                folder: "/Users/chen/oppi", label: "oppi", isWorktree: false,
                matching: ["/Users/chen/oppi"], snapshot: snapshot
            )
            try assertFocus(commands, id: "w1", pane)
        }
        // The root folder keeps its only slash.
        #expect(HerdrSnapshot.comparablePath("/") == "/")
        #expect(HerdrSnapshot.comparablePath("/a/b/") == "/a/b")
        #expect(HerdrSnapshot.comparablePath("  /a/b  ") == "/a/b")
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
            folder: folder, label: "oppi", isWorktree: false,
            matching: [folder], snapshot: snapshot
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
            folder: folder, label: "oppi · fix-x", isWorktree: true,
            matching: [folder], snapshot: snapshot
        )
        let command = try #require(commands.first)
        #expect(command.contains("herdr worktree open --path \"$p\" --label \"$l\" --focus"))
        #expect(!command.contains("workspace create"))
        #expect(command.contains(SSHTerminalRemoteShell.octalEncoded(folder)))
        #expect(command.contains(SSHTerminalRemoteShell.octalEncoded("oppi · fix-x")))
    }

    @Test func aNamespaceWithoutANameIsCalledAfterItsFolder() throws {
        #expect(HerdrMultiplexer.workspaceLabel("  ", folder: "/Users/chen/oppi") == "oppi")
        #expect(HerdrMultiplexer.workspaceLabel("", folder: "~/workspace/oppi") == "oppi")
        #expect(HerdrMultiplexer.workspaceLabel(" oppi · fix-x ", folder: "/x") == "oppi · fix-x")
    }

    @Test func anIDOppiWillNotSendBackIsRefused() throws {
        // Herdr's IDs are its own; a hostile snapshot cannot smuggle shell syntax
        // through the focus command, and an ID cannot be read as a flag.
        for id in ["w1; rm -rf /", "-rf", "-", "w1 --focus"] {
            let json = """
            {"workspaces":[{"workspace_id":"\(id)","label":"x","focused":true}],
             "tabs":[],"agents":[],
             "panes":[{"pane_id":"p","workspace_id":"\(id)","cwd":"/Users/chen/oppi"}]}
            """
            let snapshot = try JSONDecoder().decode(HerdrSnapshot.self, from: Data(json.utf8))
            #expect(throws: HerdrRemoteError.unusableID) {
                try HerdrMultiplexer.commands(
                    folder: "/Users/chen/oppi", label: "oppi", isWorktree: false,
                    matching: ["/Users/chen/oppi"], snapshot: snapshot
                )
            }
        }
        // The focus call itself refuses them too, for the agent list.
        #expect(HerdrRemote.focusCommand(.workspace("-rf"), machine: nil) == nil)
        #expect(HerdrRemote.focusCommand(.agent(""), machine: nil) == nil)
        #expect(HerdrRemote.focusCommand(.workspace("w1:p2"), machine: nil) != nil)
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
        #expect(lookup.snapshot == (try snapshot()))
    }

    @Test func aMissingFolderHasNoPhysicalPath() throws {
        // `cd` failed, so nothing can match and Herdr's create reports it.
        let lookup = try HerdrMultiplexer.parse(SSHExecResult(
            output: Data("oppi-home /Users/chen\noppi-cwd\n\(Self.snapshotJSON)\n".utf8),
            errorOutput: Data(),
            exitStatus: 0
        ))
        #expect(lookup.physicalFolder == nil)
        #expect(lookup.home == "/Users/chen")
    }

    @Test func aFolderWithANewlineCannotSpoofTheSnapshot() throws {
        // A folder named `a\n{...` would put its own line where the JSON starts
        // if the shell ever reported it. The command reports no path for it, and
        // the snapshot is whatever follows the oppi-cwd line.
        for folder in ["/tmp/a\n{", "/tmp/a\n/a", "/tmp/a\n{\"id\":\"x\"}"] {
            let command = try #require(HerdrMultiplexer.lookupCommand(folder: folder))
            #expect(command.contains(SSHTerminalRemoteShell.octalEncoded(folder)), "\(folder)")
            #expect(!command.contains(folder), "\(folder)")
            let lookup = try HerdrMultiplexer.parse(SSHExecResult(
                output: Data("oppi-home /Users/chen\noppi-cwd\n\(Self.snapshotJSON)\n".utf8),
                errorOutput: Data(),
                exitStatus: 0
            ))
            #expect(lookup.physicalFolder == nil, "\(folder)")
            #expect(lookup.snapshot == (try snapshot()), "\(folder)")
        }
        // Everything after the oppi-cwd line is what Herdr said, so a stray line
        // there is not skipped to find a later brace: the answer is that the
        // snapshot cannot be read. Nothing a folder name holds reaches that
        // region, which is what keeps the parse honest.
        let odd = SSHExecResult(
            output: Data("oppi-home /Users/chen\noppi-cwd\n{\"not\":\"snapshot\"}\n\(Self.snapshotJSON)\n".utf8),
            errorOutput: Data(),
            exitStatus: 0
        )
        #expect(throws: HerdrRemoteError.unreadable) { try HerdrMultiplexer.parse(odd) }
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
}

/// tmux's session name and attach command for one folder.
@Suite("tmux folder session")
@MainActor
struct TmuxMultiplexerTests {
    private func target(_ folder: String, label: String = "oppi", isWorktree: Bool = false) -> SSHTerminalFolderTarget {
        SSHTerminalFolderTarget(serverHost: "mac-studio", folder: folder, label: label, isWorktree: isWorktree)
    }

    private func command(_ target: SSHTerminalFolderTarget) -> String? {
        guard case .folderTerminal(let command)? = TmuxMultiplexer().opening(target) else { return nil }
        return command
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

    @Test func aSessionNameCannotCarryTmuxTargetSyntaxOrAFormat() {
        for label in ["oppi.v2", "a:b", "w1:0.1", "release/2.0:next", "two\nlines", "\u{7}bell", "#{host}", "#(echo x)"] {
            let name = TmuxMultiplexer.sessionName(label: label, folder: "/x")
            #expect(!name.contains("."), "\(label)")
            #expect(!name.contains(":"), "\(label)")
            // tmux expands `#{...}` and `#(...)` in `-s`, so every `#` is doubled.
            #expect(!name.contains("#") || name.contains("##"), "\(label)")
            #expect(name.hasSuffix("-" + TmuxMultiplexer.folderHash("/x")))
        }
        #expect(TmuxMultiplexer.sanitized("app.v2:main") == "app-v2-main")
        #expect(TmuxMultiplexer.sanitized("  spaced   name  ") == "spaced name")
        #expect(TmuxMultiplexer.sanitized("日本語 worktree") == "日本語 worktree")
        #expect(TmuxMultiplexer.sanitized("#{host}") == "##{host}")
        #expect(TmuxMultiplexer.sanitized("#(echo x)") == "##(echo x)")
        #expect(TmuxMultiplexer.sanitized(String(repeating: "a", count: 80)).count == 48)
    }

    @Test func theCommandEntersTheFolderThenAttachesItsSession() throws {
        let command = try #require(command(target("~/workspace/oppi")))
        #expect(command.hasPrefix("sh -c '"))
        #expect(command.hasSuffix("'"))
        // `new -A`: create the session the first time, attach it after that, so
        // the work is still there after a disconnect. No `-c`: tmux expands
        // formats in its arguments and falls back to the home folder when the
        // folder cannot be entered, so the shell changes folder first and the
        // session starts in this client's folder.
        #expect(command.contains("exec tmux new -A -s \"$s\""))
        // tmux is given no `-c`: the folder is the client's own.
        #expect(!command.contains("-c \"$p\""))
        #expect(!command.contains("tmux new -A -c"))
        #expect(command.contains("cd \"$p\" || { printf \"oppi: %s: no such folder\\n\" \"$p\" >&2; exit 1; }"))
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
        #expect(command(target("relative/path")) == nil)
    }

    @Test func absoluteFoldersTravelAsEscapedBytes() throws {
        let folder = "/tmp/日本語 with space"
        let command = try #require(command(target(folder, label: "oppi")))
        #expect(command.contains(SSHTerminalRemoteShell.octalEncoded(folder)))
        #expect(!command.contains(folder))
    }

    @Test func aFolderWithAHashIsNotAFormat() throws {
        let folder = "/tmp/#{host}/x"
        let command = try #require(command(target(folder, label: "oppi #{host}")))
        // The folder and the label travel as octal bytes, so tmux never sees a
        // `#{` in them at all.
        #expect(!command.contains("#{"))
        #expect(!command.contains("#("))
        #expect(command.contains(SSHTerminalRemoteShell.octalEncoded(folder)))
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
        "/tmp/hash#{host}#(echo x)",
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
            if case .folderTerminal(let command)? = TmuxMultiplexer().opening(target) {
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
                #expect(lookup.contains("exec herdr api snapshot"), "\(folder)")
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

    @Test func aFocusCallIsOneSafeWordToo() throws {
        for id in ["w1", "wY:p7", "w1:p2", "agent_x-1"] {
            let command = try #require(HerdrRemote.focusCommand(.workspace(id), machine: nil))
            try assertSafeWord(command, "focus \(id)")
            #expect(command.contains("exec herdr workspace focus \"$i\""), "\(id)")
            #expect(command.contains(SSHTerminalRemoteShell.octalEncoded(id)), "\(id)")
            #expect(!command.contains(id), "\(id): the ID is not literal shell text")
        }
    }

    /// A saved machine's profile ID comes from the host's machine list and goes
    /// back to the host the same way a workspace ID does: escaped, never in the
    /// clear, and refused when it is not an ID.
    @Test func aSavedMachineIsNamedByItsEscapedProfileID() throws {
        let machine = "9511532e7f5df1473bb50f692fc87810"
        let snapshot = try #require(HerdrRemote.snapshotCommand(machine: machine))
        try assertSafeWord(snapshot, "snapshot")
        #expect(snapshot.contains("exec herdr --machine \"$m\" api snapshot"))
        #expect(snapshot.contains(SSHTerminalRemoteShell.octalEncoded(machine)))
        #expect(!snapshot.contains(machine))
        #expect(HerdrRemote.snapshotCommand(machine: nil) == "herdr api snapshot")

        let focus = try #require(HerdrRemote.focusCommand(.agent("w1:p2"), machine: machine))
        try assertSafeWord(focus, "remote focus")
        #expect(focus.contains("exec herdr --machine \"$m\" agent focus \"$i\""))

        for hostile in ["mac-mini; rm -rf ~", "--session", "", "build machine"] {
            #expect(HerdrRemote.snapshotCommand(machine: hostile) == nil, "\(hostile)")
            #expect(HerdrRemote.focusCommand(.workspace("w1"), machine: hostile) == nil, "\(hostile)")
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
