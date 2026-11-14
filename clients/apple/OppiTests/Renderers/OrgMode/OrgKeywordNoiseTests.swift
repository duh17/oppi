import Testing
@testable import Oppi

/// The owner's fourth approved fix: keyword noise. `#+TITLE`/`#+AUTHOR`/
/// `#+DATE` already become a header and subtle metadata; `#+FILETAGS` now
/// reuses the heading-tag capsule style instead of a code chip, and every
/// other `#+KEY:` line is shown subtly instead of as a code chip.
@Suite("Org keyword noise")
struct OrgKeywordNoiseTests {
    let parser = OrgParser()

    private func convert(_ source: String) -> [MarkdownBlock] {
        OrgToMarkdownConverter.convert(parser.parse(source))
    }

    /// The badges of a line apart from a heading's bullet (`OrgHeadingFoldTests`).
    private func badges(_ inlines: [MarkdownInline]) -> [MarkdownBadge] {
        inlines.compactMap { inline in
            guard case let .html(raw) = inline, let badge = MarkdownBadge(markup: raw), badge.shape != .bullet else { return nil }
            return badge
        }
    }

    // MARK: - #+FILETAGS

    @Test func filetagsBecomesTagCapsulesNotACodeChip() {
        let blocks = convert("#+FILETAGS: :oppi:")
        guard case .paragraph(let inlines) = blocks[0] else {
            Issue.record("Expected a paragraph, got \(blocks[0])")
            return
        }
        #expect(!inlines.contains { if case .code = $0 { return true }; return false })
        let tags = badges(inlines)
        #expect(tags == [MarkdownBadge(text: "oppi", label: "tag oppi", tone: .quiet, shape: .capsule)])
    }

    @Test func filetagsWithSeveralTagsBecomesSeveralCapsules() {
        let blocks = convert("#+FILETAGS: :demo:sample:")
        guard case .paragraph(let inlines) = blocks[0] else {
            Issue.record("Expected a paragraph, got \(blocks[0])")
            return
        }
        #expect(badges(inlines).map(\.text) == ["demo", "sample"])
    }

    @Test func emptyFiletagsRendersNothing() {
        #expect(convert("#+FILETAGS:").isEmpty)
    }

    // MARK: - Other keyword lines

    @Test func otherKeywordLinesAreShownSubtlyNotAsACodeChip() {
        let blocks = convert("#+LINK: gh https://github.com/%s")
        guard case .paragraph(let inlines) = blocks[0] else {
            Issue.record("Expected a paragraph, got \(blocks[0])")
            return
        }
        guard case .emphasis(let emphasisInlines) = inlines.first else {
            Issue.record("Expected subtle emphasis, got \(inlines)")
            return
        }
        #expect(!inlines.contains { if case .code = $0 { return true }; return false })
        #expect(plainText(from: emphasisInlines) == "#+LINK: gh https://github.com/%s")
    }

    @Test func keywordWithNoValueRendersNothing() {
        #expect(convert("#+NAME:").isEmpty)
    }

    @Test func titleAuthorAndDateStillBecomeAHeaderAndSubtleMetadata() {
        let blocks = convert("#+TITLE: My Doc\n#+AUTHOR: Alex\n#+DATE: 2026-11-07")
        guard case .heading(let level, let inlines) = blocks[0] else {
            Issue.record("Expected a heading, got \(blocks[0])")
            return
        }
        #expect(level == 1)
        #expect(plainText(from: inlines) == "My Doc")
        #expect(blocks.count == 3)
        for block in blocks.dropFirst() {
            guard case .paragraph(let paragraphInlines) = block, case .emphasis = paragraphInlines.first else {
                Issue.record("Expected subtle metadata, got \(block)")
                return
            }
        }
    }

    // MARK: - Heading tags still reuse the capsule style

    @Test func headingTagsReuseTheSameCapsuleStyleAsFiletags() {
        let heading = convert("* Task :work:")
        let filetag = convert("#+FILETAGS: :work:")
        guard case .heading(_, let headingInlines) = heading[0], case .paragraph(let filetagInlines) = filetag[0] else {
            Issue.record("Expected a heading and a paragraph")
            return
        }
        #expect(badges(headingInlines) == badges(filetagInlines))
    }
}
