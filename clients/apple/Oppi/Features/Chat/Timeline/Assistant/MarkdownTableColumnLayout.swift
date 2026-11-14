import UIKit

/// Pure layout policy for assistant markdown tables.
///
/// A column's width starts at `min(naturalSingleLine, maxReadable)`. Whether a
/// table needs the wrapping grid depends only on content: any column's natural
/// width over `maxReadable`, or a cell a `<br>` breaks into lines (clip text is
/// one line per row).
///
/// The viewport decides the rest, and only through `plan`. A wrapping table
/// narrower than the text around it grows its wrapping columns into the spare
/// width, each by its share of what it still wants, so on a wide screen a
/// table of prose is as wide as the prose and wraps less. When a table is
/// wider than the viewport, its columns are fit to the viewport if every column
/// can stay at least `minimumFitCharacterCount` characters wide and as wide as
/// its longest unbreakable word (so an identifier like `rowFoldLimit` never wraps mid-word), and
/// the table scrolls sideways otherwise. A column whose natural width is at most
/// `protectedCharacterCount` characters is never narrowed, so a short value (a
/// timestamp, a date, a count) cannot wrap. Squeezing short columns left stale
/// heights and overlapping rows once (`ee911a546`), which is why the floor is per
/// column and why a width change re-plans the table instead of rescaling it.
enum MarkdownTableColumnLayout {
    /// The grid's horizontal spacing: padding inside the card around the cells,
    /// and the gap between columns. A message keeps it tight; the full-screen
    /// viewer has room to let columns breathe.
    struct Gutters: Equatable, Sendable {
        let inset: CGFloat
        let column: CGFloat

        static let message = Self(inset: 8, column: 8)
        static let viewer = Self(inset: 12, column: 16)
    }

    /// Where a long column starts wrapping, in digits of the cell font: its
    /// width when the table has no spare width to grow into, and its weight when
    /// the table is fit to a narrower viewport. 35 digits is about 360pt at the
    /// default 17pt body, some 47 characters of prose.
    static let maxReadableCharacterCount: CGFloat = 35

    /// The narrowest a longer column may be fit to the viewport, in digits.
    /// Below this, words break mid-token and the table scrolls instead.
    /// Seven, not eight: a 4-column table of row labels ("273 KB session") and
    /// short timings, the kind a benchmark answer holds, then wraps in a phone's
    /// 342 pt chat column instead of scrolling by a few points.
    static let minimumFitCharacterCount: CGFloat = 7

    /// A column at most this wide, in digits, keeps its natural width when the
    /// table is fit: it holds a value (a time, a date, a number) that must stay
    /// on one line.
    static let protectedCharacterCount: CGFloat = 10

    /// One-column wrap start shared by chat and Reader. Not viewport-derived.
    static var maxReadableColumnWidth: CGFloat {
        maxReadableCharacterCount * characterWidth
    }

    /// Natural widths are measured rounded up to whole points, so the thresholds
    /// are too: a column of exactly `protectedCharacterCount` digits must
    /// compare as protected.
    static var minimumFitColumnWidth: CGFloat {
        ceil(minimumFitCharacterCount * characterWidth)
    }

    static var protectedColumnWidth: CGFloat {
        ceil(protectedCharacterCount * characterWidth)
    }

    /// The advance of a digit in the cell font (`AppFont.messageBody`), the
    /// unit of the counts above. System digits are tabular, so a value of N
    /// digits is N of these wide; it follows Dynamic Type with the cells.
    static var characterWidth: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: AppFont.messageBody]).width
    }

    /// Never shrink a column below its natural width unless that natural width
    /// exceeds `maxReadable`. There is no squeeze floor.
    static func clampedColumnWidths(naturalWidths: [CGFloat], characterWidth unit: CGFloat = characterWidth) -> [CGFloat] {
        let cap = maxReadableCharacterCount * unit
        return naturalWidths.map { min($0, cap) }
    }

    /// Grid mode depends only on content, never on available width or column count.
    static func needsGridMode(naturalWidths: [CGFloat], characterWidth unit: CGFloat = characterWidth) -> Bool {
        let cap = maxReadableCharacterCount * unit
        return naturalWidths.contains { $0 > cap }
    }

    // MARK: - Viewport plan

    /// What the plan needs from a table's content.
    struct NaturalColumns: Equatable {
        /// Single-line width of each column.
        let columnWidths: [CGFloat]
        /// Each column's longest run that wrapping cannot break.
        let longestWordWidths: [CGFloat]
        /// Single-line width of each column's widest body cell, header aside.
        let valueWidths: [CGFloat]
        /// Width of the clip-mode text.
        let totalWidth: CGFloat
        /// A cell breaks into lines, which only the grid can draw.
        var breaksLines = false

        static let empty = Self(columnWidths: [], longestWordWidths: [], valueWidths: [], totalWidth: 0)
    }

    /// How a table is drawn at one viewport width.
    struct Plan: Equatable {
        enum Presentation: Equatable {
            /// One text view with tab stops; no wrapping. `columnWidths` are natural.
            case clip
            /// A wrapping grid at `columnWidths`.
            case grid
        }

        let presentation: Presentation
        let columnWidths: [CGFloat]
        /// The grid's spacing the widths were planned with.
        var gutters = Gutters.message
    }

    /// Width of the wrapping grid at `columnWidths`, card padding included.
    static func gridContentWidth(columnWidths: [CGFloat], gutters: Gutters = .message) -> CGFloat {
        columnWidths.reduce(0, +)
            + gutters.column * CGFloat(max(0, columnWidths.count - 1))
            + gutters.inset * 2
    }

    /// Chooses clip, grid, or fit-to-width grid for a viewport.
    ///
    /// - Parameters:
    ///   - naturalWidths: single-line width of each column.
    ///   - longestWordWidths: each column's widest run that line breaking cannot
    ///     split (`TableInlineText.unbreakableRuns`), measured in the fonts the
    ///     cells draw in; a fitted column is never narrower.
    ///   - valueWidths: each column's widest body cell. A column whose values
    ///     are short (`protectedCharacterCount`) but whose header is long fits
    ///     down to its values and its header's longest word: the header wraps,
    ///     the values never do. Nil treats the header as a value.
    ///   - clipContentWidth: width of the clip-mode text for these columns.
    ///   - availableWidth: the card's maximum width, or nil when not yet known
    ///     (the content-only layout: no fitting, the table may scroll).
    ///   - fillWidth: the width a wrapping table grows to: the width of the text
    ///     around it. Nil means `availableWidth`, which is the text's width
    ///     wherever the table is laid out at the column's width (chat). The
    ///     reader widens a table past its prose column only when it has to, so
    ///     it passes the column.
    ///   - displayScale: widths are rounded down to this pixel grid, so a fitted
    ///     table never overshoots the viewport by a rounding sliver.
    ///   - characterWidth: a digit's advance in the cells' font, the unit of the
    ///     character counts above; the message body's unless the table draws at
    ///     another size (the full-screen viewer's text size).
    ///   - gutters: the grid's padding and column gaps.
    ///   - breaksLines: a cell holds a line break (`NaturalColumns.breaksLines`),
    ///     so the table draws as a grid at any width.
    static func plan(
        naturalWidths: [CGFloat],
        longestWordWidths: [CGFloat],
        clipContentWidth: CGFloat,
        availableWidth: CGFloat?,
        valueWidths: [CGFloat]? = nil,
        fillWidth: CGFloat? = nil,
        displayScale: CGFloat,
        characterWidth unit: CGFloat = characterWidth,
        gutters: Gutters = .message,
        breaksLines: Bool = false
    ) -> Plan {
        let capped = clampedColumnWidths(naturalWidths: naturalWidths, characterWidth: unit)
        let needsGrid = breaksLines || needsGridMode(naturalWidths: naturalWidths, characterWidth: unit)
        // The narrowest each column may be: a short column its whole width, a
        // longer one `minimumFitColumnWidth` or its longest word, never past its
        // content. A word can be longer than the cap (a commit hash).
        let protected = ceil(protectedCharacterCount * unit)
        let minimum = ceil(minimumFitCharacterCount * unit)
        let floors = capped.indices.map { index -> CGFloat in
            guard capped[index] > protected else { return capped[index] }
            let word = index < longestWordWidths.count ? longestWordWidths[index] : 0
            if let values = valueWidths, index < values.count, values[index] <= protected {
                // Short values under a long header ("Oppi tonight, full
                // pipeline" over "0.08 ms"): the header wraps, so the column
                // is as narrow as its values, never narrower than a word.
                return min(naturalWidths[index], max(values[index], word))
            }
            return min(naturalWidths[index], max(minimum, word))
        }
        // The cap, widened where a word needs it, so no layout below breaks one.
        let base = zip(capped, floors).map { max($0, $1) }
        // Content-only: the table scrolls if it is wider than the viewport.
        let contentOnly = needsGrid
            ? Plan(presentation: .grid, columnWidths: base, gutters: gutters)
            : Plan(presentation: .clip, columnWidths: naturalWidths, gutters: gutters)
        guard let available = availableWidth, available > 0, !naturalWidths.isEmpty else {
            return contentOnly
        }

        if !needsGrid, clipContentWidth <= available {
            return contentOnly
        }
        // Grid gaps are narrower than clip's `  │  ` separators, so a table that
        // overflows as clip text can still fit as a grid at its natural widths.
        let baseWidth = gridContentWidth(columnWidths: base, gutters: gutters)
        if baseWidth <= available {
            let fill = min(available, fillWidth ?? available)
            return Plan(
                presentation: .grid,
                columnWidths: grown(base, toward: naturalWidths, by: fill - baseWidth, displayScale: displayScale),
                gutters: gutters
            )
        }

        let chrome = gridContentWidth(columnWidths: [CGFloat](repeating: 0, count: capped.count), gutters: gutters)
        let budget = available - chrome
        guard budget >= floors.reduce(0, +) else {
            // Even every column at its floor does not fit: scroll.
            return contentOnly
        }

        // Spread what is left over the columns by how much each still wants,
        // values first: a row label grows toward its widest value before a long
        // header gets room to wrap less, since rows outnumber the header.
        var extra = budget - floors.reduce(0, +)
        var widths = floors
        let valueTargets = capped.indices.map { index in
            min(capped[index], valueWidths.map { index < $0.count ? $0[index] : capped[index] } ?? capped[index])
        }
        for targets in [valueTargets, capped] {
            let wants = zip(targets, widths).map { max(0, $0 - $1) }
            let totalWant = wants.reduce(0, +)
            guard totalWant > 0, extra > 0 else { continue }
            let given = min(extra, totalWant)
            widths = zip(widths, wants).map { $0 + given * $1 / totalWant }
            extra -= given
        }
        // Only the shares are rounded: a floor is a word that must fit whole.
        let scale = max(displayScale, 1)
        widths = zip(floors, widths).map { floor, width in floor + ((width - floor) * scale).rounded(.down) / scale }
        return Plan(presentation: .grid, columnWidths: widths, gutters: gutters)
    }

    /// `capped` with `spare` width shared among the columns that still wrap,
    /// each in proportion to how much wider than its width its content is, and
    /// none past its natural width. A table with no wrapping column, or no
    /// spare width, keeps `capped`.
    private static func grown(
        _ capped: [CGFloat],
        toward naturalWidths: [CGFloat],
        by spare: CGFloat,
        displayScale: CGFloat
    ) -> [CGFloat] {
        let wants = zip(naturalWidths, capped).map { max(0, $0 - $1) }
        let totalWant = wants.reduce(0, +)
        guard spare > 0, totalWant > 0 else { return capped }
        if totalWant <= spare { return zip(capped, wants).map { $0 + $1 } }
        let scale = max(displayScale, 1)
        return zip(capped, wants).map { width, want in
            width + (spare * want / totalWant * scale).rounded(.down) / scale
        }
    }

    // MARK: - Overflow

    /// Right edge of each column in clip text, in content coordinates:
    /// `  c0 ⟂ c1 ⟂ … ` with `leadPad`, a `buffer` after each column, and
    /// `separator` between columns.
    static func clipTrailingEdges(
        columnWidths: [CGFloat],
        leadPad: CGFloat,
        separator: CGFloat,
        buffer: CGFloat
    ) -> [CGFloat] {
        var edges: [CGFloat] = []
        var x = leadPad
        for (index, width) in columnWidths.enumerated() {
            x += width + buffer
            edges.append(x)
            if index < columnWidths.count - 1 { x += separator }
        }
        return edges
    }

    /// Right edge of each column in the wrapping grid, in content coordinates.
    static func gridTrailingEdges(columnWidths: [CGFloat], gutters: Gutters = .message) -> [CGFloat] {
        var edges: [CGFloat] = []
        var x = gutters.inset
        for width in columnWidths {
            x += width
            edges.append(x)
            x += gutters.column
        }
        return edges
    }

    /// How many columns reach past the visible right edge, whether wholly hidden
    /// or cut. The cue says "more columns", and a cut column is one.
    static func hiddenColumnCount(trailingEdges: [CGFloat], visibleMaxX: CGFloat) -> Int {
        trailingEdges.reduce(0) { $0 + ($1 > visibleMaxX + 1 ? 1 : 0) }
    }

    /// Right edge of each column of `plan` as drawn, in content coordinates.
    @MainActor
    static func trailingEdges(for plan: Plan, gutters: Gutters) -> [CGFloat] {
        switch plan.presentation {
        case .grid:
            return gridTrailingEdges(columnWidths: plan.columnWidths, gutters: gutters)
        case .clip:
            let font = AppFont.messageBody
            func width(_ text: String) -> CGFloat {
                ceil((text as NSString).size(withAttributes: [.font: font]).width)
            }
            return clipTrailingEdges(
                columnWidths: plan.columnWidths,
                leadPad: width("  "),
                separator: width("  │  "),
                buffer: 1
            )
        }
    }
}

/// What one table view knows about how it is drawn: the columns' natural widths,
/// the plan on screen, and the width that plan was made for. A width change asks
/// `replan` whether the plan differs; a view redraws only when it does.
struct TablePlanning {
    /// Natural single-line column widths, each column's longest unbreakable
    /// word, and the clip text's width.
    var natural = MarkdownTableColumnLayout.NaturalColumns.empty
    /// The plan on screen.
    var rendered: MarkdownTableColumnLayout.Plan?
    private var plannedWidth: CGFloat?
    /// A digit's advance in the font the cells are measured in.
    var characterWidth = MarkdownTableColumnLayout.characterWidth
    /// The width a wrapping table grows to, when narrower than the view (the
    /// viewer's reading column); nil grows it to the view's width.
    var fillWidth: CGFloat?
    /// Never the tab-stop text: a table that would draw as clip text draws as
    /// a grid at the same, natural, column widths (the full-screen viewer).
    var drawsGridOnly = false
    /// The spacing to plan with when the table fits with it; a table that
    /// would scroll only because of it takes the message's tighter spacing.
    var gutters = MarkdownTableColumnLayout.Gutters.message

    /// The plan for this view's width. While it has none (not laid out yet), the
    /// last width planned or measured at, else `hint`: a table measured at a
    /// width keeps its plan across applies, or every tick would redraw it.
    @MainActor
    mutating func plan(width: CGFloat, hint: CGFloat?, displayScale: CGFloat) -> MarkdownTableColumnLayout.Plan {
        let available = width > 0 ? width : (plannedWidth ?? hint.flatMap { $0 > 0 ? $0 : nil })
        plannedWidth = available
        return plan(availableWidth: available, displayScale: displayScale)
    }

    /// How far the plan on screen reaches past the width it was planned for: the
    /// part of the table cut at rest, before any sideways scroll. Zero until the
    /// table is planned for a width.
    var overflow: CGFloat {
        guard let rendered, let plannedWidth else { return 0 }
        let contentWidth = switch rendered.presentation {
        case .grid: MarkdownTableColumnLayout.gridContentWidth(columnWidths: rendered.columnWidths, gutters: rendered.gutters)
        case .clip: natural.totalWidth
        }
        return max(0, contentWidth - plannedWidth)
    }

    /// The plan for a new `width`, or nil when the table is not drawn yet, the
    /// width is the one already planned for, or the plan would not change.
    @MainActor
    mutating func replan(forWidth width: CGFloat, displayScale: CGFloat) -> MarkdownTableColumnLayout.Plan? {
        guard width > 0, rendered != nil else { return nil }
        if let plannedWidth, abs(plannedWidth - width) < 0.5 { return nil }
        plannedWidth = width
        let next = plan(availableWidth: width, displayScale: displayScale)
        return next == rendered ? nil : next
    }

    @MainActor
    private func plan(availableWidth: CGFloat?, displayScale: CGFloat) -> MarkdownTableColumnLayout.Plan {
        let roomy = plan(availableWidth: availableWidth, displayScale: displayScale, gutters: gutters)
        guard gutters != .message, let availableWidth, Self.contentWidth(of: roomy) > availableWidth else { return roomy }
        let tight = plan(availableWidth: availableWidth, displayScale: displayScale, gutters: .message)
        return Self.contentWidth(of: tight) < Self.contentWidth(of: roomy) ? tight : roomy
    }

    private static func contentWidth(of plan: MarkdownTableColumnLayout.Plan) -> CGFloat {
        MarkdownTableColumnLayout.gridContentWidth(columnWidths: plan.columnWidths, gutters: plan.gutters)
    }

    @MainActor
    private func plan(
        availableWidth: CGFloat?,
        displayScale: CGFloat,
        gutters: MarkdownTableColumnLayout.Gutters
    ) -> MarkdownTableColumnLayout.Plan {
        let plan = MarkdownTableColumnLayout.plan(
            naturalWidths: natural.columnWidths,
            longestWordWidths: natural.longestWordWidths,
            clipContentWidth: natural.totalWidth,
            availableWidth: availableWidth,
            valueWidths: natural.valueWidths,
            fillWidth: fillWidth,
            displayScale: displayScale,
            characterWidth: characterWidth,
            gutters: gutters,
            breaksLines: natural.breaksLines
        )
        guard drawsGridOnly, plan.presentation == .clip else { return plan }
        return MarkdownTableColumnLayout.Plan(presentation: .grid, columnWidths: plan.columnWidths, gutters: plan.gutters)
    }
}
