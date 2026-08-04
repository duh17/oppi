import Testing
import SwiftUI
import UIKit
@testable import Oppi

@Suite("ANSIParser")
struct ANSIParserTests {

    // MARK: - Strip

    @Test("strips basic SGR codes")
    func stripBasic() {
        let input = "\u{1B}[1mStatus\u{1B}[0m \u{1B}[1;36m2026\u{1B}[0m"
        #expect(ANSIParser.strip(input) == "Status 2026")
    }

    @Test("strips mixed bold, dim, colors")
    func stripMixed() {
        let input = "\u{1B}[32mFresh\u{1B}[0m \u{1B}[32m████\u{1B}[0m░░░"
        #expect(ANSIParser.strip(input) == "Fresh ████░░░")
    }

    @Test("strip is no-op on plain text")
    func stripPlain() {
        let input = "Hello, world!"
        #expect(ANSIParser.strip(input) == "Hello, world!")
    }

    @Test("strips cursor movement and other non-SGR sequences")
    func stripNonSGR() {
        let input = "before\u{1B}[2Aafter\u{1B}[Kend"
        #expect(ANSIParser.strip(input) == "beforeafterend")
    }

    @Test("strip drops standalone escape bytes")
    func stripStandaloneEscapeByte() {
        let input = "hello\u{1B}world"
        #expect(ANSIParser.strip(input) == "helloworld")
    }

    @Test("strips OSC and C1 control sequences from display text")
    func stripStringControls() {
        let osc = "before\u{1B}]8;;https://example.com\u{07}link\u{1B}]8;;\u{07}after"
        let c1 = "left\u{009B}31mred\u{009D}8;;https://example.com\u{009C}right"
        let st = "a\u{1B}]0;window title\u{1B}\\b"
        let escStringControls = "a\u{1B}Pdcs\u{1B}\\b\u{1B}Xsos\u{1B}\\c\u{1B}^pm\u{1B}\\d\u{1B}_apc\u{1B}\\e"
        let c1StringControls = "a\u{0090}dcs\u{009C}b\u{0098}sos\u{009C}c\u{009E}pm\u{009C}d\u{009F}apc\u{009C}e"
        let escDCSWithBEL = "a\u{1B}Pdcs\u{07}leaked\u{1B}\\b"
        let c1DCSWithBEL = "a\u{0090}dcs\u{07}leaked\u{009C}b"

        #expect(ANSIParser.strip(osc) == "beforelinkafter")
        #expect(ANSIParser.strip(c1) == "leftredright")
        #expect(ANSIParser.strip(st) == "ab")
        #expect(ANSIParser.strip(escStringControls) == "abcde")
        #expect(ANSIParser.strip(c1StringControls) == "abcde")
        #expect(ANSIParser.strip(escDCSWithBEL) == "ab")
        #expect(ANSIParser.strip(c1DCSWithBEL) == "ab")
        #expect(ANSIParser.strip("😀 Привет") == "😀 Привет")
        #expect(ANSIParser.stripPrefix("😀 Привет", maxInputBytes: 100) == "😀 Привет")
        #expect(ANSIParser.attributedString(from: osc).string == "beforelinkafter")
        #expect(ANSIParser.attributedString(from: c1).string == "leftredright")
        #expect(ANSIParser.attributedString(from: c1StringControls).string == "abcde")
    }

    // MARK: - Attributed String

    @Test("attributedString preserves plain text")
    func attrPlain() {
        let result = ANSIParser.attributedString(from: "Hello")
        #expect(result.string == "Hello")
    }

    @Test("attributedString strips codes from character content")
    func attrCharacters() {
        let input = "\u{1B}[1mBold\u{1B}[0m Normal"
        let result = ANSIParser.attributedString(from: input)
        #expect(result.string == "Bold Normal")
    }

    @Test("attributedString drops standalone escape bytes")
    func attrStandaloneEscapeByte() {
        let input = "A\u{1B}B"
        let result = ANSIParser.attributedString(from: input)
        #expect(result.string == "AB")
    }

    @Test("attributedString applies foreground colors as UIColor")
    func attrUIKitForegroundColors() {
        let input = "\u{1B}[32mFresh\u{1B}[0m plain"
        let result = ANSIParser.attributedString(from: input)
        let text = result.string as NSString

        let freshRange = text.range(of: "Fresh")
        let plainRange = text.range(of: "plain")
        guard freshRange.location != NSNotFound,
              plainRange.location != NSNotFound else {
            Issue.record("Expected token ranges in ANSI attributed string")
            return
        }

        let freshColor = result.attribute(.foregroundColor, at: freshRange.location, effectiveRange: nil) as? UIColor
        let plainColor = result.attribute(.foregroundColor, at: plainRange.location, effectiveRange: nil) as? UIColor

        #expect(freshColor == UIColor(Color.themeGreen))
        #expect(plainColor == UIColor(Color.themeFg))
    }

    @Test("attributedString ANSI color cache updates when theme changes")
    func attrColorCacheUpdatesWhenThemeChanges() {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }

        let input = "\u{1B}[32mFresh\u{1B}[0m"
        ThemeRuntimeState.setThemeID(.dark)
        let darkResult = ANSIParser.attributedString(from: input)
        let darkColor = darkResult.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor

        ThemeRuntimeState.setThemeID(.light)
        let lightResult = ANSIParser.attributedString(from: input)
        let lightColor = lightResult.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor

        #expect(darkColor == UIColor(ThemePalettes.dark.green))
        #expect(lightColor == UIColor(ThemePalettes.light.green))
        #expect(darkColor != lightColor)
    }

    @Test("handles kypu status output")
    func kypuStatus() {
        let input = """
        \u{1B}[1mStatus\u{1B}[0m \u{1B}[1;36m2026\u{1B}[0m-\u{1B}[1;36m02\u{1B}[0m-\u{1B}[1;36m07\u{1B}[0m
        CTL \u{1B}[1;36m115\u{1B}[0m │ ATL \u{1B}[1;36m94\u{1B}[0m │ TSB \u{1B}[1;32m+\u{1B}[0m\u{1B}[1;32m21\u{1B}[0m
        \u{1B}[32mFresh\u{1B}[0m \u{1B}[32m████████████\u{1B}[0m░░░
        """
        let stripped = ANSIParser.strip(input)
        #expect(stripped.contains("Status 2026-02-07"))
        #expect(stripped.contains("CTL 115"))
        #expect(stripped.contains("TSB +21"))
        #expect(stripped.contains("Fresh ████████████░░░"))

        let attr = ANSIParser.attributedString(from: input)
        #expect(attr.string.contains("Status 2026-02-07"))
    }

    @Test("handles 256-color codes")
    func color256() {
        let input = "\u{1B}[38;5;196mRed\u{1B}[0m"
        let stripped = ANSIParser.strip(input)
        #expect(stripped == "Red")
    }

    @Test("handles RGB color codes")
    func colorRGB() {
        let input = "\u{1B}[38;2;255;128;0mOrange\u{1B}[0m"
        let stripped = ANSIParser.strip(input)
        #expect(stripped == "Orange")
    }

    @Test("ignores oversized SGR numbers without crashing")
    func oversizedSGRNumber() {
        let input = "\u{1B}[38;5;999999999999999999999mRed\u{1B}[0m plain"
        let result = ANSIParser.attributedString(from: input)
        #expect(result.string == "Red plain")
    }

    @Test("handles dim text")
    func dimText() {
        let input = "\u{1B}[2m02-07\u{1B}[0m"
        let stripped = ANSIParser.strip(input)
        #expect(stripped == "02-07")

        let attributed = ANSIParser.attributedString(from: input)
        let dimColor = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        #expect(dimColor == UIColor(Color.themeFgDim))
    }

    @Test("handles consecutive codes without text between")
    func consecutiveCodes() {
        let input = "\u{1B}[1m\u{1B}[32mBoldGreen\u{1B}[0m"
        let stripped = ANSIParser.strip(input)
        #expect(stripped == "BoldGreen")
    }

    @Test("empty input")
    func emptyInput() {
        #expect(ANSIParser.strip("").isEmpty)
        #expect(ANSIParser.attributedString(from: "").string.isEmpty)
    }

    // MARK: - stripPrefix

    @Test("stripPrefix returns stripped text within byte limit")
    func stripPrefixBasic() {
        let input = "\u{1B}[32mHello\u{1B}[0m World"
        // First 20 bytes should cover the full input
        let result = ANSIParser.stripPrefix(input, maxInputBytes: 100)
        #expect(result == "Hello World")
    }

    @Test("stripPrefix truncates at byte limit")
    func stripPrefixTruncated() {
        // "\u{1B}[32m" = 5 bytes, "Hello" = 5 bytes
        // First 10 bytes = ESC[32m + Hello
        let input = "\u{1B}[32mHello\u{1B}[0m World"
        let result = ANSIParser.stripPrefix(input, maxInputBytes: 10)
        #expect(result == "Hello")
    }

    @Test("stripPrefix on plain text returns prefix")
    func stripPrefixPlainText() {
        let input = "Just plain text here"
        let result = ANSIParser.stripPrefix(input, maxInputBytes: 10)
        #expect(result == "Just plain")
    }

    @Test("stripPrefix with zero bytes returns empty")
    func stripPrefixZero() {
        #expect(ANSIParser.stripPrefix("hello", maxInputBytes: 0) == "")
    }

    @Test("stripPrefix handles empty input")
    func stripPrefixEmpty() {
        #expect(ANSIParser.stripPrefix("", maxInputBytes: 100) == "")
    }

    @Test("stripPrefix drops trailing standalone escape byte")
    func stripPrefixTrailingEscapeByte() {
        let input = "hello\u{1B}"
        let result = ANSIParser.stripPrefix(input, maxInputBytes: 100)
        #expect(result == "hello")
    }

    // MARK: - Background colors

    @Test("background color 41 (red) is emitted as .backgroundColor attribute")
    func bgColorRed() {
        // ESC[41;37m = red bg + white fg
        let input = "\u{1B}[41;37m ERROR \u{1B}[0m"
        let result = ANSIParser.attributedString(from: input)
        #expect(result.string.trimmingCharacters(in: .whitespaces) == "ERROR")

        let ns = result.string as NSString
        let range = ns.range(of: "ERROR")
        guard range.location != NSNotFound else {
            Issue.record("ERROR token not found in attributed string")
            return
        }
        let bg = result.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? UIColor
        #expect(bg != nil, "Expected .backgroundColor attribute for code 41")

        let fg = result.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
        #expect(fg != nil, "Expected .foregroundColor attribute for code 37")
    }

    @Test("background color 49 resets to nil")
    func bgColorReset() {
        let input = "\u{1B}[41mred bg\u{1B}[49m default bg\u{1B}[0m"
        let result = ANSIParser.attributedString(from: input)
        #expect(result.string.contains("red bg"))
        #expect(result.string.contains("default bg"))

        let ns = result.string as NSString
        let defaultRange = ns.range(of: "default bg")
        guard defaultRange.location != NSNotFound else {
            Issue.record("'default bg' not found")
            return
        }
        let bg = result.attribute(.backgroundColor, at: defaultRange.location, effectiveRange: nil)
        #expect(bg == nil, "Expected no .backgroundColor after code 49 reset")
    }

    @Test("background color 46 (cyan) is mapped to a theme color")
    func bgColorCyan() {
        let input = "\u{1B}[46m cyan section \u{1B}[0m"
        let result = ANSIParser.attributedString(from: input)
        let ns = result.string as NSString
        let range = ns.range(of: "cyan section")
        guard range.location != NSNotFound else {
            Issue.record("'cyan section' not found")
            return
        }
        let bg = result.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? UIColor
        #expect(bg != nil, "Expected .backgroundColor for code 46")
    }

    @Test("reset code 0 clears both fg and bg")
    func resetClearsBoth() {
        let input = "\u{1B}[41;31m colored \u{1B}[0m plain"
        let result = ANSIParser.attributedString(from: input)
        let ns = result.string as NSString
        let plainRange = ns.range(of: "plain")
        guard plainRange.location != NSNotFound else {
            Issue.record("'plain' not found")
            return
        }
        let bg = result.attribute(.backgroundColor, at: plainRange.location, effectiveRange: nil)
        #expect(bg == nil, "Expected no .backgroundColor after reset")
    }

    @Test("256-color background 48;5;n renders as .backgroundColor")
    func bgColor256() {
        let input = "\u{1B}[48;5;196m red-ish \u{1B}[0m"
        let result = ANSIParser.attributedString(from: input)
        let ns = result.string as NSString
        let range = ns.range(of: "red-ish")
        guard range.location != NSNotFound else {
            Issue.record("'red-ish' not found")
            return
        }
        let bg = result.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? UIColor
        #expect(bg != nil, "Expected .backgroundColor for 256-color bg code")
    }

    // MARK: - IncrementalStripper

    @Test("incremental stripper produces same result as full strip")
    func incrementalMatchesFullStrip() {
        let chunks = [
            "\u{1B}[32mHello",
            "\u{1B}[32mHello\u{1B}[0m World",
            "\u{1B}[32mHello\u{1B}[0m World\n\u{1B}[31mError\u{1B}[0m line",
        ]
        var stripper = ANSIParser.IncrementalStripper()
        var accumulated = ""
        for chunk in chunks {
            if let delta = stripper.delta(chunk) {
                accumulated += delta
            }
        }
        let fullStrip = ANSIParser.strip(chunks.last!)
        #expect(accumulated == fullStrip)
    }

    @Test("incremental stripper returns nil when input unchanged")
    func incrementalNilOnUnchanged() {
        var stripper = ANSIParser.IncrementalStripper()
        let input = "\u{1B}[32mHello\u{1B}[0m"
        _ = stripper.delta(input)
        #expect(stripper.delta(input) == nil)
    }

    @Test("incremental stripper handles plain text growth")
    func incrementalPlainText() {
        var stripper = ANSIParser.IncrementalStripper()
        let d1 = stripper.delta("Hello")
        #expect(d1 == "Hello")
        let d2 = stripper.delta("Hello World")
        #expect(d2 == " World")
    }

    @Test("incremental stripper handles escape at chunk boundary")
    func incrementalEscapeAtBoundary() {
        var stripper = ANSIParser.IncrementalStripper()
        // First chunk ends mid-escape: ESC[ but no terminator
        let partial = "text\u{1B}["
        let d1 = stripper.delta(partial)
        #expect(d1 == "text")
        // Second chunk completes the escape and adds more text
        let full = "text\u{1B}[32mcolored"
        let d2 = stripper.delta(full)
        #expect(d2 == "colored")
    }

    @Test("incremental stripper handles lone ESC at chunk boundary")
    func incrementalLoneEscapeBoundary() {
        var stripper = ANSIParser.IncrementalStripper()

        // First chunk ends with just ESC (before '[' arrives).
        let partial = "text\u{1B}"
        let d1 = stripper.delta(partial)
        #expect(d1 == "text")

        // Next chunk completes the CSI escape and adds text.
        let full = "text\u{1B}[32mcolored"
        let d2 = stripper.delta(full)
        #expect(d2 == "colored")
    }

    @Test("incremental stripper handles string controls across chunk boundaries")
    func incrementalStringControlBoundary() {
        let chunks = [
            "start\u{1B}Pdcs payload",
            "start\u{1B}Pdcs payload\u{1B}\\middle\u{0090}c1 payload",
            "start\u{1B}Pdcs payload\u{1B}\\middle\u{0090}c1 payload\u{009C}end",
        ]
        var stripper = ANSIParser.IncrementalStripper()
        var accumulated = ""
        for chunk in chunks {
            if let delta = stripper.delta(chunk) {
                accumulated += delta
            }
        }

        #expect(accumulated == "startmiddleend")
        #expect(accumulated == ANSIParser.strip(chunks.last!))

        let unicodeChunks = ["😀", "😀 Пр", "😀 Привет"]
        var unicodeStripper = ANSIParser.IncrementalStripper()
        var unicodeAccumulated = ""
        for chunk in unicodeChunks {
            if let delta = unicodeStripper.delta(chunk) {
                unicodeAccumulated += delta
            }
        }
        #expect(unicodeAccumulated == "😀 Привет")
    }

    @Test("incremental stripper tracks UTF-16 length")
    func incrementalUTF16Length() {
        var stripper = ANSIParser.IncrementalStripper()
        _ = stripper.delta("\u{1B}[32mcaf\u{00E9}\u{1B}[0m")
        // "cafe\u{0301}" stripped = "caf\u{00E9}" = 4 UTF-16 units
        #expect(stripper.strippedUTF16Length == 4)
    }

    @Test("incremental stripper reset clears state")
    func incrementalReset() {
        var stripper = ANSIParser.IncrementalStripper()
        _ = stripper.delta("Hello")
        #expect(stripper.processedInputBytes == 5)
        stripper.reset()
        #expect(stripper.processedInputBytes == 0)
        #expect(stripper.strippedUTF16Length == 0)
    }

    @Test("incremental stripper handles 256-color codes at boundary")
    func incrementalExtendedColorBoundary() {
        var stripper = ANSIParser.IncrementalStripper()
        // Chunk 1: text + start of extended color
        let c1 = "before\u{1B}[38;5"
        _ = stripper.delta(c1)
        // Chunk 2: complete the color + text
        let c2 = "before\u{1B}[38;5;196mRed\u{1B}[0m after"
        let d = stripper.delta(c2)
        // Total stripped should be "beforeRed after"
        #expect(d == "Red after")
    }

    @Test("incremental stripper simulates streaming build log")
    func incrementalStreamingBuildLog() {
        // Simulate 20 streaming chunks of growing ANSI output
        var fullOutput = ""
        var stripper = ANSIParser.IncrementalStripper()
        var accumulated = ""

        for i in 0..<20 {
            let line = "\u{1B}[32m\u{2713}\u{1B}[39m test_\(i) \u{1B}[2m(\(i)ms)\u{1B}[22m\n"
            fullOutput += line
            if let delta = stripper.delta(fullOutput) {
                accumulated += delta
            }
        }

        let expected = ANSIParser.strip(fullOutput)
        #expect(accumulated == expected)
    }

    @Test("RGB background 48;2;r;g;b renders as .backgroundColor")
    func bgColorRGB() {
        let input = "\u{1B}[48;2;255;0;128m magenta-bg \u{1B}[0m"
        let result = ANSIParser.attributedString(from: input)
        let ns = result.string as NSString
        let range = ns.range(of: "magenta-bg")
        guard range.location != NSNotFound else {
            Issue.record("'magenta-bg' not found")
            return
        }
        let bg = result.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? UIColor
        #expect(bg != nil, "Expected .backgroundColor for RGB bg code")
    }

    // MARK: - Performance

    @Test("benchmark: strip handles ~32KB mixed ANSI log quickly")
    func stripBenchmark32KB() {
        var input = ""
        input.reserveCapacity(40_000)

        var i = 0
        while input.utf8.count < 32 * 1024 {
            // Include a standalone ESC periodically to cover the
            // boundary-recovery branch in the hot path.
            let strayEscape = (i % 37 == 0) ? "\u{1B}" : ""
            input += "\u{1B}[32m\u{2713}\u{1B}[0m step_\(i) \(strayEscape)done in \u{1B}[2m\(i % 13)ms\u{1B}[22m\n"
            i += 1
        }

        #expect(input.utf8.count >= 32 * 1024)

        let ns = RendererTestSupport.medianNs(iterations: 9, warmup: 2) {
            RendererTestSupport.consume(ANSIParser.strip(input))
        }
        let us = RendererTestSupport.nsToUs(ns)
        print("METRIC ansi_strip_32kb_us=\(String(format: "%.1f", us))")

        // Generous budget to avoid CI flakes while still catching major
        // regressions and accidental quadratic behavior.
        #expect(us < 40_000,
            "ansi_strip_32kb_us exceeded budget: \(String(format: "%.1f", us))us > 40000us")
    }
}
