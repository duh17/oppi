import Testing

@testable import Oppi

@Suite("ToolContentDescriptor")
struct ToolContentDescriptorTests {

    // MARK: - Structured diff

    @Test("structured edit patch keeps absolute line numbers")
    func structuredDiffKeepsAbsoluteLineNumbers() throws {
        // Line-prefix models (MacDiffOutputModel) drop hunk starts and treat
        // `---` / `+++` as headers without old/new numbers. The shared builder
        // must keep UnifiedPatchParser line numbers.
        let presentation = build(
            tool: "edit",
            argsSummary: "path: App.swift",
            args: [
                "path": .string("App.swift"),
                "edits": .array([
                    .object([
                        "oldText": .string("var body: some View {\n    HStack(spacing: 5) {\n        if isAnimated {"),
                        "newText": .string("var body: some View {\n    HStack(spacing: 5) {\n        Image(systemName: \"terminal.fill\")\n        if isAnimated {"),
                    ]),
                ]),
            ],
            details: .object([
                "patch": .string("""
                --- App.swift
                +++ App.swift
                @@ -314,3 +314,4 @@
                 var body: some View {
                     HStack(spacing: 5) {
                +        Image(systemName: \"terminal.fill\")
                     if isAnimated {
                """),
            ])
        )

        guard case .diff(let diff) = presentation.content else {
            Issue.record("Expected structured .diff, got \(String(describing: presentation.content))")
            return
        }

        let firstContext = try #require(diff.lines.first { $0.text == "var body: some View {" })
        let added = try #require(diff.lines.first { $0.text.contains("Image(systemName:") })
        #expect(diff.path == "App.swift")
        #expect(firstContext.oldLineNumber == 314)
        #expect(firstContext.newLineNumber == 314)
        #expect(added.oldLineNumber == nil)
        #expect(added.newLineNumber == 316)
        #expect(presentation.copyOutputText?.contains("Image(systemName:") == true)
    }

    @Test("extension single-file format=diff uses parsed hunk lines")
    func extensionStructuredDiffUsesParser() throws {
        let diffText = """
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,2 +1,2 @@
        -let value = 1
        +let value = 2
        """

        let presentation = build(
            tool: "extensions.patch",
            details: .object([
                "presentationFormat": .string("diff"),
                "filePath": .string("Sources/App.swift"),
            ]),
            fullOutput: diffText
        )

        guard case .diff(let diff) = presentation.content else {
            Issue.record("Expected .diff, got \(String(describing: presentation.content))")
            return
        }
        #expect(diff.path == "Sources/App.swift")
        #expect(diff.lines.contains { $0.kind == .removed && $0.text == "let value = 1" })
        #expect(diff.lines.contains { $0.kind == .added && $0.text == "let value = 2" })
        let first = try #require(diff.lines.first)
        #expect(first.oldLineNumber == 1 || first.newLineNumber == 1)
    }

    // MARK: - Multi-file diff fallback

    @Test("multi-file patches stay original unified text")
    func multiFileDiffStaysUnifiedText() {
        // MacDiffOutputModel.shouldRender is true for these markers and then
        // flattens every file into one line list. The descriptor must not.
        let diffText = """
        --- a/A.swift
        +++ b/A.swift
        @@ -1 +1 @@
        -old-a
        +new-a
        --- a/B.swift
        +++ b/B.swift
        @@ -1 +1 @@
        -old-b
        +new-b
        """

        let hinted = build(
            tool: "extensions.patch",
            details: .object(["presentationFormat": .string("diff")]),
            fullOutput: diffText
        )
        let auto = build(tool: "extensions.patch", fullOutput: diffText)

        guard case .terminal(let hintedTerminal) = hinted.content else {
            Issue.record("Expected terminal/text for hinted multi-file, got \(String(describing: hinted.content))")
            return
        }
        guard case .terminal(let autoTerminal) = auto.content else {
            Issue.record("Expected terminal/text for auto multi-file, got \(String(describing: auto.content))")
            return
        }

        #expect(hintedTerminal.unwrapped == false)
        #expect(hintedTerminal.language == nil)
        #expect(hintedTerminal.output == diffText)
        #expect(autoTerminal.output == diffText)
        #expect(hintedTerminal.output?.contains("[render note:") == false)
        #expect(hintedTerminal.output?.contains("--- a/A.swift") == true)
        #expect(hintedTerminal.output?.contains("--- a/B.swift") == true)
    }

    @Test("text hunk plus binary second file stays unified text")
    func textPlusBinaryMultiFileStaysUnifiedText() {
        let diffText = """
        --- a/A.swift
        +++ b/A.swift
        @@ -1 +1 @@
        -old-a
        +new-a
        diff --git a/photo.png b/photo.png
        index 1111111..2222222 100644
        Binary files a/photo.png and b/photo.png differ
        """

        let presentation = build(
            tool: "extensions.patch",
            details: .object(["presentationFormat": .string("diff")]),
            fullOutput: diffText
        )

        guard case .terminal(let terminal) = presentation.content else {
            Issue.record("Expected unified text, got \(String(describing: presentation.content))")
            return
        }
        #expect(terminal.output == diffText)
        #expect(terminal.output?.contains("Binary files a/photo.png") == true)
    }

    // MARK: - Code / Markdown / file metadata

    @Test("code language comes from file path not content heuristics")
    func codeLanguageComesFromFilePath() {
        // MacCodeOutputModel.inferredLanguage sees `func ` + `{` and reports
        // Swift even when the path is Python.
        let source = "func helper():\n    return 1"
        let presentation = build(
            tool: "read",
            argsSummary: "path: src/helper.py",
            args: ["path": .string("src/helper.py")],
            fullOutput: source
        )

        guard case .file(let file) = presentation.content else {
            Issue.record("Expected .file, got \(String(describing: presentation.content))")
            return
        }
        #expect(file.filePath == "src/helper.py")
        #expect(file.fileType == .code(language: .python))
        #expect(file.language == .python)
        #expect(file.text == source)
        #expect(file.startLine == 1)
    }

    @Test("extension code hints supply language path and start line")
    func extensionCodeHintsSupplyMetadata() {
        let code = "func extensionMode() -> String {\n    \"ok\"\n}"
        let presentation = build(
            tool: "extensions.codegen",
            details: .object([
                "presentationFormat": .string("code"),
                "language": .string("swift"),
                "filePath": .string("Sources/ExtensionMode.swift"),
                "startLine": .number(42),
            ]),
            fullOutput: code
        )

        guard case .code(let descriptor) = presentation.content else {
            Issue.record("Expected .code, got \(String(describing: presentation.content))")
            return
        }
        #expect(descriptor.text == code)
        #expect(descriptor.language == .swift)
        #expect(descriptor.startLine == 42)
        #expect(descriptor.filePath == "Sources/ExtensionMode.swift")
    }

    @Test("markdown file type is resolved from path")
    func markdownFileTypeFromPath() {
        let body = "# Header\n\nBody"
        let presentation = build(
            tool: "read",
            argsSummary: "path: README.md",
            args: ["path": .string("README.md")],
            fullOutput: body
        )

        guard case .file(let file) = presentation.content else {
            Issue.record("Expected .file, got \(String(describing: presentation.content))")
            return
        }
        #expect(file.filePath == "README.md")
        #expect(file.fileType == .markdown)
        #expect(file.language == nil)
        #expect(file.text == body)
    }

    @Test("tex read language is latex on the descriptor and iOS code view")
    @MainActor
    func texReadLanguageIsLatex() {
        let body = "\\documentclass{article}\n\\begin{document}\nHello\n\\end{document}"
        let presentation = build(
            tool: "read",
            argsSummary: "path: notes.tex",
            args: ["path": .string("notes.tex")],
            fullOutput: body
        )

        guard case .file(let file) = presentation.content else {
            Issue.record("Expected .file, got \(String(describing: presentation.content))")
            return
        }
        #expect(file.filePath == "notes.tex")
        #expect(file.fileType == .latex)
        #expect(file.language == .latex)
        #expect(file.text == body)

        let config = ToolPresentationBuilder.build(
            itemID: "read-tex",
            tool: "read",
            argsSummary: "path: notes.tex",
            outputPreview: body,
            isError: false,
            isDone: true,
            context: ToolPresentationBuilder.Context(
                args: ["path": .string("notes.tex")],
                expandedItemIDs: ["read-tex"],
                fullOutput: body,
                isLoadingOutput: false
            )
        )
        guard case .code(_, let language, _, let filePath) = config.expandedContent else {
            Issue.record("Expected iOS .code, got \(String(describing: config.expandedContent))")
            return
        }
        #expect(language == .latex)
        #expect(filePath == "notes.tex")
    }

    @Test("extension markdown format uses markdown descriptor")
    func extensionMarkdownFormat() {
        let body = "# Header\n\nBody"
        let presentation = build(
            tool: "extensions.notes",
            details: .object(["presentationFormat": .string("markdown")]),
            fullOutput: body
        )

        guard case .markdown(let markdown) = presentation.content else {
            Issue.record("Expected .markdown, got \(String(describing: presentation.content))")
            return
        }
        #expect(markdown.text == body)
    }

    // MARK: - Media metadata

    @Test("read media uses attachment ids not inline data URIs")
    func readMediaUsesAttachmentMetadata() {
        // MacMediaOutputModel parses base64 data URIs and ignores details.media.
        let presentation = build(
            tool: "read",
            argsSummary: "path: icon.png",
            args: ["path": .string("icon.png")],
            details: .object([
                "media": .array([
                    .object([
                        "kind": .string("image"),
                        "id": .string("att-image-1"),
                        "mimeType": .string("image/png"),
                        "fileName": .string("icon.png"),
                        "sizeBytes": .number(1234),
                        "sha256": .string("abc123"),
                        "width": .number(80),
                        "height": .number(220),
                    ]),
                ]),
            ])
        )

        guard case .file(let file) = presentation.content else {
            Issue.record("Expected .file media, got \(String(describing: presentation.content))")
            return
        }
        #expect(file.filePath == "icon.png")
        #expect(file.fileType == .image)
        #expect(file.attachments.count == 1)
        #expect(file.attachments.first?.id == "att-image-1")
        #expect(file.attachments.first?.mimeType == "image/png")
        #expect(file.attachments.first?.sha256 == "abc123")
        #expect(file.attachments.first?.height == 220)
        #expect(file.text.isEmpty)
    }

    @Test("generic image tool uses details.image attachment id")
    func genericImageUsesAttachmentId() {
        let presentation = build(
            tool: "imagen",
            details: .object([
                "image": .object([
                    "kind": .string("image"),
                    "id": .string("att-image-1"),
                    "mimeType": .string("image/png"),
                    "fileName": .string("kitten.png"),
                    "width": .number(512),
                    "height": .number(384),
                ]),
            ]),
            fullOutput: "Generated image"
        )

        guard case .media(let media) = presentation.content else {
            Issue.record("Expected .media, got \(String(describing: presentation.content))")
            return
        }
        #expect(media.filePath == "kitten.png")
        #expect(media.attachments.first?.id == "att-image-1")
        #expect(media.attachments.first?.width == 512)
        #expect(media.output == "Generated image")
        #expect(presentation.copyOutputText == "Generated image")
    }

    // MARK: - Terminal precedence

    @Test("terminal format wins over markdown and diff heuristics")
    func terminalFormatWinsOverContentHeuristics() {
        let formatted = "\u{001B}[1m$\u{001B}[0m oppi session get sess-1\n\n## Result\n- **Status:** ready\n--- a/file\n+++ b/file"
        let presentation = build(
            tool: "oppi",
            details: .object([
                "expandedText": .string(formatted),
                "presentationFormat": .string("terminal"),
            ]),
            fullOutput: "{\"ok\":true}"
        )

        guard case .terminal(let terminal) = presentation.content else {
            Issue.record("Expected .terminal, got \(String(describing: presentation.content))")
            return
        }
        #expect(terminal.output == formatted)
        #expect(terminal.unwrapped == false)
        #expect(terminal.language == nil)
        #expect(presentation.copyOutputText == ANSIParser.strip(formatted))
    }

    @Test("bash is terminal with command and unwrapped output")
    func bashIsUnwrappedTerminal() {
        let presentation = build(
            tool: "bash",
            argsSummary: "command: echo hello",
            args: ["command": .string("echo hello")],
            fullOutput: "hello\nworld"
        )

        guard case .terminal(let terminal) = presentation.content else {
            Issue.record("Expected .terminal, got \(String(describing: presentation.content))")
            return
        }
        #expect(terminal.command == "echo hello")
        #expect(terminal.output == "hello\nworld")
        #expect(terminal.unwrapped)
        #expect(presentation.copyCommandText == "echo hello")
        #expect(presentation.copyOutputText == "hello\nworld")
    }

    // MARK: - Malformed metadata

    @Test("malformed media entries are dropped")
    func malformedMediaEntriesAreDropped() {
        let presentation = build(
            tool: "read",
            argsSummary: "path: icon.png",
            args: ["path": .string("icon.png")],
            details: .object([
                "media": .array([
                    .string("not-an-object"),
                    .object([
                        "kind": .string("image"),
                        "id": .string("  "),
                        "mimeType": .string("image/png"),
                    ]),
                    .object([
                        "kind": .string("image"),
                        "mimeType": .string("image/png"),
                    ]),
                    .object([
                        "kind": .string("image"),
                        "id": .string("att-good"),
                        "mimeType": .string("image/jpeg"),
                        "fileName": .string("icon.png"),
                    ]),
                ]),
            ])
        )

        guard case .file(let file) = presentation.content else {
            Issue.record("Expected .file, got \(String(describing: presentation.content))")
            return
        }
        #expect(file.attachments.map(\.id) == ["att-good"])
        #expect(file.attachments.first?.mimeType == "image/jpeg")
    }

    @Test("image details without id are ignored")
    func imageDetailsWithoutIdAreIgnored() {
        let presentation = build(
            tool: "imagen",
            details: .object([
                "image": .object([
                    "kind": .string("image"),
                    "id": .string(""),
                    "mimeType": .string("image/png"),
                    "fileName": .string("kitten.png"),
                ]),
            ]),
            fullOutput: "Generated image"
        )

        guard case .terminal(let terminal) = presentation.content else {
            Issue.record("Expected plaintext fallback, got \(String(describing: presentation.content))")
            return
        }
        #expect(terminal.output == "Generated image")
        #expect(terminal.unwrapped == false)
    }

    @Test("invalid explicit diff format notes and stays text")
    func invalidDiffFormatNotesAndStaysText() {
        let presentation = build(
            tool: "extensions.patch",
            details: .object(["presentationFormat": .string("diff")]),
            fullOutput: "this is not a unified diff"
        )

        guard case .terminal(let terminal) = presentation.content else {
            Issue.record("Expected text fallback, got \(String(describing: presentation.content))")
            return
        }
        #expect(terminal.output?.contains("diff preview unavailable") == true)
        #expect(presentation.copyOutputText == "this is not a unified diff")
    }

    @Test("pending write without body is status not plaintext")
    func pendingWriteWithoutBodyIsStatus() {
        let presentation = build(
            tool: "write",
            argsSummary: "path: src/index.ts",
            isDone: false,
            args: ["path": .string("src/index.ts")]
        )

        guard case .status(let message) = presentation.content else {
            Issue.record("Expected .status, got \(String(describing: presentation.content))")
            return
        }
        #expect(message == "Writing…")
        #expect(presentation.copyOutputText == nil)
    }

    // MARK: - Helpers

    private func build(
        tool: String,
        argsSummary: String = "",
        outputPreview: String = "",
        isError: Bool = false,
        isDone: Bool = true,
        args: [String: JSONValue]? = nil,
        details: JSONValue? = nil,
        fullOutput: String = "",
        isLoadingOutput: Bool = false
    ) -> ToolContentPresentation {
        ToolContentDescriptorBuilder.build(
            tool: tool,
            argsSummary: argsSummary,
            outputPreview: outputPreview,
            isError: isError,
            isDone: isDone,
            context: ToolContentDescriptorBuilder.Context(
                args: args,
                details: details,
                fullOutput: fullOutput,
                isLoadingOutput: isLoadingOutput
            )
        )
    }
}
