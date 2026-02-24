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

        guard case .text(let text, _) = config.expandedContent else {
            Issue.record("Expected .text content for loading state")
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

    // MARK: - Todo

    @Test("todo collapsed uses segments when available")
    func todoCollapsedWithSegments() throws {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "todo",
            argsSummary: "action: create, title: Add tests",
            outputPreview: "",
            isError: false, isDone: true,
            context: .init(
                args: nil, expandedItemIDs: [], fullOutput: "", isLoadingOutput: false,
                callSegments: [
                    StyledSegment(text: "todo ", style: .bold),
                    StyledSegment(text: "create", style: .muted),
                    StyledSegment(text: " \"Add tests\"", style: .dim),
                ]
            )
        )

        let title = try #require(config.segmentAttributedTitle)
        #expect(title.string == "todo create \"Add tests\"")
        #expect(config.toolNamePrefix == "todo")
    }

    @Test("todo collapsed falls back to default when no segments")
    func todoCollapsedNoSegments() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "todo",
            argsSummary: "action: create, title: Add tests",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext()
        )

        // Without segments, falls through to default: tool + argsSummary
        #expect(config.segmentAttributedTitle == nil)
        #expect(config.title.contains("todo"))
        #expect(config.toolNamePrefix == "todo")
    }

    @Test("todo collapsed path stays cheaper than expanded diff path")
    func todoCollapsedVsExpandedCost() {
        let body = (0..<1_200)
            .map { "line-\($0): append detail" }
            .joined(separator: "\n")
        let args: [String: JSONValue] = [
            "action": .string("append"),
            "id": .string("TODO-a27df231"),
            "body": .string(body),
        ]

        let iterations = 30

        let collapsedStart = DispatchTime.now().uptimeNanoseconds
        for index in 0..<iterations {
            _ = ToolPresentationBuilder.build(
                itemID: "todo-collapsed-\(index)",
                tool: "todo",
                argsSummary: "action: append, id: TODO-a27df231",
                outputPreview: "",
                isError: false,
                isDone: true,
                context: emptyContext(args: args)
            )
        }
        let collapsedElapsed = DispatchTime.now().uptimeNanoseconds - collapsedStart

        let expandedStart = DispatchTime.now().uptimeNanoseconds
        for index in 0..<iterations {
            let itemID = "todo-expanded-\(index)"
            _ = ToolPresentationBuilder.build(
                itemID: itemID,
                tool: "todo",
                argsSummary: "action: append, id: TODO-a27df231",
                outputPreview: "",
                isError: false,
                isDone: true,
                context: emptyContext(args: args, expanded: [itemID])
            )
        }
        let expandedElapsed = DispatchTime.now().uptimeNanoseconds - expandedStart

        #expect(collapsedElapsed < expandedElapsed)
    }

    // MARK: - Remember

    @Test("remember collapsed uses segments when available")
    func rememberCollapsedWithSegments() throws {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "remember",
            argsSummary: "text: Some important discovery",
            outputPreview: "",
            isError: false, isDone: true,
            context: .init(
                args: nil, expandedItemIDs: [], fullOutput: "", isLoadingOutput: false,
                callSegments: [
                    StyledSegment(text: "remember ", style: .bold),
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
        #expect(title.string == "remember \"Some important discovery\" [oppi, ios]")
        #expect(trailing.string == "✓ Saved → journal")
    }

    @Test("remember expanded shows full text and tags")
    func rememberExpanded() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "remember",
            argsSummary: "",
            outputPreview: "Saved to journal",
            isError: false, isDone: true,
            context: emptyContext(
                args: [
                    "text": .string("Full discovery text"),
                    "tags": .array([.string("tag1")]),
                ],
                expanded: ["t1"]
            )
        )

        guard case .markdown(let text) = config.expandedContent else {
            Issue.record("Expected .markdown content for remember")
            return
        }
        #expect(text == "Full discovery text\n\nTags: tag1")
    }

    // MARK: - Recall

    @Test("recall collapsed uses segments when available")
    func recallCollapsedWithSegments() throws {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "recall",
            argsSummary: "query: architecture decisions",
            outputPreview: "",
            isError: false, isDone: true,
            context: .init(
                args: nil, expandedItemIDs: [], fullOutput: "", isLoadingOutput: false,
                callSegments: [
                    StyledSegment(text: "recall ", style: .bold),
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
        #expect(title.string == "recall \"architecture decisions\" scope:journal 7d")
        #expect(trailing.string == "5 match(es) — top: [0.85] Design doc")
    }

    @Test("recall collapsed falls back to default when no segments")
    func recallCollapsedNoSegments() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "recall",
            argsSummary: "query: test",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext()
        )

        // Without segments, falls through to default: tool + argsSummary
        #expect(config.segmentAttributedTitle == nil)
        #expect(config.title.contains("recall"))
    }

    // MARK: - Plot

    @Test("plot collapsed prefers details title")
    func plotCollapsedPrefersDetailsTitle() {
        let config = ToolPresentationBuilder.build(
            itemID: "t-plot",
            tool: "plot",
            argsSummary: "spec: {…}",
            outputPreview: "",
            isError: false,
            isDone: true,
            context: emptyContext(
                args: [
                    "title": .string("args title"),
                ],
                details: .object([
                    "ui": .array([
                        .object([
                            "id": .string("chart-1"),
                            "kind": .string("chart"),
                            "version": .number(1),
                            "title": .string("details title"),
                            "spec": .object([
                                "dataset": .object([
                                    "rows": .array([
                                        .object(["x": .number(0), "y": .number(1)]),
                                    ]),
                                ]),
                                "marks": .array([
                                    .object(["type": .string("line"), "x": .string("x"), "y": .string("y")]),
                                ]),
                            ]),
                        ]),
                    ]),
                ])
            )
        )

        #expect(config.title == "details title")
        #expect(config.toolNamePrefix == "plot")
    }

    @Test("plot expanded uses details ui when args spec missing")
    func plotExpandedUsesDetailsChart() {
        let config = ToolPresentationBuilder.build(
            itemID: "t-plot",
            tool: "plot",
            argsSummary: "",
            outputPreview: "fallback output",
            isError: false,
            isDone: true,
            context: emptyContext(
                details: .object([
                    "ui": .array([
                        .object([
                            "id": .string("chart-1"),
                            "kind": .string("chart"),
                            "version": .number(1),
                            "fallbackText": .string("details fallback"),
                            "spec": .object([
                                "title": .string("details chart"),
                                "dataset": .object([
                                    "rows": .array([
                                        .object(["x": .number(0), "pace": .number(295)]),
                                        .object(["x": .number(1), "pace": .number(292)]),
                                    ]),
                                ]),
                                "marks": .array([
                                    .object(["type": .string("line"), "x": .string("x"), "y": .string("pace")]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
                expanded: ["t-plot"],
                fullOutput: "fallback output"
            )
        )

        guard case .plot(let spec, let fallbackText) = config.expandedContent else {
            Issue.record("Expected .plot content from details ui")
            return
        }

        #expect(spec.title == "details chart")
        #expect(spec.rows.count == 2)
        #expect(spec.marks.count == 1)
        #expect(fallbackText == "details fallback")
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
