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

    @Test("long history preserves both ends rather than the default tail")
    func completeHistory() throws {
        let input = "\u{1B}[32mbegin\n" + String(repeating: "green line\n", count: 20_000) + "end\n"
        let resolved = ANSIParser.strip(try TerminalLogEngine.render(input))
        #expect(resolved.hasPrefix("begin\n"))
        #expect(resolved.hasSuffix("end\n"))
        #expect(resolved.split(separator: "\n").count == 20_002)
    }
}
