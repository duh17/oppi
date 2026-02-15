import Testing
import UIKit

@testable import Oppi

@MainActor
@Suite("ToolPresentationBuilder")
struct ToolPresentationBuilderTests {

    private func emptyContext(
        args: [String: JSONValue]? = nil,
        expanded: Set<String> = [],
        fullOutput: String = "",
        isLoadingOutput: Bool = false
    ) -> ToolPresentationBuilder.Context {
        ToolPresentationBuilder.Context(
            args: args,
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
        #expect(config.showSeparatedCommandAndOutput)
        #expect(config.expandedCommandText == "echo hello")
        #expect(config.expandedOutputText == "hello\nworld")
        #expect(config.prefersUnwrappedOutput)
        #expect(config.title == "bash") // expanded bash shows just "bash"
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
        #expect(config.expandedText == "full content here")
        #expect(config.expandedCodeStartLine == 42)
        #expect(config.expandedCodeFilePath == "server.ts")
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

        #expect(config.expandedText == "Loading read output…")
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
        // editAdded/editRemoved are computed from diff
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
        #expect(config.expandedDiffLines != nil)
        #expect(!config.expandedDiffLines!.isEmpty)
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

        #expect(config.expandedText == content)
        #expect(config.expandedOutputLanguage == .typescript)
        #expect(config.expandedCodeStartLine == 1)
        #expect(config.expandedCodeFilePath == "src/index.ts")
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

        #expect(config.expandedText == content)
        #expect(config.expandedTextUsesMarkdown == true)
        #expect(config.expandedOutputLanguage == nil)
    }

    @Test("write expanded falls back to output when content missing")
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

        #expect(config.expandedText == "Successfully wrote 10 bytes to file.txt")
        #expect(config.expandedTextUsesMarkdown == false)
    }

    // MARK: - Todo

    @Test("todo collapsed shows summary")
    func todoCollapsed() {
        let config = ToolPresentationBuilder.build(
            itemID: "t1", tool: "todo",
            argsSummary: "action: create, title: Add tests",
            outputPreview: "",
            isError: false, isDone: true,
            context: emptyContext(args: [
                "action": .string("create"),
                "title": .string("Add tests"),
            ])
        )

        #expect(config.title == "todo create Add tests")
        #expect(config.toolNamePrefix == "todo")
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

        #expect(config.expandedText == "full tool output")
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
}
