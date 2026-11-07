import Foundation
import Testing
import UIKit
@testable import Oppi

/// Markdown table cost in a hosted assistant message and in the document reader.
///
/// Two table shapes:
/// - **clip**: every cell fits the readable clamp, so the table is one text view.
/// - **grid**: one column holds prose past the clamp, so cells wrap.
///
/// Each step includes `layoutIfNeeded` and `CATransaction.flush()`, so layout
/// and commit are counted the way a self-sizing chat cell pays them.
///
/// Output format: `METRIC name=number` (milliseconds).
@Suite("MarkdownTablePerfBench", .tags(.perf), .serialized)
@MainActor
struct MarkdownTablePerfBench {
    private enum Shape { case clip, grid }

    private static let width: CGFloat = 390

    // MARK: - Content

    private static func cell(row: Int, column: Int, columns: Int, shape: Shape) -> String {
        switch shape {
        case .clip:
            return column == 0 ? "item-\(row)" : "value \(row).\(column) ok"
        case .grid:
            return column == columns - 1
                ? "Long explanatory note for row \(row) that keeps going past the readable clamp so it wraps"
                : "r\(row)c\(column) val"
        }
    }

    private static func table(rows: Int, columns: Int, shape: Shape) -> String {
        var lines = ["| " + (0 ..< columns).map { "Column \($0)" }.joined(separator: " | ") + " |"]
        lines.append("|" + String(repeating: "---|", count: columns))
        for row in 0 ..< rows {
            lines.append("| " + (0 ..< columns)
                .map { cell(row: row, column: $0, columns: columns, shape: shape) }
                .joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    /// `tag` makes every message unique so the segment cache never answers.
    private static func message(rows: Int, columns: Int, shape: Shape, tag: String) -> String {
        "Comparison (\(tag)):\n\n" + table(rows: rows, columns: columns, shape: shape)
            + "\n\nThat covers every row."
    }

    // MARK: - Timing

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func ms(_ ns: UInt64) -> Double { Double(ns) / 1e6 }
    private static func fmt(_ value: Double) -> String { String(format: "%.2f", value) }

    private static func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    private static func hosted() -> (AssistantMarkdownContentView, UIWindow) {
        let markdown = AssistantMarkdownContentView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 844))
        markdown.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(markdown)
        NSLayoutConstraint.activate([
            markdown.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            markdown.topAnchor.constraint(equalTo: window.topAnchor),
            markdown.widthAnchor.constraint(equalToConstant: width),
        ])
        markdown.hostLayoutWidth = width
        window.makeKeyAndVisible()
        return (markdown, window)
    }

    /// What a self-sizing timeline cell does after configure: fit, lay out, commit.
    private static func fitLayoutCommit(_ markdown: AssistantMarkdownContentView, window: UIWindow) {
        _ = markdown.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        window.layoutIfNeeded()
        CATransaction.flush()
    }

    // MARK: - Settled configure

    private static func settledMs(rows: Int, columns: Int, shape: Shape, runs: Int) -> Double {
        var samples: [Double] = []
        for run in 0 ... runs {
            autoreleasepool {
                let content = message(rows: rows, columns: columns, shape: shape, tag: "settled-\(rows)-\(run)-\(shape)")
                let (markdown, window) = hosted()
                let start = now()
                markdown.apply(configuration: .make(content: content, isStreaming: false, themeID: .dark))
                fitLayoutCommit(markdown, window: window)
                // The first run warms fonts and TextKit.
                if run > 0 { samples.append(ms(now() - start)) }
                window.isHidden = true
            }
        }
        return median(samples)
    }

    @Test func settledGrid10x3() {
        let value = Self.settledMs(rows: 10, columns: 3, shape: .grid, runs: 5)
        print("METRIC table_settled_grid_10x3_ms=\(Self.fmt(value))")
        #expect(value < 15, "a 10x3 wrap grid should configure in under 15 ms")
    }

    @Test func settledGrid200x8() {
        let value = Self.settledMs(rows: 200, columns: 8, shape: .grid, runs: 2)
        print("METRIC table_settled_grid_200x8_ms=\(Self.fmt(value))")
        #expect(value < 500, "a 200x8 wrap grid should configure in under 0.5 s")
    }

    @Test func settledClip200x8() {
        let value = Self.settledMs(rows: 200, columns: 8, shape: .clip, runs: 2)
        print("METRIC table_settled_clip_200x8_ms=\(Self.fmt(value))")
    }

    // MARK: - Streaming

    /// Streams `content` in `chunk`-byte ticks. Each tick is apply + fit + layout
    /// + commit. Stops after `capSeconds` so a quadratic table cannot stall the run.
    private static func streamTicks(
        content: String,
        chunk: Int,
        capSeconds: Double,
        mode: ContentRenderingMode
    ) -> (ticks: [Double], completed: Bool) {
        let utf8 = Array(content.utf8)
        let (markdown, window) = hosted()
        defer { window.isHidden = true }
        var ticks: [Double] = []
        var end = 0
        let start = now()
        while end < utf8.count {
            if ms(now() - start) > capSeconds * 1000 { return (ticks, false) }
            end = min(utf8.count, end + chunk)
            while end < utf8.count, (utf8[end] & 0xC0) == 0x80 { end += 1 }
            let prefix = String(decoding: utf8[0 ..< end], as: UTF8.self)
            let tickStart = now()
            markdown.apply(configuration: .make(content: prefix, isStreaming: true, themeID: .dark, renderingMode: mode))
            fitLayoutCommit(markdown, window: window)
            ticks.append(ms(now() - tickStart))
        }
        return (ticks, true)
    }

    /// Chat folds a table past 20 rows, so after row 20 a chat tick only updates
    /// "Show all N rows". `.staticReader` never folds: it streams every row, which
    /// keeps the per-row cost of a long table measured.
    private func reportStream(shape: Shape, name: String, mode: ContentRenderingMode = .staticReader) {
        let content = Self.message(rows: 200, columns: 8, shape: shape, tag: "stream-\(name)")
        let (ticks, completed) = Self.streamTicks(content: content, chunk: 64, capSeconds: 60, mode: mode)
        let tenth = max(1, ticks.count / 10)
        let late = ticks.suffix(tenth)
        let lateMean = late.reduce(0, +) / Double(late.count)
        let sorted = ticks.sorted()
        print("METRIC table_stream_\(name)_200x8_ticks=\(ticks.count)")
        print("METRIC table_stream_\(name)_200x8_completed=\(completed ? 1 : 0)")
        print("METRIC table_stream_\(name)_200x8_p50_ms=\(Self.fmt(sorted[sorted.count / 2]))")
        print("METRIC table_stream_\(name)_200x8_late_mean_ms=\(Self.fmt(lateMean))")
        print("METRIC table_stream_\(name)_200x8_late_max_ms=\(Self.fmt(late.max() ?? 0))")
        print("METRIC table_stream_\(name)_200x8_total_ms=\(Self.fmt(ticks.reduce(0, +)))")
        print("METRIC table_stream_\(name)_200x8_max_ms=\(Self.fmt(sorted.last ?? 0))")
        #expect(completed, "the \(name) stream should finish inside the cap")
        // Target: no late tick over 50 ms.
        #expect((late.max() ?? 0) < 50, "no late \(name) tick should take 50 ms")
    }

    @Test func streamedClip200x8() { reportStream(shape: .clip, name: "clip") }
    @Test func streamedGrid200x8() { reportStream(shape: .grid, name: "grid") }
    @Test func streamedClip200x8InChat() { reportStream(shape: .clip, name: "chat_clip", mode: .live) }
    @Test func streamedGrid200x8InChat() { reportStream(shape: .grid, name: "chat_grid", mode: .live) }

    // MARK: - Reader

    @Test func readerGrid200x8() async throws {
        let content = "# Big table\n\nIntro paragraph.\n\n" + Self.table(rows: 200, columns: 8, shape: .grid)
            + "\n\nTrailing paragraph.\n"
        let start = Self.now()
        let body = NativeFullScreenMarkdownBody(
            content: content,
            sourceFormat: .markdown,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: 844))
        defer { window.isHidden = true }
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        body.layoutIfNeeded()
        let collectionView = timelineFirstView(ofType: UICollectionView.self, in: body)
        collectionView?.layoutIfNeeded()
        var waited = 0
        while body.debugIsSourcePreparationPendingForTesting, waited < 3000 {
            try await Task.sleep(for: .milliseconds(5))
            waited += 5
        }
        body.layoutIfNeeded()
        collectionView?.layoutIfNeeded()
        CATransaction.flush()
        let value = Self.ms(Self.now() - start)
        print("METRIC table_reader_grid_200x8_ms=\(Self.fmt(value))")
        #expect(value < 300, "a 200x8 wrap grid should open in the reader in under 0.3 s")
    }
}
