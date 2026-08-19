import Foundation
import Testing
@testable import Oppi

@Suite("Session touched file routing")
struct SessionTouchedFileRoutingTests {
    private let guestPath = "/workspace/deep-research/reports/2026-08-19-private-cdp-browser/brief.md"
    private let hostMount = "~/workspace/deep-research"

    @Test func sandboxGuestPathUsesSessionRawNotHostBrowse() {
        let route = SessionTouchedFileLoadRoute.resolve(
            path: guestPath,
            workspaceRuntime: .sandbox,
            hostMount: hostMount
        )
        #expect(route == .sessionRaw(path: guestPath))
    }

    @Test func sandboxAbsoluteUnixPathDoesNotBecomeHostBrowse() {
        let route = SessionTouchedFileLoadRoute.resolve(
            path: "/Users/someone/.aws/credentials",
            workspaceRuntime: .sandbox,
            hostMount: hostMount
        )
        #expect(route == .sessionRaw(path: "/Users/someone/.aws/credentials"))
    }

    @Test func hostWorkspaceStillBrowsesAbsoluteHostPaths() {
        let hostPath = NSString(string: "~/workspace/oppi/README.md").expandingTildeInPath
        let route = SessionTouchedFileLoadRoute.resolve(
            path: hostPath,
            workspaceRuntime: .host,
            hostMount: "~/workspace/oppi"
        )
        #expect(route == .hostFile(path: hostPath))
    }

    @Test func sandboxNavigationTitleUsesFileNameNotGuestPath() {
        let title = SessionTouchedFileLoadRoute.navigationTitle(
            path: guestPath,
            fileName: "brief.md",
            workspaceRuntime: .sandbox
        )
        #expect(title == "brief.md")
    }
}
