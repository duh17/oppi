import Foundation
import Testing
@testable import Oppi

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

    @Test func anExactNameBeatsAShortNameMatch() {
        // The exact saved name is the same machine the server named, so it wins
        // even though the short-name host runs the nicer command.
        let exactWithCommand = profile("mac-studio.tail1234.ts.net", startup: "herdr")
        let shortName = profile("Mac-Studio", startup: nil)
        #expect(
            SSHTerminalHostMatch.bestMatch(
                in: [shortName, exactWithCommand], serverHost: "mac-studio.tail1234.ts.net"
            )?.id == exactWithCommand.id
        )
        // Even a plain exact name beats a short-name host running a multiplexer.
        let exactPlain = profile("mac-studio.tail1234.ts.net", startup: nil)
        let shortNameMultiplexer = profile("Mac-Studio", startup: "herdr")
        #expect(
            SSHTerminalHostMatch.bestMatch(
                in: [shortNameMultiplexer, exactPlain], serverHost: "mac-studio.tail1234.ts.net"
            )?.id == exactPlain.id
        )
    }

    @Test func withinOneKindAMultiplexerWinsThenAPlainHostThenAnotherCommand() {
        // Both saved names are the same exact host (case and dot ignored). The
        // host whose Run on Connect command is a multiplexer wins, because its
        // folder opens inside Herdr or tmux: saving the machine twice, once with
        // `herdr` and once plain, must not hide the multiplexer.
        let herdr = profile("mac-studio.tail1234.ts.net", startup: "herdr")
        let plain = profile("MAC-STUDIO.TAIL1234.TS.NET.", startup: nil)
        #expect(
            SSHTerminalHostMatch.bestMatch(
                in: [plain, herdr], serverHost: "mac-studio.tail1234.ts.net"
            )?.id == herdr.id
        )
        // tmux counts the same way, and a host with no command beats one running
        // something that is not a multiplexer.
        let tmux = profile("mac-studio.tail1234.ts.net", startup: "tmux new -A -s main")
        let other = profile("mac-studio.tail1234.ts.net", startup: "htop")
        #expect(
            SSHTerminalHostMatch.bestMatch(
                in: [other, tmux], serverHost: "mac-studio.tail1234.ts.net"
            )?.id == tmux.id
        )
        #expect(
            SSHTerminalHostMatch.bestMatch(
                in: [other, plain], serverHost: "mac-studio.tail1234.ts.net"
            )?.id == plain.id
        )
        // Two multiplexer hosts: the first saved one.
        let later = profile("mac-studio.tail1234.ts.net", startup: "tmux")
        #expect(
            SSHTerminalHostMatch.bestMatch(
                in: [herdr, later], serverHost: "mac-studio.tail1234.ts.net"
            )?.id == herdr.id
        )
        #expect(
            SSHTerminalHostMatch.bestMatch(
                in: [later, herdr], serverHost: "mac-studio.tail1234.ts.net"
            )?.id == later.id
        )
        // Two plain hosts: still the first saved one.
        let first = profile("mac-studio")
        let second = profile("other")
        #expect(
            SSHTerminalHostMatch.bestMatch(
                in: [profile("mac-mini", startup: "herdr"), first, second],
                serverHost: "MAC-STUDIO.tail1234.ts.net."
            )?.id == first.id
        )
    }

    @Test func noSavedHostServingTheServerIsNoMatch() {
        #expect(SSHTerminalHostMatch.bestMatch(in: [profile("mac-mini")], serverHost: "mac-studio.ts.net") == nil)
        // An unconfigured host (no username) cannot serve a folder terminal.
        let unconfigured = SSHTerminalProfile(host: "mac-studio.ts.net")
        #expect(SSHTerminalHostMatch.bestMatch(in: [unconfigured], serverHost: "mac-studio.ts.net") == nil)
        #expect(SSHTerminalHostMatch.bestMatch(in: [profile("mac-studio")], serverHost: "") == nil)
    }
}

@Suite("SSH terminal folder resolution")
struct SSHTerminalFolderResolveTests {
    private func worktree(_ id: String, path: String) -> WorkspaceWorktree {
        WorkspaceWorktree(
            id: id, name: id, path: path, branch: nil, headSha: nil,
            isMain: id == WorkspaceWorktree.mainId, isGitRepo: true, sessionCount: nil
        )
    }

    /// The resolution for a workspace root: the folder, named after the workspace.
    private func root(_ path: String) -> SSHTerminalFolderResolution {
        .folder(path: path, label: "oppi", isWorktree: false)
    }

    @Test func aSessionWithoutAWorktreeUsesTheWorkspaceRoot() {
        #expect(
            SSHTerminalFolderResolve.resolution(
                worktreeId: nil, root: "~/workspace/oppi", workspaceName: "oppi", worktrees: [], lookupError: nil
            ) == root("~/workspace/oppi")
        )
        #expect(
            SSHTerminalFolderResolve.resolution(
                worktreeId: WorkspaceWorktree.mainId, root: "/Users/chen/oppi",
                workspaceName: "oppi", worktrees: [], lookupError: nil
            ) == root("/Users/chen/oppi")
        )
    }

    @Test func aSessionsOwnWorktreeWinsOverTheWorkspaceRoot() {
        let worktrees = [
            worktree(WorkspaceWorktree.mainId, path: "/Users/chen/oppi"),
            worktree("fix-x", path: "/Users/chen/oppi-fix-x"),
        ]
        #expect(
            SSHTerminalFolderResolve.resolution(
                worktreeId: "fix-x", root: "/Users/chen/oppi",
                workspaceName: "oppi", worktrees: worktrees, lookupError: nil
            ) == .folder(path: "/Users/chen/oppi-fix-x", label: "oppi · fix-x", isWorktree: true)
        )
        // A worktree the server no longer lists is a failure: the workspace root
        // is a folder the session never ran in.
        guard case .failure(let missing) = SSHTerminalFolderResolve.resolution(
            worktreeId: "gone", root: "/Users/chen/oppi", workspaceName: "oppi", worktrees: worktrees, lookupError: nil
        ) else {
            Issue.record("a deleted worktree must not fall back to the workspace root")
            return
        }
        #expect(missing.contains("worktree"))
        // An empty list from a server that answered is the same answer.
        #expect(
            SSHTerminalFolderResolve.resolution(
                worktreeId: "fix-x", root: "/Users/chen/oppi", workspaceName: "oppi", worktrees: [], lookupError: nil
            ) != root("/Users/chen/oppi")
        )
    }

    @Test func onlyAnUnsupportedRouteFallsBackSilently() {
        // An older server has no worktree route: its sessions still run in the
        // workspace root, so the terminal opens there.
        let notFound = APIError.server(status: 404, message: "Not found")
        #expect(SSHTerminalFolderResolve.isUnsupportedRoute(notFound))
        #expect(
            SSHTerminalFolderResolve.resolution(
                worktreeId: "fix-x", root: "/Users/chen/oppi",
                workspaceName: "oppi", worktrees: [], lookupError: notFound
            ) == root("/Users/chen/oppi")
        )
        // Any other failure is shown: a shell in the wrong folder is worse than
        // no terminal.
        let failed = APIError.server(status: 500, message: "Server exploded")
        #expect(!SSHTerminalFolderResolve.isUnsupportedRoute(failed))
        guard case .failure(let message) = SSHTerminalFolderResolve.resolution(
            worktreeId: "fix-x", root: "/Users/chen/oppi", workspaceName: "oppi", worktrees: [], lookupError: failed
        ) else {
            Issue.record("a failed worktree lookup must not fall back to the workspace root")
            return
        }
        #expect(message.contains("Server exploded"))
        #expect(
            SSHTerminalFolderResolve.resolution(
                worktreeId: "fix-x", root: "/Users/chen/oppi",
                workspaceName: "oppi", worktrees: [], lookupError: URLError(.timedOut)
            ) != root("/Users/chen/oppi")
        )
    }

    @Test func aWorkspaceWithoutAFolderReportsThat() {
        #expect(
            SSHTerminalFolderResolve.resolution(
                worktreeId: nil, root: "", workspaceName: "oppi", worktrees: [], lookupError: nil
            ) == .noFolder
        )
        #expect(
            SSHTerminalFolderResolve.resolution(
                worktreeId: "fix-x", root: "  ",
                workspaceName: "oppi", worktrees: [], lookupError: APIError.server(status: 404, message: "nope")
            ) == .noFolder
        )
    }

    @Test func onlyAHostWorkspaceFolderOpensATerminal() {
        let host = Workspace(
            id: "oppi", name: "oppi", hostMount: "~/workspace/oppi",
            createdAt: Date(), updatedAt: Date()
        )
        #expect(SSHTerminalFolderTarget.workspace(host) == "~/workspace/oppi")
        let sandbox = Workspace(
            id: "sbx", name: "sandbox", hostMount: "/sandbox/work",
            runtime: .sandbox, createdAt: Date(), updatedAt: Date()
        )
        #expect(SSHTerminalFolderTarget.workspace(sandbox) == nil)
        let relative = Workspace(
            id: "rel", name: "relative", hostMount: "workspace/oppi",
            createdAt: Date(), updatedAt: Date()
        )
        #expect(SSHTerminalFolderTarget.workspace(relative) == nil)
        let missing = Workspace(id: "none", name: "none", hostMount: nil, createdAt: Date(), updatedAt: Date())
        #expect(SSHTerminalFolderTarget.workspace(missing) == nil)
    }
}
