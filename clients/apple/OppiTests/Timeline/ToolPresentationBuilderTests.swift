import Testing
import UIKit
import Dispatch

@testable import Oppi

@MainActor
@Suite("ToolPresentationBuilder")
struct ToolPresentationBuilderTests {

    private func emptyContext(
        args: [String: JSONValue]? = nil,
        details: JSONValue? = nil,
        expanded: Set<String> = [],
        fullOutput: String = "",
        isLoadingOutput: Bool = false
    ) -> ToolPresentationBuilder.Context {
        ToolPresentationBuilder.Context(
            args: args,
            details: details,
            expandedItemIDs: expanded,
            fullOutput: fullOutput,
            isLoadingOutput: isLoadingOutput
        )
    }

    // MARK: - Bash

    @Test("bash collapsed shows command text")
    func bashCollapsed() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "bash",
            argsSummary: "command: ls -la",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext(args: ["command": .string("ls -la")])
        )

        #expect(config.title == "ls -la")
        #expect(config.toolNamePrefix == "$")
        #expect(!config.isExpanded)
    }

    @Test("bash expanded shows separated command and output")
    func bashExpanded() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "bash",
            argsSummary: "command: echo hello",
            outputPreview: "hello",
            isError: false, isDone: true,
            context: emptyContext(
                args: ["command": .string("echo hello")],
                expanded: ["t1"],
                fullOutput: "hello\nworld"
            )
        )

        #expect(config.isExpanded)
        guard case .bash(let command, let output, let unwrapped) = config.expandedContent else {
            Issue.record("Expected .bash content")
            return
        }
        #expect(command == "echo hello")
        #expect(output == "hello\nworld")
        #expect(unwrapped)
        #expect(config.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("bash expanded suppresses segment command preview title")
    func bashExpandedSuppressesSegmentTitlePreview() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "bash",
            argsSummary: "command: npm test",
            outputPreview: "",
            isError: false, isDone: true,
            context: .init(
                args: ["command": .string("npm test")],
                expandedItemIDs: ["t1"],
                fullOutput: "",
                isLoadingOutput: false,
                callSegments: [
                    StyledSegment(text: "$ ", style: .bold),
                    StyledSegment(text: "npm test", style: .accent),
                ]
            )
        )

        #expect(config.isExpanded)
        #expect(config.segmentAttributedTitle == nil)
        #expect(config.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(config.toolNamePrefix == "$")
    }

    @Test("bash with heredoc inline script shows language badge")
    func bashHeredocLanguageBadge() {
        let command = "node - <<'NODE'\nconsole.log('hello');\nNODE"
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "bash",
            argsSummary: "command: \(command)",
            outputPreview: "hello",
            isError: false, isDone: true,
            context: emptyContext(args: ["command": .string(command)])
        )

        #expect(config.languageBadge == "JavaScript")
    }

    @Test("bash with python inline flag shows language badge")
    func bashPythonInlineBadge() {
        let command = "python3 -c 'print(42)'"
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "bash",
            argsSummary: "command: \(command)",
            outputPreview: "42",
            isError: false, isDone: true,
            context: emptyContext(args: ["command": .string(command)])
        )

        #expect(config.languageBadge == "Python")
    }

    @Test("bash with plain command has no language badge")
    func bashPlainNoLanguageBadge() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "bash",
            argsSummary: "command: ls -la",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext(args: ["command": .string("ls -la")])
        )

        #expect(config.languageBadge == nil)
    }

    @Test("read zig file shows Zig language badge")
    func readZigLanguageBadge() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "read",
            argsSummary: "path: build.zig",
            outputPreview: "const std = @import(\"std\");",
            isError: false, isDone: true,
            context: emptyContext(args: ["path": .string("build.zig")])
        )

        #expect(config.languageBadge == "Zig")
    }

    @Test("read markdown file shows Markdown language badge")
    func readMarkdownLanguageBadge() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "read",
            argsSummary: "path: README.md",
            outputPreview: "# Hello",
            isError: false, isDone: true,
            context: emptyContext(args: ["path": .string("README.md")])
        )

        #expect(config.languageBadge == "Markdown")
    }

    // MARK: - Read

    @Test("read collapsed shows file path")
    func readCollapsed() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "read",
            argsSummary: "path: src/server.ts",
            outputPreview: "const x = 1;",
            isError: false, isDone: true,
            context: emptyContext(args: ["path": .string("src/server.ts")])
        )

        #expect(config.title == "src/server.ts")
        #expect(config.toolNamePrefix == "read")
        #expect(config.titleLineBreakMode == .byTruncatingMiddle)
    }

    @Test("read expanded shows code with start line")
    func readExpanded() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "read",
            argsSummary: "path: server.ts",
            outputPreview: "line content",
            isError: false, isDone: true,
            context: emptyContext(
                args: ["path": .string("server.ts"), "offset": .number(42)],
                expanded: ["t1"],
                fullOutput: "full content here"
            )
        )

        #expect(config.isExpanded)
        guard case .code(let text, _, let startLine, let filePath) = config.expandedContent else {
            Issue.record("Expected .code content")
            return
        }
        #expect(text == "full content here")
        #expect(startLine == 42)
        #expect(filePath == "server.ts")
    }

    @Test("read loading shows loading message")
    func readLoading() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "read",
            argsSummary: "path: server.ts",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext(
                args: ["path": .string("server.ts")],
                expanded: ["t1"],
                isLoadingOutput: true
            )
        )

        guard case .status(let text) = config.expandedContent else {
            Issue.record("Expected .status content for loading state")
            return
        }
        #expect(text == "Loading read output…")
    }

    // MARK: - Edit

    @Test("edit collapsed shows diff stats")
    func editCollapsedWithDiff() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "edit",
            argsSummary: "path: file.swift",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext(args: [
                "path": .string("file.swift"),
                "old_text": .string("old line\n"),
                "new_text": .string("new line\nanother line\n"),
            ])
        )

        #expect(config.toolNamePrefix == "edit")
        #expect(config.editAdded != nil)
        #expect(config.editRemoved != nil)
    }

    @Test("edit expanded shows diff lines")
    func editExpanded() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "edit",
            argsSummary: "path: file.swift",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext(
                args: [
                    "path": .string("file.swift"),
                    "old_text": .string("old"),
                    "new_text": .string("new"),
                ],
                expanded: ["t1"]
            )
        )

        #expect(config.isExpanded)
        guard case .diff(let lines, _) = config.expandedContent else {
            Issue.record("Expected .diff content")
            return
        }
        #expect(!lines.isEmpty)
    }

    // MARK: - Write

    @Test("write collapsed shows file path")
    func writeCollapsed() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "write",
            argsSummary: "path: new-file.ts",
            outputPreview: "wrote 42 bytes",
            isError: false, isDone: true,
            context: emptyContext(args: ["path": .string("src/new-file.ts")])
        )

        #expect(config.title == "src/new-file.ts")
        #expect(config.toolNamePrefix == "write")
    }

    @Test("write collapsed shows language badge")
    func writeCollapsedLanguageBadge() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "write",
            argsSummary: "path: app.swift",
            outputPreview: "wrote 100 bytes",
            isError: false, isDone: true,
            context: emptyContext(args: [
                "path": .string("src/app.swift"),
                "content": .string("import Foundation"),
            ])
        )

        #expect(config.languageBadge == "Swift")
    }

    @Test("write expanded shows file content with syntax highlighting")
    func writeExpandedCode() {
        let content = "const x = 42;\nconsole.log(x);"
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "write",
            argsSummary: "path: index.ts",
            outputPreview: "wrote 30 bytes",
            isError: false, isDone: true,
            context: emptyContext(
                args: [
                    "path": .string("src/index.ts"),
                    "content": .string(content),
                ],
                expanded: ["t1"],
                fullOutput: "Successfully wrote 30 bytes to src/index.ts"
            )
        )

        guard case .code(let text, let language, let startLine, let filePath) = config.expandedContent else {
            Issue.record("Expected .code content")
            return
        }
        #expect(text == content)
        #expect(language == .typescript)
        #expect(startLine == 1)
        #expect(filePath == "src/index.ts")
        #expect(config.copyOutputText == content)
    }

    @Test("streaming expanded tool without body renders status placeholder")
    func streamingExpandedToolWithoutBodyRendersStatusPlaceholder() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "write",
            argsSummary: "path: src/index.ts",
            outputPreview: "",
            isError: false, isDone: false,
            context: emptyContext(
                args: [
                    "path": .string("src/index.ts"),
                ],
                expanded: ["t1"]
            )
        )

        #expect(config.isExpanded)
        guard case .status(let message) = config.expandedContent else {
            Issue.record("Expected .status placeholder content")
            return
        }
        #expect(message == "Writing…")
        #expect(config.copyOutputText == nil)
    }

    @Test("write streaming markdown uses incremental markdown pipeline")
    func writeStreamingMarkdown() {
        let content = "# Hello\n\nSome **bold** text."
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "write",
            argsSummary: "path: README.md",
            outputPreview: "",
            isError: false, isDone: false,
            context: emptyContext(
                args: [
                    "path": .string("README.md"),
                    "content": .string(content),
                ],
                expanded: ["t1"]
            )
        )

        // Streaming markdown files use the incremental markdown pipeline
        // (tail-only CommonMark parse) instead of plain text downgrade.
        guard case .markdown(let text) = config.expandedContent else {
            Issue.record("Expected .markdown content during streaming, got \(String(describing: config.expandedContent))")
            return
        }
        #expect(text == content)
    }

    @Test("write streaming and done both use markdown for .md files")
    func writeStreamingToDoneMarkdownTransition() {
        let content = "# Hello\n\nSome **bold** text."
        let args: [String: JSONValue] = [
            "path": .string("docs/guide.md"),
            "content": .string(content),
        ]

        // Phase 1: streaming — should be .markdown (incremental pipeline)
        let streaming = ToolPresentationBuilder.build(
            itemID: "t1", tool: "write",
            argsSummary: "path: docs/guide.md",
            outputPreview: "",
            isError: false, isDone: false,
            context: emptyContext(args: args, expanded: ["t1"])
        )
        #expect(modeName(streaming.expandedContent) == "markdown",
                "Streaming write of .md should use markdown mode (incremental pipeline)")

        // Phase 2: done — still .markdown
        let done = ToolPresentationBuilder.build(
            itemID: "t1", tool: "write",
            argsSummary: "path: docs/guide.md",
            outputPreview: "wrote 28 bytes",
            isError: false, isDone: true,
            context: emptyContext(
                args: args,
                expanded: ["t1"],
                fullOutput: "Successfully wrote 28 bytes to docs/guide.md"
            )
        )
        #expect(modeName(done.expandedContent) == "markdown",
                "Done write of .md should use markdown mode")
    }

    @Test("write expanded renders markdown files")
    func writeExpandedMarkdown() {
        let content = "# Hello\n\nSome **bold** text."
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "write",
            argsSummary: "path: README.md",
            outputPreview: "wrote 28 bytes",
            isError: false, isDone: true,
            context: emptyContext(
                args: [
                    "path": .string("README.md"),
                    "content": .string(content),
                ],
                expanded: ["t1"],
                fullOutput: "Successfully wrote 28 bytes to README.md"
            )
        )

        guard case .markdown(let text) = config.expandedContent else {
            Issue.record("Expected .markdown content")
            return
        }
        #expect(text == content)
    }

    @Test("write expanded falls back to code viewer when content missing")
    func writeExpandedFallback() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "write",
            argsSummary: "path: file.txt",
            outputPreview: "wrote 10 bytes",
            isError: false, isDone: true,
            context: emptyContext(
                args: ["path": .string("file.txt")],
                expanded: ["t1"],
                fullOutput: "Successfully wrote 10 bytes to file.txt"
            )
        )

        guard case .code(let text, _, _, let filePath) = config.expandedContent else {
            Issue.record("Expected .code content for write fallback")
            return
        }
        #expect(text == "Successfully wrote 10 bytes to file.txt")
        #expect(filePath == "file.txt")
    }

    @Test("content-based mode routing stays aligned across read/write/extension")
    func contentBasedModeRoutingParityAcrossToolFamilies() {
        let readMarkdown = ToolPresentationBuilder.build(
            itemID: "read-md", tool: "read",
            argsSummary: "path: README.md",
            outputPreview: "# Header",
            isError: false, isDone: true,
            context: emptyContext(
                args: ["path": .string("README.md")],
                expanded: ["read-md"],
                fullOutput: "# Header\n\nBody"
            )
        )

        let writeMarkdown = ToolPresentationBuilder.build(
            itemID: "write-md", tool: "write",
            argsSummary: "path: README.md",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext(
                args: [
                    "path": .string("README.md"),
                    "content": .string("# Header\n\nBody"),
                ],
                expanded: ["write-md"],
                fullOutput: "ok"
            )
        )

        let extensionMarkdown = ToolPresentationBuilder.build(
            itemID: "ext-md", tool: "extensions.notes",
            argsSummary: "",
            outputPreview: "# Header\n\nBody",
            isError: false, isDone: true,
            context: emptyContext(
                expanded: ["ext-md"],
                fullOutput: "# Header\n\nBody"
            )
        )

        #expect(modeName(readMarkdown.expandedContent) == "markdown")
        #expect(modeName(writeMarkdown.expandedContent) == "markdown")
        #expect(modeName(extensionMarkdown.expandedContent) == "markdown")

        let readCode = ToolPresentationBuilder.build(
            itemID: "read-code", tool: "read",
            argsSummary: "path: App.swift",
            outputPreview: "func app() {}",
            isError: false, isDone: true,
            context: emptyContext(
                args: ["path": .string("App.swift")],
                expanded: ["read-code"],
                fullOutput: "func app() {}"
            )
        )

        let writeCode = ToolPresentationBuilder.build(
            itemID: "write-code", tool: "write",
            argsSummary: "path: App.swift",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext(
                args: [
                    "path": .string("App.swift"),
                    "content": .string("func app() {}"),
                ],
                expanded: ["write-code"],
                fullOutput: "ok"
            )
        )

        let extensionCode = ToolPresentationBuilder.build(
            itemID: "ext-code", tool: "extensions.codegen",
            argsSummary: "",
            outputPreview: "func app() {}",
            isError: false, isDone: true,
            context: emptyContext(
                details: .object([
                    "presentationFormat": .string("code"),
                    "language": .string("swift"),
                ]),
                expanded: ["ext-code"],
                fullOutput: "func app() {}"
            )
        )

        #expect(modeName(readCode.expandedContent) == "code")
        #expect(modeName(writeCode.expandedContent) == "code")
        #expect(modeName(extensionCode.expandedContent) == "code")

        let editDiff = ToolPresentationBuilder.build(
            itemID: "edit-diff", tool: "edit",
            argsSummary: "path: App.swift",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext(
                args: [
                    "path": .string("App.swift"),
                    "old_text": .string("let value = 1"),
                    "new_text": .string("let value = 2"),
                ],
                expanded: ["edit-diff"]
            )
        )

        let extensionDiff = ToolPresentationBuilder.build(
            itemID: "ext-diff", tool: "extensions.patch",
            argsSummary: "",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext(
                details: .object(["presentationFormat": .string("diff")]),
                expanded: ["ext-diff"],
                fullOutput: "--- a/App.swift\n+++ b/App.swift\n@@ -1 +1 @@\n-let value = 1\n+let value = 2"
            )
        )

        #expect(modeName(editDiff.expandedContent) == "diff")
        #expect(modeName(extensionDiff.expandedContent) == "diff")
    }

    // MARK: - Extension tools

    @Test("extension collapsed uses segments when available")
    func extensionCollapsedWithSegments() throws {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "extensions.backlog",
            argsSummary: "action: create, title: Add tests",
            outputPreview: "",
            isError: false, isDone: true,
            context: .init(
                args: nil, expandedItemIDs: [], fullOutput: "", isLoadingOutput: false,
                callSegments: [
                    StyledSegment(text: "backlog ", style: .bold),
                    StyledSegment(text: "create", style: .muted),
                    StyledSegment(text: " \"Add tests\"", style: .dim),
                ]
            )
        )

        let title = try #require(config.segmentAttributedTitle)
        #expect(title.string == "backlog create \"Add tests\"")
        #expect(config.toolNamePrefix == "backlog")
    }

    @Test("extension collapsed falls back to default when no segments")
    func extensionCollapsedNoSegments() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "extensions.backlog",
            argsSummary: "action: create, title: Add tests",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext()
        )

        // Without segments, falls through to default: tool + argsSummary
        #expect(config.segmentAttributedTitle == nil)
        #expect(config.title.contains("extensions.backlog"))
        #expect(config.toolNamePrefix == "extensions.backlog")
    }

    @Test("extension collapsed path stays within budget versus expanded text path")
    func extensionCollapsedVsExpandedCost() {
        let body = (0..<1_200)
            .map { "line-\($0): append detail" }
            .joined(separator: "\n")
        let args: [String: JSONValue] = [
            "action": .string("append"),
            "id": .string("EXT-a27df231"),
            "body": .string(body),
        ]

        let iterations = 30

        let collapsedStart = DispatchTime.now().uptimeNanoseconds
        for index in 0..<iterations {
            _ = ToolPresentationBuilder.build(
                itemID: "extension-collapsed-\(index)",
                tool: "extensions.backlog",
                argsSummary: "action: append, id: EXT-a27df231",
                outputPreview: "",
                isError: false,
                isDone: true,
                context: emptyContext(args: args)
            )
        }
        let collapsedElapsed = DispatchTime.now().uptimeNanoseconds - collapsedStart

        let expandedStart = DispatchTime.now().uptimeNanoseconds
        for index in 0..<iterations {
            let itemID = "extension-expanded-\(index)"
            _ = ToolPresentationBuilder.build(
                itemID: itemID,
                tool: "extensions.backlog",
                argsSummary: "action: append, id: EXT-a27df231",
                outputPreview: "",
                isError: false,
                isDone: true,
                context: emptyContext(args: args, expanded: [itemID])
            )
        }
        let expandedElapsed = DispatchTime.now().uptimeNanoseconds - expandedStart

        #expect(
            collapsedElapsed <= expandedElapsed + (expandedElapsed / 2),
            "Collapsed build path regressed unexpectedly (collapsed=\(collapsedElapsed), expanded=\(expandedElapsed))"
        )
    }

    @Test("extension markdown collapsed uses segments when available")
    func extensionMarkdownCollapsedWithSegments() throws {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "extensions.notes",
            argsSummary: "text: Some important discovery",
            outputPreview: "",
            isError: false, isDone: true,
            context: .init(
                args: nil, expandedItemIDs: [], fullOutput: "", isLoadingOutput: false,
                callSegments: [
                    StyledSegment(text: "notes ", style: .bold),
                    StyledSegment(text: "\"Some important discovery\"", style: .muted),
                    StyledSegment(text: " [oppi, ios]", style: .dim),
                ],
                resultSegments: [
                    StyledSegment(text: "✓ Saved ", style: .success),
                    StyledSegment(text: "→ journal", style: .muted),
                ]
            )
        )

        let title = try #require(config.segmentAttributedTitle)
        let trailing = try #require(config.segmentAttributedTrailing)
        #expect(title.string == "notes \"Some important discovery\" [oppi, ios]")
        #expect(trailing.string == "✓ Saved → journal")
    }

    @Test("extension markdown expanded auto-detects markdown content")
    func extensionMarkdownExpanded() {
        let markdown = """
        # Discovery

        - item one
        - item two
        """

        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "extensions.notes",
            argsSummary: "",
            outputPreview: markdown,
            isError: false, isDone: true,
            context: emptyContext(
                args: [
                    "text": .string("Full discovery text"),
                    "tags": .array([.string("tag1")]),
                ],
                expanded: ["t1"],
                fullOutput: markdown
            )
        )

        guard case .markdown(let text) = config.expandedContent else {
            Issue.record("Expected .markdown content for extension markdown tool")
            return
        }
        #expect(text == markdown)
    }

    @Test("extension streaming uses markdown pipeline (not plain text downgrade)")
    func extensionStreamingUsesMarkdown() {
        let markdown = """
        ## Related

        - server/src/types.ts
        - ios/Oppi/Features/Chat
        """

        let config = ToolPresentationBuilder.build(
            itemID: "t-streaming-md", tool: "todo",
            argsSummary: "create \"Expand plot extension\"",
            outputPreview: markdown,
            isError: false, isDone: false,
            context: emptyContext(
                expanded: ["t-streaming-md"],
                fullOutput: markdown
            )
        )

        // Streaming extension tools with markdown output use the incremental
        // markdown pipeline instead of downgrading to plain text.
        guard case .markdown(let text) = config.expandedContent else {
            Issue.record("Expected .markdown content for streaming extension with markdown output, got \(String(describing: config.expandedContent))")
            return
        }
        #expect(text == markdown)
    }

    @Test("extension done renders markdown normally")
    func extensionDoneRendersMarkdown() {
        let markdown = """
        ## Related

        - server/src/types.ts
        - ios/Oppi/Features/Chat
        """

        let config = ToolPresentationBuilder.build(
            itemID: "t-done-md", tool: "todo",
            argsSummary: "create \"Expand plot extension\"",
            outputPreview: markdown,
            isError: false, isDone: true,
            context: emptyContext(
                expanded: ["t-done-md"],
                fullOutput: markdown
            )
        )

        // When done, the same content should render as markdown.
        guard case .markdown(let text) = config.expandedContent else {
            Issue.record("Expected .markdown content for done extension with markdown output")
            return
        }
        #expect(text == markdown)
    }

    @Test("extension expanded honors code presentation hints")
    func extensionExpandedCodeHint() {
        let code = "func extensionMode() -> String {\n    \"ok\"\n}"
        let config = ToolPresentationBuilder.build(
            itemID: "ext-code", tool: "extensions.codegen",
            argsSummary: "",
            outputPreview: code,
            isError: false, isDone: true,
            context: emptyContext(
                details: .object([
                    "presentationFormat": .string("code"),
                    "language": .string("swift"),
                    "filePath": .string("Sources/ExtensionMode.swift"),
                    "startLine": .number(42),
                ]),
                expanded: ["ext-code"],
                fullOutput: code
            )
        )

        guard case .code(let text, let language, let startLine, let filePath) = config.expandedContent else {
            Issue.record("Expected .code content for extension code hint")
            return
        }

        #expect(text == code)
        #expect(language == .swift)
        #expect(startLine == 42)
        #expect(filePath == "Sources/ExtensionMode.swift")
    }

    @Test("extension expanded honors diff presentation hints")
    func extensionExpandedDiffHint() {
        let diffText = """
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,2 +1,2 @@
        -let value = 1
        +let value = 2
        """

        let config = ToolPresentationBuilder.build(
            itemID: "ext-diff", tool: "extensions.patch",
            argsSummary: "",
            outputPreview: diffText,
            isError: false, isDone: true,
            context: emptyContext(
                details: .object([
                    "presentationFormat": .string("diff"),
                    "filePath": .string("Sources/App.swift"),
                ]),
                expanded: ["ext-diff"],
                fullOutput: diffText
            )
        )

        guard case .diff(let lines, let path) = config.expandedContent else {
            Issue.record("Expected .diff content for extension diff hint")
            return
        }

        #expect(path == "Sources/App.swift")
        #expect(lines.contains { $0.kind == .removed && $0.text == "let value = 1" })
        #expect(lines.contains { $0.kind == .added && $0.text == "let value = 2" })
    }

    @Test("extension expanded mode routing uses visual/json/markdown/text deterministically")
    func extensionExpandedModeRoutingMatrix() {
        let jsonHint = ToolPresentationBuilder.build(
            itemID: "ext-json-hint", tool: "extensions.lookup",
            argsSummary: "",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext(
                details: .object(["presentationFormat": .string("json")]),
                expanded: ["ext-json-hint"],
                fullOutput: "{\"b\":2,\"a\":1}"
            )
        )

        guard case .text(let hintedJSONText, let hintedJSONLanguage) = jsonHint.expandedContent else {
            Issue.record("Expected .text(.json) for explicit json format")
            return
        }
        #expect(hintedJSONLanguage == .json)
        #expect(hintedJSONText.contains("\n"))

        let autoJSON = ToolPresentationBuilder.build(
            itemID: "ext-json-auto", tool: "extensions.lookup",
            argsSummary: "",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext(
                expanded: ["ext-json-auto"],
                fullOutput: "{\"assigned\":[{\"id\":\"EXT-1\"}],\"open\":[],\"closed\":[]}"
            )
        )

        guard case .text(let autoJSONText, let autoJSONLanguage) = autoJSON.expandedContent else {
            Issue.record("Expected .text(.json) for auto-detected json")
            return
        }
        #expect(autoJSONLanguage == .json)
        #expect(autoJSONText.contains("\"EXT-1\""))

        let markdownHint = ToolPresentationBuilder.build(
            itemID: "ext-md-hint", tool: "extensions.notes",
            argsSummary: "",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext(
                details: .object(["presentationFormat": .string("markdown")]),
                expanded: ["ext-md-hint"],
                fullOutput: "# Header\n\nBody"
            )
        )

        guard case .markdown(let markdownText) = markdownHint.expandedContent else {
            Issue.record("Expected .markdown for explicit markdown format")
            return
        }
        #expect(markdownText == "# Header\n\nBody")

    }

    @Test("extension json/markdown over budget fall back to text with note")
    func extensionStructuredBudgetFallbackToText() {
        let oversizedJSON = "{\"payload\":\"" + String(repeating: "x", count: 70_000) + "\"}"
        let jsonFallback = ToolPresentationBuilder.build(
            itemID: "ext-json-over-budget", tool: "extensions.lookup",
            argsSummary: "",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext(
                details: .object(["presentationFormat": .string("json")]),
                expanded: ["ext-json-over-budget"],
                fullOutput: oversizedJSON
            )
        )

        guard case .text(let jsonText, let jsonLanguage) = jsonFallback.expandedContent else {
            Issue.record("Expected text fallback for oversized json")
            return
        }
        #expect(jsonLanguage == nil)
        #expect(jsonText.contains("json preview skipped (over 64KB)"))
        #expect(jsonFallback.copyOutputText == oversizedJSON)

        let oversizedMarkdown = String(repeating: "- row\n", count: 20_000)
        let markdownFallback = ToolPresentationBuilder.build(
            itemID: "ext-md-over-budget", tool: "extensions.notes",
            argsSummary: "",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext(
                details: .object(["presentationFormat": .string("markdown")]),
                expanded: ["ext-md-over-budget"],
                fullOutput: oversizedMarkdown
            )
        )

        guard case .text(let markdownText, let markdownLanguage) = markdownFallback.expandedContent else {
            Issue.record("Expected text fallback for oversized markdown")
            return
        }
        #expect(markdownLanguage == nil)
        #expect(markdownText.contains("markdown preview skipped (over 64KB)"))
        #expect(markdownFallback.copyOutputText == oversizedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test("extension expanded strips invocation echo and excessive blank lines")
    func extensionExpandedStripsInvocationEcho() {
        let noisyOutput = """
        remember tags: [6 items], text:
        Oppi timeline epic status sync
        M3 complete, dispatch M4



        Saved to journal: 2026-02-28-mac-studio.md
        """

        let config = ToolPresentationBuilder.build(
            itemID: "t-remember", tool: "remember",
            argsSummary: "tags: [6 items], text: Oppi timeline epic status sync",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext(expanded: ["t-remember"], fullOutput: noisyOutput)
        )

        guard case .text(let text, let language) = config.expandedContent else {
            Issue.record("Expected .text content for remember tool")
            return
        }

        #expect(language == nil)
        #expect(text == "Saved to journal: 2026-02-28-mac-studio.md")
        #expect(config.copyOutputText == "Saved to journal: 2026-02-28-mac-studio.md")

        let namespacedOutput = """
        extensions.remember(tags: [2], text: first line
        second line)

        Saved to journal: 2026-02-28-mac-studio.md
        """

        let namespaced = ToolPresentationBuilder.build(
            itemID: "t-remember-ns", tool: "extensions.remember",
            argsSummary: "tags: [2], text: first line",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext(expanded: ["t-remember-ns"], fullOutput: namespacedOutput)
        )

        guard case .text(let namespacedText, _) = namespaced.expandedContent else {
            Issue.record("Expected .text content for namespaced remember tool")
            return
        }

        #expect(namespacedText == "Saved to journal: 2026-02-28-mac-studio.md")
    }

    @Test("extension expanded quoted invocation + ansi progress lines reproduces empty-space bug")
    func extensionExpandedQuotedInvocationWithANSIProgressArtifacts() {
        let ansiClearLine = "\u{001B}[2K"
        let ansiProgressBlock = Array(repeating: ansiClearLine, count: 120).joined(separator: "\n")
        let noisyOutput = """
        \(ansiProgressBlock)
        remember "Compacted summary and details"
        \(ansiProgressBlock)

        Saved to journal: 2026-02-28-mac-studio.md
        """

        let config = ToolPresentationBuilder.build(
            itemID: "t-remember-quoted-ansi", tool: "remember",
            argsSummary: "text: Compacted summary and details",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext(expanded: ["t-remember-quoted-ansi"], fullOutput: noisyOutput)
        )

        guard case .text(let text, let language) = config.expandedContent else {
            Issue.record("Expected .text content for remember tool")
            return
        }

        #expect(language == nil)
        #expect(text == "Saved to journal: 2026-02-28-mac-studio.md")
        #expect(!text.contains("remember \"Compacted"))
        #expect(!text.contains("\u{001B}["))
        #expect(config.copyOutputText == "Saved to journal: 2026-02-28-mac-studio.md")
    }

    @Test("extension lookup collapsed uses segments when available")
    func extensionLookupCollapsedWithSegments() throws {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "extensions.lookup",
            argsSummary: "query: architecture decisions",
            outputPreview: "",
            isError: false, isDone: true,
            context: .init(
                args: nil, expandedItemIDs: [], fullOutput: "", isLoadingOutput: false,
                callSegments: [
                    StyledSegment(text: "lookup ", style: .bold),
                    StyledSegment(text: "\"architecture decisions\"", style: .muted),
                    StyledSegment(text: " scope:journal", style: .dim),
                    StyledSegment(text: " 7d", style: .dim),
                ],
                resultSegments: [
                    StyledSegment(text: "5 match(es)", style: .success),
                    StyledSegment(text: " — top: ", style: .muted),
                    StyledSegment(text: "[0.85] Design doc", style: .dim),
                ]
            )
        )

        let title = try #require(config.segmentAttributedTitle)
        let trailing = try #require(config.segmentAttributedTrailing)
        #expect(title.string == "lookup \"architecture decisions\" scope:journal 7d")
        #expect(trailing.string == "5 match(es) — top: [0.85] Design doc")
    }

    @Test("extension lookup collapsed falls back to default when no segments")
    func extensionLookupCollapsedNoSegments() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "extensions.lookup",
            argsSummary: "query: test",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext()
        )

        // Without segments, falls through to default: tool + argsSummary
        #expect(config.segmentAttributedTitle == nil)
        #expect(config.title.contains("extensions.lookup"))
    }

    // MARK: - Expanded Text Primitive (details.expandedText)

    @Test("extension expanded uses details.expandedText when present")
    func extensionExpandedTextFromDetails() {
        let config = ToolPresentationBuilder.build(
            itemID: "t-expanded", tool: "remember",
            argsSummary: "text: Important discovery",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext(
                details: .object([
                    "expandedText": .string("Important discovery about architecture.\n\nTags: oppi, design"),
                    "presentationFormat": .string("markdown"),
                ]),
                expanded: ["t-expanded"],
                fullOutput: "Saved to journal: 2026-03-04.md"
            )
        )

        guard case .markdown(let md) = config.expandedContent else {
            Issue.record("Expected .markdown content from details.expandedText")
            return
        }

        #expect(md.contains("Important discovery about architecture"))
        #expect(md.contains("Tags: oppi, design"))
        #expect(!md.contains("Saved to journal"))
    }

    @Test("extension expanded falls back to raw output when no expandedText")
    func extensionExpandedTextFallback() {
        let config = ToolPresentationBuilder.build(
            itemID: "t-no-expanded", tool: "extensions.custom",
            argsSummary: "",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext(
                expanded: ["t-no-expanded"],
                fullOutput: "plain output text"
            )
        )

        guard case .text(let text, _) = config.expandedContent else {
            Issue.record("Expected .text content when no expandedText")
            return
        }
        #expect(text == "plain output text")
    }

    @Test("extension expanded with expandedText and code format renders code")
    func extensionExpandedTextCodeFormat() {
        let code = "func hello() { print(\"world\") }"
        let config = ToolPresentationBuilder.build(
            itemID: "t-code-expanded", tool: "extensions.codegen",
            argsSummary: "",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext(
                details: .object([
                    "expandedText": .string(code),
                    "presentationFormat": .string("code"),
                    "language": .string("swift"),
                ]),
                expanded: ["t-code-expanded"],
                fullOutput: "Generated 1 file"
            )
        )

        guard case .code(let text, let language, _, _) = config.expandedContent else {
            Issue.record("Expected .code content from expandedText + code format")
            return
        }
        #expect(text == code)
        #expect(language == .swift)
    }

    @Test("extension expanded with empty expandedText uses raw output")
    func extensionExpandedTextEmpty() {
        let config = ToolPresentationBuilder.build(
            itemID: "t-empty-expanded", tool: "extensions.custom",
            argsSummary: "",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext(
                details: .object([
                    "expandedText": .string(""),
                ]),
                expanded: ["t-empty-expanded"],
                fullOutput: "fallback output"
            )
        )

        // Empty expandedText should fall through to raw output
        guard case .text(let text, _) = config.expandedContent else {
            Issue.record("Expected .text content for empty expandedText")
            return
        }
        #expect(text == "fallback output")
    }

    // MARK: - Unknown Tool

    @Test("unknown tool uses raw name")
    func unknownTool() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "custom_tool",
            argsSummary: "some args",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext()
        )

        #expect(config.title == "custom_tool some args")
        #expect(config.toolNamePrefix == "custom_tool")
    }

    @Test("unknown tool expanded shows output")
    func unknownToolExpanded() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "custom_tool",
            argsSummary: "",
            outputPreview: "tool output text",
            isError: false, isDone: true,
            context: emptyContext(expanded: ["t1"], fullOutput: "full tool output")
        )

        guard case .text(let text, _) = config.expandedContent else {
            Issue.record("Expected .text content for unknown tool")
            return
        }
        #expect(text == "full tool output")
    }

    // MARK: - Title Truncation

    @Test("title is truncated at 240 chars")
    func titleTruncation() {
        let longArgs = String(repeating: "x", count: 300)
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "custom",
            argsSummary: longArgs,
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext()
        )

        #expect(config.title.count == 240)
        #expect(config.title.hasSuffix("…"))
    }

    // MARK: - Error State

    @Test("error state is passed through")
    func errorState() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "bash",
            argsSummary: "command: bad",
            outputPreview: "command not found",
            isError: true, isDone: true,
            context: emptyContext(args: ["command": .string("bad")])
        )

        #expect(config.isError)
        #expect(config.isDone)
    }

    // MARK: - Media Warning

    @Test("inline media warning for unknown tool with data URI")
    func mediaWarning() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "custom_render",
            argsSummary: "",
            outputPreview: "here is data:image/png;base64,abc",
            isError: false, isDone: true,
            context: emptyContext()
        )

        #expect(config.languageBadge == "⚠︎media")
    }

    @Test("no media warning for bash tool with data URI")
    func noMediaWarningForBash() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "bash",
            argsSummary: "command: cat img.txt",
            outputPreview: "data:image/png;base64,abc",
            isError: false, isDone: true,
            context: emptyContext(args: ["command": .string("cat img.txt")])
        )

        #expect(config.languageBadge == nil)
    }

    // MARK: - File Type Helpers

    @Test("readOutputFileType detects Swift")
    func readFileTypeSwift() {
        let ft = ToolPresentationBuilder.readOutputFileType(
            args: ["path": .string("Oppi/App.swift")],
            argsSummary: ""
        )
        #expect(ft == .code(language: .swift))
    }

    @Test("readOutputFileType detects markdown")
    func readFileTypeMarkdown() {
        let ft = ToolPresentationBuilder.readOutputFileType(
            args: ["path": .string("README.md")],
            argsSummary: ""
        )
        #expect(ft == .markdown)
    }

    @Test("readOutputLanguage returns swift for .swift files")
    func readLanguageSwift() {
        let lang = ToolPresentationBuilder.readOutputLanguage(
            args: ["path": .string("file.swift")],
            argsSummary: ""
        )
        #expect(lang == .swift)
    }

    @Test("readOutputLanguage returns nil for markdown")
    func readLanguageMarkdown() {
        let lang = ToolPresentationBuilder.readOutputLanguage(
            args: ["path": .string("README.md")],
            argsSummary: ""
        )
        #expect(lang == nil)
    }

    // MARK: - Collapsed Image Preview

    @Test("read image file provides collapsed image preview")
    func readImageCollapsedPreview() {
        let fakeBase64 = "iVBORw0KGgo="
        let output = "Read image file [image/png]\ndata:image/png;base64,\(fakeBase64)"

        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "read",
            argsSummary: "path: icon.png",
            outputPreview: output,
            isError: false, isDone: true,
            context: emptyContext(
                args: ["path": .string("icon.png")],
                fullOutput: output
            )
        )

        #expect(config.collapsedImageBase64 == fakeBase64)
        #expect(config.collapsedImageMimeType == "image/png")
    }

    @Test("read non-image file has no collapsed image preview")
    func readTextFileNoImagePreview() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "read",
            argsSummary: "path: server.ts",
            outputPreview: "const x = 1;",
            isError: false, isDone: true,
            context: emptyContext(
                args: ["path": .string("server.ts")],
                fullOutput: "const x = 1;"
            )
        )

        #expect(config.collapsedImageBase64 == nil)
        #expect(config.collapsedImageMimeType == nil)
    }

    @Test("read image with no data URI yet has no preview")
    func readImageNoDataURIYet() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "read",
            argsSummary: "path: icon.png",
            outputPreview: "Read image file [image/png]",
            isError: false, isDone: false,
            context: emptyContext(
                args: ["path": .string("icon.png")],
                fullOutput: "Read image file [image/png]"
            )
        )

        #expect(config.collapsedImageBase64 == nil)
    }

    @Test("expanded image read uses readMedia content")
    func readImageExpandedUsesReadMedia() {
        let fakeBase64 = "iVBORw0KGgo="
        let output = "Read image file [image/png]\ndata:image/png;base64,\(fakeBase64)"

        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "read",
            argsSummary: "path: icon.png",
            outputPreview: output,
            isError: false, isDone: true,
            context: emptyContext(
                args: ["path": .string("icon.png")],
                expanded: ["t1"],
                fullOutput: output
            )
        )

        #expect(config.isExpanded)
        guard case .readMedia = config.expandedContent else {
            Issue.record("Expected .readMedia content for image read")
            return
        }
        // Builder still provides preview data, cell decides visibility
        #expect(config.collapsedImageBase64 == fakeBase64)
    }

    @Test("non-read tool has no collapsed image preview")
    func bashNoImagePreview() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "bash",
            argsSummary: "command: cat icon.png",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext(args: ["command": .string("cat icon.png")])
        )

        #expect(config.collapsedImageBase64 == nil)
    }
}

private func modeName(_ content: ToolPresentationBuilder.ToolExpandedContent?) -> String {
    switch content {
    case .bash:
        return "bash"
    case .diff:
        return "diff"
    case .code:
        return "code"
    case .markdown:
        return "markdown"
    case .readMedia:
        return "readMedia"
    case .status:
        return "status"
    case .text:
        return "text"
    case nil:
        return "nil"
    }
}
