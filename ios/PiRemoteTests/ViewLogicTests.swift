import Testing
import Foundation
import SwiftUI
@testable import PiRemote

// MARK: - DiffEngine

@Suite("DiffEngine")
struct DiffEngineTests {

    @Test func emptyBoth() {
        let result = DiffEngine.compute(old: "", new: "")
        #expect(result.isEmpty)
    }

    @Test func emptyOldAllAdded() {
        let result = DiffEngine.compute(old: "", new: "a\nb\nc")
        #expect(result.count == 3)
        #expect(result.allSatisfy { $0.kind == .added })
        #expect(result.map(\.text) == ["a", "b", "c"])
    }

    @Test func emptyNewAllRemoved() {
        let result = DiffEngine.compute(old: "a\nb\nc", new: "")
        #expect(result.count == 3)
        #expect(result.allSatisfy { $0.kind == .removed })
        #expect(result.map(\.text) == ["a", "b", "c"])
    }

    @Test func identicalTexts() {
        let text = "line1\nline2\nline3"
        let result = DiffEngine.compute(old: text, new: text)
        #expect(result.count == 3)
        #expect(result.allSatisfy { $0.kind == .context })
    }

    @Test func singleLineChange() {
        let result = DiffEngine.compute(old: "hello", new: "world")
        let removed = result.filter { $0.kind == .removed }
        let added = result.filter { $0.kind == .added }
        #expect(removed.count == 1)
        #expect(removed[0].text == "hello")
        #expect(added.count == 1)
        #expect(added[0].text == "world")
    }

    @Test func contextPreserved() {
        let old = "a\nb\nc"
        let new = "a\nB\nc"
        let result = DiffEngine.compute(old: old, new: new)

        #expect(result.count == 4) // context a, removed b, added B, context c
        #expect(result[0] == DiffLine(kind: .context, text: "a"))
        #expect(result[1] == DiffLine(kind: .removed, text: "b"))
        #expect(result[2] == DiffLine(kind: .added, text: "B"))
        #expect(result[3] == DiffLine(kind: .context, text: "c"))
    }

    @Test func multipleEdits() {
        let old = "a\nb\nc\nd\ne"
        let new = "a\nB\nc\nD\ne"
        let result = DiffEngine.compute(old: old, new: new)

        let context = result.filter { $0.kind == .context }
        let removed = result.filter { $0.kind == .removed }
        let added = result.filter { $0.kind == .added }

        #expect(context.count == 3) // a, c, e
        #expect(removed.count == 2) // b, d
        #expect(added.count == 2)   // B, D
    }

    @Test func insertedLines() {
        let old = "a\nc"
        let new = "a\nb\nc"
        let result = DiffEngine.compute(old: old, new: new)

        #expect(result.count == 3)
        #expect(result[0] == DiffLine(kind: .context, text: "a"))
        #expect(result[1] == DiffLine(kind: .added, text: "b"))
        #expect(result[2] == DiffLine(kind: .context, text: "c"))
    }

    @Test func deletedLines() {
        let old = "a\nb\nc"
        let new = "a\nc"
        let result = DiffEngine.compute(old: old, new: new)

        #expect(result.count == 3)
        #expect(result[0] == DiffLine(kind: .context, text: "a"))
        #expect(result[1] == DiffLine(kind: .removed, text: "b"))
        #expect(result[2] == DiffLine(kind: .context, text: "c"))
    }

    @Test func trailingNewlineHandled() {
        // Trailing newline produces an empty last element from split — should be trimmed
        let old = "a\nb\n"
        let new = "a\nc\n"
        let result = DiffEngine.compute(old: old, new: new)

        let removed = result.filter { $0.kind == .removed }
        let added = result.filter { $0.kind == .added }
        #expect(removed.count == 1)
        #expect(removed[0].text == "b")
        #expect(added.count == 1)
        #expect(added[0].text == "c")
    }

    // MARK: - Stats

    @Test func statsCountsCorrectly() {
        let lines = [
            DiffLine(kind: .context, text: "a"),
            DiffLine(kind: .added, text: "b"),
            DiffLine(kind: .added, text: "c"),
            DiffLine(kind: .removed, text: "d"),
        ]
        let (added, removed) = DiffEngine.stats(lines)
        #expect(added == 2)
        #expect(removed == 1)
    }

    @Test func statsEmpty() {
        let (added, removed) = DiffEngine.stats([])
        #expect(added == 0)
        #expect(removed == 0)
    }

    // MARK: - Format

    @Test func formatUnified() {
        let lines = [
            DiffLine(kind: .context, text: "a"),
            DiffLine(kind: .removed, text: "b"),
            DiffLine(kind: .added, text: "B"),
        ]
        let formatted = DiffEngine.formatUnified(lines)
        #expect(formatted == "  a\n- b\n+ B")
    }

    // MARK: - DiffLine.Kind.prefix

    @Test func kindPrefixes() {
        #expect(DiffLine.Kind.context.prefix == " ")
        #expect(DiffLine.Kind.added.prefix == "+")
        #expect(DiffLine.Kind.removed.prefix == "-")
    }
}

// Make DiffLine Equatable for test assertions
extension DiffLine: @retroactive Equatable {
    public static func == (lhs: DiffLine, rhs: DiffLine) -> Bool {
        lhs.kind == rhs.kind && lhs.text == rhs.text
    }
}

// MARK: - SyntaxLanguage

@Suite("SyntaxLanguage")
struct SyntaxLanguageTests {

    @Test func detectSwift() {
        #expect(SyntaxLanguage.detect("swift") == .swift)
    }

    @Test func detectTypeScript() {
        #expect(SyntaxLanguage.detect("ts") == .typescript)
        #expect(SyntaxLanguage.detect("tsx") == .typescript)
        #expect(SyntaxLanguage.detect("typescript") == .typescript)
    }

    @Test func detectJavaScript() {
        #expect(SyntaxLanguage.detect("js") == .javascript)
        #expect(SyntaxLanguage.detect("jsx") == .javascript)
        #expect(SyntaxLanguage.detect("mjs") == .javascript)
    }

    @Test func detectPython() {
        #expect(SyntaxLanguage.detect("py") == .python)
        #expect(SyntaxLanguage.detect("pyi") == .python)
        #expect(SyntaxLanguage.detect("python") == .python)
    }

    @Test func detectGo() {
        #expect(SyntaxLanguage.detect("go") == .go)
        #expect(SyntaxLanguage.detect("golang") == .go)
    }

    @Test func detectRust() {
        #expect(SyntaxLanguage.detect("rs") == .rust)
        #expect(SyntaxLanguage.detect("rust") == .rust)
    }

    @Test func detectShell() {
        #expect(SyntaxLanguage.detect("sh") == .shell)
        #expect(SyntaxLanguage.detect("bash") == .shell)
        #expect(SyntaxLanguage.detect("zsh") == .shell)
    }

    @Test func detectJSON() {
        #expect(SyntaxLanguage.detect("json") == .json)
        #expect(SyntaxLanguage.detect("jsonl") == .json)
    }

    @Test func detectCpp() {
        #expect(SyntaxLanguage.detect("cpp") == .cpp)
        #expect(SyntaxLanguage.detect("cc") == .cpp)
        #expect(SyntaxLanguage.detect("hpp") == .cpp)
    }

    @Test func caseInsensitive() {
        #expect(SyntaxLanguage.detect("SWIFT") == .swift)
        #expect(SyntaxLanguage.detect("Py") == .python)
        #expect(SyntaxLanguage.detect("JSON") == .json)
    }

    @Test func unknownExtension() {
        #expect(SyntaxLanguage.detect("xyz") == .unknown)
        #expect(SyntaxLanguage.detect("") == .unknown)
    }

    @Test func displayNames() {
        #expect(SyntaxLanguage.swift.displayName == "Swift")
        #expect(SyntaxLanguage.typescript.displayName == "TypeScript")
        #expect(SyntaxLanguage.unknown.displayName == "Text")
        #expect(SyntaxLanguage.cpp.displayName == "C++")
    }

    @Test func lineCommentPrefixes() {
        #expect(SyntaxLanguage.swift.lineCommentPrefix == ["/", "/"])
        #expect(SyntaxLanguage.python.lineCommentPrefix == ["#"])
        #expect(SyntaxLanguage.sql.lineCommentPrefix == ["-", "-"])
        #expect(SyntaxLanguage.json.lineCommentPrefix == nil)
    }

    @Test func blockCommentSupport() {
        #expect(SyntaxLanguage.swift.hasBlockComments)
        #expect(SyntaxLanguage.typescript.hasBlockComments)
        #expect(!SyntaxLanguage.python.hasBlockComments)
        #expect(!SyntaxLanguage.shell.hasBlockComments)
        #expect(!SyntaxLanguage.json.hasBlockComments)
    }

    @Test func keywordSetsNonEmpty() {
        #expect(!SyntaxLanguage.swift.keywords.isEmpty)
        #expect(!SyntaxLanguage.python.keywords.isEmpty)
        #expect(!SyntaxLanguage.go.keywords.isEmpty)
        #expect(SyntaxLanguage.json.keywords.isEmpty)
        #expect(SyntaxLanguage.unknown.keywords.isEmpty)
    }
}

// MARK: - SyntaxHighlighter

@Suite("SyntaxHighlighter")
struct SyntaxHighlighterTests {

    @Test func highlightEmptyString() {
        let result = SyntaxHighlighter.highlight("", language: .swift)
        #expect(String(result.characters) == "")
    }

    @Test func highlightPreservesText() {
        let code = "let x = 42"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(String(result.characters) == code)
    }

    @Test func highlightMultiLine() {
        let code = "let x = 1\nlet y = 2"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(String(result.characters) == code)
    }

    @Test func highlightLinePreservesText() {
        let line = "func hello() -> String {"
        let result = SyntaxHighlighter.highlightLine(line, language: .swift)
        #expect(String(result.characters) == line)
    }

    @Test func highlightJSONPreservesText() {
        let json = """
        {"key": "value", "num": 42, "flag": true, "n": null}
        """
        let result = SyntaxHighlighter.highlight(json, language: .json)
        #expect(String(result.characters) == json)
    }

    @Test func highlightStringLiteral() {
        let code = #"let s = "hello""#
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        // Text should be preserved exactly
        #expect(String(result.characters) == code)
    }

    @Test func highlightLineComment() {
        let code = "x = 1 // comment"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(String(result.characters) == code)
    }

    @Test func highlightHashComment() {
        let code = "x = 1 # comment"
        let result = SyntaxHighlighter.highlight(code, language: .python)
        #expect(String(result.characters) == code)
    }

    @Test func highlightBlockComment() {
        let code = "a /* block */ b"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(String(result.characters) == code)
    }

    @Test func highlightMultiLineBlockComment() {
        let code = "a /* start\ncontinue */ b"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(String(result.characters) == code)
    }

    @Test func highlightDecorator() {
        let code = "@Observable class Foo"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(String(result.characters) == code)
    }

    @Test func highlightHexNumber() {
        let code = "let n = 0xFF"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(String(result.characters) == code)
    }

    @Test func highlightFloat() {
        let code = "let pi = 3.14"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(String(result.characters) == code)
    }

    @Test func highlightEscapedString() {
        let code = #"let s = "hello \"world\"""#
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(String(result.characters) == code)
    }

    @Test func maxLinesEnforced() {
        let lines = (0..<600).map { "line \($0)" }.joined(separator: "\n")
        let result = SyntaxHighlighter.highlight(lines, language: .swift)
        let outputLines = String(result.characters).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(outputLines.count <= SyntaxHighlighter.maxLines)
    }

    @Test func unknownLanguagePassesThrough() {
        let code = "just some text"
        let result = SyntaxHighlighter.highlight(code, language: .unknown)
        #expect(String(result.characters) == code)
    }
}

// MARK: - FileType

@Suite("FileType")
struct FileTypeTests {

    @Test func detectSwift() {
        let ft = FileType.detect(from: "Sources/main.swift")
        guard case .code(let lang) = ft else {
            Issue.record("Expected .code, got \(ft)")
            return
        }
        #expect(lang == .swift)
    }

    @Test func detectTypeScript() {
        let ft = FileType.detect(from: "src/index.ts")
        guard case .code(let lang) = ft else {
            Issue.record("Expected .code")
            return
        }
        #expect(lang == .typescript)
    }

    @Test func detectMarkdown() {
        #expect(FileType.detect(from: "README.md") == .markdown)
        #expect(FileType.detect(from: "docs/guide.mdx") == .markdown)
    }

    @Test func detectJSON() {
        #expect(FileType.detect(from: "config.json") == .json)
    }

    @Test func detectImage() {
        #expect(FileType.detect(from: "logo.png") == .image)
        #expect(FileType.detect(from: "photo.jpg") == .image)
        #expect(FileType.detect(from: "anim.gif") == .image)
        #expect(FileType.detect(from: "icon.webp") == .image)
        #expect(FileType.detect(from: "icon.svg") == .image)
    }

    @Test func detectDockerfile() {
        let ft = FileType.detect(from: "Dockerfile")
        guard case .code(let lang) = ft else {
            Issue.record("Expected .code for Dockerfile")
            return
        }
        #expect(lang == .shell)
    }

    @Test func detectContainerfile() {
        let ft = FileType.detect(from: "Containerfile")
        guard case .code(let lang) = ft else {
            Issue.record("Expected .code for Containerfile")
            return
        }
        #expect(lang == .shell)
    }

    @Test func detectMakefile() {
        let ft = FileType.detect(from: "Makefile")
        guard case .code(let lang) = ft else {
            Issue.record("Expected .code for Makefile")
            return
        }
        #expect(lang == .shell)
    }

    @Test func nilPathIsPlain() {
        #expect(FileType.detect(from: nil) == .plain)
    }

    @Test func unknownExtensionIsPlain() {
        #expect(FileType.detect(from: "file.xyz") == .plain)
    }

    @Test func noExtensionIsPlain() {
        #expect(FileType.detect(from: "LICENSE") == .plain)
    }

    @Test func displayLabels() {
        #expect(FileType.markdown.displayLabel == "Markdown")
        #expect(FileType.json.displayLabel == "JSON")
        #expect(FileType.image.displayLabel == "Image")
        #expect(FileType.plain.displayLabel == "Text")
        #expect(FileType.code(language: .swift).displayLabel == "Swift")
    }
}

// MARK: - ImageExtractor

@Suite("ImageExtractor")
struct ImageExtractorTests {

    @Test func extractDataURI() {
        let text = "Here is an image: data:image/png;base64,iVBORw0KGgoAAAANSUhEUg== done."
        let images = ImageExtractor.extract(from: text)
        #expect(images.count == 1)
        #expect(images[0].mimeType == "image/png")
        #expect(images[0].base64 == "iVBORw0KGgoAAAANSUhEUg==")
    }

    @Test func extractMultipleDataURIs() {
        let text = """
        data:image/png;base64,AAAA data:image/jpeg;base64,BBBB
        """
        let images = ImageExtractor.extract(from: text)
        #expect(images.count == 2)
        #expect(images[0].mimeType == "image/png")
        #expect(images[1].mimeType == "image/jpeg")
    }

    @Test func noImagesInPlainText() {
        let text = "Just some plain text with no images"
        let images = ImageExtractor.extract(from: text)
        #expect(images.isEmpty)
    }

    @Test func malformedDataURIIgnored() {
        let text = "data:text/plain;base64,SGVsbG8="
        let images = ImageExtractor.extract(from: text)
        #expect(images.isEmpty)
    }

    @Test func dataURIWithNewlines() {
        let text = "data:image/gif;base64,R0lGODlh\nAQABAIAAAP///wAAA\nCH5BAEAAA=="
        let images = ImageExtractor.extract(from: text)
        #expect(images.count == 1)
        // Newlines stripped from base64
        #expect(!images[0].base64.contains("\n"))
    }
}

// MARK: - parseCodeBlocks

@Suite("parseCodeBlocks")
struct ParseCodeBlocksTests {

    @Test func plainMarkdown() {
        let blocks = parseCodeBlocks("Hello world")
        #expect(blocks == [.markdown("Hello world")])
    }

    @Test func singleCodeBlock() {
        let input = """
        before
        ```
        code here
        ```
        after
        """
        let blocks = parseCodeBlocks(input)
        #expect(blocks.count == 3)
        #expect(blocks[0] == .markdown("before"))
        #expect(blocks[1] == .codeBlock(language: nil, code: "code here", isComplete: true))
        #expect(blocks[2] == .markdown("after"))
    }

    @Test func codeBlockWithLanguage() {
        let input = """
        ```swift
        let x = 1
        ```
        """
        let blocks = parseCodeBlocks(input)
        #expect(blocks.count == 1)
        #expect(blocks[0] == .codeBlock(language: "swift", code: "let x = 1", isComplete: true))
    }

    @Test func multipleCodeBlocks() {
        let input = """
        text1
        ```python
        print("hi")
        ```
        text2
        ```go
        fmt.Println("hi")
        ```
        text3
        """
        let blocks = parseCodeBlocks(input)
        #expect(blocks.count == 5)
        #expect(blocks[0] == .markdown("text1"))
        #expect(blocks[1] == .codeBlock(language: "python", code: #"print("hi")"#, isComplete: true))
        #expect(blocks[2] == .markdown("text2"))
        #expect(blocks[3] == .codeBlock(language: "go", code: #"fmt.Println("hi")"#, isComplete: true))
        #expect(blocks[4] == .markdown("text3"))
    }

    @Test func unclosedCodeBlockStreamingCase() {
        let input = """
        text
        ```swift
        let x = 1
        let y = 2
        """
        let blocks = parseCodeBlocks(input)
        #expect(blocks.count == 2)
        #expect(blocks[0] == .markdown("text"))
        #expect(blocks[1] == .codeBlock(language: "swift", code: "let x = 1\nlet y = 2", isComplete: false))
    }

    @Test func emptyCodeBlock() {
        let input = """
        ```
        ```
        """
        let blocks = parseCodeBlocks(input)
        #expect(blocks.count == 1)
        #expect(blocks[0] == .codeBlock(language: nil, code: "", isComplete: true))
    }

    @Test func codeBlockOnlyNoSurroundingText() {
        let input = """
        ```typescript
        const x = 42;
        ```
        """
        let blocks = parseCodeBlocks(input)
        #expect(blocks.count == 1)
        guard case .codeBlock(let lang, let code, let isComplete) = blocks[0] else {
            Issue.record("Expected codeBlock")
            return
        }
        #expect(lang == "typescript")
        #expect(code == "const x = 42;")
        #expect(isComplete)
    }

    @Test func multiLineCodeBlock() {
        let input = """
        ```rust
        fn main() {
            println!("hello");
        }
        ```
        """
        let blocks = parseCodeBlocks(input)
        #expect(blocks.count == 1)
        guard case .codeBlock(_, let code, let isComplete) = blocks[0] else {
            Issue.record("Expected codeBlock")
            return
        }
        #expect(code.contains("fn main()"))
        #expect(code.contains("println!"))
        #expect(isComplete)
    }

    @Test func emptyInput() {
        let blocks = parseCodeBlocks("")
        #expect(blocks.isEmpty)
    }

    @Test func completedThenStreamingBlocks() {
        // Simulates streaming: first block closed, second still open
        let input = """
        intro
        ```python
        print("done")
        ```
        middle
        ```swift
        let x = 1
        """
        let blocks = parseCodeBlocks(input)
        #expect(blocks.count == 4)
        #expect(blocks[0] == .markdown("intro"))
        guard case .codeBlock(_, _, let firstComplete) = blocks[1] else {
            Issue.record("Expected codeBlock at [1]")
            return
        }
        #expect(firstComplete)
        #expect(blocks[2] == .markdown("middle"))
        guard case .codeBlock(_, _, let secondComplete) = blocks[3] else {
            Issue.record("Expected codeBlock at [3]")
            return
        }
        #expect(!secondComplete)
    }
}

// MARK: - lineNumberInfo

@Suite("lineNumberInfo")
struct LineNumberInfoTests {

    @Test func singleLine() {
        let (numbers, _) = lineNumberInfo(lineCount: 1, startLine: 1)
        #expect(numbers == "1")
    }

    @Test func multipleLines() {
        let (numbers, _) = lineNumberInfo(lineCount: 3, startLine: 1)
        #expect(numbers == "1\n2\n3")
    }

    @Test func startLineOffset() {
        let (numbers, _) = lineNumberInfo(lineCount: 3, startLine: 10)
        #expect(numbers == "10\n11\n12")
    }

    @Test func gutterWidthScalesWithDigits() {
        let (_, width1) = lineNumberInfo(lineCount: 1, startLine: 1)
        let (_, width3) = lineNumberInfo(lineCount: 100, startLine: 1)
        #expect(width3 > width1) // 3-digit numbers need wider gutter
    }

    @Test func minimumTwoDigitWidth() {
        let (_, width) = lineNumberInfo(lineCount: 1, startLine: 1)
        // Single digit "1" but min is 2 digits → 2 * 7.5 = 15
        #expect(width == 15.0)
    }

    @Test func threeDigitWidth() {
        let (_, width) = lineNumberInfo(lineCount: 100, startLine: 1)
        // End line 100 → 3 digits → 3 * 7.5 = 22.5
        #expect(width == 22.5)
    }

    @Test func highStartLine() {
        let (numbers, width) = lineNumberInfo(lineCount: 2, startLine: 999)
        #expect(numbers == "999\n1000")
        // End line 1000 → 4 digits → 4 * 7.5 = 30
        #expect(width == 30.0)
    }
}
