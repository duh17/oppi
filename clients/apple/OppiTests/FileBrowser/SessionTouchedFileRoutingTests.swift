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
    @Test func sessionFileReaderKeepsRelativeChildrenOnImmutableOrigin() throws {
        let rewritten = MarkdownWikiLinkRewriter.rewrite(
            blocks: parseCommonMark("[Child](child.md)"),
            serverID: "server-origin",
            workspaceID: "workspace-origin",
            sessionID: "session-origin",
            sourceDirectory: "docs"
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
        #expect(reference.kind == .workspaceFile)
        #expect(reference.fileCandidatePath == "docs/child.md")
        #expect(OppiApp.sessionFileTarget(for: reference)?.kind == .sessionFile(
            path: "docs/child.md",
            fileName: "child.md",
            sessionId: "session-origin"
        ))
        #expect(ChatReaderLinkedFileRouting.target(
            for: action,
            serverID: "server-origin",
            workspaceID: "workspace-origin",
            sessionID: "session-origin"
        )?.kind == .sessionFile(
            path: "docs/child.md",
            fileName: "child.md",
            sessionId: "session-origin"
        ))
    }

    @Test func sandboxOriginKeepsHostFileKindOnSessionRaw() {
        #expect(SessionOriginLinkedFileRouting.routesThroughSessionRaw(
            kind: .hostFile,
            workspaceRuntime: .sandbox,
            routesFileReferencesThroughSession: true
        ))
        #expect(!SessionOriginLinkedFileRouting.routesThroughSessionRaw(
            kind: .hostFile,
            workspaceRuntime: .host,
            routesFileReferencesThroughSession: true
        ))
        #expect(SessionOriginLinkedFileRouting.routesThroughSessionRaw(
            kind: .workspaceFile,
            workspaceRuntime: .host,
            routesFileReferencesThroughSession: true
        ))
        #expect(SessionOriginLinkedFileRouting.routesThroughSessionRaw(
            kind: .hostFile,
            workspaceRuntime: nil,
            routesFileReferencesThroughSession: true
        ))
    }

    @MainActor
    @Test func sessionFileReaderKeepsSandboxGuestChildrenOnImmutableOrigin() throws {
        let expectedPath = "/workspace/deep-research/docs/child.md"
        let rewritten = MarkdownWikiLinkRewriter.rewrite(
            blocks: parseCommonMark("[Child](child.md)"),
            serverID: "server-origin",
            workspaceID: "workspace-origin",
            sessionID: "session-origin",
            sourceDirectory: "/workspace/deep-research/docs"
        )
        guard case .paragraph(let inlines) = try #require(rewritten.first),
              case .link(_, let destination) = try #require(inlines.first) else {
            Issue.record("Expected a routed guest child file reference")
            return
        }
        let routedDestination = try #require(destination)
        let url = try #require(URL(string: routedDestination))
        let action = MarkdownLinkInteractionSupport.classify(
            url,
            serverID: "server-origin",
            workspaceID: "workspace-origin",
            sessionID: "session-origin",
            routesFileReferencesThroughSession: true,
            workspaceRuntime: .sandbox
        )
        guard case .sessionFileReference(let reference) = action else {
            Issue.record("Sandbox guest children must stay on session-raw, got \(action)")
            return
        }
        #expect(reference.kind == .hostFile)
        #expect(reference.fileCandidatePath == expectedPath)
        #expect(OppiApp.sessionFileTarget(for: reference)?.kind == .sessionFile(
            path: expectedPath,
            fileName: "child.md",
            sessionId: "session-origin"
        ))
        #expect(ChatReaderLinkedFileRouting.target(
            for: action,
            serverID: "server-origin",
            workspaceID: "workspace-origin",
            sessionID: "session-origin",
            workspaceRuntime: .sandbox
        )?.kind == .sessionFile(
            path: expectedPath,
            fileName: "child.md",
            sessionId: "session-origin"
        ))
    }

    @MainActor
    @Test func sessionFileReaderKeepsUnknownRuntimeGuestChildrenOnImmutableOrigin() throws {
        let expectedPath = "/workspace/deep-research/docs/child.md"
        let rewritten = MarkdownWikiLinkRewriter.rewrite(
            blocks: parseCommonMark("[Child](child.md)"),
            serverID: "server-origin",
            workspaceID: "workspace-origin",
            sessionID: "session-origin",
            sourceDirectory: "/workspace/deep-research/docs"
        )
        guard case .paragraph(let inlines) = try #require(rewritten.first),
              case .link(_, let destination) = try #require(inlines.first) else {
            Issue.record("Expected a routed guest child file reference")
            return
        }
        let routedDestination = try #require(destination)
        let url = try #require(URL(string: routedDestination))
        let action = MarkdownLinkInteractionSupport.classify(
            url,
            serverID: "server-origin",
            workspaceID: "workspace-origin",
            sessionID: "session-origin",
            routesFileReferencesThroughSession: true,
            workspaceRuntime: nil
        )
        guard case .sessionFileReference(let reference) = action else {
            Issue.record("Unknown runtime must keep guest children on session-raw, got \(action)")
            return
        }
        #expect(reference.kind == .hostFile)
        #expect(reference.fileCandidatePath == expectedPath)
        #expect(OppiApp.sessionFileTarget(for: reference)?.kind == .sessionFile(
            path: expectedPath,
            fileName: "child.md",
            sessionId: "session-origin"
        ))
        #expect(ChatReaderLinkedFileRouting.target(
            for: action,
            serverID: "server-origin",
            workspaceID: "workspace-origin",
            sessionID: "session-origin",
            workspaceRuntime: nil
        )?.kind == .sessionFile(
            path: expectedPath,
            fileName: "child.md",
            sessionId: "session-origin"
        ))
    }

    @MainActor
    @Test func sessionOriginHostFileChildUsesHostRawNotSessionRaw() throws {
        let cases: [(source: String, expectedPath: String)] = [
            ("[[/Users/owner/docs/child.md|Child]]", "/Users/owner/docs/child.md"),
            ("[[~/docs/child.md|Child]]", "~/docs/child.md"),
        ]
        for item in cases {
            let rewritten = MarkdownWikiLinkRewriter.rewrite(
                blocks: parseCommonMark(item.source),
                serverID: "server-origin",
                workspaceID: "workspace-origin",
                sessionID: "session-origin",
                sourceDirectory: nil
            )
            guard case .paragraph(let inlines) = try #require(rewritten.first),
                  case .link(_, let destination) = try #require(inlines.first) else {
                Issue.record("Expected a routed host-file child")
                return
            }
            let routedDestination = try #require(destination)
            let url = try #require(URL(string: routedDestination))
            let action = MarkdownLinkInteractionSupport.classify(
                url,
                serverID: "server-origin",
                workspaceID: "workspace-origin",
                sessionID: "session-origin",
                routesFileReferencesThroughSession: true,
                workspaceRuntime: .host
            )
            guard case .resourceReference(let reference) = action else {
                Issue.record("Host-file children must use /files/raw, got \(action)")
                return
            }
            #expect(reference.kind == .hostFile)
            #expect(reference.fileCandidatePath == item.expectedPath)
            #expect(ChatReaderLinkedFileRouting.target(
                for: action,
                serverID: "server-origin",
                workspaceID: "workspace-origin",
                sessionID: "session-origin",
                workspaceRuntime: .host
            )?.kind == .hostFile(
                path: item.expectedPath,
                fileName: "child.md"
            ))
        }
    }

    @MainActor
    @Test func chatReaderDoesNotStuffHostFileResourceIntoSessionRaw() {
        let path = "/Users/owner/docs/child.md"
        let reference = ResourceReference(
            target: path,
            sourceServerID: "server-origin",
            workspaceID: "workspace-origin",
            sourceSessionID: "session-origin",
            fileCandidatePath: path,
            kind: .hostFile
        )
        let target = ChatReaderLinkedFileRouting.target(
            for: .resourceReference(reference),
            serverID: "server-origin",
            workspaceID: "workspace-origin",
            sessionID: "session-origin",
            workspaceRuntime: .host
        )
        #expect(target?.kind == .hostFile(path: path, fileName: "child.md"))
    }

    @MainActor
    @Test func chatReaderSandboxGuestHostFileStaysOnSessionRaw() {
        let path = "/workspace/deep-research/docs/child.md"
        let reference = ResourceReference(
            target: path,
            sourceServerID: "server-origin",
            workspaceID: "workspace-origin",
            sourceSessionID: "session-origin",
            fileCandidatePath: path,
            kind: .hostFile
        )
        let target = ChatReaderLinkedFileRouting.target(
            for: .resourceReference(reference),
            serverID: "server-origin",
            workspaceID: "workspace-origin",
            sessionID: "session-origin",
            workspaceRuntime: .sandbox
        )
        #expect(target?.kind == .sessionFile(
            path: path,
            fileName: "child.md",
            sessionId: "session-origin"
        ))
    }

    @MainActor
    @Test func chatReaderUnknownRuntimeGuestHostFileStaysOnSessionRaw() {
        let path = "/workspace/deep-research/docs/child.md"
        let reference = ResourceReference(
            target: path,
            sourceServerID: "server-origin",
            workspaceID: "workspace-origin",
            sourceSessionID: "session-origin",
            fileCandidatePath: path,
            kind: .hostFile
        )
        let target = ChatReaderLinkedFileRouting.target(
            for: .resourceReference(reference),
            serverID: "server-origin",
            workspaceID: "workspace-origin",
            sessionID: "session-origin",
            workspaceRuntime: nil
        )
        #expect(target?.kind == .sessionFile(
            path: path,
            fileName: "child.md",
            sessionId: "session-origin"
        ))
    }

    @MainActor
    @Test func completedReaderControllerCarriesExactOriginIntoActualLinkDelegate() throws {
        let context = FullScreenCodeContent.WorkspaceContext(
            workspaceID: "workspace-origin", serverID: "server-origin",
            serverBaseURL: try #require(URL(string: "https://origin.example")),
            fetchWorkspaceFile: { _, _ in Data() }, sessionID: "session-origin",
            routesFileReferencesThroughSession: true,
            workspaceRuntime: .host
        )
        let controller = FullScreenCodeViewController(
            content: .markdown(content: "[Child](child.md)", filePath: "docs/current.md", workspaceContext: context)
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
            return
        }
        #expect(child.sourceSessionID == "session-origin")
        #expect(OppiApp.sessionFileTarget(for: child)?.kind == .sessionFile(
            path: "docs/child.md",
            fileName: "child.md", sessionId: "session-origin"
        ))
    }

    @MainActor
    @Test func completedReaderSandboxGuestChildStaysOnSessionRaw() throws {
        let context = FullScreenCodeContent.WorkspaceContext(
            workspaceID: "workspace-origin", serverID: "server-origin",
            serverBaseURL: try #require(URL(string: "https://origin.example")),
            fetchWorkspaceFile: { _, _ in Data() }, sessionID: "session-origin",
            routesFileReferencesThroughSession: true,
            workspaceRuntime: .sandbox
        )
        let controller = FullScreenCodeViewController(
            content: .markdown(
                content: "[Child](child.md)",
                filePath: "/workspace/project/docs/current.md",
                workspaceContext: context
            )
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        let body = try #require(timelineAllViews(in: controller.view).compactMap { $0 as? NativeFullScreenMarkdownBody }.first)
        let textView = try #require(timelineAllTextViews(in: body).first { timelineRenderedText(of: $0).contains("Child") })
        let attributed = try #require(textView.attributedText)
        let link = try #require(attributed.attribute(.link, at: 0, effectiveRange: nil) as? URL)
        guard case .sessionFileReference(let child) = body.linkAction(for: link) else {
            Issue.record("Sandbox guest children must stay on session-raw, got \(String(describing: body.linkAction(for: link)))")
            return
        }
        #expect(child.sourceSessionID == "session-origin")
        #expect(OppiApp.sessionFileTarget(for: child)?.kind == .sessionFile(
            path: "/workspace/project/docs/child.md",
            fileName: "child.md", sessionId: "session-origin"
        ))
    }

    @MainActor
    @Test func completedReaderHostFileChildUsesHostRawNotSessionRaw() throws {
        let context = FullScreenCodeContent.WorkspaceContext(
            workspaceID: "workspace-origin", serverID: "server-origin",
            serverBaseURL: try #require(URL(string: "https://origin.example")),
            fetchWorkspaceFile: { _, _ in Data() }, sessionID: "session-origin",
            routesFileReferencesThroughSession: true,
            workspaceRuntime: .host
        )
        let controller = FullScreenCodeViewController(
            content: .markdown(
                content: "[[/Users/owner/docs/child.md|Child]]",
                filePath: "docs/current.md",
                workspaceContext: context
            )
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        let body = try #require(timelineAllViews(in: controller.view).compactMap { $0 as? NativeFullScreenMarkdownBody }.first)
        let textView = try #require(timelineAllTextViews(in: body).first { timelineRenderedText(of: $0).contains("Child") })
        let attributed = try #require(textView.attributedText)
        let link = try #require(attributed.attribute(.link, at: 0, effectiveRange: nil) as? URL)
        guard case .resourceReference(let child) = body.linkAction(for: link) else {
            Issue.record("Host-file children must use /files/raw, got \(String(describing: body.linkAction(for: link)))")
            return
        }
        #expect(child.kind == .hostFile)
        #expect(child.sourceSessionID == "session-origin")
        #expect(ChatReaderLinkedFileRouting.target(
            for: .resourceReference(child),
            serverID: "server-origin",
            workspaceID: "workspace-origin",
            sessionID: "session-origin",
            workspaceRuntime: .host
        )?.kind == .hostFile(
            path: "/Users/owner/docs/child.md",
            fileName: "child.md"
        ))
    }

    @MainActor
    @Test func serializedHostFileChildUsesHostRawAndMissingServerFailsClosed() throws {
        let hostPath = "/Users/owner/docs/child.md"
        let reference = ResourceReference(
            target: hostPath, sourceServerID: "server-origin",
            workspaceID: "workspace-origin", sourceSessionID: "different-session",
            fileCandidatePath: hostPath, kind: .hostFile
        )
        let url = try #require(ResourceReferenceURL.make(reference))
        for sessionID in ["session-origin", nil] {
            let action = MarkdownLinkInteractionSupport.classify(
                url, serverID: "server-origin", workspaceID: "workspace-origin",
                sessionID: sessionID, routesFileReferencesThroughSession: true,
                workspaceRuntime: .host
            )
            guard case .resourceReference(let child) = action else {
                Issue.record("Host-file children must use /files/raw, got \(action)")
                return
            }
            #expect(child.kind == .hostFile)
            #expect(child.sourceSessionID == sessionID)
            #expect(child.sourceServerID == "server-origin")
            #expect(ChatReaderLinkedFileRouting.target(
                for: action,
                serverID: "server-origin",
                workspaceID: "workspace-origin",
                sessionID: sessionID,
                workspaceRuntime: .host
            )?.kind == .hostFile(path: hostPath, fileName: "child.md"))
        }
        for missing in ["server", "workspace"] {
            let child = ResourceReference(
                target: hostPath,
                sourceServerID: missing == "server" ? nil : "server-origin",
                workspaceID: missing == "workspace" ? nil : "workspace-origin",
                sourceSessionID: "session-origin", fileCandidatePath: hostPath,
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
