import Foundation
import Testing
@testable import Oppi

@Suite("Terminal log interpretation")
struct TerminalLogEngineTests {
    @Test("carriage returns and erase replace a progress bar")
    func progressRedraw() throws {
        let resolved = try TerminalLogEngine.render("Downloading 10%\r\u{1B}[2KDownloading 60%\r\u{1B}[2K\u{1B}[32mDownloading 100%\u{1B}[0m\n")
        #expect(ANSIParser.strip(resolved) == "Downloading 100%\n")
        #expect(resolved.contains("\u{1B}[38;5;2m"))
    }

    @Test("cursor movement rewrites a previous line")
    func cursorRewrite() throws {
        let input = "first\nStep: pending\n\u{1B}[1A\r\u{1B}[2KStep: complete\n"
        #expect(ANSIParser.strip(try TerminalLogEngine.render(input)) == "first\nStep: complete\n")
    }

    @Test("wide and combining cells keep cursor addressing")
    func wideCells() throws {
        let engine = try TerminalLogEngine()
        // 中文 occupies columns 1–4; X is at column 5.
        let input = "中文X e\u{301} 🙂"
        #expect(ANSIParser.strip(try engine.update(input)) == input)
        let updated = try engine.update(input + "\u{1B}[1;5HY")
        #expect(ANSIParser.strip(updated) == "中文Y e\u{301} 🙂")
    }

    @Test("split CSI prefixes do not duplicate screen text")
    func incrementalFeed() throws {
        let engine = try TerminalLogEngine()
        #expect(ANSIParser.strip(try engine.update("line\u{1B}")) == "line")
        #expect(ANSIParser.strip(try engine.update("line\u{1B}[32mok")) == "lineok")
        #expect(ANSIParser.strip(try engine.update("line\u{1B}[32mok\r\u{1B}[2Kdone")) == "done")
    }

    @Test("replacement and byte-unequal Unicode reset terminal state")
    func replacementReset() throws {
        let engine = try TerminalLogEngine()
        _ = try engine.update("\u{1B}[32mold\n")
        let replaced = try engine.update("new")
        #expect(ANSIParser.strip(replaced) == "new")
        #expect(!replaced.contains("38;5;2"))
        _ = try engine.update("é")
        #expect(ANSIParser.strip(try engine.update("e\u{301}x")) == "e\u{301}x")
    }

    @Test("alternate screen restores primary output")
    func alternateScreen() throws {
        let engine = try TerminalLogEngine()
        let input = "primary\u{1B}[?1049h\u{1B}[2J\u{1B}[Htemporary"
        #expect(ANSIParser.strip(try engine.update(input)) == "temporary")
        #expect(ANSIParser.strip(try engine.update(input + "\u{1B}[?1049l")) == "primary")
    }

    @Test("OSC clipboard and notification payloads never become presentation")
    func inertEffects() throws {
        let input = "before\u{1B}]52;c;YXR0YWNr\u{7}\u{1B}]777;notify;attack;payload\u{7}after"
        #expect(ANSIParser.strip(try TerminalLogEngine.render(input)) == "beforeafter")
    }

    @Test("byte chunks preserve CR, cursor, SGR and split UTF-8", arguments: [
        "before\r\u{1B}[2Kafter\n",
        "first\nStep: pending\n\u{1B}[1A\r\u{1B}[2KStep: complete\n",
        "\u{1B}[32mgreen\n中文 e\u{301} 🙂\u{1B}[0m\n",
        String(repeating: "line\n", count: 30) + String(repeating: "w", count: 250) + "\nend\n",
        "\u{1B}[32m" + String(repeating: "green\n", count: 30) + String(repeating: "w", count: 250) + "\nend\u{1B}[0m\n"
    ])
    func byteChunkInvariance(_ source: String) throws {
        let engine = try TerminalLogEngine(live: true)
        let bytes = Data(source.utf8)
        for offset in stride(from: 0, to: bytes.count, by: 3) {
            try engine.feed(bytes.subdata(in: offset..<min(bytes.count, offset + 3)))
            _ = try engine.paint()
        }
        let actual = try engine.paint()
        let expected = try TerminalLogEngine.render(source)
        #expect(ANSIParser.strip(actual) == ANSIParser.strip(expected))
        #expect(ANSIParser.attributedString(from: actual).isEqual(to: ANSIParser.attributedString(from: expected)))
    }

    @Test("clear scrollback rebuilds committed cache")
    func clearScrollbackCache() throws {
        let engine = try TerminalLogEngine(live: true)
        let initial = String(repeating: "old\n", count: 60)
        try engine.feed(Data(initial.utf8))
        _ = try engine.paint()
        let clear = "\u{1B}[3J\u{1B}[2J\u{1B}[Hnew\n"
        try engine.feed(Data(clear.utf8))
        #expect(ANSIParser.strip(try engine.paint()) == ANSIParser.strip(try TerminalLogEngine.render(initial + clear)))
    }

    @Test("pruning at a full scrollback cap drops stale formatted rows")
    func boundedLiveRing() throws {
        let engine = try TerminalLogEngine(live: true)
        for batch in 0..<30 {
            let text = (batch * 100..<(batch + 1) * 100).map { "line \($0)\n" }.joined()
            try engine.feed(Data(text.utf8))
            _ = try engine.paint()
        }
        let tail = ANSIParser.strip(try engine.paint())
        #expect(!tail.contains("line 0\n"))
        #expect(tail.hasSuffix("line 2999\n"))
        #expect(tail.split(separator: "\n", omittingEmptySubsequences: false).count <= 2000)
    }

    @Test("long history preserves both ends rather than the default tail")
    func completeHistory() throws {
        let input = "\u{1B}[32mbegin\n" + String(repeating: "green line\n", count: 20_000) + "end\n"
        let resolved = ANSIParser.strip(try TerminalLogEngine.render(input))
        #expect(resolved.hasPrefix("begin\n"))
        #expect(resolved.hasSuffix("end\n"))
        #expect(resolved.split(separator: "\n").count == 20_002)
    }
}
