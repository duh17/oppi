import Testing
import Foundation
import UIKit
@testable import Oppi

/// Settled configure cost of a message that holds one markdown table, in the
/// chat configuration (`.live`, long tables fold) and the reader configuration
/// (`.staticReader`, the whole table renders).
///
/// Each sample is what a self-sizing cell does after a configure: apply, fit at
/// the cell width, lay out, and commit. Every sample uses a fresh view and unique
/// content, so parse and render are both counted.
///
/// Output format: METRIC name=milliseconds (median of `samples`).
@Suite("TableLayoutPerfBench", .tags(.perf), .serialized)
@MainActor
struct TableLayoutPerfBench {
    private static let samples = 3
    private static let width: CGFloat = 390

    private enum Shape {
        /// Every cell fits the readable clamp.
        case clip
        /// The last column is prose, so the table is a wrapping grid.
        case grid
    }

    private struct Case {
        let rows: Int
        let columns: Int
        let shape: Shape
        let name: String
    }

    private static let cases: [Case] = [
        Case(rows: 6, columns: 3, shape: .grid, name: "6x3_grid"),
        Case(rows: 24, columns: 4, shape: .clip, name: "24x4_clip"),
        Case(rows: 24, columns: 4, shape: .grid, name: "24x4_grid"),
        Case(rows: 200, columns: 8, shape: .clip, name: "200x8_clip"),
        Case(rows: 1000, columns: 5, shape: .clip, name: "1000x5_clip"),
    ]

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

    private static func message(_ spec: Case, serial: Int) -> String {
        var lines = ["Comparison (\(spec.name) sample \(serial)):", ""]
        lines.append("| " + (0 ..< spec.columns).map { "Column \($0)" }.joined(separator: " | ") + " |")
        lines.append("|" + String(repeating: "---|", count: spec.columns))
        for row in 0 ..< spec.rows {
            lines.append(
                "| " + (0 ..< spec.columns)
                    .map { cell(row: row, column: $0, columns: spec.columns, shape: spec.shape) }
                    .joined(separator: " | ") + " |"
            )
        }
        lines.append("")
        lines.append("That covers every row.")
        return lines.joined(separator: "\n")
    }

    private static func settledMilliseconds(content: String, mode: ContentRenderingMode) -> Double {
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
        defer { window.isHidden = true }

        let start = DispatchTime.now().uptimeNanoseconds
        markdown.apply(configuration: .make(
            content: content,
            isStreaming: false,
            themeID: .dark,
            renderingMode: mode
        ))
        _ = markdown.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        window.layoutIfNeeded()
        CATransaction.flush()
        return Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e6
    }

    @Test func settledConfigure() {
        var serial = 0
        var medians: [String: Double] = [:]
        for spec in Self.cases {
            for (label, mode) in [("chat", ContentRenderingMode.live), ("reader", .staticReader)] {
                var timings: [Double] = []
                for _ in 0 ..< Self.samples {
                    serial += 1
                    autoreleasepool {
                        timings.append(Self.settledMilliseconds(
                            content: Self.message(spec, serial: serial),
                            mode: mode
                        ))
                    }
                }
                timings.sort()
                let median = timings[timings.count / 2]
                medians["\(label)_\(spec.name)"] = median
                print("METRIC table_settled_\(label)_\(spec.name)_ms=\(String(format: "%.1f", median))")
            }
        }

        // Chat folds a long table at 20 rows, so a 200-row or 1000-row table costs a
        // fraction of what the reader pays to render every row.
        for name in ["200x8_clip", "1000x5_clip"] {
            let chat = medians["chat_\(name)"] ?? .infinity
            let reader = medians["reader_\(name)"] ?? 0
            #expect(chat < reader / 2, "\(name): chat \(chat) ms should be well under reader \(reader) ms")
        }
    }
}
