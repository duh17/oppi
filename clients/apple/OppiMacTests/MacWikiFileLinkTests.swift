import Foundation
import Testing
@testable import Oppi

@Suite("Mac wiki file links open the document column")
struct MacWikiFileLinkTests {
    @Test func workspaceWikiLinkOpensAWorkspaceFileViewerPlan() throws {
        let destination = try firstLinkDestination(
            from: "See [[docs/Notes.md]]",
            workspaceID: "ws-1",
            sessionID: "sess-1"
        )
        let url = try #require(URL(string: destination))
        let plan = try #require(FileViewerPlan.opening(url: url))

        #expect(plan.id == "workspace-file:ws-1:docs/Notes.md")
        #expect(plan.workspaceID == "ws-1")
        #expect(plan.path == "docs/Notes.md")
        #expect(plan.fileName == "Notes.md")
        guard case .workspaceFile(let workspaceID, let path) = plan.source else {
            Issue.record("Expected a workspace file plan, got \(plan.source)")
            return
        }
        #expect(workspaceID == "ws-1")
        #expect(path == "docs/Notes.md")
    }

    @Test func labeledWorkspaceWikiLinkUsesThePathNotTheLabel() throws {
        let destination = try firstLinkDestination(
            from: "See [[docs/Notes.md|Notes]]",
            workspaceID: "ws-1"
        )
        let url = try #require(URL(string: destination))
        let plan = try #require(FileViewerPlan.opening(url: url))

        #expect(plan.path == "docs/Notes.md")
        #expect(plan.id == "workspace-file:ws-1:docs/Notes.md")
        #expect(!plan.id.contains("Notes]]"))
    }

    @Test func hostWikiLinkOpensAHostFileViewerPlan() throws {
        let destination = try firstLinkDestination(
            from: "See [[/tmp/host.txt]]",
            workspaceID: "ws-1"
        )
        let url = try #require(URL(string: destination))
        let plan = try #require(FileViewerPlan.opening(url: url))

        #expect(plan.id == "host-file:/tmp/host.txt")
        #expect(plan.path == "/tmp/host.txt")
        #expect(plan.fileName == "host.txt")
        #expect(plan.workspaceID.isEmpty)
        guard case .hostFile(let path) = plan.source else {
            Issue.record("Expected a host file plan, got \(plan.source)")
            return
        }
        #expect(path == "/tmp/host.txt")
    }

    @Test func homeHostWikiLinkOpensAHostFileViewerPlan() throws {
        let destination = try firstLinkDestination(from: "See [[~/Notes.md]]")
        let url = try #require(URL(string: destination))
        let plan = try #require(FileViewerPlan.opening(url: url))

        #expect(plan.id == "host-file:~/Notes.md")
        guard case .hostFile(let path) = plan.source else {
            Issue.record("Expected a host file plan, got \(plan.source)")
            return
        }
        #expect(path == "~/Notes.md")
    }

    @Test func markdownFileLinkSharesTheWikiViewerPlan() throws {
        let destination = try firstLinkDestination(
            from: "See [Notes](docs/Notes.md)",
            workspaceID: "ws-1"
        )
        let url = try #require(URL(string: destination))
        let plan = try #require(FileViewerPlan.opening(url: url))

        #expect(plan.id == "workspace-file:ws-1:docs/Notes.md")
        #expect(plan.path == "docs/Notes.md")
    }

    @Test func workspaceWikiLinkCarriesTheSelectedWorktreeOnTheViewerPlan() throws {
        let destination = try firstLinkDestination(
            from: "See [[docs/Notes.md]]",
            workspaceID: "ws-1"
        )
        let url = try #require(URL(string: destination))
        let feature = try #require(FileViewerPlan.opening(url: url, worktreeId: "wt_feature"))
        let main = try #require(FileViewerPlan.opening(url: url, worktreeId: WorkspaceWorktree.mainId))
        let blank = try #require(FileViewerPlan.opening(url: url, worktreeId: "  "))

        #expect(feature.worktreeId == "wt_feature")
        #expect(feature.id == "workspace-file:ws-1:wt_feature:docs/Notes.md")
        #expect(main.worktreeId == nil)
        #expect(main.id == "workspace-file:ws-1:docs/Notes.md")
        #expect(blank.worktreeId == nil)
        #expect(
            MacMarkdownWorkspaceFileLoader.workspaceRawRequestPath(for: feature)
                == "/workspaces/ws-1/raw/docs/Notes.md?worktreeId=wt_feature"
        )
        #expect(
            MacMarkdownWorkspaceFileLoader.workspaceRawRequestPath(for: main)
                == "/workspaces/ws-1/raw/docs/Notes.md"
        )
        #expect(
            MacWikiFileLinkRouting.decision(for: url, worktreeId: "wt_feature")
                == .open(FileViewerPlan.workspaceFile(
                    workspaceID: "ws-1",
                    path: "docs/Notes.md",
                    worktreeId: "wt_feature"
                ))
        )
        #expect(
            MacWikiFileLinkRouting.decision(for: url, worktreeId: WorkspaceWorktree.mainId)
                == .open(FileViewerPlan.workspaceFile(workspaceID: "ws-1", path: "docs/Notes.md"))
        )
    }

    @Test func markdownFileLinkCarriesTheSelectedWorktreeOnTheViewerPlan() throws {
        let destination = try firstLinkDestination(
            from: "See [Notes](docs/Notes.md)",
            workspaceID: "ws-1"
        )
        let url = try #require(URL(string: destination))
        let plan = try #require(FileViewerPlan.opening(url: url, worktreeId: "wt_feature"))

        #expect(plan.worktreeId == "wt_feature")
        #expect(plan.id == "workspace-file:ws-1:wt_feature:docs/Notes.md")
        #expect(
            MacMarkdownWorkspaceFileLoader.workspaceRawRequestPath(for: plan)
                == "/workspaces/ws-1/raw/docs/Notes.md?worktreeId=wt_feature"
        )
    }

    @Test func httpLinkDoesNotOpenAFileViewerPlan() throws {
        let destination = try firstLinkDestination(from: "See [site](https://example.com/doc)")
        let url = try #require(URL(string: destination))

        #expect(FileViewerPlan.opening(url: url) == nil)
        #expect(MacWikiFileLinkRouting.decision(for: url) == .system)
    }

    @Test func sessionWikiLinkDoesNotOpenAFileViewerPlan() throws {
        // SessionTraceShellDetail always parses with both IDs, so [[sess-1]]
        // becomes workspace-file:ws-1:sess-1.md. Omitting workspaceID is a false green.
        let destination = try firstLinkDestination(
            from: "See [[sess-1]]",
            workspaceID: "ws-1",
            sessionID: "sess-1"
        )
        let url = try #require(URL(string: destination))
        let reference = try #require(ResourceReferenceURL.parse(url))

        #expect(reference.target == "sess-1")
        #expect(reference.workspaceID == "ws-1")
        #expect(reference.sourceSessionID == "sess-1")
        #expect(reference.fileCandidatePath == "sess-1.md")
        #expect(reference.lineAnchor == nil)
        #expect(reference.sourceServerID == nil)
        #expect(FileViewerPlan.opening(reference: reference) == nil)
        #expect(FileViewerPlan.opening(url: url) == nil)
        #expect(MacWikiFileLinkRouting.decision(for: url) == .ignoreResourceReference)
    }

    @Test func currentSessionReferenceDoesNotOpenWithoutSourceServerID() {
        let reference = ResourceReference(
            target: "sess-1",
            sourceServerID: nil,
            workspaceID: "ws-1",
            sourceSessionID: "sess-1",
            fileCandidatePath: "sess-1.md"
        )

        #expect(FileViewerPlan.opening(reference: reference) == nil)
    }

    @Test func currentSessionLineAnchorStillOpensAFileViewerPlan() throws {
        let reference = ResourceReference(
            target: "sess-1",
            sourceServerID: nil,
            workspaceID: "ws-1",
            sourceSessionID: "sess-1",
            fileCandidatePath: "sess-1.md",
            lineAnchor: try #require(SourceLineAnchor.parse("#L12"))
        )
        let plan = try #require(FileViewerPlan.opening(reference: reference))

        #expect(plan.id == "workspace-file:ws-1:sess-1.md")
    }

    @Test func wikiClickInvokesTheOpenPlanCallbackInsteadOfCopyingThePath() throws {
        let destination = try firstLinkDestination(
            from: "See [[docs/Notes.md]]",
            workspaceID: "ws-1"
        )
        let url = try #require(URL(string: destination))
        var opened: FileViewerPlan?
        let decision = MacWikiFileLinkRouting.decision(for: url)

        if case .open(let plan) = decision {
            opened = plan
        }

        #expect(decision == .open(FileViewerPlan.workspaceFile(workspaceID: "ws-1", path: "docs/Notes.md")))
        #expect(opened?.id == "workspace-file:ws-1:docs/Notes.md")
        #expect(opened?.path == "docs/Notes.md")
    }

    @Test func hostWikiClickOpensTheHostPlan() throws {
        let destination = try firstLinkDestination(from: "See [[/tmp/host.txt]]")
        let url = try #require(URL(string: destination))
        #expect(MacWikiFileLinkRouting.decision(for: url) == .open(FileViewerPlan.hostFile(path: "/tmp/host.txt")))
    }

    @Test func markdownClickRoutingIsNotCopyPathOrASheet() throws {
        let markdown = try source(named: "OppiMac/Views/MacMarkdownBlockViews.swift")
        let sessionShell = try source(named: "OppiMac/Views/MacSessionShellViews.swift")
        let workspaceShell = try source(named: "OppiMac/Views/MacWorkspaceShellViews.swift")

        #expect(markdown.contains("macOpenFileViewer"))
        #expect(markdown.contains("OpenURLAction"))
        #expect(markdown.contains("FileViewerPlan"))
        #expect(markdown.contains("MacWikiFileLinkRouting"))
        #expect(markdown.contains("opening(url: url, worktreeId: worktreeId)"))
        #expect(markdown.contains("worktreeId: worktreeId"))
        #expect(markdown.contains("MacMarkdownVideoView(embed: embed, worktreeId: worktreeId)"))
        #expect(!markdown.contains("NSPasteboard"))
        #expect(!markdown.contains(".sheet("))
        #expect(!markdown.contains("fullScreenCover"))
        #expect(!markdown.contains("WindowGroup"))

        #expect(sessionShell.contains("openPlan"))
        #expect(sessionShell.contains("macOpenFileViewer"))
        #expect(sessionShell.contains("MacToolDocumentColumn("))
        #expect(sessionShell.contains("HSplitView"))
        #expect(sessionShell.contains("MacToolDocumentColumnMetrics.minWidth"))
        #expect(!sessionShell.contains("fullScreenCover"))
        #expect(!sessionShell.contains("WindowGroup"))

        #expect(workspaceShell.contains("macOpenFileViewer"))
        #expect(workspaceShell.contains("openPlan"))
        #expect(workspaceShell.contains("MacToolDocumentColumn("))
        #expect(!workspaceShell.contains("fullScreenCover"))
        #expect(!workspaceShell.contains("WindowGroup"))
    }

    private func firstLinkDestination(
        from markdown: String,
        workspaceID: String? = nil,
        sessionID: String? = nil
    ) throws -> String {
        let blocks = MacMarkdownPaintDispatch.parsedBlocks(
            from: markdown,
            workspaceID: workspaceID,
            sessionID: sessionID
        )
        let destinations = linkDestinations(in: blocks)
        return try #require(destinations.first)
    }

    private func linkDestinations(in blocks: [MarkdownBlock]) -> [String] {
        blocks.flatMap(linkDestinations(in:))
    }

    private func linkDestinations(in block: MarkdownBlock) -> [String] {
        switch block {
        case .heading(_, let inlines), .paragraph(let inlines):
            return linkDestinations(in: inlines)
        case .blockQuote(let children):
            return children.flatMap(linkDestinations(in:))
        case .unorderedList(let items), .orderedList(_, let items):
            return items.flatMap { $0.flatMap(linkDestinations(in:)) }
        case .taskList(let items):
            return items.flatMap { $0.content.flatMap(linkDestinations(in:)) }
        case .table(let headers, let rows):
            return headers.flatMap(linkDestinations(in:))
                + rows.flatMap { $0.flatMap(linkDestinations(in:)) }
        case .codeBlock, .thematicBreak, .htmlBlock:
            return []
        }
    }

    private func linkDestinations(in inlines: [MarkdownInline]) -> [String] {
        inlines.flatMap { inline -> [String] in
            switch inline {
            case .link(let children, let destination):
                return [destination].compactMap { $0 } + linkDestinations(in: children)
            case .emphasis(let children), .strong(let children), .strikethrough(let children):
                return linkDestinations(in: children)
            case .text, .code, .image, .videoEmbed, .softBreak, .hardBreak, .html:
                return []
            }
        }
    }

    private func source(named relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
