import Testing
import UIKit
@testable import Oppi

/// Wrap-grid tables draw as one view, and a streamed table grows by rows.
@Suite("MarkdownTableGrid")
@MainActor
struct MarkdownTableGridTests {
    // MARK: - Fixtures

    /// What UIKit hands `hitTest` for a finger on the screen.
    private final class TouchEvent: UIEvent {
        override var type: UIEvent.EventType { .touches }
    }

    private static let headers: [[MarkdownInline]] = [[.text("Name")], [.text("Value")], [.text("Notes")]]

    /// The Notes column is past the readable clamp, so the table wraps.
    private static func gridRows(_ count: Int) -> [[[MarkdownInline]]] {
        (0 ..< count).map { row in
            [
                [.text("r\(row)")],
                [.text("v\(row)")],
                [.text("Long explanatory note for row \(row) that keeps going past the readable clamp so it wraps")],
            ]
        }
    }

    private static let clipHeaders: [[MarkdownInline]] = [[.text("Name")], [.text("Value")], [.text("Note")]]

    private static func clipRows(_ count: Int) -> [[[MarkdownInline]]] {
        (0 ..< count).map { row in
            [[.text("item-\(row)")], [.text("value \(row).1 ok")], [.text("note \(row)")]]
        }
    }

    private static func mount(
        headers: [[MarkdownInline]],
        rows: [[[MarkdownInline]]],
        selection: Bool = false,
        palette: ThemePalette = ThemeRuntimeState.currentPalette()
    ) -> (table: NativeTableBlockView, window: UIWindow) {
        let table = NativeTableBlockView()
        if selection {
            table.configureReviewCommentSelection(
                router: ReviewCommentSelectionRouter { _ in },
                sourceContext: .init(sessionId: "session-1", surface: .assistantProse)
            )
        }
        table.configureResourceReferenceScope(serverID: "server-1", workspaceID: "workspace-1")
        table.apply(headers: headers, rows: rows, palette: palette)
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 370, height: 900))
        window.addSubview(table)
        window.makeKeyAndVisible()
        table.frame = CGRect(x: 0, y: 0, width: 370, height: table.debugMeasuredHeightForTesting)
        table.layoutIfNeeded()
        return (table, window)
    }

    private static func gridLayout(_ table: NativeTableBlockView) throws -> MarkdownTableGridLayout {
        try #require(table.debugGridViewForTesting.layout)
    }

    /// The grid drawn through its renderer, one pixel per point.
    private static func render(_ grid: MarkdownTableGridView, clip: CGRect? = nil) throws -> RenderedPixels {
        let layout = try #require(grid.layout)
        let size = CGSize(width: ceil(layout.contentWidth), height: ceil(layout.contentHeight))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            if let clip { context.cgContext.clip(to: clip) }
            grid.renderer.draw(CALayer(), in: context.cgContext)
        }
        return try RenderedPixels(image)
    }

    private struct RenderedPixels: Equatable {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(_ image: UIImage) throws {
            let cgImage = try #require(image.cgImage)
            let pixelWidth = cgImage.width
            let pixelHeight = cgImage.height
            var buffer = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
            let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress,
                    width: pixelWidth,
                    height: pixelHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: pixelWidth * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
                return true
            }
            #expect(drawn)
            width = pixelWidth
            height = pixelHeight
            bytes = buffer
        }

        private static func standsOut(_ pixel: [UInt8], from background: [UInt8]) -> Bool {
            zip(pixel, background).contains { abs(Int($0) - Int($1)) > 48 }
        }

        /// The box around the pixels in `rect` (top-left origin) that stand out
        /// from the rect's dominant color (its background), relative to `rect`'s
        /// origin. A pixel counts as ink when a channel is more than 48 off, so
        /// the blended edge of a row that sits between pixels is not text.
        func inkBounds(in rect: CGRect) -> CGRect {
            let minX = max(0, Int(rect.minX)), maxX = min(width, Int(rect.maxX))
            let minY = max(0, Int(rect.minY)), maxY = min(height, Int(rect.maxY))
            func pixel(_ x: Int, _ y: Int) -> [UInt8] {
                let offset = (y * width + x) * 4
                return Array(bytes[offset ..< offset + 4])
            }
            var counts: [[UInt8]: Int] = [:]
            for y in minY ..< maxY {
                for x in minX ..< maxX { counts[pixel(x, y), default: 0] += 1 }
            }
            guard let background = counts.max(by: { $0.value < $1.value })?.key else { return .null }
            var box: CGRect?
            for y in minY ..< maxY {
                for x in minX ..< maxX where Self.standsOut(pixel(x, y), from: background) {
                    let point = CGRect(x: x - minX, y: y - minY, width: 1, height: 1)
                    box = box.map { $0.union(point) } ?? point
                }
            }
            return box ?? .null
        }

        /// Whether every pixel in `rect` (top-left origin) is the same color.
        func isUniform(_ rect: CGRect) -> Bool {
            let minX = max(0, Int(rect.minX)), maxX = min(width, Int(rect.maxX))
            let minY = max(0, Int(rect.minY)), maxY = min(height, Int(rect.maxY))
            guard minX < maxX, minY < maxY else { return true }
            let first = Array(bytes[(minY * width + minX) * 4 ..< (minY * width + minX) * 4 + 4])
            for y in minY ..< maxY {
                for x in minX ..< maxX {
                    let offset = (y * width + x) * 4
                    if Array(bytes[offset ..< offset + 4]) != first { return false }
                }
            }
            return true
        }
    }

    private static func sameLayout(_ lhs: MarkdownTableGridLayout, _ rhs: MarkdownTableGridLayout) -> Bool {
        lhs.columnWidths == rhs.columnWidths
            && lhs.columnOrigins == rhs.columnOrigins
            && lhs.rowHeights == rhs.rowHeights
            && lhs.rowOrigins == rhs.rowOrigins
            && lhs.contentHeight == rhs.contentHeight
            && lhs.cells.count == rhs.cells.count
            && zip(lhs.cells, rhs.cells).allSatisfy { left, right in
                left.count == right.count && zip(left, right).allSatisfy { $0.isEqual(to: $1) }
            }
    }

    /// Where two attributed strings first differ, for a failure message.
    private static func firstDifference(_ lhs: NSAttributedString, _ rhs: NSAttributedString) -> String {
        guard lhs.length == rhs.length else { return "length \(lhs.length) vs \(rhs.length)" }
        for index in 0 ..< lhs.length {
            let left = lhs.attributes(at: index, effectiveRange: nil)
            let right = rhs.attributes(at: index, effectiveRange: nil)
            if !NSDictionary(dictionary: left).isEqual(to: right) {
                let keys = Set(left.keys).union(right.keys).filter { key in
                    !(left[key] as AnyObject).isEqual(right[key])
                }
                return "index \(index) attrs differ: \(keys.map(\.rawValue))"
            }
        }
        return "equal"
    }

    private static func textCellPoint(_ layout: MarkdownTableGridLayout, row: Int, column: Int) -> CGPoint {
        let frame = layout.cellFrame(row: row, column: column)
        return CGPoint(x: frame.minX + 6, y: frame.minY + MarkdownTableGridLayout.cellVerticalInset + 4)
    }

    /// The text view a touch at `point` lands in: the hit view or the text view
    /// that holds it (a laid-out text view hit-tests to its text's own view).
    private static func touchedTextView(_ grid: MarkdownTableGridView, at point: CGPoint) -> UITextView? {
        var view = grid.hitTest(point, with: TouchEvent())
        while let current = view, current !== grid {
            if let textView = current as? UITextView { return textView }
            view = current.superview
        }
        return nil
    }

    // MARK: - One view, not one text view per cell

    @Test func wrapGridIsDrawnWithoutCellTextViews() throws {
        let (table, window) = Self.mount(headers: Self.headers, rows: Self.gridRows(30))
        defer { window.isHidden = true }

        let layout = try Self.gridLayout(table)
        #expect(layout.cells.count == 31, "header plus 30 body rows")
        #expect(layout.columnWidths.count == 3)
        #expect(timelineAllTextViews(in: table).filter { !$0.isHidden }.isEmpty)
        // Counted inside the grid: the card's overflow cue and fold bar are not cells.
        #expect(timelineAllViews(in: table.debugGridViewForTesting).count < 20, "a 93-cell grid should not mount a view per cell")
        #expect(!table.debugGridViewForTesting.isInteractive)

        // Wrapped notes make rows taller than a single line.
        let noteHeight = layout.rowHeights[1]
        let nameCell = layout.cells[1][0]
        #expect(noteHeight > ceil(nameCell.size().height) + 2 * MarkdownTableGridLayout.cellVerticalInset)
        // Every row is at least as tall as the cells it holds.
        #expect(layout.rowOrigins[2] >= layout.rowOrigins[1] + layout.rowHeights[1])
    }

    @Test func drawnGridPaintsCellText() throws {
        let (table, window) = Self.mount(headers: Self.headers, rows: Self.gridRows(6))
        defer { window.isHidden = true }
        let layout = try Self.gridLayout(table)
        let pixels = try Self.render(table.debugGridViewForTesting)

        for row in 0 ..< layout.cells.count {
            let frame = layout.cellFrame(row: row, column: 0)
            let textArea = frame.insetBy(dx: 0, dy: MarkdownTableGridLayout.cellVerticalInset)
            #expect(!pixels.isUniform(textArea), "row \(row) first cell should show text")
        }
    }

    @Test func rowHeightsMatchWhatATextViewPerCellWouldMeasure() throws {
        let (table, window) = Self.mount(headers: Self.headers, rows: Self.gridRows(8))
        defer { window.isHidden = true }
        let layout = try Self.gridLayout(table)

        for row in layout.cells.indices {
            var tallest: CGFloat = 0
            for column in layout.columnWidths.indices {
                let textView = UITextView()
                textView.isScrollEnabled = false
                textView.textContainerInset = UIEdgeInsets(
                    top: MarkdownTableGridLayout.cellVerticalInset,
                    left: 0,
                    bottom: MarkdownTableGridLayout.cellVerticalInset,
                    right: 0
                )
                textView.textContainer.lineFragmentPadding = 0
                textView.attributedText = layout.cells[row][column]
                let fitted = textView.sizeThatFits(CGSize(width: layout.columnWidths[column], height: CGFloat.greatestFiniteMagnitude))
                tallest = max(tallest, fitted.height)
            }
            #expect(
                abs(layout.rowHeights[row] - tallest) <= 1.5,
                "row \(row): drawn height \(layout.rowHeights[row]) vs text view \(tallest)"
            )
        }
    }

    // MARK: - Touches mount one text view

    @Test func touchedCellMountsOneSelectableTextViewOverIt() throws {
        let (table, window) = Self.mount(headers: Self.headers, rows: Self.gridRows(10), selection: true)
        defer { window.isHidden = true }
        let grid = table.debugGridViewForTesting
        let layout = try Self.gridLayout(table)
        #expect(grid.isInteractive)
        #expect(grid.subviews.compactMap { $0 as? UITextView }.isEmpty)

        let hit = try #require(Self.touchedTextView(grid, at: Self.textCellPoint(layout, row: 3, column: 2)))
        #expect(hit.isSelectable)
        #expect(hit.delegate === table)
        #expect(hit.frame == layout.cellFrame(row: 3, column: 2))
        #expect(hit.attributedText.isEqual(to: layout.cells[3][2]))
        #expect(grid.activeCell?.row == 3 && grid.activeCell?.column == 2)

        // Another cell takes the text view; the first draws itself again.
        let second = try #require(Self.touchedTextView(grid, at: Self.textCellPoint(layout, row: 5, column: 0)))
        #expect(second !== hit)
        #expect(hit.superview == nil)
        #expect(grid.subviews.compactMap { $0 as? UITextView }.count == 1)
        #expect(second.attributedText.isEqual(to: layout.cells[5][0]))
    }

    @Test func mountedTextViewCoversTheDrawnCellWithTheColorTheGridShowsThere() throws {
        let (table, window) = Self.mount(headers: Self.headers, rows: Self.gridRows(6), selection: true)
        defer { window.isHidden = true }
        let grid = table.debugGridViewForTesting
        let layout = try Self.gridLayout(table)
        let before = try Self.render(grid)

        // Header, a striped row and a plain row: each cover matches the grid's
        // fill composited over the card behind it.
        let card = ThemeRuntimeState.currentPalette().ui.bgDark.resolvedColor(with: table.traitCollection)
        for (row, fill) in [(0, layout.style.headerBackground), (1, nil), (2, layout.style.zebraBackground)] {
            grid.activateCell(row: row, column: 2)
            let cover = try #require(grid.activeTextView?.backgroundColor)
            var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, ca: CGFloat = 0
            #expect(cover.getRed(&cr, green: &cg, blue: &cb, alpha: &ca))
            #expect(ca == 1, "row \(row): a translucent cover would show the drawn text through it")

            var expected: [CGFloat] = [0, 0, 0]
            var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
            card.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
            let base = [br, bg, bb]
            if let fill {
                var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
                fill.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
                expected = [fr * fa + base[0] * (1 - fa), fg * fa + base[1] * (1 - fa), fb * fa + base[2] * (1 - fa)]
            } else {
                expected = base
            }
            #expect(
                zip([cr, cg, cb], expected).allSatisfy { abs($0 - $1) < 0.01 },
                "row \(row): cover \([cr, cg, cb]) vs grid over card \(expected)"
            )
        }

        // The drawn layer is the same picture throughout.
        #expect(try Self.render(grid) == before)
        grid.deactivateCell()
        #expect(try Self.render(grid) == before)
    }

    @Test func textViewIsOnlyMountedWhenTheGridTakesTouches() throws {
        let (table, window) = Self.mount(headers: Self.headers, rows: Self.gridRows(4))
        defer { window.isHidden = true }
        let grid = table.debugGridViewForTesting
        let layout = try Self.gridLayout(table)

        let hit = grid.hitTest(Self.textCellPoint(layout, row: 1, column: 2), with: TouchEvent())
        #expect(hit === grid, "no links and no review selection: the table copies on long press instead")
        #expect(grid.activeTextView == nil)
    }

    @Test func linkCellsMountATextViewThatCarriesTheLink() throws {
        let link: [MarkdownInline] = [.link(children: [.text("docs")], destination: "https://example.com/docs")]
        let rows: [[[MarkdownInline]]] = [[
            link,
            [.text(String(repeating: "wrap-column-notes-", count: 20))],
        ]]
        let (table, window) = Self.mount(headers: [[.text("Link")], [.text("Notes")]], rows: rows)
        defer { window.isHidden = true }
        let grid = table.debugGridViewForTesting
        let layout = try Self.gridLayout(table)
        #expect(grid.isInteractive)

        let textView = try #require(Self.touchedTextView(grid, at: Self.textCellPoint(layout, row: 1, column: 0)))
        #expect(textView.isSelectable)
        let range = (textView.attributedText.string as NSString).range(of: "docs")
        let url = try #require(textView.attributedText.attribute(.link, at: range.location, effectiveRange: nil) as? URL)
        #expect(url.absoluteString == "https://example.com/docs")
        #expect(!textView.isScrollEnabled)
        #expect(textView.gestureRecognizerShouldBegin(textView.panGestureRecognizer) == false)
    }

    @Test func drawnLinkTakesTheThemeLinkColorLikeTheTextViewOverIt() throws {
        let link: [MarkdownInline] = [.link(children: [.text("docs page")], destination: "https://example.com/docs")]
        let rows: [[[MarkdownInline]]] = [[
            link,
            [.text(String(repeating: "wrap-column-notes-", count: 20))],
        ]]
        let (table, window) = Self.mount(headers: [[.text("Link")], [.text("Notes")]], rows: rows)
        defer { window.isHidden = true }
        let grid = table.debugGridViewForTesting
        let layout = try Self.gridLayout(table)
        let pixels = try Self.render(grid)

        // The underline is a solid run of the link color: the pixel farthest
        // from the transparent background in the link's cell is that color.
        let frame = layout.cellFrame(row: 1, column: 0)
        var strongest: [UInt8] = [0, 0, 0, 0]
        for y in Int(frame.minY) ..< Int(frame.maxY) {
            for x in Int(frame.minX) ..< Int(frame.maxX) {
                let offset = (y * pixels.width + x) * 4
                let pixel = Array(pixels.bytes[offset ..< offset + 4])
                if pixel[3] > strongest[3] { strongest = pixel }
            }
        }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        layout.style.link.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let expected = [red, green, blue].map { Int(($0 * 255).rounded()) }
        let drawn = strongest.prefix(3).map(Int.init)
        #expect(
            zip(expected, drawn).allSatisfy { abs($0 - $1) <= 6 },
            "drawn link \(drawn) vs theme link \(expected)"
        )
    }

    // MARK: - A touch does not redraw the grid

    /// A scroll view that reports a scroll in progress, as UIKit does between
    /// a drag's start and the end of its deceleration.
    private final class ScrollingScrollView: UIScrollView {
        var scrolling = false
        override var isDragging: Bool { scrolling }
    }

    private static func contentLayer(_ grid: MarkdownTableGridView) throws -> CALayer {
        try #require(grid.layer.sublayers?.first { $0.delegate === grid.renderer })
    }

    /// Lets the layer tree commit and tiles finish drawing.
    private static func settle(_ layer: CALayer) {
        for _ in 0 ..< 5 {
            layer.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    @Test(arguments: [6, 300])
    func theGridLayerNeverCrossFadesItsContents(rowCount: Int) throws {
        let (table, window) = Self.mount(headers: Self.headers, rows: Self.gridRows(rowCount))
        defer { window.isHidden = true }
        let grid = table.debugGridViewForTesting
        let layer = try Self.contentLayer(grid)

        // A standalone layer fades a changed `contents` in over 0.25s unless its
        // delegate answers the action lookup with NSNull. (`CALayer.action(forKey:)`
        // reports that as nil, and a test window is never committed, so the
        // delegate's answer is what can be observed.)
        #expect(layer.delegate === grid.renderer)
        #expect(grid.renderer.action(for: layer, forKey: "contents") is NSNull)
    }

    @Test(arguments: [6, 300])
    func touchingACellDoesNotInvalidateTheDrawnGrid(rowCount: Int) throws {
        let (table, window) = Self.mount(headers: Self.headers, rows: Self.gridRows(rowCount), selection: true)
        defer { window.isHidden = true }
        let grid = table.debugGridViewForTesting
        let layout = try Self.gridLayout(table)
        let layer = try Self.contentLayer(grid)
        #expect(grid.isTiled == (rowCount == 300))
        Self.settle(layer)
        #expect(!layer.needsDisplay(), "grid should be drawn before the touch")

        // Redrawing even one tile blanks a 512pt band until it comes back.
        grid.activateCell(row: 2, column: 2)
        #expect(grid.activeCell?.row == 2)
        #expect(!layer.needsDisplay(), "activating a cell invalidated the drawn grid")

        grid.activateCell(row: 3, column: 0)
        grid.deactivateCell()
        #expect(grid.activeCell == nil)
        #expect(!layer.needsDisplay(), "leaving a cell invalidated the drawn grid")
        _ = layout
    }

    @Test func aTouchThatStopsOrStartsAScrollDoesNotMountACell() throws {
        let scroller = ScrollingScrollView(frame: CGRect(x: 0, y: 0, width: 370, height: 900))
        let (table, tableWindow) = Self.mount(headers: Self.headers, rows: Self.gridRows(10), selection: true)
        tableWindow.isHidden = true
        let window = makeTestWindow(frame: scroller.frame)
        window.addSubview(scroller)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        scroller.addSubview(table)
        table.frame = CGRect(x: 0, y: 0, width: 370, height: table.debugMeasuredHeightForTesting)
        table.layoutIfNeeded()
        let grid = table.debugGridViewForTesting
        let layout = try Self.gridLayout(table)
        let point = Self.textCellPoint(layout, row: 2, column: 2)

        scroller.scrolling = true
        _ = grid.hitTest(point, with: TouchEvent())
        #expect(grid.activeTextView == nil, "a touch during a scroll mounted a cell")

        scroller.scrolling = false
        _ = grid.hitTest(point, with: TouchEvent())
        #expect(grid.activeCell?.row == 2 && grid.activeCell?.column == 2)
    }

    @Test func hitTestsThatAreNotTouchesDoNotMountACell() throws {
        let (table, window) = Self.mount(headers: Self.headers, rows: Self.gridRows(6), selection: true)
        defer { window.isHidden = true }
        let grid = table.debugGridViewForTesting
        let layout = try Self.gridLayout(table)

        // UIKit hit-tests with no event to find views for accessibility and menus.
        _ = grid.hitTest(Self.textCellPoint(layout, row: 2, column: 2), with: nil)
        #expect(grid.activeTextView == nil)
    }

    /// The text view mounted on a cell lays its text out where the grid drew it,
    /// so a tap swaps one for the other without the text moving.
    @Test func mountedCellTextSitsWhereTheGridDrewIt() throws {
        let (table, window) = Self.mount(headers: Self.headers, rows: Self.gridRows(6), selection: true)
        defer { window.isHidden = true }
        let grid = table.debugGridViewForTesting
        let layout = try Self.gridLayout(table)

        for (row, column) in [(0, 0), (2, 2), (3, 2), (4, 0)] {
            let frame = layout.cellFrame(row: row, column: column)
            let drawn = try Self.render(grid)
            grid.activateCell(row: row, column: column)
            let textView = try #require(grid.activeTextView)
            #expect(textView.frame == frame)

            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let mountedImage = UIGraphicsImageRenderer(size: frame.size, format: format).image { _ in
                textView.drawHierarchy(in: CGRect(origin: .zero, size: frame.size), afterScreenUpdates: true)
            }
            let mounted = try RenderedPixels(mountedImage)
            let drawnInk = drawn.inkBounds(in: frame)
            let mountedInk = mounted.inkBounds(in: CGRect(origin: .zero, size: frame.size))
            let label = "row \(row) column \(column): drawn \(drawnInk) mounted \(mountedInk)"
            #expect(abs(drawnInk.minX - mountedInk.minX) <= 1 && abs(drawnInk.maxX - mountedInk.maxX) <= 1, "\(label)")
            #expect(abs(drawnInk.minY - mountedInk.minY) <= 1 && abs(drawnInk.maxY - mountedInk.maxY) <= 1, "\(label)")
        }
    }

    // MARK: - VoiceOver

    @Test func voiceOverReadsTheGridAsADataTableWithColumnHeaders() throws {
        let (table, window) = Self.mount(headers: Self.headers, rows: Self.gridRows(5))
        defer { window.isHidden = true }
        let grid = table.debugGridViewForTesting
        let layout = try Self.gridLayout(table)

        #expect(!grid.isAccessibilityElement)
        #expect(grid.accessibilityContainerType == .dataTable)
        #expect(grid.accessibilityRowCount() == 6)
        #expect(grid.accessibilityColumnCount() == 3)
        let elements = try #require(grid.accessibilityElements as? [UIAccessibilityElement])
        #expect(elements.count == 18)

        let value = try #require(grid.accessibilityDataTableCellElement(forRow: 2, column: 1) as? UIAccessibilityElement)
        #expect(value.accessibilityLabel == "v1")
        #expect(value.accessibilityFrameInContainerSpace == layout.cellFrame(row: 2, column: 1))
        let cell = try #require(grid.accessibilityDataTableCellElement(forRow: 2, column: 1))
        #expect(cell.accessibilityRowRange() == NSRange(location: 2, length: 1))
        #expect(cell.accessibilityColumnRange() == NSRange(location: 1, length: 1))

        // Through the protocol, as VoiceOver asks: a near-miss signature is never called.
        let dataTable: any UIAccessibilityContainerDataTable = grid
        let header = try #require(dataTable.accessibilityHeaderElements?(forColumn: 1)?.first as? UIAccessibilityElement)
        #expect(header.accessibilityLabel == "Value")
        #expect(header.accessibilityTraits.contains(.header))
        #expect(!value.accessibilityTraits.contains(.header))
        #expect(grid.accessibilityDataTableCellElement(forRow: 6, column: 0) == nil)
    }

    @Test func voiceOverActivatesALinkCellThroughTheOpener() throws {
        let link: [MarkdownInline] = [.link(children: [.text("docs")], destination: "https://example.com/docs")]
        let rows: [[[MarkdownInline]]] = [[
            link,
            [.text(String(repeating: "wrap-column-notes-", count: 20))],
        ]]
        let (table, tableWindow) = Self.mount(headers: [[.text("Link")], [.text("Notes")]], rows: rows)
        tableWindow.isHidden = true
        let (root, recorder) = makeRecordingAppRoot()
        let window = makeAppRootWindow(root)
        defer { window.isHidden = true }
        window.addSubview(table)

        let grid = table.debugGridViewForTesting
        let element = try #require(grid.accessibilityDataTableCellElement(forRow: 1, column: 0) as? UIAccessibilityElement)
        #expect(element.accessibilityTraits.contains(.link))
        #expect(element.accessibilityActivate())
        let url = try #require(URL(string: "https://example.com/docs"))
        #expect(recorder.requests == [.webLink(url)])
    }

    // MARK: - Large grids tile

    @Test func largeGridsDrawIntoTilesThatRenderOnlyTheirRows() throws {
        let (small, smallWindow) = Self.mount(headers: Self.headers, rows: Self.gridRows(6))
        defer { smallWindow.isHidden = true }
        #expect(!small.debugGridViewForTesting.isTiled)

        let (large, largeWindow) = Self.mount(headers: Self.headers, rows: Self.gridRows(300))
        defer { largeWindow.isHidden = true }
        let grid = large.debugGridViewForTesting
        let layout = try Self.gridLayout(large)
        #expect(grid.isTiled)

        // A tile far down the table still draws the rows that sit there.
        let row = 250
        let frame = layout.cellFrame(row: row, column: 2)
        let tile = CGRect(x: 0, y: frame.minY - 20, width: layout.contentWidth, height: frame.height + 40)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: tile.size, format: format).image { context in
            context.cgContext.translateBy(x: -tile.minX, y: -tile.minY)
            context.cgContext.clip(to: tile)
            grid.renderer.draw(CALayer(), in: context.cgContext)
        }
        let pixels = try RenderedPixels(image)
        let textArea = CGRect(x: frame.minX, y: 20 + MarkdownTableGridLayout.cellVerticalInset, width: frame.width, height: frame.height - 2 * MarkdownTableGridLayout.cellVerticalInset)
        #expect(!pixels.isUniform(textArea))
    }

    // MARK: - Streaming grows by rows

    @Test func streamedGridMatchesTheSettledRenderAndKeepsEarlierRows() throws {
        let rows = Self.gridRows(40)
        let table = NativeTableBlockView()
        let palette = ThemeRuntimeState.currentPalette()
        var previousCells: [NSAttributedString] = []
        for count in 1 ... rows.count {
            table.apply(headers: Self.headers, rows: Array(rows.prefix(count)), palette: palette)
            let layout = try Self.gridLayout(table)
            if count > 1 {
                // Rows that did not change are the same objects: they were not built again.
                for (index, kept) in previousCells.enumerated() {
                    #expect(layout.cells[index + 1][0] === kept, "row \(index) rebuilt at \(count) rows")
                }
            }
            previousCells = layout.cells.dropFirst().map { $0[0] }
        }
        #expect(table.debugRenderCountForTesting == rows.count)

        let settled = NativeTableBlockView()
        settled.apply(headers: Self.headers, rows: rows, palette: palette)
        let streamedLayout = try Self.gridLayout(table)
        let settledLayout = try Self.gridLayout(settled)
        #expect(Self.sameLayout(streamedLayout, settledLayout))
        #expect(table.debugMeasuredHeightForTesting == settled.debugMeasuredHeightForTesting)

        for view in [table, settled] {
            let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 370, height: 900))
            window.addSubview(view)
            view.frame = CGRect(x: 0, y: 0, width: 370, height: view.debugMeasuredHeightForTesting)
            view.layoutIfNeeded()
            window.isHidden = true
        }
        #expect(try Self.render(table.debugGridViewForTesting) == Self.render(settled.debugGridViewForTesting))
    }

    @Test func streamedGridRebuildsWhenAColumnWidens() throws {
        var rows = Self.gridRows(6)
        let table = NativeTableBlockView()
        let palette = ThemeRuntimeState.currentPalette()
        table.apply(headers: Self.headers, rows: rows, palette: palette)
        // A longer value widens the Value column: every row's cell width changes.
        rows.append([[.text("r6")], [.text("a much longer value")], [.text("note")]])
        table.apply(headers: Self.headers, rows: rows, palette: palette)

        let settled = NativeTableBlockView()
        settled.apply(headers: Self.headers, rows: rows, palette: palette)
        #expect(Self.sameLayout(try Self.gridLayout(table), try Self.gridLayout(settled)))
    }

    @Test func streamedClipTableMatchesTheSettledRender() throws {
        let rows = Self.clipRows(60)
        let table = NativeTableBlockView()
        let palette = ThemeRuntimeState.currentPalette()
        for count in 1 ... rows.count {
            table.apply(headers: Self.clipHeaders, rows: Array(rows.prefix(count)), palette: palette)
        }
        #expect(table.debugRenderCountForTesting == rows.count)

        let settled = NativeTableBlockView()
        settled.apply(headers: Self.clipHeaders, rows: rows, palette: palette)
        let streamedText = try #require(table.debugClipTextForTesting)
        let settledText = try #require(settled.debugClipTextForTesting)
        #expect(streamedText.string == settledText.string)
        #expect(streamedText.isEqual(to: settledText), "\(Self.firstDifference(streamedText, settledText))")
        #expect(table.debugMeasuredHeightForTesting == settled.debugMeasuredHeightForTesting)
    }

    @Test func streamedClipTableRebuildsWhenAColumnWidens() throws {
        var rows = Self.clipRows(5)
        let table = NativeTableBlockView()
        let palette = ThemeRuntimeState.currentPalette()
        table.apply(headers: Self.clipHeaders, rows: rows, palette: palette)
        rows.append([[.text("item-5")], [.text("a longer value than before")], [.text("note 5")]])
        table.apply(headers: Self.clipHeaders, rows: rows, palette: palette)

        let settled = NativeTableBlockView()
        settled.apply(headers: Self.clipHeaders, rows: rows, palette: palette)
        let streamedText = try #require(table.debugClipTextForTesting)
        #expect(streamedText.isEqual(to: try #require(settled.debugClipTextForTesting)))
    }

    @Test func clipTableTextViewStaysSelectableLinkedAndSpoken() throws {
        let link: [MarkdownInline] = [.link(children: [.text("docs")], destination: "https://example.com/docs")]
        let (table, window) = Self.mount(
            headers: [[.text("Name")], [.text("Link")]],
            rows: [[[.text("one")], link]],
            selection: true
        )
        defer { window.isHidden = true }
        let textView = try #require(timelineAllTextViews(in: table).first { !$0.isHidden })

        // Grows by appending rows, which needs TextKit 1's incremental layout.
        #expect(textView.textLayoutManager == nil)
        #expect(textView.isSelectable)
        // Speaks as it did on TextKit 2.
        let reference = BaselineSafeTextView(usingTextLayoutManager: true)
        reference.isScrollEnabled = false
        reference.isEditable = false
        reference.attributedText = textView.attributedText
        #expect(textView.isAccessibilityElement == reference.isAccessibilityElement)
        #expect(textView.accessibilityLabel == reference.accessibilityLabel)
        #expect(textView.accessibilityValue == reference.accessibilityValue)
        #expect(textView.attributedText.string.contains("one"))
        let range = (textView.attributedText.string as NSString).range(of: "docs")
        #expect(textView.attributedText.attribute(.link, at: range.location, effectiveRange: nil) is URL)

        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: range.location, length: 4),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))
        #expect((menu.children.first as? UIAction)?.title == "Comment")

        // The text a copy of the whole selection yields is the table text.
        textView.selectedRange = NSRange(location: 0, length: textView.attributedText.length)
        let selected = (textView.attributedText.string as NSString).substring(with: textView.selectedRange)
        #expect(selected.contains("one") && selected.contains("docs"))
    }

    @Test func clipHeightMatchesATextViewLayingOutTheSameText() throws {
        let rows = Self.clipRows(25)
        let (table, window) = Self.mount(headers: Self.clipHeaders, rows: rows)
        defer { window.isHidden = true }
        let text = try #require(table.debugClipTextForTesting)

        // The clip label is TextKit 1 (it grows by rows); a TextKit 2 view adds
        // the body font's leading to every line and would not match it.
        let textView = UITextView(usingTextLayoutManager: false)
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.attributedText = text
        let fitted = textView.sizeThatFits(CGSize(width: 2_000, height: CGFloat.greatestFiniteMagnitude))
        #expect(abs(fitted.height - table.debugMeasuredHeightForTesting) <= 1.5)
    }
}
