import CoreText
import GhosttyVt
import UIKit

/// How one cell paints: colors after inverse, and the attributes text drawing
/// reads. Equal neighbours on a row share one fill and one text draw.
struct SSHTerminalPaintStyle: Equatable {
    let foreground: UInt32
    let background: UInt32
    let bold: Bool
    let italic: Bool
    let faint: Bool
    let invisible: Bool
    let underline: Bool
    let strikethrough: Bool

    init(_ cell: SSHTerminalCell) {
        let style = cell.style
        foreground = Self.pack(style.inverse ? cell.background : cell.foreground)
        background = Self.pack(style.inverse ? cell.foreground : cell.background)
        bold = style.bold
        italic = style.italic
        faint = style.faint
        invisible = style.invisible
        underline = style.underline != 0
        strikethrough = style.strikethrough
    }

    static func pack(_ rgb: GhosttyColorRgb) -> UInt32 { UInt32(rgb.r) << 16 | UInt32(rgb.g) << 8 | UInt32(rgb.b) }
}

/// A stretch of one row painted with one fill and one text draw. Printable
/// ASCII neighbours of one style share a run, kerned onto the cell grid. Any
/// other grapheme (wide, combining, non-ASCII) is its own run, so a fallback
/// font's advance cannot shift the columns after it.
struct SSHTerminalPaintRun: Equatable {
    let column: Int
    let columns: Int
    let text: String
    let style: SSHTerminalPaintStyle
    let fixedPitch: Bool
}

/// What a repaint touches. Agent TUIs redraw a spinner or a status line many
/// times a second; repainting the whole grid one cell at a time for each of
/// those cost about 73 ms per frame at 48x40 and pinned the main thread.
enum SSHTerminalPaintPlan {
    static func runs(_ row: [SSHTerminalCell]) -> [SSHTerminalPaintRun] {
        var runs = [SSHTerminalPaintRun]()
        var start = 0
        var text = ""
        var count = 0
        var style: SSHTerminalPaintStyle?
        func flush() {
            if let style, count > 0 {
                runs.append(.init(column: start, columns: count, text: text, style: style, fixedPitch: true))
            }
            style = nil
            text = ""
            count = 0
        }
        for (column, cell) in row.enumerated() {
            // A wide tail is painted by its head.
            guard cell.width > 0 else { continue }
            let cellStyle = SSHTerminalPaintStyle(cell)
            if cell.width == 1, let character = Self.fixedPitchCharacter(cell.text) {
                if cellStyle != style || start + count != column {
                    flush()
                    start = column
                    style = cellStyle
                }
                text.append(character)
                count += 1
            } else {
                flush()
                runs.append(.init(column: column, columns: cell.width, text: cell.text, style: cellStyle, fixedPitch: false))
            }
        }
        flush()
        return runs
    }

    /// Rows whose cells or cursor differ from the last painted frame. Nil when
    /// the grid's shape or default background changed: repaint everything.
    static func changedRows(from old: SSHTerminalFrame?, to new: SSHTerminalFrame) -> IndexSet? {
        guard let old, old.rows.count == new.rows.count,
              SSHTerminalPaintStyle.pack(old.background) == SSHTerminalPaintStyle.pack(new.background) else { return nil }
        var rows = IndexSet()
        for y in new.rows.indices {
            let before = old.rows[y], after = new.rows[y]
            guard before.count == after.count else { return nil }
            let same = zip(before, after).allSatisfy {
                $0.text == $1.text && $0.width == $1.width && SSHTerminalPaintStyle($0) == SSHTerminalPaintStyle($1)
            }
            if !same { rows.insert(y) }
        }
        if !sameCursor(old.cursor, new.cursor) {
            for y in [cursorRow(old), cursorRow(new)].compactMap({ $0 }) where new.rows.indices.contains(y) { rows.insert(y) }
        }
        return rows
    }

    /// The next rows to invalidate within one tick's paint budget, from the
    /// first pending row. A window, not a scattered pick: UIKit draws the
    /// bounding box of what is invalidated, so the box is what costs time.
    static func rowsWithinBudget(_ pending: IndexSet, secondsPerRow: Double, budget: Double) -> IndexSet {
        guard let first = pending.first else { return [] }
        let rows = max(1, Int(budget / max(secondsPerRow, .ulpOfOne)))
        return pending.intersection(IndexSet(integersIn: first..<first + rows))
    }

    /// The rects a tick invalidates: one full-width rect per run of adjacent
    /// rows, plus the strip below the grid when a full pass ends.
    static func invalidationRects(rows: IndexSet, margin: Bool, rowCount: Int, cellHeight: CGFloat, bounds: CGSize) -> [CGRect] {
        var rects = rows.rangeView.map {
            CGRect(x: 0, y: CGFloat($0.lowerBound) * cellHeight, width: bounds.width, height: CGFloat($0.count) * cellHeight)
        }
        let gridBottom = CGFloat(rowCount) * cellHeight
        if margin, bounds.height > gridBottom {
            rects.append(CGRect(x: 0, y: gridBottom, width: bounds.width, height: bounds.height - gridBottom))
        }
        return rects
    }

    static func cursorRow(_ frame: SSHTerminalFrame) -> Int? {
        frame.cursor.visible && frame.cursor.viewport_has_value ? Int(frame.cursor.viewport_y) : nil
    }

    private static func sameCursor(_ a: GhosttyRenderStateCursor, _ b: GhosttyRenderStateCursor) -> Bool {
        a.visible == b.visible && a.viewport_has_value == b.viewport_has_value && a.viewport_x == b.viewport_x
            && a.viewport_y == b.viewport_y && a.wide_tail == b.wide_tail && a.visual_style == b.visual_style
    }

    /// A blank cell paints as a space; printable ASCII keeps the font's one advance.
    private static func fixedPitchCharacter(_ text: String) -> Character? {
        if text.isEmpty { return " " }
        let scalars = text.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first, (0x20...0x7E).contains(scalar.value) else { return nil }
        return Character(scalar)
    }
}

/// Damage waiting to be invalidated. One pass drains front to back before new
/// damage joins it, so a row that changes every frame (a spinner on top, a
/// status line) cannot pull the window back and leave later rows stale for a
/// whole burst. A row still waiting in the pass paints the latest frame when
/// its turn comes; a row already taken waits for the next pass.
struct SSHTerminalRepaintQueue {
    private(set) var pass = IndexSet()
    private(set) var next = IndexSet()
    private(set) var margin = false
    var isEmpty: Bool { pass.isEmpty && next.isEmpty && !margin }

    /// `changed` nil: the grid's shape changed, so the open pass no longer
    /// describes it. Start one full pass, including the strip below the grid.
    mutating func add(_ changed: IndexSet?, rowCount: Int) {
        guard let changed else {
            pass = IndexSet(integersIn: 0..<rowCount)
            next = []
            margin = true
            return
        }
        next.formUnion(changed.subtracting(pass))
    }

    /// This tick's rows, and whether the strip below the grid goes with them.
    mutating func take(secondsPerRow: Double, budget: Double) -> (rows: IndexSet, margin: Bool) {
        if pass.isEmpty {
            pass = next
            next = []
        }
        let rows = SSHTerminalPaintPlan.rowsWithinBudget(pass, secondsPerRow: secondsPerRow, budget: budget)
        pass.subtract(rows)
        let withMargin = margin && pass.isEmpty
        if withMargin { margin = false }
        return (rows, withMargin)
    }
}

/// Draws planned runs with cached faces. Fixed-pitch runs are kerned so each
/// glyph lands on its cell even though the cell width is the font's rounded-up
/// advance.
@MainActor
final class SSHTerminalGridPainter {
    let cellSize: CGSize
    private let font: UIFont
    /// The family's own bold face: bundled code fonts have no bold trait to derive.
    private let boldFont: UIFont
    private var faces = [Int: (font: UIFont, kern: CGFloat)]()

    init(font: UIFont, boldFont: UIFont) {
        self.font = font
        self.boldFont = boldFont
        cellSize = CGSize(width: ceil(("M" as NSString).size(withAttributes: [.font: font]).width),
                          height: ceil(font.lineHeight))
    }

    /// The Code Font family at the Code Text Size, with Nerd Font symbols as a
    /// fallback once they are installed. A 12pt base is 13pt at 100%, the
    /// terminal's size before it followed Code Text Size.
    static func codeFont() -> SSHTerminalGridPainter {
        let family = FontPreferences.codeFont
        let size = FontPreferences.codePointSize(baseSize: 12)
        return SSHTerminalGridPainter(font: family.font(size: size, weight: .regular),
                                      boldFont: family.font(size: size, weight: .bold))
    }

    func paint(_ frame: SSHTerminalFrame, rows: Range<Int>, cursorColor: UIColor, in context: CGContext) {
        for y in rows where frame.rows.indices.contains(y) {
            let top = CGFloat(y) * cellSize.height
            for run in SSHTerminalPaintPlan.runs(frame.rows[y]) { paint(run, top: top, in: context) }
        }
        guard let y = SSHTerminalPaintPlan.cursorRow(frame), rows.contains(y) else { return }
        var area = CGRect(x: CGFloat(frame.cursor.viewport_x) * cellSize.width, y: CGFloat(y) * cellSize.height,
                          width: cellSize.width, height: cellSize.height)
        cursorColor.setStroke()
        if frame.cursor.visual_style == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR { area.size.width = 2 }
        if frame.cursor.visual_style == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE {
            area.origin.y += cellSize.height - 2
            area.size.height = 2
        }
        context.stroke(area.insetBy(dx: 0.5, dy: 0.5))
    }

    private func paint(_ run: SSHTerminalPaintRun, top: CGFloat, in context: CGContext) {
        let style = run.style
        let area = CGRect(x: CGFloat(run.column) * cellSize.width, y: top,
                          width: CGFloat(run.columns) * cellSize.width, height: cellSize.height)
        Self.color(style.background).setFill()
        context.fill(area)
        guard !style.invisible else { return }
        if run.fixedPitch, !style.underline, !style.strikethrough, run.text.allSatisfy({ $0 == " " }) { return }
        let face = face(bold: style.bold, italic: style.italic)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: face.font,
            .foregroundColor: Self.color(style.foreground).withAlphaComponent(style.faint ? 0.5 : 1),
        ]
        if run.fixedPitch { attributes[.kern] = face.kern }
        if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        context.saveGState()
        context.clip(to: area)
        if let text = withSymbols(run, face: face, attributes: attributes) {
            text.draw(at: area.origin)
        } else {
            (run.text as NSString).draw(at: area.origin, withAttributes: attributes)
        }
        context.restoreGState()
    }

    /// Nerd Font icons the face lacks, drawn with the symbols font and kerned to
    /// one cell. nil when the run has none (the common case) or the symbols
    /// are not installed. Explicit, because SF Mono ignores cascade lists.
    private func withSymbols(_ run: SSHTerminalPaintRun, face: (font: UIFont, kern: CGFloat),
                             attributes: [NSAttributedString.Key: Any]) -> NSAttributedString? {
        guard run.text.unicodeScalars.contains(where: NerdFontSymbols.isPrivateUse),
              let symbols = symbolsFace() else { return nil }
        let text = NSMutableAttributedString(string: run.text, attributes: attributes)
        var location = 0
        for character in run.text {
            let length = character.utf16.count
            if character.unicodeScalars.contains(where: NerdFontSymbols.isPrivateUse),
               !Self.covers(face.font, character) {
                let range = NSRange(location: location, length: length)
                text.addAttribute(.font, value: symbols.font, range: range)
                if run.fixedPitch { text.addAttribute(.kern, value: symbols.kern, range: range) }
            }
            location += length
        }
        return text
    }

    private func symbolsFace() -> (font: UIFont, kern: CGFloat)? {
        if let face = faces[Self.symbolsKey] { return face }
        guard let symbols = NerdFontSymbols.font(size: font.pointSize) else { return nil }
        let advance = ("\u{E0B0}" as NSString).size(withAttributes: [.font: symbols]).width
        let face = (symbols, cellSize.width - advance)
        faces[Self.symbolsKey] = face
        return face
    }

    private static let symbolsKey = 4

    private static func covers(_ font: UIFont, _ character: Character) -> Bool {
        let units = Array(character.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font as CTFont, units, &glyphs, units.count)
    }

    private func face(bold: Bool, italic: Bool) -> (font: UIFont, kern: CGFloat) {
        let key = (bold ? 1 : 0) | (italic ? 2 : 0)
        if let face = faces[key] { return face }
        let weighted = bold ? boldFont : font
        // A family without an italic face stays upright.
        let styled = italic
            ? weighted.fontDescriptor.withSymbolicTraits(.traitItalic)
                .map { NerdFontSymbols.withFallback(UIFont(descriptor: $0, size: weighted.pointSize)) } ?? weighted
            : weighted
        let advance = ("M" as NSString).size(withAttributes: [.font: styled]).width
        let face = (styled, cellSize.width - advance)
        faces[key] = face
        return face
    }

    private static func color(_ packed: UInt32) -> UIColor {
        UIColor(red: CGFloat(packed >> 16 & 0xFF) / 255, green: CGFloat(packed >> 8 & 0xFF) / 255,
                blue: CGFloat(packed & 0xFF) / 255, alpha: 1)
    }
}

