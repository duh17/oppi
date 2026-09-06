import Foundation
import Testing
@testable import Oppi

@Suite("File browser host-home scope")
struct FileBrowserHostHomeTests {
    @Test func hostHomeTargetNeverInventsAWorkspaceId() {
        let target = FileBrowserNavTarget.hostHome(serverId: "server-1")
        #expect(target.serverId == "server-1")
        #expect(target.workspaceId == nil)
        #expect(target.worktreeId == nil)
        #expect(target.path.isEmpty)
        if case .hostHome = target.scope {
        } else {
            Issue.record("expected host-home scope")
        }
    }

    @Test func hostHomeBreadcrumbRootIsHome() {
        let root = FileBrowserNavTarget.hostHome(serverId: "server-1")
        #expect(root.breadcrumbSegments.map(\.label) == ["Home"])
        let nested = FileBrowserNavTarget.hostHome(serverId: "server-1", path: "Documents/notes/")
        #expect(nested.breadcrumbSegments.map(\.label) == ["Home", "Documents", "notes"])
        #expect(nested.depth == 2)
    }

    @Test func workspaceBreadcrumbRootStaysFiles() {
        let target = FileBrowserNavTarget(
            serverId: "server-1",
            workspaceId: "ws-1",
            path: "src/"
        )
        #expect(target.workspaceId == "ws-1")
        #expect(target.breadcrumbSegments.map(\.label) == ["Files", "src"])
    }

    @Test func directoryRequestUsesHostHomeListing() {
        #expect(
            FileBrowserDirectoryRequest.make(scope: .hostHome, path: "Documents/")
                == .hostHome(path: "Documents/")
        )
        #expect(
            FileBrowserDirectoryRequest.make(
                scope: .workspace(workspaceId: "ws-1", worktreeId: "wt-1"),
                path: "src/"
            ) == .workspace(workspaceId: "ws-1", path: "src/", worktreeId: "wt-1")
        )
    }

    @Test func hostHomeFileOpenUsesTildePath() {
        #expect(FileBrowserHostHomePath.rawPath(relativePath: "") == "~")
        #expect(FileBrowserHostHomePath.rawPath(relativePath: "Documents/notes.md") == "~/Documents/notes.md")
        #expect(FileBrowserHostHomePath.rawPath(relativePath: "~/already.md") == "~/already.md")
    }

    @Test func hostHomeLoadCallsListHostDirectoryNotWorkspaceDirectory() throws {
        let source = try appleSource("Oppi/Features/FileBrowser/FileBrowserView.swift")
        #expect(source.contains("api.listHostDirectory(path: listingPath)"))
        #expect(source.contains("api.listWorkspaceDirectory("))
        let loadStart = try #require(source.range(of: "private func loadDirectory(path: String) async"))
        let load = String(source[loadStart.lowerBound...])
        let hostCase = try #require(load.range(of: "case .hostHome(let listingPath):"))
        let hostCall = try #require(load.range(of: "api.listHostDirectory(path: listingPath)"))
        #expect(hostCase.lowerBound < hostCall.lowerBound)
        let hostSlice = String(load[hostCase.lowerBound..<load.index(hostCall.upperBound, offsetBy: 0)])
        #expect(!hostSlice.contains("listWorkspaceDirectory"))
    }

    @Test func hostHomeIPadTreeRailHidesSearchField() throws {
        let source = try appleSource("Oppi/Features/FileBrowser/FileBrowserView.swift")
        let railStart = try #require(
            source.range(of: "private func fileTreeRail(showCloseButton: Bool) -> some View")
        )
        let headerStart = try #require(
            source.range(of: "private func fileTreeHeader(showCloseButton: Bool) -> some View")
        )
        #expect(railStart.lowerBound < headerStart.lowerBound)
        let rail = String(source[railStart.lowerBound..<headerStart.lowerBound])
        let hostHomeGuard = try #require(rail.range(of: "if !isHostHome"))
        let searchField = try #require(rail.range(of: "fileTreeSearchField"))
        #expect(hostHomeGuard.lowerBound < searchField.lowerBound)
    }
}

private func appleSource(_ relativePath: String) throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: relativePath)
    return try String(contentsOf: sourceURL, encoding: .utf8)
}
