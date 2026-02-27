import Testing
@testable import Oppi

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
        #expect(width3 > width1)
    }

    @Test func minimumTwoDigitWidth() {
        let (_, width) = lineNumberInfo(lineCount: 1, startLine: 1)
        #expect(width == 15.0)
    }

    @Test func threeDigitWidth() {
        let (_, width) = lineNumberInfo(lineCount: 100, startLine: 1)
        #expect(width == 22.5)
    }

    @Test func highStartLine() {
        let (numbers, width) = lineNumberInfo(lineCount: 2, startLine: 999)
        #expect(numbers == "999\n1000")
        #expect(width == 30.0)
    }
}
