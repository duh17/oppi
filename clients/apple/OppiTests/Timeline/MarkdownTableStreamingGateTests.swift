import Testing
import UIKit
@testable import Oppi

/// A streamed table shows a row once its line has ended, and settles to the
/// same render a non-streamed message gets.
@Suite("MarkdownTableStreamingGate")
@MainActor
struct MarkdownTableStreamingGateTests {
    private static let headers: [[MarkdownInline]] = [[.text("Name")], [.text("Value")], [.text("Notes")]]
    private static let clipHeaders: [[MarkdownInline]] = [[.text("Name")], [.text("Value")], [.text("Note")]]

    private static func gridRows(_ count: Int) -> [[[MarkdownInline]]] {
        (0 ..< count).map { row in
            [
                [.text("r\(row)")],
                [.text("v\(row)")],
                [.text("Long explanatory note for row \(row) that keeps going past the readable clamp so it wraps")],
            ]
        }
    }

    private static func clipRows(_ count: Int) -> [[[MarkdownInline]]] {
        (0 ..< count).map { row in
            [[.text("item-\(row)")], [.text("value \(row).1 ok")], [.text("note \(row)")]]
        }
    }

    private static func gridLayout(_ table: NativeTableBlockView) throws -> MarkdownTableGridLayout {
        try #require(table.debugGridViewForTesting.layout)
    }

    private static func sameLayout(_ lhs: MarkdownTableGridLayout, _ rhs: MarkdownTableGridLayout) -> Bool {
        lhs.columnWidths == rhs.columnWidths
            && lhs.rowHeights == rhs.rowHeights
            && lhs.rowOrigins == rhs.rowOrigins
            && lhs.cells.count == rhs.cells.count
            && zip(lhs.cells, rhs.cells).allSatisfy { left, right in
                left.count == right.count && zip(left, right).allSatisfy { $0.isEqual(to: $1) }
            }
    }

    @Test(arguments: [true, false])
    func streamingTableLaysOutOncePerFinishedRowAndSettlesLikeAFreshRender(wraps: Bool) throws {
        let headers = wraps ? Self.headers : Self.clipHeaders
        let rows = wraps ? Self.gridRows(12) : Self.clipRows(12)
        let source = markdownSource(headers: headers, rows: rows)

        let streaming = AssistantMarkdownContentView()
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 370, height: 1_200))
        streaming.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(streaming)
        NSLayoutConstraint.activate([
            streaming.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            streaming.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            streaming.topAnchor.constraint(equalTo: container.topAnchor),
        ])

        var tableView: NativeTableBlockView?
        var content = ""
        for character in source {
            content.append(character)
            streaming.apply(configuration: .make(content: content, isStreaming: true, themeID: .dark))
            tableView = tableView ?? timelineFirstView(ofType: NativeTableBlockView.self, in: streaming)
        }
        let live = try #require(tableView)
        let lastTickRenders = live.debugRenderCountForTesting
        // Header + delimiter, then one render per row whose line ended. The
        // source has no trailing newline, so the last row waits for the settle.
        #expect(lastTickRenders == rows.count, "renders \(lastTickRenders) for \(rows.count) rows")

        streaming.apply(configuration: .make(content: source, isStreaming: false, themeID: .dark))
        container.layoutIfNeeded()
        let settledLive = try #require(timelineFirstView(ofType: NativeTableBlockView.self, in: streaming))

        let fresh = AssistantMarkdownContentView()
        let freshContainer = UIView(frame: CGRect(x: 0, y: 0, width: 370, height: 1_200))
        fresh.translatesAutoresizingMaskIntoConstraints = false
        freshContainer.addSubview(fresh)
        NSLayoutConstraint.activate([
            fresh.leadingAnchor.constraint(equalTo: freshContainer.leadingAnchor),
            fresh.trailingAnchor.constraint(equalTo: freshContainer.trailingAnchor),
            fresh.topAnchor.constraint(equalTo: freshContainer.topAnchor),
        ])
        fresh.apply(configuration: .make(content: source, isStreaming: false, themeID: .dark))
        freshContainer.layoutIfNeeded()
        let freshTable = try #require(timelineFirstView(ofType: NativeTableBlockView.self, in: fresh))

        if wraps {
            #expect(Self.sameLayout(try Self.gridLayout(settledLive), try Self.gridLayout(freshTable)))
        } else {
            let liveText = try #require(settledLive.debugClipTextForTesting)
            let freshText = try #require(freshTable.debugClipTextForTesting)
            #expect(liveText.isEqual(to: freshText))
        }
        #expect(settledLive.debugMeasuredHeightForTesting == freshTable.debugMeasuredHeightForTesting)
        let rowCount = wraps
            ? try Self.gridLayout(settledLive).bodyRowCount
            : (settledLive.debugClipTextForTesting?.string.split(separator: "\n").count ?? 0) - 2
        #expect(rowCount == rows.count)
    }

    /// A lone `|` under a delimiter row may still become a row, so the table
    /// stays open while that line streams as text below it. When the row
    /// arrives with the next block, the table view gets it although a text
    /// segment, not the table, is the streaming tail.
    @Test func tableHeldOpenAboveTheStreamingTextGetsItsRow() throws {
        let view = AssistantMarkdownContentView()
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 370, height: 800))
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        let table = "Intro.\n\n| Case | Cost |\n| --- | --- |\n|"
        for content in [table, table + " A8 | $8.50 |\n\n- The bound holds"] {
            view.apply(configuration: .make(content: content, isStreaming: true, themeID: .dark))
            container.layoutIfNeeded()
        }
        let tableView = try #require(timelineFirstView(ofType: NativeTableBlockView.self, in: view))
        #expect(tableView.debugClipTextForTesting?.string.contains("A8") == true)
    }

    @Test func tailTableHidesItsRowUntilTheLineEnds() {
        let table: MarkdownBlock = .table(
            headers: [[.text("A")]],
            rows: [[[.text("1")]], [[.text("2")]]]
        )
        func rowCount(_ content: String) -> Int {
            let kept = AssistantMarkdownSegmentSource.droppingUnfinishedTableRow([table], content: content)
            guard case .table(_, let rows, _)? = kept.last else { return -1 }
            return rows.count
        }
        #expect(rowCount("| A |\n|---|\n| 1 |\n| 2") == 1)
        #expect(rowCount("| A |\n|---|\n| 1 |\n| 2 |") == 1)
        #expect(rowCount("| A |\n|---|\n| 1 |\n| 2 |\n") == 2)
        #expect(rowCount("| A |\n|---|\n| 1 |\n| 2 |\n  ") == 2)
        // Not at the tail: nothing to hold back.
        let paragraph: MarkdownBlock = .paragraph([.text("after")])
        #expect(AssistantMarkdownSegmentSource.droppingUnfinishedTableRow([table, paragraph], content: "x") == [table, paragraph])
    }

    /// The flush that ends a table's last rows can also start the paragraph after
    /// it. The table stops being the tail there and is frozen until the message
    /// settles, so it must take those rows in that same flush.
    @Test func rowsThatEndInTheFlushThatStartsTheNextBlockStillShow() throws {
        let markdown = AssistantMarkdownContentView()
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 370, height: 1_600))
        markdown.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(markdown)
        NSLayoutConstraint.activate([
            markdown.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            markdown.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            markdown.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        let headers: [[MarkdownInline]] = [[.text("Item")], [.text("State")]]
        func rows(_ count: Int) -> [[[MarkdownInline]]] {
            (1 ... count).map { [[.text("item-\($0)")], [.text("open")]] }
        }
        func stream(_ content: String) {
            markdown.apply(configuration: .make(content: content, isStreaming: true, themeID: .dark))
        }

        let upToRow23 = markdownSource(headers: headers, rows: rows(23)) + "\n"
        stream(upToRow23)
        let table = try #require(timelineFirstView(ofType: NativeTableBlockView.self, in: markdown))
        #expect(table.tableText(.tsv).split(separator: "\n").count == 24)

        // Rows 24 and 25 end, and the paragraph after the table starts, in one flush.
        stream(markdownSource(headers: headers, rows: rows(25)) + "\n\nThat is")
        container.layoutIfNeeded()
        #expect(timelineFirstView(ofType: NativeTableBlockView.self, in: markdown) === table)
        #expect(table.tableText(.tsv).split(separator: "\n").count == 26, "header plus 25 rows")
        let showAll = try #require(timelineAllViews(in: table).compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == "markdown.table.showAll"
        })
        #expect(showAll.accessibilityLabel == "Show 5 more rows")
    }

    private func markdownSource(headers: [[MarkdownInline]], rows: [[[MarkdownInline]]]) -> String {
        func line(_ cells: [[MarkdownInline]]) -> String {
            "| " + cells.map { plainText(from: $0) }.joined(separator: " | ") + " |"
        }
        var lines = [line(headers), "|" + String(repeating: "---|", count: headers.count)]
        lines.append(contentsOf: rows.map(line))
        return "Here is the table:\n\n" + lines.joined(separator: "\n")
    }
}
