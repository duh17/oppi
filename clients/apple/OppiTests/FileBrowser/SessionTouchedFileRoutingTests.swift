import Foundation
import Testing
import UIKit
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

    @MainActor
    @Test func sessionFileReaderKeepsAbsoluteAndRelativeChildrenOnImmutableOrigin() throws {
        for (sourceDirectory, expectedPath) in [
            ("/workspace/deep-research/docs", "/workspace/deep-research/docs/child.md"),
            ("docs", "docs/child.md"),
        ] {
            let rewritten = MarkdownWikiLinkRewriter.rewrite(
                blocks: parseCommonMark("[Child](child.md)"),
                serverID: "server-origin",
                workspaceID: "workspace-origin",
                sessionID: "session-origin",
                sourceDirectory: sourceDirectory
            )
            guard case .paragraph(let inlines) = try #require(rewritten.first),
                  case .link(_, let destination) = try #require(inlines.first) else {
                Issue.record("Expected a routed child file reference")
                return
            }
            let routedDestination = try #require(destination)
            let url = try #require(URL(string: routedDestination))
            let action = MarkdownLinkInteractionSupport.classify(
                url,
                serverID: "server-origin",
                workspaceID: "workspace-origin",
                sessionID: "session-origin",
                routesFileReferencesThroughSession: true
            )
            guard case .sessionFileReference(let reference) = action else {
                Issue.record("Expected immutable session-file origin, got \(action)")
                return
            }
            #expect(reference.fileCandidatePath == expectedPath)
            #expect(OppiApp.sessionFileTarget(for: reference)?.kind == .sessionFile(
                path: expectedPath,
                fileName: "child.md",
                sessionId: "session-origin"
            ))
        }
    }

    @MainActor
    @Test func completedReaderControllerCarriesExactOriginIntoActualLinkDelegate() throws {
        for parent in ["docs/current.md", "/workspace/project/docs/current.md"] {
            let context = FullScreenCodeContent.WorkspaceContext(
                workspaceID: "workspace-origin", serverID: "server-origin",
                serverBaseURL: try #require(URL(string: "https://origin.example")),
                fetchWorkspaceFile: { _, _ in Data() }, sessionID: "session-origin",
                routesFileReferencesThroughSession: true
            )
            let controller = FullScreenCodeViewController(
                content: .markdown(content: "[Child](child.md)", filePath: parent, workspaceContext: context)
            )
            controller.loadViewIfNeeded()
            controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            controller.view.layoutIfNeeded()
            let body = try #require(timelineAllViews(in: controller.view).compactMap { $0 as? NativeFullScreenMarkdownBody }.first)
            let textView = try #require(timelineAllTextViews(in: body).first { timelineRenderedText(of: $0).contains("Child") })
            let attributed = try #require(textView.attributedText)
            let link = try #require(attributed.attribute(.link, at: 0, effectiveRange: nil) as? URL)
            guard case .sessionFileReference(let child) = body.linkAction(for: link) else {
                Issue.record("Completed reader lost exact-session routing before its link delegate")
                continue
            }
            #expect(child.sourceSessionID == "session-origin")
            #expect(OppiApp.sessionFileTarget(for: child)?.kind == .sessionFile(
                path: (parent as NSString).deletingLastPathComponent + "/child.md",
                fileName: "child.md", sessionId: "session-origin"
            ))
        }
    }

    @MainActor
    @Test func serializedChildCannotReplaceReaderSessionAndMissingOriginFailsClosed() throws {
        let reference = ResourceReference(
            target: "/workspace/docs/child.md", sourceServerID: "server-origin",
            workspaceID: "workspace-origin", sourceSessionID: "different-session",
            fileCandidatePath: "/workspace/docs/child.md", kind: .hostFile
        )
        let url = try #require(ResourceReferenceURL.make(reference))
        for sessionID in ["session-origin", nil] {
            let action = MarkdownLinkInteractionSupport.classify(
                url, serverID: "server-origin", workspaceID: "workspace-origin",
                sessionID: sessionID, routesFileReferencesThroughSession: true
            )
            guard case .sessionFileReference(let child) = action else {
                Issue.record("Exact-file links must not fall through to ordinary host discovery")
                return
            }
            #expect(child.sourceSessionID == sessionID)
            let target = OppiApp.sessionFileTarget(for: child)
            #expect((target != nil) == (sessionID != nil))
            #expect(target?.sourceSessionId == sessionID)
        }
        for missing in ["server", "workspace"] {
            let child = ResourceReference(
                target: reference.target,
                sourceServerID: missing == "server" ? nil : "server-origin",
                workspaceID: missing == "workspace" ? nil : "workspace-origin",
                sourceSessionID: "session-origin", fileCandidatePath: reference.fileCandidatePath,
                kind: .hostFile
            )
            #expect(OppiApp.sessionFileTarget(for: child) == nil)
        }
    }

    @MainActor
    @Test func ordinaryHostLinkDoesNotAcquireSessionFileOrigin() throws {
        let reference = ResourceReference(
            target: "/Users/owner/docs/child.md",
            sourceServerID: "server-origin",
            workspaceID: "workspace-origin",
            sourceSessionID: "session-origin",
            fileCandidatePath: "/Users/owner/docs/child.md",
            kind: .hostFile
        )
        let url = try #require(ResourceReferenceURL.make(reference))
        #expect(MarkdownLinkInteractionSupport.classify(
            url,
            serverID: "server-origin",
            workspaceID: "workspace-origin"
        ) == .resourceReference(reference))
    }
}
