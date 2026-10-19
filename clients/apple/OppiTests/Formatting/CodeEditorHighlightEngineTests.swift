import Foundation
import Testing
@testable import Oppi

@Suite("Code editor highlight engine")
struct CodeEditorHighlightEngineTests {
    private static let source = """
    function greet(name) {
      // say hi
      return "hello " + name;
    }
    const answer = 42;
    """

    private func text(_ spans: [CodeEditorSpan], in source: String, style: CodeEditorSpanStyle) -> [String] {
        spans.filter { $0.style == style }.map { (source as NSString).substring(with: $0.range) }
    }

    @Test func treeSitterSpansColorTheWholeDocument() async {
        let engine = CodeEditorHighlightEngine(grammar: .treeSitter(.javascript))
        let full = NSRange(location: 0, length: (Self.source as NSString).length)
        let spans = await engine.spans(text: Self.source, window: full)
        #expect(text(spans, in: Self.source, style: .token(.comment)) == ["// say hi"])
        #expect(text(spans, in: Self.source, style: .token(.string)).contains("\"hello \""))
        #expect(text(spans, in: Self.source, style: .token(.number)) == ["42"])
    }

    /// Typing reparses incrementally; the result must equal a fresh parse.
    @Test func incrementalEditsMatchAFreshParse() async {
        let engine = CodeEditorHighlightEngine(grammar: .treeSitter(.javascript))
        var current = Self.source
        _ = await engine.spans(text: current, window: NSRange(location: 0, length: (current as NSString).length))
        let edits: [(String, String)] = [
            ("return", "/* x */ return"),
            ("42;", "42; // done"),
            ("// say hi\n", ""),
            ("\"hello \"", "`hi ${name}`"),
        ]
        for (old, new) in edits {
            current = current.replacingOccurrences(of: old, with: new)
            let window = NSRange(location: 0, length: (current as NSString).length)
            let incremental = await engine.spans(text: current, window: window)
            let fresh = await CodeEditorHighlightEngine(grammar: .treeSitter(.javascript)).spans(text: current, window: window)
            #expect(incremental == fresh, "after replacing \(old)")
        }
    }

    @Test func windowLimitsSpansToNearbyRows() async {
        let lines = (0..<400).map { "const value\($0) = \($0); // note \($0)" }
        let source = lines.joined(separator: "\n")
        let ns = source as NSString
        let window = ns.lineRange(for: NSRange(location: ns.range(of: "value300 ").location, length: 0))
        let spans = await CodeEditorHighlightEngine(grammar: .treeSitter(.javascript)).spans(text: source, window: window)
        #expect(!spans.isEmpty)
        #expect(spans.allSatisfy { NSIntersectionRange($0.range, window).length > 0 })
    }

    @Test func editComputesOneSpanBetweenSharedPrefixAndSuffix() {
        let old = "a\nbc\nd" as NSString
        let new = "a\nbXYc\nd" as NSString
        let edit = CodeEditorHighlightEngine.edit(from: old, to: new, oldLines: CodeLineIndex(old))
        #expect(edit?.start == 3)
        #expect(edit?.oldEnd == 3)
        #expect(edit?.newEnd == 5)
        #expect(CodeEditorHighlightEngine.edit(from: old, to: old, oldLines: CodeLineIndex(old)) == nil)
    }

    @Test func grammarFollowsTheFileType() {
        #expect(CodeEditorHighlightEngine.grammar(forPath: "README.md") == .markdown)
        #expect(CodeEditorHighlightEngine.grammar(forPath: "main.go") == .treeSitter(.go))
        #expect(CodeEditorHighlightEngine.grammar(forPath: "App.swift") == .scanner(.swift))
        #expect(CodeEditorHighlightEngine.grammar(forPath: "package.json") == .scanner(.json))
        #expect(CodeEditorHighlightEngine.grammar(forPath: "notes.txt") == .plain)
    }

    @Test func markdownSourceStylesSyntaxAndFencedCode() async {
        let source = """
        # Title
        Some **bold**, _soft_, `code`, and [a link](https://x.dev).
        - [ ] task
        ```python
        def f(): return 1
        ```
        > quoted
        """
        let spans = await CodeEditorHighlightEngine(grammar: .markdown)
            .spans(text: source, window: NSRange(location: 0, length: (source as NSString).length))
        #expect(text(spans, in: source, style: .heading) == ["# Title"])
        #expect(text(spans, in: source, style: .strong) == ["**bold**"])
        #expect(text(spans, in: source, style: .emphasis) == ["_soft_"])
        #expect(text(spans, in: source, style: .inlineCode) == ["`code`"])
        #expect(text(spans, in: source, style: .link) == ["a link"])
        #expect(text(spans, in: source, style: .url) == ["https://x.dev"])
        #expect(text(spans, in: source, style: .quote) == ["> quoted"])
        #expect(text(spans, in: source, style: .marker).contains("- [ ] "))
        #expect(text(spans, in: source, style: .token(.keyword)).contains("def"))
    }

    @Test func markdownKeepsFenceStateFromAboveTheWindow() async {
        let body = (0..<50).map { "x = **not bold** \($0)" }.joined(separator: "\n")
        let source = "```\n" + body + "\n```\nafter **bold**"
        let ns = source as NSString
        let window = ns.lineRange(for: NSRange(location: ns.range(of: "not bold** 40").location, length: 0))
        let spans = await CodeEditorHighlightEngine(grammar: .markdown).spans(text: source, window: window)
        #expect(text(spans, in: source, style: .strong).isEmpty)
    }
}
