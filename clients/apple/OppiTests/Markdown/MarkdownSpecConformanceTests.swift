import Foundation
import Testing
@testable import Oppi

/// The CommonMark 0.31.2 spec examples and the GFM 0.29 spec's extension
/// examples (`Fixtures/markdown-spec`), parsed by `parseCommonMark` into
/// Oppi's own tree and written back as HTML (`MarkdownSpecHTML`), checked
/// against the spec's HTML as the spec's runner normalizes it.
///
/// The counts are floors: a change that makes an example fail fails here.
/// Raise a floor when an example starts passing. Examples where Oppi departs
/// from the spec on purpose (`MarkdownSpec.deliberate`) count neither way.
///
/// Known failures outside `deliberate`, as of the floors below: CommonMark
/// 28 and 354 (cmark-gfm follows spec 0.29 there: an out-of-range numeric
/// reference becomes U+FFFD, and `£`/`€` are not yet punctuation for
/// emphasis). The tree-gap examples are loose lists and link titles.
@Suite("Markdown spec conformance")
struct MarkdownSpecConformanceTests {
    @Test func commonMarkExamplesStayAtTheirFloor() throws {
        let results = try MarkdownSpec.run(MarkdownSpec.load("commonmark-0.31.2.json"))
        try MarkdownSpec.recordIfAsked(results, name: "commonmark")
        MarkdownSpec.expectFloors(results, key: MarkdownSpec.Key.commonMark, pass: 556, passOrTreeGap: 628, label: "CommonMark")
    }

    @Test func gfmExtensionExamplesStayAtTheirFloor() throws {
        let results = try MarkdownSpec.run(MarkdownSpec.load("gfm-0.29-extensions.json"))
        try MarkdownSpec.recordIfAsked(results, name: "gfm")
        MarkdownSpec.expectFloors(results, key: MarkdownSpec.Key.gfm, pass: 12, passOrTreeGap: 12, label: "GFM extensions")
    }
}

enum MarkdownSpec {
    struct Example: Decodable, Sendable {
        let markdown: String
        let html: String
        let example: Int
        let section: String
        let extension_: String?

        enum CodingKeys: String, CodingKey {
            case markdown, html, example, section
            case extension_ = "extension"
        }
    }

    enum Outcome: String, Encodable {
        case pass
        /// Equal once list tightness and titles, which the tree does not keep, are ignored.
        case treeGap
        case fail
    }

    struct Result: Encodable {
        let example: Example
        let outcome: Outcome
        let actual: String
        let expectedNormalized: String
        let actualNormalized: String
        let hasMath: Bool
        let tableRepaired: Bool

        enum CodingKeys: String, CodingKey {
            case outcome, actual, expectedNormalized, actualNormalized, hasMath, tableRepaired
            case number, section, markdown, html
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(example.example, forKey: .number)
            try container.encode(example.section, forKey: .section)
            try container.encode(example.markdown, forKey: .markdown)
            try container.encode(example.html, forKey: .html)
            try container.encode(outcome, forKey: .outcome)
            try container.encode(actual, forKey: .actual)
            try container.encode(expectedNormalized, forKey: .expectedNormalized)
            try container.encode(actualNormalized, forKey: .actualNormalized)
            try container.encode(hasMath, forKey: .hasMath)
            try container.encode(tableRepaired, forKey: .tableRepaired)
        }
    }

    enum Key: Hashable {
        case commonMark(Int)
        case gfm(Int)
    }

    /// Examples where Oppi departs from the spec on purpose, by example number.
    static let deliberate: [Key: String] = {
        var reasons: [Key: String] = [:]
        // A fence of four or more drops a trailing inner fence line that no
        // earlier line opens (`stripTrailingInnerFence`).
        for number in [124, 125] { reasons[.commonMark(number)] = "inner fence stripped" }
        // An HTML `<table>` becomes a native table (`MarkdownTableMarkupRewriter`).
        for number in [148, 149, 160, 190, 191] { reasons[.commonMark(number)] = "HTML table repaired" }
        // `[[…]]` is a wiki link before it is a bracketed reference link.
        reasons[.commonMark(559)] = "wiki link"
        // The inline HTML subset (`MarkdownInlineHTML`) reads raw HTML into
        // the tree instead of passing it through: comments are dropped (no
        // renderer shows them), its tags become native styles without their
        // attributes, an HTML block of them becomes a paragraph, and an
        // unpaired or unsupported tag shows as text.
        for number in [177, 179, 183, 308, 309, 625, 626] { reasons[.commonMark(number)] = "HTML comment dropped" }
        for number in [21, 31, 162, 164, 165, 166, 167] { reasons[.commonMark(number)] = "inline HTML subset" }
        // Bare URLs and emails stay text: chat text views link them with
        // iOS link detection when a reply finishes.
        for number in 621 ... 631 { reasons[.gfm(number)] = "bare links left to iOS link detection" }
        // Raw HTML outside the supported subset shows as text, so the
        // filtered tags never reach a web view to filter.
        reasons[.gfm(652)] = "raw HTML shown as text"
        return reasons
    }()

    static func expectFloors(
        _ results: [Result],
        key: (Int) -> Key,
        pass: Int,
        passOrTreeGap: Int,
        label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let counted = results.filter { deliberate[key($0.example.example)] == nil }
        let passed = counted.filter { $0.outcome == .pass }.count
        let close = counted.filter { $0.outcome != .fail }.count
        let failing = counted.filter { $0.outcome == .fail }.map { "\($0.example.example)" }.joined(separator: ",")
        #expect(passed >= pass, "\(label): \(passed) of \(counted.count) pass", sourceLocation: sourceLocation)
        #expect(close >= passOrTreeGap, "\(label): \(close) of \(counted.count) pass or differ only by tree gaps; failing: \(failing)", sourceLocation: sourceLocation)
    }

    static func load(_ fileName: String) throws -> [Example] {
        let url = try #require(TestFixtures.bundle.resourceURL?.appending(path: "markdown-spec/\(fileName)"))
        return try JSONDecoder().decode([Example].self, from: Data(contentsOf: url))
    }

    static func run(_ examples: [Example]) -> [Result] {
        examples.map { example in
            let blocks = parseCommonMark(example.markdown)
            let actual = MarkdownSpecHTML.render(blocks)
            let expected = MarkdownSpecHTML.normalize(example.html)
            let normalized = MarkdownSpecHTML.normalize(actual)
            let outcome: Outcome = if expected == normalized {
                .pass
            } else if MarkdownSpecHTML.relaxed(expected) == MarkdownSpecHTML.relaxed(normalized) {
                .treeGap
            } else {
                .fail
            }
            return Result(
                example: example,
                outcome: outcome,
                actual: actual,
                expectedNormalized: expected,
                actualNormalized: normalized,
                hasMath: actual.contains("class=\"math\""),
                tableRepaired: MarkdownTableMarkupRewriter.rewrite(example.markdown) != example.markdown
            )
        }
    }

    /// `TEST_RUNNER_OPPI_MARKDOWN_SPEC_RECORD_DIR` set: write every example's
    /// outcome there as JSON, for a conformance report.
    static func recordIfAsked(_ results: [Result], name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["OPPI_MARKDOWN_SPEC_RECORD_DIR"] else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: URL(filePath: directory).appending(path: "\(name)-results.json"))
    }
}
