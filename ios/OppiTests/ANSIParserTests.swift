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
        #expect(String(result.characters) == "Hello")
    }

    @Test("attributedString strips codes from character content")
    func attrCharacters() {
        let input = "\u{1B}[1mBold\u{1B}[0m Normal"
        let result = ANSIParser.attributedString(from: input)
        #expect(String(result.characters) == "Bold Normal")
    }

    @Test("attributedString bridges foreground colors for UIKit rendering")
    func attrUIKitForegroundColors() {
        let input = "\u{1B}[32mFresh\u{1B}[0m plain"
        let attributed = ANSIParser.attributedString(from: input)
        let bridged = NSAttributedString(attributed)
        let text = bridged.string as NSString

        let freshRange = text.range(of: "Fresh")
        let plainRange = text.range(of: "plain")
        guard freshRange.location != NSNotFound,
              plainRange.location != NSNotFound else {
            Issue.record("Expected token ranges in bridged ANSI attributed string")
            return
        }

        let freshColor = bridged.attribute(.foregroundColor, at: freshRange.location, effectiveRange: nil) as? UIColor
        let plainColor = bridged.attribute(.foregroundColor, at: plainRange.location, effectiveRange: nil) as? UIColor

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
        #expect(String(attr.characters).contains("Status 2026-02-07"))
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
        #expect(ANSIParser.strip("") == "")
        #expect(String(ANSIParser.attributedString(from: "").characters) == "")
    }
}
