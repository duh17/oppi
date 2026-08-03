import Foundation
import Testing
import UIKit
@testable import Oppi

/// Regression: long completed markdown can render with a large blank vertical
/// tail inside the assistant card.
///
/// Root cause: `AssistantMarkdownContentView.intrinsicContentSize` is
/// width-dependent (320pt fallback while `bounds.width == 0`). Auto Layout
/// caches the intrinsic height captured during the first self-sizing pass,
/// before the view receives its real width. For short messages the difference
/// is negligible; long wrapping-heavy markdown amplifies it substantially.
@Suite("AssistantLongMarkdownBlankTail")
@MainActor
struct AssistantLongMarkdownBlankTailTests {

    private final class BundleAnchor: NSObject {}

    private func syntheticMarkdown() throws -> String {
        let bundle = Bundle(for: BundleAnchor.self)
        let url = try #require(
            bundle.url(forResource: "synthetic-long-markdown", withExtension: "md"),
            "Missing synthetic-long-markdown.md fixture in OppiTests bundle"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Row-level seam: after the row has been laid out at its real width, a
    /// subsequent self-sizing pass (what SafeSizingCell runs on every layout
    /// invalidation) must match the rendered content height instead of the
    /// stale 320pt-fallback measurement captured before first layout.
    @Test func settledRowSizingMatchesRenderedContent() throws {
        let text = try syntheticMarkdown()
        let row = AssistantTimelineRowContentView(configuration: .init(
            text: text,
            isStreaming: false,
            canFork: false,
            onFork: nil
        ))

        let rowWidth: CGFloat = 358
        // First sizing pass mirrors SafeSizingCell measuring a fresh cell.
        _ = row.systemLayoutSizeFitting(
            CGSize(width: rowWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .defaultLow
        )

        // Give the row its real width, like a laid-out cell.
        let container = UIView(frame: CGRect(x: 0, y: 0, width: rowWidth, height: 800))
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        container.layoutIfNeeded()

        let markdownView = try #require(
            timelineFirstView(ofType: AssistantMarkdownContentView.self, in: row)
        )
        let stack = try #require(timelineFirstView(ofType: UIStackView.self, in: markdownView))
        let contentHeight = stack.arrangedSubviews.map(\.frame.maxY).max() ?? 0
        let expectedRowHeight = contentHeight
            + AssistantTimelineRowContentView.bubbleVerticalPadding * 2

        let settled = row.systemLayoutSizeFitting(
            CGSize(width: rowWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .defaultLow
        )

        #expect(
            abs(settled.height - expectedRowHeight) <= 2,
            "Settled assistant row height \(settled.height) should match rendered content height \(expectedRowHeight); blank tail \(settled.height - expectedRowHeight)pt"
        )
    }

    /// User-visible outcome: a completed session opened from history must not
    /// leave a blank tail inside the final assistant card.
    @Test func historyLongMarkdownRowHasNoBlankTail() async throws {
        let text = try syntheticMarkdown()
        let wh = makeWindowedTimelineHarness(
            sessionId: "synthetic-long-markdown-blank-tail",
            useAnchoredCollectionView: true
        )
        wh.applyItems(
            [
                .assistantMessage(
                    id: "a-early",
                    text: "Earlier synthetic assistant note.",
                    timestamp: Date(timeIntervalSince1970: 0)
                ),
                .assistantMessage(id: "a-long", text: text, timestamp: Date(timeIntervalSince1970: 1)),
            ],
            isBusy: false
        )

        let ip = IndexPath(item: 1, section: 0)
        let collectionView = wh.collectionView
        collectionView.scrollToItem(at: ip, at: .bottom, animated: false)
        collectionView.layoutIfNeeded()

        let settled = await waitForTimelineCondition(timeoutMs: 2_000) {
            await MainActor.run {
                collectionView.layoutIfNeeded()
                guard let blank = Self.blankTail(in: collectionView, at: ip) else { return false }
                return blank <= 2
            }
        }

        let blank = await MainActor.run { Self.blankTail(in: collectionView, at: ip) ?? -1 }
        #expect(
            settled,
            "Final long-markdown card retains a \(blank)pt blank tail below the rendered content"
        )
    }

    /// Empty space between the rendered markdown content bottom and the markdown
    /// view's own bounds — the blank tail visible inside the assistant bubble.
    @MainActor
    private static func blankTail(in collectionView: UICollectionView, at ip: IndexPath) -> CGFloat? {
        guard let cell = collectionView.cellForItem(at: ip),
              let row = timelineFirstView(ofType: AssistantTimelineRowContentView.self, in: cell.contentView),
              let markdownView = timelineFirstView(ofType: AssistantMarkdownContentView.self, in: row),
              let stack = timelineFirstView(ofType: UIStackView.self, in: markdownView)
        else { return nil }
        let contentMaxY = stack.arrangedSubviews.map(\.frame.maxY).max() ?? 0
        return markdownView.bounds.height - contentMaxY
    }
}
