import Foundation
import Testing
@testable import Oppi

/// `|` marks a caret; `[` `]` mark a selection, before and after a command.
private func parse(_ marked: String) -> (NSString, NSRange) {
    let ns = marked as NSString
    let open = ns.range(of: "[")
    if open.location != NSNotFound {
        let close = ns.range(of: "]")
        let text = marked.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        return (text as NSString, NSRange(location: open.location, length: close.location - open.location - 1))
    }
    let caret = ns.range(of: "|").location
    return (marked.replacingOccurrences(of: "|", with: "") as NSString, NSRange(location: caret, length: 0))
}

private func render(_ text: NSString, _ edit: CodeTextEdit?) -> String? {
    guard let edit else { return nil }
    let result = text.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
    if edit.selection.length > 0 {
        let closed = result.replacingCharacters(in: NSRange(location: NSMaxRange(edit.selection), length: 0), with: "]") as NSString
        return closed.replacingCharacters(in: NSRange(location: edit.selection.location, length: 0), with: "[")
    }
    return result.replacingCharacters(in: NSRange(location: edit.selection.location, length: 0), with: "|")
}

private let spaces2 = CodeIndentation(usesTabs: false, width: 2)
private let spaces4 = CodeIndentation(usesTabs: false, width: 4)
private let tabs = CodeIndentation(usesTabs: true, width: 4)

@Suite("Code editor commands")
struct CodeTextEditingTests {
    private func run(_ marked: String, _ command: (NSString, NSRange) -> CodeTextEdit?) -> String? {
        let (text, selection) = parse(marked)
        return render(text, command(text, selection))
    }

    @Test func indentAndOutdentKeepTheSelectionOnItsText() {
        #expect(run("a|b\nc") { CodeTextEditing.indent($0, selection: $1, indentation: spaces2) } == "  a|b\nc")
        #expect(run("[ab\ncd]\ne") { CodeTextEditing.indent($0, selection: $1, indentation: spaces2) } == "[  ab\n  cd]\ne")
        #expect(run("[ab\n\ncd\n]e") { CodeTextEditing.indent($0, selection: $1, indentation: tabs) } == "[\tab\n\n\tcd\n]e")
        #expect(run("    a|b") { CodeTextEditing.outdent($0, selection: $1, indentation: spaces2) } == "  a|b")
        #expect(run(" |ab") { CodeTextEditing.outdent($0, selection: $1, indentation: spaces4) } == "|ab")
        #expect(run("\ta|b") { CodeTextEditing.outdent($0, selection: $1, indentation: spaces4) } == "a|b")
        #expect(run("a|b") { CodeTextEditing.outdent($0, selection: $1, indentation: spaces4) } == nil)
    }

    @Test func tabKeyUsesStopsOrIndentsBlocks() {
        #expect(run("a|") { CodeTextEditing.insertTab($0, selection: $1, indentation: spaces4) } == "a   |")
        #expect(run("|") { CodeTextEditing.insertTab($0, selection: $1, indentation: spaces4) } == "    |")
        #expect(run("a|") { CodeTextEditing.insertTab($0, selection: $1, indentation: tabs) } == "a\t|")
        #expect(run("[a\nb]") { CodeTextEditing.insertTab($0, selection: $1, indentation: spaces2) } == "[  a\n  b]")
    }

    @Test func backspaceInLeadingSpacesDeletesToTabStop() {
        #expect(run("        |x") { CodeTextEditing.softTabDeletion($0, caret: $1.location, indentation: spaces4) } == "    |x")
        #expect(run("      |x") { CodeTextEditing.softTabDeletion($0, caret: $1.location, indentation: spaces4) } == "    |x")
        #expect(run("a   |x") { CodeTextEditing.softTabDeletion($0, caret: $1.location, indentation: spaces4) } == nil)
        #expect(run("    |x") { CodeTextEditing.softTabDeletion($0, caret: $1.location, indentation: tabs) } == nil)
    }

    @Test func returnKeepsAndOpensIndentation() {
        func newline(_ marked: String, colon: Bool = false) -> String? {
            run(marked) { CodeTextEditing.newline($0, selection: $1, indentation: spaces2, colonOpensBlock: colon) }
        }
        #expect(newline("  foo|") == "  foo\n  |")
        #expect(newline("  if x {|") == "  if x {\n    |")
        #expect(newline("f(|)") == "f(\n  |\n)")
        #expect(newline("  a = {|}") == "  a = {\n    |\n  }")
        #expect(newline("def f():|", colon: true) == "def f():\n  |")
        #expect(newline("a: |", colon: false) == "a: \n|")
        #expect(newline("x\r\n  y|\r\n") == "x\r\n  y\r\n  |\r\n")
    }

    @Test func bracketsAndQuotesPair() {
        func type(_ marked: String, _ typed: String, quotes: Bool = true) -> String? {
            run(marked) { CodeTextEditing.pairedInsertion($0, selection: $1, typed: typed, pairsQuotes: quotes) }
        }
        #expect(type("|", "(") == "(|)")
        #expect(type("f|", "(") == "f(|)")
        #expect(type("|x", "(") == nil)
        #expect(type("(|)", ")") == "()|")
        #expect(type("{|}", "}") == "{}|")
        #expect(type("[ab]", "(") == "([ab])")
        #expect(type("|", "\"") == "\"|\"")
        #expect(type("\"|\"", "\"") == "\"\"|")
        #expect(type("don|", "'") == nil)
        #expect(type("|", "'", quotes: false) == nil)
        #expect(type("|", "a") == nil)
    }

    @Test func backspaceRemovesEmptyPair() {
        #expect(run("(|)") { CodeTextEditing.pairDeletion($0, caret: $1.location) } == "|")
        #expect(run("\"|\"") { CodeTextEditing.pairDeletion($0, caret: $1.location) } == "|")
        #expect(run("(|x)") { CodeTextEditing.pairDeletion($0, caret: $1.location) } == nil)
    }

    @Test func lineCommentsToggleAtShallowestIndent() {
        func toggle(_ marked: String, _ prefix: String = "//") -> String? {
            run(marked) { CodeTextEditing.toggleLineComment($0, selection: $1, prefix: prefix) }
        }
        #expect(toggle("  fo|o") == "  // fo|o")
        #expect(toggle("  // fo|o") == "  fo|o")
        #expect(toggle("[  a\n    b]") == "[  // a\n  //   b]")
        #expect(toggle("[  // a\n\n  //   b]") == "[  a\n\n    b]")
        #expect(toggle("[  // a\n  b]") == "[  // // a\n  // b]")
        #expect(toggle("x = |1", "#") == "# x = |1")
        #expect(toggle("|") == nil)
    }

    @Test func blockCommentsWrapAndUnwrap() {
        let wrapped = run("  a|b") { CodeTextEditing.toggleBlockComment($0, selection: $1, open: "<!--", close: "-->") }
        #expect(wrapped == "[  <!-- ab -->]")
        let unwrapped = run("  <!-- a|b -->") { CodeTextEditing.toggleBlockComment($0, selection: $1, open: "<!--", close: "-->") }
        #expect(unwrapped == "[  ab]")
    }

    @Test func moveLinesSwapNeighborsAndKeepBreaks() {
        func move(_ marked: String, up: Bool) -> String? {
            run(marked) { CodeTextEditing.moveLines($0, selection: $1, up: up) }
        }
        #expect(move("a\nb|b\nc", up: true) == "b|b\na\nc")
        #expect(move("a\nb|b\nc", up: false) == "a\nc\nb|b")
        #expect(move("a\nb|", up: true) == "b|\na")
        #expect(move("a|\nb", up: false) == "b\na|")
        #expect(move("a|\nb", up: true) == nil)
        #expect(move("a\nb|", up: false) == nil)
        #expect(move("[a\nb]\nc", up: false) == "c\n[a\nb]")
    }

    @Test func duplicateDeleteAndOpenLines() {
        #expect(run("a|b\nc") { CodeTextEditing.duplicateLines($0, selection: $1) } == "ab\na|b\nc")
        #expect(run("a\nb|") { CodeTextEditing.duplicateLines($0, selection: $1) } == "a\nb\nb|")
        #expect(run("a\nb|b\nc") { CodeTextEditing.deleteLines($0, selection: $1) } == "a\n|c")
        #expect(run("a\nb|") { CodeTextEditing.deleteLines($0, selection: $1) } == "|a")
        #expect(run("a\n\nb|") { CodeTextEditing.deleteLines($0, selection: $1) } == "a\n|")
        #expect(run("  a|b\nc") { CodeTextEditing.insertLine($0, selection: $1, below: true) } == "  ab\n  |\nc")
        #expect(run("  a|b\nc") { CodeTextEditing.insertLine($0, selection: $1, below: false) } == "  |\n  ab\nc")
    }

    @Test func markdownWrapTogglesMarkers() {
        #expect(run("say [hi]") { CodeTextEditing.toggleWrap($0, selection: $1, marker: "**") } == "say **[hi]**")
        #expect(run("say **[hi]**") { CodeTextEditing.toggleWrap($0, selection: $1, marker: "**") } == "say [hi]")
        #expect(run("|") { CodeTextEditing.toggleWrap($0, selection: $1, marker: "_") } == "_|_")
    }

    @Test func indentationDetectionFollowsTheFile() {
        let fallback = spaces4
        #expect(CodeIndentation.detect(in: "a\n  b\n    c\n  d", fallback: fallback) == spaces2)
        #expect(CodeIndentation.detect(in: "a\n\tb\n\t\tc", fallback: fallback) == tabs)
        #expect(CodeIndentation.detect(in: "a\nb", fallback: fallback) == fallback)
        #expect(CodeIndentation.detect(in: "a\n        b\nc\n        d", fallback: fallback) == CodeIndentation(usesTabs: false, width: 8))
    }

    @Test func lineIndexMatchesLaidOutParagraphs() {
        let index = CodeLineIndex("a\r\nb\nc\rd\n")
        #expect(index.starts == [0, 3, 5, 7, 9])
        #expect(index.line(containing: 0) == 0)
        #expect(index.line(containing: 2) == 0)
        #expect(index.line(containing: 3) == 1)
        #expect(index.line(containing: 9) == 4)
        #expect(CodeLineIndex("").lineCount == 1)
    }

    /// Typing updates the index from the edit alone; it must always equal a
    /// full rescan, including CR and LF joining or splitting at the edit's edges.
    @Test func incrementalLineIndexMatchesFullRescan() {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        let alphabet = ["a", "b", "\n", "\r", "\r\n", "\u{2029}", " "]
        let text = NSMutableString(string: "a\r\nb\nc\rd")
        var index = CodeLineIndex(text)
        for _ in 0..<2_000 {
            let location = next(text.length + 1)
            let removed = min(next(4), text.length - location)
            let inserted = (0..<next(4)).map { _ in alphabet[next(alphabet.count)] }.joined()
            text.replaceCharacters(in: NSRange(location: location, length: removed), with: inserted)
            let insertedLength = (inserted as NSString).length
            index.apply(
                editedRange: NSRange(location: location, length: insertedLength),
                changeInLength: insertedLength - removed,
                in: text
            )
            #expect(index == CodeLineIndex(text), "after editing at \(location)")
            if index != CodeLineIndex(text) { return }
        }
    }
}
