import UIKit

/// Pure layout policy for assistant markdown tables.
///
/// A column's width is `min(naturalSingleLine, maxReadable)`. Whether a table
/// needs the wrapping grid depends only on content: any column's natural width
/// over `maxReadable`.
///
/// The viewport decides one more thing, and only through `plan`: when a table is
/// wider than the viewport, its columns are fit to the viewport if every column
/// can stay at least `minimumFitCharacterCount` characters wide, and the table
/// scrolls sideways otherwise. A column whose natural width is at most
/// `protectedCharacterCount` characters is never narrowed, so a short value (a
/// timestamp, a date, a count) cannot wrap. Squeezing short columns left stale
/// heights and overlapping rows once (`ee911a546`), which is why the floor is per
/// column and why a width change re-plans the table instead of rescaling it.
enum MarkdownTableColumnLayout {
    /// Horizontal padding inside the table card around cell content.
    static let horizontalContentInset: CGFloat = 8

    /// Gap between columns in grid mode (includes room for a thin divider).
    static let columnSpacing: CGFloat = 8

    /// Readable wrap budget, in mono cells of `AppFont.monoMedium`.
    /// 35 cells is about 280pt at the default 12pt SF Mono.
    static let maxReadableCharacterCount: CGFloat = 35

    /// The narrowest a longer column may be fit to the viewport, in mono cells.
    /// Below this, words break mid-token and the table scrolls instead.
    static let minimumFitCharacterCount: CGFloat = 8

    /// A column at most this wide, in mono cells, keeps its natural width when
    /// the table is fit: it holds a value (a time, a date, a number) that must
    /// stay on one line.
    static let protectedCharacterCount: CGFloat = 10

    /// One-column wrap cap shared by chat and Reader. Not viewport-derived.
    static var maxReadableColumnWidth: CGFloat {
        maxReadableCharacterCount * monoAdvanceWidth
    }

    /// Natural widths are measured rounded up to whole points, so the thresholds
    /// are too: a column of exactly `protectedCharacterCount` characters must
    /// compare as protected.
    static var minimumFitColumnWidth: CGFloat {
        ceil(minimumFitCharacterCount * monoAdvanceWidth)
    }

    static var protectedColumnWidth: CGFloat {
        ceil(protectedCharacterCount * monoAdvanceWidth)
    }

    static var monoAdvanceWidth: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: AppFont.monoMedium]).width
    }

    /// Never shrink a column below its natural width unless that natural width
    /// exceeds `maxReadable`. There is no squeeze floor.
    static func clampedColumnWidths(naturalWidths: [CGFloat]) -> [CGFloat] {
        let cap = maxReadableColumnWidth
        return naturalWidths.map { min($0, cap) }
    }

    /// Grid mode depends only on content, never on available width or column count.
    static func needsGridMode(naturalWidths: [CGFloat]) -> Bool {
        let cap = maxReadableColumnWidth
        return naturalWidths.contains { $0 > cap }
    }

    // MARK: - Viewport plan

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
    }

    /// Width of the wrapping grid at `columnWidths`, card padding included.
    static func gridContentWidth(columnWidths: [CGFloat]) -> CGFloat {
        columnWidths.reduce(0, +)
            + columnSpacing * CGFloat(max(0, columnWidths.count - 1))
            + horizontalContentInset * 2
    }

    /// Chooses clip, grid, or fit-to-width grid for a viewport.
    ///
    /// - Parameters:
    ///   - naturalWidths: single-line width of each column.
    ///   - clipContentWidth: width of the clip-mode text for these columns.
    ///   - availableWidth: the card's maximum width, or nil when not yet known
    ///     (the content-only layout: no fitting, the table may scroll).
    ///   - displayScale: widths are rounded down to this pixel grid, so a fitted
    ///     table never overshoots the viewport by a rounding sliver.
    static func plan(
        naturalWidths: [CGFloat],
        clipContentWidth: CGFloat,
        availableWidth: CGFloat?,
        displayScale: CGFloat
    ) -> Plan {
        let capped = clampedColumnWidths(naturalWidths: naturalWidths)
        let needsGrid = needsGridMode(naturalWidths: naturalWidths)
        // Content-only: the table scrolls if it is wider than the viewport.
        let contentOnly = needsGrid
            ? Plan(presentation: .grid, columnWidths: capped)
            : Plan(presentation: .clip, columnWidths: naturalWidths)
        guard let available = availableWidth, available > 0, !naturalWidths.isEmpty else {
            return contentOnly
        }

        if !needsGrid, clipContentWidth <= available {
            return contentOnly
        }
        // Grid gaps are narrower than clip's `  │  ` separators, so a table that
        // overflows as clip text can still fit as a grid at its natural widths.
        if gridContentWidth(columnWidths: capped) <= available {
            return Plan(presentation: .grid, columnWidths: capped)
        }

        let chrome = gridContentWidth(columnWidths: [CGFloat](repeating: 0, count: capped.count))
        let budget = available - chrome
        let protected = protectedColumnWidth
        let minimum = minimumFitColumnWidth
        let floors = capped.map { $0 <= protected ? $0 : min($0, minimum) }
        guard budget >= floors.reduce(0, +) else {
            // Even every column at its floor does not fit: scroll.
            return contentOnly
        }

        // Spread what is left over the columns by how much each still wants.
        let extra = budget - floors.reduce(0, +)
        let wants = zip(capped, floors).map { $0 - $1 }
        let totalWant = wants.reduce(0, +)
        let scale = max(displayScale, 1)
        let widths = zip(floors, wants).map { floor, want in
            let share = totalWant > 0 ? extra * want / totalWant : 0
            return ((floor + share) * scale).rounded(.down) / scale
        }
        return Plan(presentation: .grid, columnWidths: widths)
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
    static func gridTrailingEdges(columnWidths: [CGFloat]) -> [CGFloat] {
        var edges: [CGFloat] = []
        var x = horizontalContentInset
        for width in columnWidths {
            x += width
            edges.append(x)
            x += columnSpacing
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
    static func trailingEdges(for plan: Plan) -> [CGFloat] {
        switch plan.presentation {
        case .grid:
            return gridTrailingEdges(columnWidths: plan.columnWidths)
        case .clip:
            let font = AppFont.monoMedium
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
    /// Natural single-line column widths and the clip text's width.
    var natural: (columnWidths: [CGFloat], totalWidth: CGFloat) = ([], 0)
    /// The plan on screen.
    var rendered: MarkdownTableColumnLayout.Plan?
    private var plannedWidth: CGFloat?

    /// The plan for this view's width. While it has none (not laid out yet), the
    /// last width planned or measured at, else `hint`: a table measured at a
    /// width keeps its plan across applies, or every tick would redraw it.
    @MainActor
    mutating func plan(width: CGFloat, hint: CGFloat?, displayScale: CGFloat) -> MarkdownTableColumnLayout.Plan {
        let available = width > 0 ? width : (plannedWidth ?? hint.flatMap { $0 > 0 ? $0 : nil })
        plannedWidth = available
        return plan(availableWidth: available, displayScale: displayScale)
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
        MarkdownTableColumnLayout.plan(
            naturalWidths: natural.columnWidths,
            clipContentWidth: natural.totalWidth,
            availableWidth: availableWidth,
            displayScale: displayScale
        )
    }
}
