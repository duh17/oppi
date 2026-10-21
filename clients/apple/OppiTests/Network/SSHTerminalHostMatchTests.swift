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
        // even though it runs a command and the short-name host does not.
        let exactWithCommand = profile("mac-studio.tail1234.ts.net", startup: "herdr")
        let shortName = profile("Mac-Studio", startup: nil)
        #expect(
            SSHTerminalHostMatch.bestMatch(
                in: [shortName, exactWithCommand], serverHost: "mac-studio.tail1234.ts.net"
            )?.id == exactWithCommand.id
        )
    }

    @Test func withinOneKindAHostWithNoRunOnConnectWinsThenTheFirstSaved() {
        // Both saved names are the same exact host (case and dot ignored); the
        // plain machine beats a host that runs a command.
        let withCommand = profile("mac-studio.tail1234.ts.net", startup: "herdr")
        let plain = profile("MAC-STUDIO.TAIL1234.TS.NET.", startup: nil)
        #expect(
            SSHTerminalHostMatch.bestMatch(
                in: [withCommand, plain], serverHost: "mac-studio.tail1234.ts.net"
            )?.id == plain.id
        )
        // Both exact and both with commands: the first saved one.
        let second = profile("mac-studio.tail1234.ts.net", startup: "tmux new -A -s main")
        #expect(
            SSHTerminalHostMatch.bestMatch(
                in: [withCommand, second], serverHost: "mac-studio.tail1234.ts.net"
            )?.id == withCommand.id
        )
        // Both are short-name matches for the FQDN, and neither runs a command.
        let first = profile("mac-studio")
        let other = profile("other")
        #expect(
            SSHTerminalHostMatch.bestMatch(
                in: [profile("mac-mini", startup: "herdr"), first, other],
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

    @Test func aSessionWithoutAWorktreeUsesTheWorkspaceRoot() {
        #expect(
            SSHTerminalFolderResolve.resolution(
                worktreeId: nil, root: "~/workspace/oppi", worktrees: [], lookupError: nil
            ) == .folder("~/workspace/oppi")
        )
        #expect(
            SSHTerminalFolderResolve.resolution(
                worktreeId: WorkspaceWorktree.mainId, root: "/Users/chen/oppi", worktrees: [], lookupError: nil
            ) == .folder("/Users/chen/oppi")
        )
    }

    @Test func aSessionsOwnWorktreeWinsOverTheWorkspaceRoot() {
        let worktrees = [
            worktree(WorkspaceWorktree.mainId, path: "/Users/chen/oppi"),
            worktree("fix-x", path: "/Users/chen/oppi-fix-x"),
        ]
        #expect(
            SSHTerminalFolderResolve.resolution(
                worktreeId: "fix-x", root: "/Users/chen/oppi", worktrees: worktrees, lookupError: nil
            ) == .folder("/Users/chen/oppi-fix-x")
        )
        // A worktree the server no longer lists is a failure: the workspace root
        // is a folder the session never ran in.
        guard case .failure(let missing) = SSHTerminalFolderResolve.resolution(
            worktreeId: "gone", root: "/Users/chen/oppi", worktrees: worktrees, lookupError: nil
        ) else {
            Issue.record("a deleted worktree must not fall back to the workspace root")
            return
        }
        #expect(missing.contains("worktree"))
        // An empty list from a server that answered is the same answer.
        #expect(
            SSHTerminalFolderResolve.resolution(
                worktreeId: "fix-x", root: "/Users/chen/oppi", worktrees: [], lookupError: nil
            ) != .folder("/Users/chen/oppi")
        )
    }

    @Test func onlyAnUnsupportedRouteFallsBackSilently() {
        // An older server has no worktree route: its sessions still run in the
        // workspace root, so the terminal opens there.
        let notFound = APIError.server(status: 404, message: "Not found")
        #expect(SSHTerminalFolderResolve.isUnsupportedRoute(notFound))
        #expect(
            SSHTerminalFolderResolve.resolution(
                worktreeId: "fix-x", root: "/Users/chen/oppi", worktrees: [], lookupError: notFound
            ) == .folder("/Users/chen/oppi")
        )
        // Any other failure is shown: a shell in the wrong folder is worse than
        // no terminal.
        let failed = APIError.server(status: 500, message: "Server exploded")
        #expect(!SSHTerminalFolderResolve.isUnsupportedRoute(failed))
        guard case .failure(let message) = SSHTerminalFolderResolve.resolution(
            worktreeId: "fix-x", root: "/Users/chen/oppi", worktrees: [], lookupError: failed
        ) else {
            Issue.record("a failed worktree lookup must not fall back to the workspace root")
            return
        }
        #expect(message.contains("Server exploded"))
        #expect(
            SSHTerminalFolderResolve.resolution(
                worktreeId: "fix-x", root: "/Users/chen/oppi", worktrees: [], lookupError: URLError(.timedOut)
            ) != .folder("/Users/chen/oppi")
        )
    }

    @Test func aWorkspaceWithoutAFolderReportsThat() {
        #expect(
            SSHTerminalFolderResolve.resolution(
                worktreeId: nil, root: "", worktrees: [], lookupError: nil
            ) == .noFolder
        )
        #expect(
            SSHTerminalFolderResolve.resolution(
                worktreeId: "fix-x", root: "  ", worktrees: [], lookupError: APIError.server(status: 404, message: "nope")
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
