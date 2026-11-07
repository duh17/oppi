import Testing
import UIKit
@testable import Oppi

/// The full-screen document reader keeps its scroll view full-bleed and places
/// each block in the reading column (`ReaderReadingColumn`): prose centered at
/// the column width on a wide window, wide tables and code widened past it and
/// centered with it, short code at the prose width, and everything at the full
/// width on a narrow window.
@MainActor
@Suite("Full-screen reader centered column", .serialized)
struct FullScreenReaderCenteredColumnTests {
    private static let proseMarker = "Prose that would otherwise run edge to edge"
    private static let longCode = String(repeating: "wide_identifier ", count: 12)
    private static let markdown = """
    # Report

    \(proseMarker) across a wide window, long enough to wrap in the column.

    | Capability | Where it lives in the checkout | How a game uses it | Notes |
    | --- | --- | --- | --- |
    | Stored image and video attachments in tool rows, details.media, H.264 MP4 | docs/attachment-rendering.md and the server's sdk backend | Playtest frames and clips in the chat | Long enough to wrap in every column |

    ```sh
    \(longCode)
    ```

    ```sh
    ls
    ```
    """

    @Test("a wide window centers prose and widens the table and long code, not short code")
    func wideWindowPlacesBlocksInTheColumn() async throws {
        let window = try await makeWindow(content: .markdown(content: Self.markdown, filePath: "report.md"), width: 1376)
        defer { hideTestWindow(window) }
        let collection = try #require(collectionView(in: window))
        #expect(collection.frame.width == window.bounds.width, "the scroll view stays full-bleed")

        let prose = try #require(proseFrame(in: collection, window: window))
        #expect(prose.width < window.bounds.width * 0.75, "a wide window caps the prose column: \(prose)")
        #expect(abs(prose.midX - window.bounds.midX) <= 1, "the column is centered: \(prose)")

        let table = try #require(frames(of: NativeTableBlockView.self, in: collection, window: window).first)
        #expect(table.width > prose.width + 40, "the wide table widens past the prose: \(table)")
        #expect(table.maxX <= window.bounds.width - 12, "and stays inside the content width: \(table)")
        #expect(abs(table.midX - window.bounds.midX) <= 1, "centered with the column: \(table)")

        let code = frames(of: NativeCodeBlockView.self, in: collection, window: window).sorted { $0.minY < $1.minY }
        try #require(code.count == 2)
        #expect(code[0].width > prose.width + 40, "the long code block widens: \(code[0])")
        #expect(abs(code[0].midX - window.bounds.midX) <= 1, "centered with the column: \(code[0])")
        #expect(abs(code[1].minX - prose.minX) <= 1 && abs(code[1].width - prose.width) <= 1, "short code keeps the prose column: \(code[1])")
    }

    @Test("a narrow window reads at the full width and widening it centers the column")
    func resizingFromNarrowToWideCentersTheColumn() async throws {
        let window = try await makeWindow(content: .markdown(content: Self.markdown, filePath: "report.md"), width: 393)
        defer { hideTestWindow(window) }
        let collection = try #require(collectionView(in: window))
        let narrow = try #require(proseFrame(in: collection, window: window))
        #expect(abs(narrow.minX - 12) <= 1 && abs(narrow.maxX - (window.bounds.width - 12)) <= 1, "full width: \(narrow)")

        window.frame = CGRect(x: 0, y: 0, width: 1376, height: 1032)
        window.rootViewController?.view.frame = window.bounds
        window.layoutIfNeeded()
        let wide = try #require(proseFrame(in: collection, window: window))
        #expect(wide.width < window.bounds.width * 0.75, "the wider window caps the column: \(wide)")
        #expect(abs(wide.midX - window.bounds.midX) <= 1, "and centers it: \(wide)")
    }

    @Test("Org prose sits in the same column as Markdown")
    func orgUsesTheSameColumn() async throws {
        let window = try await makeWindow(
            content: .orgMode(content: "* Report\n\n\(Self.proseMarker) across a wide window.\n", filePath: "notes.org"),
            width: 1376
        )
        defer { hideTestWindow(window) }
        let collection = try #require(collectionView(in: window))
        let prose = try #require(proseFrame(in: collection, window: window))
        #expect(prose.width < window.bounds.width * 0.75, "Org caps the prose column too: \(prose)")
        #expect(abs(prose.midX - window.bounds.midX) <= 1, "centered: \(prose)")
    }

    // MARK: - Helpers

    /// A reader in a real window, returned once its prose is laid out: Org
    /// converts off the main actor first, so the wait is on that condition.
    private func makeWindow(content: FullScreenCodeContent, width: CGFloat) async throws -> UIWindow {
        let controller = FullScreenCodeViewController(content: content, presentationMode: .embedded(onDismiss: {}))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1032))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        let rendered = await waitForMainActorCondition(timeout: .seconds(30)) {
            window.layoutIfNeeded()
            guard let collection = collectionView(in: window) else { return false }
            return proseFrame(in: collection, window: window) != nil
        }
        if !rendered { hideTestWindow(window) }
        try #require(rendered, "the reader laid out its prose")
        return window
    }

    private func collectionView(in view: UIView) -> UICollectionView? {
        if let collection = view as? UICollectionView { return collection }
        return view.subviews.lazy.compactMap { collectionView(in: $0) }.first
    }

    private func proseFrame(in collection: UICollectionView, window: UIWindow) -> CGRect? {
        collection.layoutIfNeeded()
        return descendants(of: UITextView.self, in: collection)
            .first { $0.text.contains(Self.proseMarker) }
            .map { $0.convert($0.bounds, to: window) }
    }

    private func frames<T: UIView>(of type: T.Type, in collection: UICollectionView, window: UIWindow) -> [CGRect] {
        descendants(of: type, in: collection).map { $0.convert($0.bounds, to: window) }
    }

    private func descendants<T: UIView>(of type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { subview in
            (subview as? T).map { [$0] } ?? descendants(of: type, in: subview)
        }
    }
}
