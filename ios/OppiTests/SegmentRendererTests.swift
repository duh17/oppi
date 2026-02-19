import Testing
import UIKit
@testable import Oppi

@Suite("SegmentRenderer")
@MainActor
struct SegmentRendererTests {

    // MARK: - attributedString

    @Test func rendersEmptySegments() {
        let result = SegmentRenderer.attributedString(from: [])
        #expect(result.length == 0)
    }

    @Test func rendersSingleBoldSegment() {
        let segments: [StyledSegment] = [
            StyledSegment(text: "bash ", style: .bold),
        ]
        let result = SegmentRenderer.attributedString(from: segments)
        #expect(result.string == "bash ")

        var range = NSRange()
        let font = result.attribute(.font, at: 0, effectiveRange: &range) as? UIFont
        #expect(font != nil)
        #expect(font!.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    @Test func rendersMultipleSegmentsWithStyles() {
        let segments: [StyledSegment] = [
            StyledSegment(text: "read ", style: .bold),
            StyledSegment(text: "src/main.ts", style: .accent),
            StyledSegment(text: ":1-50", style: .warning),
        ]
        let result = SegmentRenderer.attributedString(from: segments)
        #expect(result.string == "read src/main.ts:1-50")
    }

    @Test func rendersUnstyled() {
        let segments: [StyledSegment] = [
            StyledSegment(text: "plain text", style: nil),
        ]
        let result = SegmentRenderer.attributedString(from: segments)
        #expect(result.string == "plain text")
    }

    // MARK: - plainText

    @Test func plainTextConcatenation() {
        let segments: [StyledSegment] = [
            StyledSegment(text: "remember ", style: .bold),
            StyledSegment(text: "\"hello\"", style: .muted),
            StyledSegment(text: " [test]", style: .dim),
        ]
        #expect(SegmentRenderer.plainText(from: segments) == "remember \"hello\" [test]")
    }

    // MARK: - toolNamePrefix

    @Test func toolNamePrefixFromBoldFirstSegment() {
        let segments: [StyledSegment] = [
            StyledSegment(text: "recall ", style: .bold),
            StyledSegment(text: "\"query\"", style: .muted),
        ]
        #expect(SegmentRenderer.toolNamePrefix(from: segments) == "recall")
    }

    @Test func toolNamePrefixNilWhenNotBold() {
        let segments: [StyledSegment] = [
            StyledSegment(text: "output", style: .success),
        ]
        #expect(SegmentRenderer.toolNamePrefix(from: segments) == nil)
    }

    @Test func toolNamePrefixNilWhenEmpty() {
        #expect(SegmentRenderer.toolNamePrefix(from: []) == nil)
    }

    // MARK: - trailingText

    @Test func trailingTextFromResultSegments() {
        let segments: [StyledSegment] = [
            StyledSegment(text: "✓ Saved ", style: .success),
            StyledSegment(text: "→ journal", style: .muted),
        ]
        #expect(SegmentRenderer.trailingText(from: segments) == "✓ Saved → journal")
    }

    @Test func trailingTextNilWhenEmpty() {
        #expect(SegmentRenderer.trailingText(from: []) == nil)
    }

    // MARK: - trailingAttributedString

    @Test func trailingAttributedStringRenders() {
        let segments: [StyledSegment] = [
            StyledSegment(text: "exit 127", style: .error),
        ]
        let result = SegmentRenderer.trailingAttributedString(from: segments)
        #expect(result != nil)
        #expect(result!.string == "exit 127")
    }

    @Test func trailingAttributedStringNilWhenEmpty() {
        #expect(SegmentRenderer.trailingAttributedString(from: []) == nil)
    }
}
