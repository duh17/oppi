import Testing
import UIKit
@testable import Oppi

@Suite("Table viewer grid")
@MainActor
struct TableViewerTests {
    private let palette = ThemeRuntimeState.currentPalette()

    // MARK: Grid viewer

    private func makeGrid(rows: Int) throws -> (view: DelimitedTableRenderView, grid: UICollectionView, window: UIWindow) {
        let csv = "alpha,beta,gamma\n" + (1 ... rows).map { "r\($0),v\($0),w\($0)" }.joined(separator: "\n")
        let plan = try #require(DelimitedTableViewerPlan.opening(path: "t.csv", text: csv))
        let view = DelimitedTableRenderView(plan: plan, palette: palette)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        view.frame = window.bounds
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.layoutIfNeeded()
        let grid = try #require(timelineAllViews(in: view).compactMap { $0 as? UICollectionView }.first)
        grid.layoutIfNeeded()
        return (view, grid, window)
    }

    @Test func headerStaysPinnedWhileRowsScrollAndOnlyVisibleCellsExist() throws {
        let (_, grid, window) = try makeGrid(rows: 400)
        defer { window.isHidden = true }

        grid.contentOffset = CGPoint(x: 0, y: 3000)
        grid.layoutIfNeeded()

        let header = try #require(grid.cellForItem(at: IndexPath(item: 1, section: 0)))
        #expect(abs(header.frame.minY - (grid.contentOffset.y + grid.adjustedContentInset.top)) < 0.5)
        #expect(header.layer.zPosition >= 0)
        #expect(grid.visibleCells.count < 150, "A 401-row, 3-column table (1,203 cells) must mount only what is in view (\(grid.visibleCells.count))")

        // Far down the table: the rows in view are mounted, and so is the header.
        let labels = grid.visibleCells.compactMap(\.accessibilityLabel)
        let rowNumbers = labels.compactMap { label -> Int? in
            guard let range = label.range(of: ", row ") else { return nil }
            return Int(label[range.upperBound...].prefix { $0.isNumber })
        }
        #expect((rowNumbers.min() ?? 0) > 50, "Scrolled to y=3000, got rows \(rowNumbers.min() ?? 0)...")
        #expect(labels.contains("alpha"), "The header must stay mounted over the rows")
    }

    @Test func headerCellsAreHeadersForVoiceOverAndBodyCellsNameTheirColumnAndRow() throws {
        let (_, grid, window) = try makeGrid(rows: 5)
        defer { window.isHidden = true }

        let header = try #require(grid.cellForItem(at: IndexPath(item: 0, section: 0)))
        #expect(header.accessibilityTraits.contains(.header))
        #expect(header.accessibilityLabel == "alpha")
        let body = try #require(grid.cellForItem(at: IndexPath(item: 4, section: 0)))
        #expect(body.accessibilityLabel == "beta, row 1, v1")
    }

    @Test func viewerCopiesTheDisplayedTableAsTSVAndMarkdown() throws {
        let (view, _, window) = try makeGrid(rows: 2)
        defer { window.isHidden = true }

        #expect(view.copyText(.tsv) == "alpha\tbeta\tgamma\nr1\tv1\tw1\nr2\tv2\tw2")
        #expect(view.copyText(.markdown) == "| alpha | beta | gamma |\n| --- | --- | --- |\n| r1 | v1 | w1 |\n| r2 | v2 | w2 |")
    }
}
