import Testing
import SwiftUI
import UIKit
@testable import Oppi

@Suite("DiffAttributedStringBuilder gutter attributes")
@MainActor
struct DiffGutterAttributeTests {

    private func makeHunks() -> [WorkspaceReviewDiffHunk] {
        [
            WorkspaceReviewDiffHunk(
                oldStart: 1,
                oldCount: 3,
                newStart: 1,
                newCount: 3,
                lines: [
                    WorkspaceReviewDiffLine(
                        kind: .context,
                        text: "let x = 1",
                        oldLine: 1,
                        newLine: 1,
                        spans: nil
                    ),
                    WorkspaceReviewDiffLine(
                        kind: .removed,
                        text: "let y = 2",
                        oldLine: 2,
                        newLine: nil,
                        spans: nil
                    ),
                    WorkspaceReviewDiffLine(
                        kind: .added,
                        text: "let y = 3",
                        oldLine: nil,
                        newLine: 2,
                        spans: nil
                    ),
                    WorkspaceReviewDiffLine(
                        kind: .context,
                        text: "let z = 4",
                        oldLine: 3,
                        newLine: 3,
                        spans: nil
                    ),
                ]
            ),
        ]
    }

    // MARK: - Gutter background coverage

    /// The gutter region (" + " / " - ") must carry a .backgroundColor attribute
    /// so that timeline expanded views (plain UITextView, no custom layout manager)
    /// show the tinted line background across the entire row — not just line
    /// numbers and code. UnifiedDiffView compensates with UnifiedDiffLayoutManager
    /// but the attributed string itself must be self-contained.
    @Test func addedGutterHasBackgroundColor() throws {
        let result = DiffAttributedStringBuilder.build(
            hunks: makeHunks(), filePath: "test.swift"
        )
        let text = result.string as NSString

        // Find the added line gutter: " + "
        let gutterRange = text.range(of: " + ")
        guard gutterRange.location != NSNotFound else {
            Issue.record("Expected ' + ' gutter marker in diff output")
            return
        }

        let bg = result.attribute(.backgroundColor, at: gutterRange.location, effectiveRange: nil)
        #expect(bg != nil, "Added gutter ' + ' must have a .backgroundColor attribute for non-layout-manager contexts")
    }

    @Test func removedGutterHasBackgroundColor() throws {
        let result = DiffAttributedStringBuilder.build(
            hunks: makeHunks(), filePath: "test.swift"
        )
        let text = result.string as NSString

        // Find the removed line gutter: " - "
        let gutterRange = text.range(of: " - ")
        guard gutterRange.location != NSNotFound else {
            Issue.record("Expected ' - ' gutter marker in diff output")
            return
        }

        let bg = result.attribute(.backgroundColor, at: gutterRange.location, effectiveRange: nil)
        #expect(bg != nil, "Removed gutter ' - ' must have a .backgroundColor attribute for non-layout-manager contexts")
    }

    /// Context lines use "   " (no gutter bar) — they must NOT have a background.
    @Test func contextGutterHasNoBackgroundColor() throws {
        let result = DiffAttributedStringBuilder.build(
            hunks: makeHunks(), filePath: "test.swift"
        )
        let text = result.string as NSString

        // Find context lines by looking for "   " followed by line number
        // Context gutter is 3 spaces. Find the first line of text that starts with spaces.
        // We need the position right after a newline that starts with "   "
        let lines = (text as String).components(separatedBy: "\n")
        var offset = 0
        var contextGutterStart: Int?
        for line in lines {
            if line.hasPrefix("   ") && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Check it's not a header line
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.hasPrefix("@@") {
                    contextGutterStart = offset
                    break
                }
            }
            offset += (line as NSString).length + 1 // +1 for newline
        }

        guard let start = contextGutterStart else {
            Issue.record("Expected a context line with '   ' gutter")
            return
        }

        let bg = result.attribute(.backgroundColor, at: start, effectiveRange: nil)
        #expect(bg == nil, "Context gutter '   ' should NOT have a background color")
    }

    // MARK: - Gutter background matches line background

    /// The gutter background must use the same tint as the line number/code region
    /// so the entire row reads as one continuous band.
    @Test func addedGutterBackgroundMatchesCodeBackground() throws {
        let result = DiffAttributedStringBuilder.build(
            hunks: makeHunks(), filePath: "test.swift"
        )
        let text = result.string as NSString

        let gutterRange = text.range(of: " + ")
        guard gutterRange.location != NSNotFound else {
            Issue.record("Expected ' + ' gutter marker")
            return
        }

        // Find the code region (after line numbers) on the same line
        let lineStart = gutterRange.location
        let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
        // The code starts after gutter + line numbers; just check middle of line
        let midLine = lineRange.location + lineRange.length / 2
        guard midLine < text.length else {
            Issue.record("Line too short to find code region")
            return
        }

        let gutterBg = result.attribute(.backgroundColor, at: gutterRange.location, effectiveRange: nil) as? UIColor
        let codeBg = result.attribute(.backgroundColor, at: midLine, effectiveRange: nil) as? UIColor

        #expect(gutterBg != nil, "Gutter must have background")
        #expect(codeBg != nil, "Code region must have background")
        #expect(gutterBg == codeBg, "Gutter background must match code background for visual continuity")
    }

    // MARK: - Theme cache invalidation

    /// StyleAttrs must rebuild when the theme changes — cached colors from
    /// a previous theme must not leak into the new theme's diff output.
    @Test func gutterColorUpdatesOnThemeChange() throws {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }

        // Build with dark theme
        ThemeRuntimeState.setThemeID(.dark)
        let darkResult = DiffAttributedStringBuilder.build(
            hunks: makeHunks(), filePath: "test.swift"
        )
        let darkText = darkResult.string as NSString
        let darkGutterRange = darkText.range(of: " + ")
        let darkGutterColor = darkResult.attribute(
            .foregroundColor, at: darkGutterRange.location, effectiveRange: nil
        ) as? UIColor

        // Switch to light theme and rebuild
        ThemeRuntimeState.setThemeID(.light)
        let lightResult = DiffAttributedStringBuilder.build(
            hunks: makeHunks(), filePath: "test.swift"
        )
        let lightText = lightResult.string as NSString
        let lightGutterRange = lightText.range(of: " + ")
        let lightGutterColor = lightResult.attribute(
            .foregroundColor, at: lightGutterRange.location, effectiveRange: nil
        ) as? UIColor

        #expect(darkGutterColor != nil, "Dark gutter must have foreground color")
        #expect(lightGutterColor != nil, "Light gutter must have foreground color")
        #expect(darkGutterColor != lightGutterColor,
                "Gutter color must change when theme changes (dark vs light use different accent colors)")
    }

    // MARK: - diffLineKindAttributeKey coverage

    /// The gutter region must carry diffLineKindAttributeKey so that
    /// UnifiedDiffLayoutManager can paint full-width backgrounds for
    /// the gutter area too (not just line numbers + code).
    @Test func addedGutterHasDiffLineKindAttribute() throws {
        let result = DiffAttributedStringBuilder.build(
            hunks: makeHunks(), filePath: "test.swift"
        )
        let text = result.string as NSString

        let gutterRange = text.range(of: " + ")
        guard gutterRange.location != NSNotFound else {
            Issue.record("Expected ' + ' gutter marker")
            return
        }

        let kind = result.attribute(diffLineKindAttributeKey, at: gutterRange.location, effectiveRange: nil) as? String
        #expect(kind == "added", "Added gutter must have diffLineKindAttributeKey='added'")
    }

    @Test func removedGutterHasDiffLineKindAttribute() throws {
        let result = DiffAttributedStringBuilder.build(
            hunks: makeHunks(), filePath: "test.swift"
        )
        let text = result.string as NSString

        let gutterRange = text.range(of: " - ")
        guard gutterRange.location != NSNotFound else {
            Issue.record("Expected ' - ' gutter marker")
            return
        }

        let kind = result.attribute(diffLineKindAttributeKey, at: gutterRange.location, effectiveRange: nil) as? String
        #expect(kind == "removed", "Removed gutter must have diffLineKindAttributeKey='removed'")
    }
}
