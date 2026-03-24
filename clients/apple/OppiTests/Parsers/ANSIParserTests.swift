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

    @Test("handles dim text")
    func dimText() {
        let input = "\u{1B}[2m02-07\u{1B}[0m"
        let stripped = ANSIParser.strip(input)
        #expect(stripped == "02-07")
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
}
