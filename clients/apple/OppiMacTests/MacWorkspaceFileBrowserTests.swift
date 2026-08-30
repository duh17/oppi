import Foundation
import Testing
@testable import Oppi

@Suite("Mac workspace file browser document column")
struct MacWorkspaceFileBrowserTests {
    @Test func nonDirectoryRowsOpenAWorkspaceFileViewerPlan() {
        let file = FileEntry(
            name: "main.swift",
            type: .file,
            size: 42,
            modifiedAt: 1_760_000_001_000,
            path: "Sources/main.swift"
        )
        let directory = FileEntry(
            name: "App",
            type: .directory,
            size: 128,
            modifiedAt: 1_760_000_000_000,
            path: "Sources/App"
        )

        let plan = FileViewerPlan.opening(
            entry: file,
            workspaceID: "ws-1",
            currentPath: "Sources/"
        )
        let directoryPlan = FileViewerPlan.opening(
            entry: directory,
            workspaceID: "ws-1",
            currentPath: "Sources/"
        )

        #expect(plan?.id == "workspace-file:ws-1:Sources/main.swift")
        #expect(plan?.workspaceID == "ws-1")
        #expect(plan?.path == "Sources/main.swift")
        #expect(plan?.fileName == "main.swift")
        #expect(plan?.worktreeId == nil)
        #expect(directoryPlan == nil)
        #expect(plan?.id.contains("func main") != true)
    }

    @Test func viewerPlanCarriesTheSelectedWorktreeAndOmitsMain() {
        let file = FileEntry(
            name: "main.swift",
            type: .file,
            size: 42,
            modifiedAt: 1_760_000_001_000,
            path: "Sources/main.swift"
        )

        let feature = FileViewerPlan.opening(
            entry: file,
            workspaceID: "ws-1",
            currentPath: "Sources/",
            worktreeId: "wt_feature"
        )
        let main = FileViewerPlan.opening(
            entry: file,
            workspaceID: "ws-1",
            currentPath: "Sources/",
            worktreeId: WorkspaceWorktree.mainId
        )
        let blank = FileViewerPlan.opening(
            entry: file,
            workspaceID: "ws-1",
            currentPath: "Sources/",
            worktreeId: "  "
        )

        #expect(feature?.worktreeId == "wt_feature")
        #expect(feature?.id == "workspace-file:ws-1:wt_feature:Sources/main.swift")
        #expect(feature?.path == "Sources/main.swift")
        #expect(main?.worktreeId == nil)
        #expect(main?.id == "workspace-file:ws-1:Sources/main.swift")
        #expect(blank?.worktreeId == nil)
        #expect(feature != main)
    }

    @Test func rawLoaderRequestPathSendsWorktreeQueryForTheSelectedCheckout() {
        let feature = FileViewerPlan.workspaceFile(
            workspaceID: "ws-1",
            path: "Notes.md",
            worktreeId: "wt_feature"
        )
        let main = FileViewerPlan.workspaceFile(
            workspaceID: "ws-1",
            path: "Notes.md",
            worktreeId: WorkspaceWorktree.mainId
        )

        #expect(
            MacMarkdownWorkspaceFileLoader.workspaceRawRequestPath(for: feature)
                == "/workspaces/ws-1/raw/Notes.md?worktreeId=wt_feature"
        )
        #expect(
            MacMarkdownWorkspaceFileLoader.workspaceRawRequestPath(for: main)
                == "/workspaces/ws-1/raw/Notes.md"
        )
        #expect(
            MacMarkdownWorkspaceFileLoader.workspaceRawRequestPath(
                workspaceID: "ws-1",
                path: "clips/demo.mp4",
                worktreeId: "wt_feature"
            ) == "/workspaces/ws-1/raw/clips/demo.mp4?worktreeId=wt_feature"
        )
        #expect(
            MacMarkdownWorkspaceFileLoader.workspaceRawRequestPath(
                workspaceID: "ws-1",
                path: MacMarkdownWorkspaceFileLoader.resolvedPath(
                    "diagram.png",
                    sourceDirectory: "docs"
                ),
                worktreeId: "wt_feature"
            ) == "/workspaces/ws-1/raw/docs/diagram.png?worktreeId=wt_feature"
        )
    }

    @Test func viewerPlanJoinsTheCurrentPathWhenTheEntryHasNoPath() {
        let file = FileEntry(
            name: "README.md",
            type: .file,
            size: 12,
            modifiedAt: 0,
            path: nil
        )

        let rooted = FileViewerPlan.opening(entry: file, workspaceID: "ws-1", currentPath: "")
        let nested = FileViewerPlan.opening(entry: file, workspaceID: "ws-1", currentPath: "docs")
        let slashed = FileViewerPlan.opening(entry: file, workspaceID: "ws-1", currentPath: "docs/")

        #expect(rooted?.path == "README.md")
        #expect(nested?.path == "docs/README.md")
        #expect(slashed?.path == "docs/README.md")
        #expect(rooted?.id == "workspace-file:ws-1:README.md")
    }

    @Test func viewerPlanDoesNotCarryFileBytes() {
        let huge = String(repeating: "x", count: 8_192)
        let plan = FileViewerPlan.workspaceFile(workspaceID: "ws-1", path: "Notes.md")

        #expect(plan.id == "workspace-file:ws-1:Notes.md")
        #expect(!plan.id.contains(huge))
        #expect(String(describing: plan).contains(huge) == false)
    }

    @Test func textAndCodeFilesBecomeSharedFileDescriptors() throws {
        let swift = try #require("func main() {}\n".data(using: .utf8))
        let markdown = try #require("# Title\n\nBody\n".data(using: .utf8))
        let html = try #require("<html><body>Hi</body></html>\n".data(using: .utf8))
        let svg = try #require("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>\n".data(using: .utf8))

        guard case .file(let swiftFile) = FileViewerDescriptorBuilder.descriptor(
            path: "Sources/main.swift",
            data: swift
        ) else {
            Issue.record("Expected a file descriptor for Swift source")
            return
        }
        guard case .file(let markdownFile) = FileViewerDescriptorBuilder.descriptor(
            path: "README.md",
            data: markdown
        ) else {
            Issue.record("Expected a file descriptor for markdown")
            return
        }
        guard case .file(let htmlFile) = FileViewerDescriptorBuilder.descriptor(
            path: "index.html",
            data: html
        ) else {
            Issue.record("Expected HTML to open as source, not a preview")
            return
        }
        guard case .file(let svgFile) = FileViewerDescriptorBuilder.descriptor(
            path: "icon.svg",
            data: svg
        ) else {
            Issue.record("Expected SVG to open as source, not a preview")
            return
        }

        #expect(swiftFile.filePath == "Sources/main.swift")
        #expect(swiftFile.language == .swift)
        #expect(swiftFile.text.contains("func main"))
        #expect(markdownFile.fileType == .markdown)
        #expect(htmlFile.fileType == .html)
        #expect(svgFile.fileType == .image)
        #expect(MacToolDocumentColumnPaint.surface(for: .file(swiftFile)) == .file)
        #expect(MacToolDocumentColumnPaint.fileUsesSyntaxHighlighter(swiftFile))
    }

    @Test func audioAndVideoBecomeMediaDescriptorsWithoutDownloadingBytes() throws {
        let audio = FileViewerDescriptorBuilder.descriptor(
            path: "clip.m4a",
            data: Data([0x00, 0x01, 0x02])
        )
        let video = FileViewerDescriptorBuilder.descriptor(
            path: "clip.mp4",
            data: Data([0x00, 0x01, 0x02])
        )

        guard case .media(let audioMedia) = audio else {
            Issue.record("Expected audio to play in the document column, got \(audio)")
            return
        }
        guard case .media(let videoMedia) = video else {
            Issue.record("Expected video to play in the document column, got \(video)")
            return
        }

        #expect(audioMedia.filePath == "clip.m4a")
        #expect(videoMedia.filePath == "clip.mp4")
        #expect(FileViewerDescriptorBuilder.needsFileBytes(path: "clip.m4a") == false)
        #expect(FileViewerDescriptorBuilder.needsFileBytes(path: "clip.mp4") == false)
        #expect(MacToolDocumentColumnPaint.surface(for: audio) == .media)
        #expect(MacToolDocumentColumnPaint.surface(for: video) == .media)
    }

    @Test func fileBrowserReloadsDirectoryListingForTheSelectedWorktree() throws {
        let browser = try source(named: "OppiMac/Views/MacWorkspaceFileBrowserView.swift")
        let shell = try source(named: "OppiMac/Views/MacWorkspaceShellViews.swift")
        let client = try source(named: "OppiMac/Networking/MacWorkspaceClient.swift")

        #expect(browser.contains("let worktreeId: String"))
        #expect(browser.contains("\\(workspace.id):\\(worktreeId)"))
        #expect(browser.contains("listWorkspaceDirectory("))
        #expect(browser.contains("worktreeId: worktreeId"))
        #expect(browser.contains("FileViewerPlan.opening("))
        #expect(browser.contains("worktreeId: worktreeId"))
        #expect(shell.contains("MacWorkspaceFileBrowserView("))
        #expect(shell.contains("worktreeId: selectedWorktreeId"))
        #expect(shell.contains("onChange(of: selectedWorktreeId)"))
        #expect(shell.contains("reopenDocumentForSelectedWorktree"))
        #expect(client.contains("func listWorkspaceDirectory("))
        #expect(client.contains("worktreeId: String? = nil"))
        #expect(client.contains("func getWorkspaceRawFileData("))
        #expect(client.contains("queryItems.append(URLQueryItem(name: \"worktreeId\""))

        let loader = try source(named: "OppiMac/Views/MacMarkdownImageView.swift")
        #expect(loader.contains("getWorkspaceRawFileData("))
        #expect(loader.contains("worktreeId: worktreeId"))
        #expect(loader.contains("worktreeId: plan.worktreeId"))
        #expect(loader.contains("var worktreeId: String? = nil"))
        #expect(loader.contains("sessionID: sessionID,\n                    worktreeId: worktreeId"))

        let video = try source(named: "OppiMac/Views/MacMarkdownVideoView.swift")
        #expect(video.contains("worktreeId: worktreeId"))
        #expect(video.contains("MacOwnerMediaSource.workspaceFile("))
    }

    @Test func fileBrowserEmitsAPlanAndTheWorkspaceShellHostsTheWideColumn() throws {
        let browser = try source(named: "OppiMac/Views/MacWorkspaceFileBrowserView.swift")
        let shell = try source(named: "OppiMac/Views/MacWorkspaceShellViews.swift")
        let column = try source(named: "OppiMac/Views/MacToolDocumentColumn.swift")

        #expect(browser.contains("FileViewerPlan"))
        #expect(browser.contains("openPlan"))
        #expect(browser.contains("MacWorkspaceFileBrowserPresentation"))
        #expect(browser.contains("case column"))
        #expect(browser.contains("presentation == .column"))
        #expect(browser.contains("Copy Workspace Path"))
        #expect(browser.contains(".contextMenu"))
        #expect(!browser.contains("HSplitView"))
        #expect(!browser.contains("MacToolDocumentColumn"))
        #expect(!browser.contains("MacToolDocumentColumnMetrics"))
        #expect(!browser.contains("fullScreenCover"))
        #expect(!browser.contains("WindowGroup"))
        #expect(!browser.contains("inspectorColumnWidth"))
        #expect(!browser.contains(".sheet("))
        #expect(!browser.contains("Label(\"Copy Path\""))

        #expect(shell.contains("HSplitView"))
        #expect(shell.contains("MacToolDocumentColumn("))
        #expect(shell.contains("MacToolDocumentColumnMetrics.minWidth"))
        #expect(shell.contains("MacToolDocumentColumnMetrics.idealWidth"))
        #expect(shell.contains("FileViewerPlan"))
        #expect(shell.contains("needsFileBytes"))
        #expect(!shell.contains("inspectorColumnWidth"))
        #expect(!shell.contains("fullScreenCover"))
        #expect(!shell.contains("WindowGroup"))

        #expect(column.contains("FileViewerPlan"))
        #expect(column.contains("MacToolDocumentDescriptorView"))
        #expect(column.contains("plan.worktreeId"))
        #expect(column.contains("toggleFullScreen"))
        #expect(!column.contains("inspectorColumnWidth"))
        #expect(!column.contains("fullScreenCover"))
        #expect(!column.contains("WindowGroup"))
        #expect(!column.contains(".sheet("))
        #expect(MacToolDocumentColumnMetrics.minWidth > 420)
        #expect(MacToolDocumentColumnMetrics.minWidth >= 520)
    }

    private func source(named relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
