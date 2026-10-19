import Foundation
import Testing
@testable import Oppi

/// In-memory buffer that behaves like the editor: one undo step per command,
/// typed text in Insert mode goes straight into the buffer.
@MainActor
private final class VimTestBuffer: VimBuffer {
    var text: NSMutableString
    var selection: NSRange
    var visibleLines = 10
    private var undoStack: [(String, NSRange)] = []
    private var redoStack: [(String, NSRange)] = []
    private var stepOpen = false

    init(_ marked: String) {
        let caret = (marked as NSString).range(of: "|").location
        text = NSMutableString(string: marked.replacingOccurrences(of: "|", with: ""))
        selection = NSRange(location: caret == NSNotFound ? 0 : caret, length: 0)
    }

    var vimText: NSString { text }
    var vimSelection: NSRange { selection }
    var vimVisibleLineCount: Int { visibleLines }
    var vimIndentation: CodeIndentation { CodeIndentation(usesTabs: false, width: 2) }

    func vimSelect(_ range: NSRange) { selection = range }

    func vimReplace(_ range: NSRange, with replacement: String) {
        if !stepOpen {
            undoStack.append((text as String, selection))
            redoStack = []
            stepOpen = true
        }
        text.replaceCharacters(in: range, with: replacement)
    }

    func vimUndo() -> Bool {
        guard let (previous, range) = undoStack.popLast() else { return false }
        redoStack.append((text as String, selection))
        text.setString(previous)
        selection = range
        return true
    }

    func vimRedo() -> Bool {
        guard let (next, range) = redoStack.popLast() else { return false }
        undoStack.append((text as String, selection))
        text.setString(next)
        selection = range
        return true
    }

    func endStep() { stepOpen = false }

    /// `|` at the caret; a selection renders as `[...]`.
    var rendered: String {
        let ns = text as NSString
        if selection.length > 0 {
            return ns.replacingCharacters(in: NSRange(location: NSMaxRange(selection), length: 0), with: "]")
                .replacingCharacters(in: selection.location..<selection.location, with: "[")
        }
        return ns.replacingCharacters(in: NSRange(location: selection.location, length: 0), with: "|")
    }
}

private extension String {
    func replacingCharacters(in range: Range<Int>, with string: String) -> String {
        (self as NSString).replacingCharacters(in: NSRange(location: range.lowerBound, length: 0), with: string)
    }
}

@MainActor
private final class VimHarness {
    let buffer: VimTestBuffer
    let engine: VimEngine
    var requests: [VimHostRequest] = []
    var yanked: [String] = []

    init(_ marked: String) {
        buffer = VimTestBuffer(marked)
        engine = VimEngine(buffer: buffer)
        engine.onYank = { [weak self] in self?.yanked.append($0) }
        engine.reset()
    }

    /// Keys use Vim notation: `<esc>`, `<cr>`, `<bs>`, `<c-r>`, `<c-d>`.
    @discardableResult
    func send(_ keys: String) -> VimHarness {
        var index = keys.startIndex
        while index < keys.endIndex {
            let key: VimKey
            if keys[index] == "<", let close = keys[index...].firstIndex(of: ">") {
                let name = keys[keys.index(after: index)..<close].lowercased()
                index = keys.index(after: close)
                switch name {
                case "esc": key = .escape
                case "cr": key = .enter
                case "bs": key = .backspace
                case "lt": key = .char("<")
                default:
                    if name.hasPrefix("c-"), let character = name.dropFirst(2).first {
                        key = .ctrl(character)
                    } else {
                        Issue.record("unknown key <\(name)>")
                        return self
                    }
                }
            } else {
                key = .char(keys[index])
                index = keys.index(after: index)
            }
            if engine.mode == .insert, key != .escape {
                // The editor types this into the buffer itself.
                let typed: String = switch key {
                case .char(let character): String(character)
                case .enter: "\n"
                default: ""
                }
                buffer.vimReplace(buffer.selection, with: typed)
                buffer.selection = NSRange(location: buffer.selection.location + (typed as NSString).length, length: 0)
                continue
            }
            requests += engine.handle(key)
            if engine.pendingKeys.isEmpty, engine.mode != .insert { buffer.endStep() }
        }
        if engine.mode != .insert { buffer.endStep() }
        return self
    }

    func command(_ prompt: Character, _ entry: String) -> VimHarness {
        requests += engine.runCommandLine(prompt, entry)
        buffer.endStep()
        return self
    }

    var rendered: String { buffer.rendered }
}

@Suite("Vim engine")
@MainActor
struct VimEngineTests {
    private func vim(_ start: String, _ keys: String) -> String {
        VimHarness(start).send(keys).rendered
    }

    // MARK: Motions

    @Test func wordMotionsStopAtPunctuationAndEmptyLines() {
        #expect(vim("|foo.bar baz", "w") == "foo|.bar baz")
        #expect(vim("|foo.bar baz", "W") == "foo.bar |baz")
        #expect(vim("|foo\n\nbar", "w") == "foo\n|\nbar")
        #expect(vim("foo bar |baz", "b") == "foo |bar baz")
        #expect(vim("foo\n\n|bar", "b") == "foo\n|\nbar")
        #expect(vim("|foo bar", "e") == "fo|o bar")
        #expect(vim("|foo bar", "ee") == "foo ba|r")
        #expect(vim("foo |bar", "ge") == "fo|o bar")
    }

    @Test func lineMotionsAndCounts() {
        #expect(vim("  fo|o", "0") == "|  foo")
        #expect(vim("|  foo", "^") == "  |foo")
        #expect(vim("|foo  ", "$") == "foo | ")
        #expect(vim("|a\nb\nc\nd", "2j") == "a\nb\n|c\nd")
        #expect(vim("a\nb\n|c", "gg") == "|a\nb\nc")
        #expect(vim("|a\n  b\nc", "2G") == "a\n  |b\nc")
        #expect(vim("|a\nb\nc", "G") == "a\nb\n|c")
    }

    @Test func verticalMotionKeepsDesiredColumn() {
        #expect(vim("abcd|e\nx\nabcdef", "jj") == "abcde\nx\nabcd|ef")
        #expect(vim("|abc\nabcdef", "$j") == "abc\nabcde|f")
    }

    @Test func findCharacterAndRepeat() {
        #expect(vim("|a,b,c,d", "f,") == "a|,b,c,d")
        #expect(vim("|a,b,c,d", "f,;;") == "a,b,c|,d")
        #expect(vim("|a,b,c,d", "2f,") == "a,b|,c,d")
        #expect(vim("|a,b,c,d", "t,;") == "a,|b,c,d")
        #expect(vim("a,b,c,|d", "F,,") == "a,b,c|,d")
    }

    @Test func matchPairAndParagraphs() {
        #expect(vim("|if (a(b)) x", "%") == "if (a(b)|) x")
        #expect(vim("if (a(b)|) x", "%") == "if |(a(b)) x")
        #expect(vim("|a\nb\n\nc", "}") == "a\nb\n|\nc")
        #expect(vim("a\n\nb\n|c", "{") == "a\n|\nb\nc")
    }

    // MARK: Operators

    @Test func deleteWithMotions() {
        #expect(vim("|foo bar baz", "dw") == "|bar baz")
        #expect(vim("|foo bar baz", "d2w") == "|baz")
        #expect(vim("|foo bar baz", "2dw") == "|baz")
        #expect(vim("foo |bar\nbaz", "dw") == "foo| \nbaz")
        #expect(vim("foo b|ar baz", "de") == "foo b| baz")
        #expect(vim("foo b|ar baz", "d$") == "foo |b")
        #expect(vim("foo b|ar baz", "D") == "foo |b")
        #expect(vim("abc|def", "d0") == "|def")
        #expect(vim("a,b,|c,d", "dt,") == "a,b,|,d")
        #expect(vim("a,b,|c,d", "df,") == "a,b,|d")
    }

    @Test func deleteAndChangeLines() {
        #expect(vim("a\n|b\nc", "dd") == "a\n|c")
        #expect(vim("a\n|b\nc\nd", "2dd") == "a\n|d")
        #expect(vim("a\n|b", "dd") == "|a")
        #expect(vim("a\n  |b\nc", "dj") == "|a")
        #expect(vim("|a\nb\nc", "dG") == "|")
        #expect(vim("a\n  b|b\nc", "ccx<esc>") == "a\n  |x\nc")
        #expect(vim("a\n  b|b\nc", "Sx<esc>") == "a\n  |x\nc")
    }

    @Test func changeWordActsLikeChangeToEnd() {
        #expect(vim("|foo bar", "cwx<esc>") == "|x bar")
        #expect(vim("f|oo bar", "Cx<esc>") == "f|x")
        #expect(vim("|foo", "sx<esc>") == "|xoo")
    }

    @Test func charwiseDeletes() {
        #expect(vim("|abc", "x") == "|bc")
        #expect(vim("|abc", "3x") == "|")
        #expect(vim("ab|c", "x") == "a|b")
        #expect(vim("ab|c", "X") == "a|c")
        #expect(vim("|\nabc", "x") == "|\nabc")
    }

    @Test func textObjects() {
        #expect(vim("say \"he|llo\" now", "ci\"x<esc>") == "say \"|x\" now")
        #expect(vim("say \"he|llo\" now", "da\"") == "say | now")
        #expect(vim("f(a, |b)", "di(") == "f(|)")
        #expect(vim("f(a, |b)", "da(") == "|f")
        #expect(vim("f(a, (|b))", "di(") == "f(a, (|))")
        #expect(vim("foo b|ar baz", "daw") == "foo |baz")
        #expect(vim("foo b|ar baz", "ciwx<esc>") == "foo |x baz")
        #expect(vim("{\n  a|b\n}", "di{") == "{\n|}")
        #expect(vim("a\n|b\nc\n\nd", "dap") == "|d")
        #expect(vim("a\n|b\nc\n\nd", "dip") == "|\nd")
    }

    @Test func caseAndReplace() {
        #expect(vim("|abc", "~~") == "AB|c")
        #expect(vim("|abc", "rx") == "|xbc")
        #expect(vim("|abc", "2rx") == "x|xc")
        #expect(vim("|abc", "4rx") == "|abc")
        #expect(vim("|abc def", "gUiw") == "|ABC def")
        #expect(vim("|ABC def", "guu") == "|abc def")
    }

    @Test func indentOperators() {
        #expect(vim("|a\nb", ">>") == "  |a\nb")
        #expect(vim("|a\nb", ">j") == "  |a\n  b")
        #expect(vim("    |a", "<<") == "  |a")
        #expect(vim("|a\nb\nc", "2>>") == "  |a\n  b\nc")
    }

    // MARK: Registers and paste

    @Test func yankAndPaste() {
        #expect(vim("|foo bar", "ywP") == "foo| foo bar")
        #expect(vim("|foo bar", "yw$p") == "foo barfoo| ")
        #expect(vim("|a\nb", "yyp") == "a\n|a\nb")
        #expect(vim("a\n|b", "yyp") == "a\nb\n|b")
        #expect(vim("a\n|b", "yyP") == "a\n|b\nb")
        #expect(vim("|a\nb", "ddp") == "b\n|a")
        #expect(vim("|ab", "xp") == "b|a")
        #expect(vim("|a\nb", "\"_ddP") == "|b")
    }

    @Test func yankMirrorsToClipboardHook() {
        let harness = VimHarness("|one\ntwo").send("yy")
        #expect(harness.yanked == ["one\n"])
        #expect(harness.rendered == "|one\ntwo")
    }

    @Test func joinLines() {
        #expect(vim("|a\n  b", "J") == "a| b")
        #expect(vim("|a\nb\nc", "3J") == "a b| c")
        #expect(vim("|f(\n)", "J") == "f(|)")
        #expect(vim("|a\n  b", "gJ") == "a|  b")
    }

    // MARK: Insert

    @Test func insertEntryPoints() {
        #expect(vim("a|bc", "ix<esc>") == "a|xbc")
        #expect(vim("a|bc", "ax<esc>") == "ab|xc")
        #expect(vim("  a|bc", "Ix<esc>") == "  |xabc")
        #expect(vim("a|bc", "Ax<esc>") == "abc|x")
        #expect(vim("  a|b\nc", "ox<esc>") == "  ab\n  |x\nc")
        #expect(vim("  a|b\nc", "Ox<esc>") == "  |x\n  ab\nc")
        #expect(VimHarness("a|b").send("i").engine.mode == .insert)
    }

    // MARK: Undo and repeat

    @Test func undoRedo() {
        #expect(vim("|foo bar", "dwu") == "|foo bar")
        #expect(vim("|foo bar", "dwu<c-r>") == "|bar")
    }

    @Test func dotRepeatsLastChange() {
        #expect(vim("|a b c d", "dw.") == "|c d")
        #expect(vim("|a b c d", "dw2.") == "|d")
        #expect(vim("|foo\nfoo", "ciwbar<esc>j0.") == "bar\nba|r")
        #expect(vim("|a\nb", "Ax;<esc>j.") == "ax;\nbx|;")
        #expect(vim("|a\nb\nc", "dd.") == "|c")
    }

    // MARK: Visual

    @Test func visualCharacterwise() {
        #expect(vim("|abcdef", "vl") == "[ab]cdef")
        #expect(vim("|abcdef", "vld") == "|cdef")
        #expect(vim("ab|cdef", "vhy") == "a|bcdef")
        #expect(vim("|abc", "vlU") == "|ABc")
        #expect(vim("|foo bar", "viwcx<esc>") == "|x bar")
        #expect(vim("|abc", "vl<esc>") == "a|bc")
    }

    @Test func visualLinewise() {
        #expect(vim("|a\nb\nc", "Vjd") == "|c")
        #expect(vim("|a\nb\nc", "Vj>") == "  |a\n  b\nc")
        #expect(vim("|a\nb\nc", "VjJ") == "a| b\nc")
        #expect(vim("|a\nb", "yyjVp") == "a\n|a")
        #expect(vim("|a\nb\nc", "yyjVp") == "a\n|a\nc")
    }

    @Test func visualSelectionTracksExternalChanges() {
        let harness = VimHarness("|hello world")
        harness.buffer.selection = NSRange(location: 0, length: 5)
        harness.engine.selectionDidChange()
        #expect(harness.engine.mode == .visual)
        harness.send("d")
        #expect(harness.rendered == "| world")
    }

    @Test func normalModeNeverRestsOnLineBreak() {
        let harness = VimHarness("abc|\ndef")
        #expect(harness.rendered == "ab|c\ndef")
        harness.buffer.selection = NSRange(location: 3, length: 0)
        harness.engine.selectionDidChange()
        #expect(harness.rendered == "ab|c\ndef")
    }

    // MARK: Search and command line

    @Test func searchForwardBackwardAndRepeat() {
        let harness = VimHarness("|foo bar foo baz foo")
        _ = harness.command("/", "foo")
        #expect(harness.rendered == "foo bar |foo baz foo")
        harness.send("n")
        #expect(harness.rendered == "foo bar foo baz |foo")
        harness.send("N")
        #expect(harness.rendered == "foo bar |foo baz foo")
        #expect(vim("|foo x foo", "*") == "foo x |foo")
    }

    @Test func searchSmartCaseAndNotFound() {
        let harness = VimHarness("|a Foo foo")
        _ = harness.command("/", "foo")
        #expect(harness.rendered == "a |Foo foo")
        _ = harness.command("/", "Foo")
        #expect(harness.rendered == "a |Foo foo")
        _ = harness.command("/", "zzz")
        #expect(harness.engine.message == "Pattern not found: zzz")
    }

    @Test func commandLineRequestsAndLineJumps() {
        #expect(VimHarness("|a").command(":", "w").requests == [.save])
        #expect(VimHarness("|a").command(":", "q").requests == [.quit])
        #expect(VimHarness("|a").command(":", "wq").requests == [.saveAndQuit])
        #expect(VimHarness("|a").command(":", "x").requests == [.saveAndQuit])
        #expect(VimHarness("|a\n  b\nc").command(":", "2").rendered == "a\n  |b\nc")
        #expect(VimHarness("|a").send(":").requests == [.commandLine(":")])
        #expect(VimHarness("|a").command(":", "bogus").engine.message == "Not an editor command: bogus")
    }

    @Test func substitute() {
        #expect(VimHarness("|foo foo\nfoo").command(":", "s/foo/bar/").rendered == "|bar foo\nfoo")
        #expect(VimHarness("|foo foo\nfoo").command(":", "s/foo/bar/g").rendered == "|bar bar\nfoo")
        #expect(VimHarness("|foo foo\nfoo").command(":", "%s/foo/bar/g").rendered == "bar bar\n|bar")
        #expect(VimHarness("|a-b").command(":", "s/\\(a\\)-\\(b\\)/\\2-\\1/").rendered == "|b-a")
        #expect(VimHarness("|cost").command(":", "s/cost/$5 &/").rendered == "|$5 cost")
    }

    @Test func scrollAndPagingRequests() {
        #expect(VimHarness("|a").send("zz").requests == [.scrollCaret(.center)])
        let paged = VimHarness("|" + (0..<30).map(String.init).joined(separator: "\n")).send("<c-d>")
        #expect(paged.requests == [.scrollCaret(.center)])
        #expect(paged.rendered.hasPrefix("0\n1\n2\n3\n4\n|5"))
    }

    @Test func pendingKeysShowUntilComplete() {
        let harness = VimHarness("|abc")
        harness.send("2d")
        #expect(harness.engine.pendingDisplay == "2d")
        harness.send("<esc>")
        #expect(harness.engine.pendingDisplay.isEmpty)
        #expect(harness.rendered == "|abc")
    }
}
