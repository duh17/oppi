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
}
