import Testing
import UIKit
@testable import Oppi

/// The reader's text cells stay a bounded height however long a run of prose
/// is. One cell per 180 KB run of paragraphs, or per huge paragraph, drew a
/// text view near 100,000 points tall and took the app past 1 GB.
@MainActor
@Suite("Reader text segment bound", .serialized)
struct ReaderTextSegmentBoundTests {
    nonisolated private static let sentence = "The quick brown fox jumps over the lazy dog near the riverbank. "

    /// Prose paragraphs with no heading or code between them: one merged run.
    nonisolated private static let paragraphs: String = {
        var text = ""
        var index = 0
        while text.utf8.count < 180_000 {
            index += 1
            text += "Paragraph \(index): " + String(repeating: sentence, count: 3) + "\n\n"
        }
        return text
    }()

    /// One paragraph, as when minified JSON or a log is pasted into a note.
    nonisolated private static let oneParagraph = String(repeating: sentence, count: 2_800)

    @Test("long prose builds into bounded segments that keep every word in order", arguments: [paragraphs, oneParagraph])
    func longProseSplitsWithoutLosingText(_ markdown: String) throws {
        let limit = FlatSegment.BuildResult.textSegmentCharacterLimit
        let build = FlatSegment.buildWithSourceLineRanges(from: parseCommonMarkLocated(markdown), themeID: .dark)
        let texts = build.segments.compactMap { segment -> String? in
            if case .text(let text) = segment { return String(text.characters) }
            return nil
        }
        #expect(texts.count == build.segments.count, "prose builds only text segments")
        #expect(texts.count > 1, "a long run splits")
        for text in texts {
            #expect(text.count <= limit)
            #expect(text.first?.isWhitespace == false, "a piece starts on a word")
        }
        #expect(build.sourceLineRanges.count == build.segments.count)
        #expect(Set(build.identities).count == build.identities.count, "every piece has its own identity")

        let unbounded = FlatSegment.build(from: parseCommonMark(markdown), themeID: .dark)
        let original = unbounded.compactMap { segment -> String? in
            if case .text(let text) = segment { return String(text.characters) }
            return nil
        }.joined(separator: " ")
        #expect(words(texts.joined(separator: " ")) == words(original), "no word is lost or cut")
    }

    @Test("the reader lays 180 KB of prose out in cells no taller than a few screens")
    func readerCellsStayBounded() async throws {
        let controller = FullScreenCodeViewController(
            content: .markdown(content: Self.paragraphs, filePath: "notes.md"),
            presentationMode: .embedded(onDismiss: {})
        )
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { hideTestWindow(window) }
        controller.view.frame = window.bounds
        var collection: UICollectionView?
        let rendered = await waitForMainActorCondition(timeout: .seconds(30)) {
            window.layoutIfNeeded()
            collection = collectionView(in: window)
            return (collection?.numberOfSections ?? 0) > 0 && (collection?.numberOfItems(inSection: 0) ?? 0) > 0
        }
        try #require(rendered, "the reader laid out its document")
        let collectionView = try #require(collection)
        collectionView.layoutIfNeeded()
        let heights = (0..<collectionView.numberOfItems(inSection: 0)).compactMap {
            collectionView.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.size.height
        }
        let tallest = try #require(heights.max())
        #expect(tallest < 8_000, "tallest cell \(tallest) pt across \(heights.count) cells")
    }

    private func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }

    private func collectionView(in view: UIView) -> UICollectionView? {
        if let collection = view as? UICollectionView { return collection }
        return view.subviews.lazy.compactMap { collectionView(in: $0) }.first
    }
}
