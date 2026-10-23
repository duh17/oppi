import Foundation
import Testing
import UIKit

@testable import Oppi

/// The applier appends a streamed tick only on the segment source's proof that
/// the text on screen is unchanged, attributes included. Whatever a tick does
/// to earlier glyphs (a setext underline, a list marker, a closing delimiter, a
/// late link definition, a reader-scale change) the view must end up exactly
/// where a fresh full render of the same content lands.
@Suite("Streaming text append differential")
@MainActor
struct StreamingTextAppendDifferentialTests {
    private static let scaled = FullScreenReaderPreferences(textScale: 1.3)

    private struct Fixture {
        let name: String
        let source: String
        /// Reader preferences from this UTF-8 length on. The tick that crosses
        /// it is applied twice: once with the old preferences, once with the
        /// new ones and the same content.
        var scaleFromUTF8Count: Int?
    }

    private static let fixtures: [Fixture] = [
        Fixture(name: "setext =", source: "Prose line\n===\n\nAfter the heading.\n"),
        Fixture(name: "setext -", source: "Wrapped prose\nthat continues\n---\n\nAfter the heading.\n"),
        Fixture(name: "intro then bullet", source: "Intro:\n- First\n- Second\n\nAfter the list.\n"),
        Fixture(name: "tight to loose list", source: "- one\n- two\n\n- three\n\nAfter the list.\n"),
        Fixture(name: "lazy blockquote", source: "> quoted line\nlazy continuation\n\nAfter the quote.\n"),
        Fixture(
            name: "inline spans closing",
            source: "Use **bold** and `code` and *em* here.\n\nThen ~~strike~~ and **more `nested`** markup.\n"
        ),
        Fixture(
            name: "late link definition",
            source: "See [foo] here.\n\nA middle paragraph.\n\n[foo]: /url\n\nAfter [foo].\n"
        ),
        Fixture(
            name: "nested fence in a list item",
            source: "1. step\n\n   ```swift\n   let a = 1\n   ```\n\n2. next step\n\nAfter the list.\n"
        ),
        Fixture(name: "two-item ordered list", source: "Steps:\n\n1. First step\n\n2. Second step\n\nDone.\n"),
        Fixture(
            name: "reader scale mid-stream",
            source: "First paragraph streams at the default size.\n\nSecond paragraph keeps streaming after the scale changes.\n",
            scaleFromUTF8Count: 30
        ),
    ]

    @Test(arguments: [1, 3, 8, 32])
    func streamedTextMatchesAFreshRenderAfterEveryTick(chunkSize: Int) {
        for fixture in Self.fixtures {
            let view = AssistantMarkdownContentView()
            var scaled = false

            for prefix in Self.prefixes(of: fixture.source, chunkSize: chunkSize) {
                if let threshold = fixture.scaleFromUTF8Count, !scaled, prefix.utf8.count >= threshold {
                    // Same content, old preferences first, then only the scale changes.
                    stream(prefix, preferences: nil, into: view, fixture: fixture.name, chunkSize: chunkSize)
                    scaled = true
                }
                stream(
                    prefix,
                    preferences: scaled ? Self.scaled : nil,
                    into: view,
                    fixture: fixture.name,
                    chunkSize: chunkSize
                )
            }
        }
    }

    /// The perf contract the proof exists for: plain prose, paragraph freezes
    /// included, appends every tick and never reboxes the whole tail.
    @Test func plainProseStreamNeverReplacesTheTail() {
        let paragraphs = (0..<6).map { "Paragraph \($0) streams plain prose with no markup in it at all." }
        let view = AssistantMarkdownContentView()
        let ticks = Self.prefixes(of: paragraphs.joined(separator: "\n\n"), chunkSize: 8)

        for prefix in ticks {
            view.apply(configuration: .make(content: prefix, isStreaming: true, themeID: .dark))
        }

        #expect(view.debugStreamingFullNSConversionCountForTesting == 0)
        #expect(view.debugStreamingDeltaNSConversionCountForTesting > ticks.count / 2)
    }

    private func stream(
        _ content: String,
        preferences: FullScreenReaderPreferences?,
        into view: AssistantMarkdownContentView,
        fixture: String,
        chunkSize: Int
    ) {
        view.apply(configuration: .make(
            content: content,
            isStreaming: true,
            themeID: .dark,
            readerPreferences: preferences
        ))
        // A fresh full render, through a text view too: UIKit resolves
        // presentation intents into fonts and spreads a paragraph's style over
        // its newline, so a bare NSAttributedString never matches a view.
        let fullConfig = AssistantMarkdownContentView.Configuration.make(
            content: content,
            isStreaming: false,
            themeID: .dark,
            readerPreferences: preferences
        )
        let freshStack = UIStackView()
        let freshApplier = AssistantMarkdownSegmentApplier(
            stackView: freshStack,
            textViewDelegate: textViewDelegate
        )
        freshApplier.apply(
            segments: AssistantMarkdownSegmentSource().buildSegments(fullConfig),
            config: fullConfig
        )
        let expected = Self.attributedTexts(in: freshStack)
        let rendered = Self.attributedTexts(in: Self.stack(of: view))

        #expect(
            rendered.count == expected.count
                && zip(rendered, expected).allSatisfy { $0.isEqual(to: $1) },
            "\(fixture) diverged from a fresh render at \(content.utf8.count) UTF-8 bytes (chunk \(chunkSize)): \(String(reflecting: content))"
        )
    }

    private let textViewDelegate = NoOpTextViewDelegate()

    private static func stack(of view: AssistantMarkdownContentView) -> UIStackView? {
        view.subviews.lazy.compactMap { $0 as? UIStackView }.first
    }

    /// Text of the views stacked for `.text` segments, in order. Code blocks
    /// and tables nest their own text views; those are not prose.
    private static func attributedTexts(in stack: UIStackView?) -> [NSAttributedString] {
        (stack?.arrangedSubviews ?? []).compactMap { view in
            (view as? UITextView).map { $0.attributedText ?? NSAttributedString() }
        }
    }

    private static func prefixes(of source: String, chunkSize: Int) -> [String] {
        let characters = Array(source)
        var result: [String] = []
        var content = ""
        var offset = 0
        while offset < characters.count {
            let end = min(offset + chunkSize, characters.count)
            content.append(contentsOf: characters[offset..<end])
            offset = end
            result.append(content)
        }
        return result
    }
}

private final class NoOpTextViewDelegate: NSObject, UITextViewDelegate {}
