import CoreGraphics
import CoreText
import Foundation

/// Renderer for Mermaid gantt charts.
///
/// Draws a horizontal timeline with sections and task bars.
/// Uses the same `FlowchartLayout` container with `customDraw`/`customSize`.
///
/// Layout strategy: tasks are positioned sequentially. Each duration unit maps
/// to a fixed pixel width. Actual date parsing is skipped — the chart shows
/// relative positioning based on declared order and durations.
enum MermaidGanttRenderer {

    // MARK: - Layout constants

    private static let sectionLabelWidth: CGFloat = 120
    private static let taskLabelWidth: CGFloat = 130
    private static let barHeight: CGFloat = 22
    private static let rowSpacing: CGFloat = 6
    private static let sectionHeaderHeight: CGFloat = 28
    private static let titleHeight: CGFloat = 32
    private static let axisHeight: CGFloat = 24
    private static let leftMargin: CGFloat = 16
    private static let rightMargin: CGFloat = 24
    /// Natural width of one duration unit; a fitted chart compresses it.
    private static let pixelsPerUnit: CGFloat = 30
    /// Floor for a compressed unit so year-long charts still lay out.
    private static let minUnitWidth: CGFloat = 0.25
    /// Closest two grid lines may sit before every other one is dropped.
    private static let minGridSpacing: CGFloat = 8
    /// Bars stay visible however far the scale compresses.
    private static let minBarWidth: CGFloat = 3
    /// Gap between a fitted task-name column and the chart.
    private static let taskLabelGap: CGFloat = 8
    private static let milestoneSize: CGFloat = 14
    /// Reserved band under the bottom axis for vertical marker names.
    private static let markerLabelBand: CGFloat = 16

    // MARK: - Compact label placement

    /// Where a compact-mode task label sits relative to its bar.
    enum CompactLabelAlignment: Equatable {
        /// Label fits inside the bar and is centered in it.
        case centerInBar
        /// Label does not fit; drawn just right of the bar end.
        case rightOfBar
        /// Right side would clip the chart edge; drawn left of the bar start.
        case leftOfBar
    }

    /// Decide where a task label on the bars is drawn, and how wide it may be.
    ///
    /// Order of preference: centered inside the bar when it fits with
    /// padding, else to the right of the bar, else to the left of it. A
    /// label that fits whole in none of those spots never crosses its bar's
    /// edge: it takes the roomiest one and `width` is less than
    /// `labelWidth`, so the caller truncates it.
    static func compactLabelPlacement(
        labelWidth: CGFloat,
        barX: CGFloat,
        barWidth: CGFloat,
        chartLeft: CGFloat,
        chartRight: CGFloat
    ) -> (alignment: CompactLabelAlignment, x: CGFloat, width: CGFloat) {
        let padding: CGFloat = 8
        let gap: CGFloat = 4
        if labelWidth + padding * 2 <= barWidth {
            return (.centerInBar, barX + (barWidth - labelWidth) / 2, labelWidth)
        }
        let rightX = barX + barWidth + gap
        let rightRoom = chartRight - rightX
        if labelWidth <= rightRoom {
            return (.rightOfBar, rightX, labelWidth)
        }
        let leftRoom = barX - gap - chartLeft
        if labelWidth <= leftRoom {
            return (.leftOfBar, barX - gap - labelWidth, labelWidth)
        }
        let insideRoom = barWidth - padding * 2
        if insideRoom >= rightRoom, insideRoom >= leftRoom {
            return (.centerInBar, barX + padding, insideRoom)
        }
        if rightRoom >= leftRoom {
            return (.rightOfBar, rightX, max(rightRoom, 0))
        }
        return (.leftOfBar, chartLeft, leftRoom)
    }

    // MARK: - Public entry point

    nonisolated static func layout(
        _ diagram: GanttDiagram,
        configuration: RenderConfiguration
    ) -> MermaidFlowchartRenderer.FlowchartLayout {
        let theme = configuration.theme
        let fontSize = configuration.fontSize

        // Flatten all tasks to compute timeline extent.
        let allTasks = diagram.sections.flatMap(\.tasks)
        guard !allTasks.isEmpty else {
            return MermaidFlowchartRenderer().placeholderLayout(
                text: "Empty gantt chart",
                configuration: configuration
            )
        }

        // Resolve task positions: each task gets a (start, length) in abstract units.
        let resolved = resolveTasks(allTasks)
        let maxEnd = resolved.values.map { $0.start + $0.length }.max() ?? 1
        let timelineUnits = max(maxEnd, 1)
        let isCompact = diagram.displayMode == .compact
        let smallFontSize = fontSize * 0.85
        let smallFont = CTFontCreateWithName("Helvetica" as CFString, smallFontSize, nil)

        // Natural geometry: section and task label columns, fixed unit width.
        var fit = (
            fitted: false,
            unitWidth: pixelsPerUnit,
            taskLabelX: leftMargin + sectionLabelWidth,
            chartLeft: leftMargin + sectionLabelWidth + (isCompact ? 0 : taskLabelWidth),
            labelsOnBars: isCompact
        )
        // Fit to width only when the natural chart is wider than the view.
        // Section names already sit on their own header rows, so the fitted
        // chart drops the section column, keeps a task column only as wide
        // as the longest task name (when that leaves most of the width for
        // the axis), otherwise moves task names onto their bars, and
        // compresses the time scale into what is left.
        let available = configuration.maxWidth
        if fit.chartLeft + CGFloat(timelineUnits) * fit.unitWidth + rightMargin > available {
            fit.fitted = true
            let room = available - leftMargin - rightMargin
            let indent = fontSize * 0.75
            let longest = allTasks
                .filter { $0.status != .vert }
                .map { MermaidTextUtils.lineWidth($0.name, font: smallFont, fontSize: smallFontSize) }
                .max() ?? 0
            if !isCompact, indent + longest + taskLabelGap <= room * 0.4 {
                fit.taskLabelX = leftMargin + indent
                fit.chartLeft = fit.taskLabelX + longest + taskLabelGap
            } else {
                fit.labelsOnBars = true
                fit.chartLeft = leftMargin
            }
            fit.unitWidth = max((available - fit.chartLeft - rightMargin) / CGFloat(timelineUnits), minUnitWidth)
        }
        let (fitted, unitWidth, taskLabelX, chartLeft, labelsOnBars) = fit
        let timelineWidth = CGFloat(timelineUnits) * unitWidth
        let totalWidth = chartLeft + timelineWidth + rightMargin
        // A fitted chart lets bar labels use the right margin too, so a long
        // name beside a late bar stays off the bar.
        let labelRight = fitted ? totalWidth - 4 : chartLeft + timelineWidth

        // Grid lines and axis labels thin out as the scale compresses so
        // lines stay apart and numbers never overlap.
        let widestAxisLabel = MermaidTextUtils.lineWidth("\(timelineUnits)", font: smallFont, fontSize: smallFontSize)
        let axisStep = max(timelineUnits / 10, niceStep(atLeast: (widestAxisLabel + 6) / unitWidth), 1)
        let gridStep = niceStep(atLeast: minGridSpacing / unitWidth)

        var y: CGFloat = leftMargin

        // Title.
        if diagram.title != nil {
            y += titleHeight
        }

        let topAxisY: CGFloat?
        if diagram.topAxis {
            topAxisY = y
            y += axisHeight
        } else {
            topAxisY = nil
        }

        let chartBodyTop = y

        // Compute row positions per section.
        struct RowInfo {
            let task: GanttTask
            let y: CGFloat
            let start: Int
            let length: Int
        }
        struct SectionInfo {
            let name: String
            let headerY: CGFloat
            let rows: [RowInfo]
            let markers: [RowInfo]
        }

        var sectionInfos: [SectionInfo] = []
        for section in diagram.sections {
            let headerY = y
            y += sectionHeaderHeight

            var rows: [RowInfo] = []
            var markers: [RowInfo] = []
            if isCompact {
                var rowEnds: [Int] = []
                for task in section.tasks {
                    let pos = resolved[task.name] ?? TaskPosition(start: 0, length: 1)
                    if task.status == .vert {
                        markers.append(RowInfo(task: task, y: y, start: pos.start, length: pos.length))
                        continue
                    }
                    // A 0-day milestone starting where another task ends would
                    // visually collide with that bar's label, so it gets its own row.
                    let rowIndex = task.status == .milestone
                        ? rowEnds.firstIndex { pos.start > $0 } ?? rowEnds.count
                        : firstAvailableCompactRow(start: pos.start, rowEnds: rowEnds)
                    // Reserve at least one unit for a milestone so a following
                    // same-start task cannot join its zero-length row.
                    let packEnd = task.status == .milestone
                        ? pos.start + max(pos.length, 1)
                        : pos.start + pos.length
                    if rowIndex == rowEnds.count {
                        rowEnds.append(packEnd)
                    } else {
                        rowEnds[rowIndex] = packEnd
                    }
                    let rowY = y + CGFloat(rowIndex) * (barHeight + rowSpacing)
                    rows.append(RowInfo(task: task, y: rowY, start: pos.start, length: pos.length))
                }
                y += CGFloat(max(rowEnds.count, rows.isEmpty ? 0 : 1)) * (barHeight + rowSpacing)
            } else {
                for task in section.tasks {
                    let pos = resolved[task.name] ?? TaskPosition(start: 0, length: 1)
                    if task.status == .vert {
                        markers.append(RowInfo(task: task, y: y, start: pos.start, length: pos.length))
                    } else {
                        rows.append(RowInfo(task: task, y: y, start: pos.start, length: pos.length))
                        y += barHeight + rowSpacing
                    }
                }
            }
            sectionInfos.append(SectionInfo(name: section.name, headerY: headerY, rows: rows, markers: markers))
        }

        let bottomAxisY = y
        y += axisHeight
        // Vertical marker names draw under the axis instead of overlapping
        // the chart body, so reserve a band for them when any exist.
        let hasVerticalMarkers = sectionInfos.contains { !$0.markers.isEmpty }
        if hasVerticalMarkers {
            y += markerLabelBand
        }
        let totalHeight = y + leftMargin

        let size = CGSize(width: totalWidth, height: totalHeight)
        let capturedSections = sectionInfos

        let customDraw: @Sendable (CGContext, CGPoint) -> Void = { ctx, origin in
            let ox = origin.x
            let oy = origin.y
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let smallFont = CTFontCreateWithName("Helvetica" as CFString, smallFontSize, nil)

            func text(_ string: String, at point: CGPoint, small: Bool, color: CGColor) {
                MermaidTextUtils.drawText(
                    string,
                    at: point,
                    font: small ? smallFont : font,
                    fontSize: small ? smallFontSize : fontSize,
                    foregroundColor: color,
                    in: ctx
                )
            }

            // Title.
            if let title = diagram.title {
                text(title, at: CGPoint(x: ox + leftMargin, y: oy + leftMargin), small: false, color: theme.foreground)
            }

            // Grid lines, one stroke each: Core Graphics rasterizes a path
            // over its whole bounding box, and one path holding every line
            // would span the full chart.
            let gridTop = topAxisY ?? chartBodyTop
            ctx.saveGState()
            ctx.setStrokeColor(theme.comment.copy(alpha: 0.35) ?? theme.comment)
            ctx.setLineWidth(0.5)
            for unit in stride(from: 0, through: timelineUnits, by: gridStep) {
                let x = ox + chartLeft + CGFloat(unit) * unitWidth
                ctx.move(to: CGPoint(x: x, y: oy + gridTop))
                ctx.addLine(to: CGPoint(x: x, y: oy + bottomAxisY))
                ctx.strokePath()
            }
            ctx.restoreGState()

            // Axis labels. Mermaid's `topAxis` adds a second axis at the top;
            // the bottom axis remains available for scanability.
            func drawAxisLabels(at axisY: CGFloat) {
                for unit in stride(from: 0, through: timelineUnits, by: axisStep) {
                    let x = ox + chartLeft + CGFloat(unit) * unitWidth
                    text("\(unit)", at: CGPoint(x: x, y: oy + axisY + 2), small: true, color: theme.foregroundDim)
                }
            }
            if let topAxisY {
                drawAxisLabels(at: topAxisY)
            }
            drawAxisLabels(at: bottomAxisY)

            // Vertical markers do not consume a row in Mermaid.
            for marker in capturedSections.flatMap(\.markers) {
                let markerX = ox + chartLeft + CGFloat(marker.start) * unitWidth
                ctx.saveGState()
                ctx.setStrokeColor(theme.accentOrange.copy(alpha: 0.85) ?? theme.accentOrange)
                ctx.setLineWidth(1.5)
                ctx.move(to: CGPoint(x: markerX, y: oy + chartBodyTop))
                ctx.addLine(to: CGPoint(x: markerX, y: oy + bottomAxisY))
                ctx.strokePath()
                ctx.restoreGState()

                // Name under the chart, centered on the marker line and
                // clamped so it stays within the drawing bounds.
                let nameWidth = MermaidTextUtils.lineWidth(marker.task.name, font: smallFont, fontSize: smallFontSize)
                let minX = ox + leftMargin
                let maxX = max(minX, ox + totalWidth - rightMargin - nameWidth)
                let nameX = min(max(markerX - nameWidth / 2, minX), maxX)
                text(
                    marker.task.name,
                    at: CGPoint(x: nameX, y: oy + bottomAxisY + axisHeight + 2),
                    small: true,
                    color: theme.accentOrange
                )
            }

            // Sections and tasks.
            for section in capturedSections {
                text(
                    section.name,
                    at: CGPoint(x: ox + leftMargin, y: oy + section.headerY + 4),
                    small: false,
                    color: theme.foreground
                )

                // Section separator line.
                ctx.saveGState()
                ctx.setStrokeColor(theme.comment.copy(alpha: 0.25) ?? theme.comment)
                ctx.setLineWidth(0.5)
                ctx.move(to: CGPoint(x: ox + leftMargin, y: oy + section.headerY))
                ctx.addLine(to: CGPoint(
                    x: ox + totalWidth - rightMargin,
                    y: oy + section.headerY
                ))
                ctx.strokePath()
                ctx.restoreGState()

                for row in section.rows {
                    let task = row.task

                    // Task label in the task column, unless names sit on
                    // their bars (compact rows, or a fitted chart too narrow
                    // for a label column).
                    if !labelsOnBars {
                        text(
                            task.name,
                            at: CGPoint(x: ox + taskLabelX, y: oy + row.y + 2),
                            small: true,
                            color: theme.foregroundDim
                        )
                    }

                    // Task bar or milestone.
                    let barX = ox + chartLeft + CGFloat(row.start) * unitWidth
                    let barW = max(CGFloat(max(row.length, 1)) * unitWidth, minBarWidth)

                    if task.status == .milestone {
                        // Diamond marker.
                        let cx = barX
                        let cy = oy + row.y + barHeight / 2
                        let s = milestoneSize / 2
                        let diamond = CGMutablePath()
                        diamond.move(to: CGPoint(x: cx, y: cy - s))
                        diamond.addLine(to: CGPoint(x: cx + s, y: cy))
                        diamond.addLine(to: CGPoint(x: cx, y: cy + s))
                        diamond.addLine(to: CGPoint(x: cx - s, y: cy))
                        diamond.closeSubpath()
                        ctx.saveGState()
                        ctx.setFillColor(theme.accentPurple)
                        ctx.addPath(diamond)
                        ctx.fillPath()
                        ctx.restoreGState()
                    } else {
                        let barRect = CGRect(
                            x: barX,
                            y: oy + row.y,
                            width: barW,
                            height: barHeight
                        )
                        let barColor = barColor(for: task.status, theme: theme)
                        ctx.saveGState()
                        ctx.setFillColor(barColor)
                        let corner = min(4, barW / 2)
                        let rounded = CGPath(
                            roundedRect: barRect,
                            cornerWidth: corner,
                            cornerHeight: corner,
                            transform: nil
                        )
                        ctx.addPath(rounded)
                        ctx.fillPath()
                        ctx.restoreGState()
                    }

                    if labelsOnBars {
                        // Diamonds are markers, not bars: place against the
                        // diamond centered on `barX` so labels never try to
                        // center inside it or cover it.
                        let isMilestone = task.status == .milestone
                        let labelWidth = MermaidTextUtils.lineWidth(task.name, font: smallFont, fontSize: smallFontSize)
                        let placement = Self.compactLabelPlacement(
                            labelWidth: labelWidth,
                            barX: isMilestone ? barX - milestoneSize / 2 : barX,
                            barWidth: isMilestone ? milestoneSize : barW,
                            chartLeft: ox + chartLeft,
                            chartRight: ox + labelRight
                        )
                        text(
                            placement.width < labelWidth
                                ? Self.truncated(task.name, toWidth: placement.width, font: smallFont, fontSize: smallFontSize)
                                : task.name,
                            at: CGPoint(x: placement.x, y: oy + row.y + 3),
                            small: true,
                            color: theme.foreground
                        )
                    }
                }
            }
        }

        return MermaidFlowchartRenderer.FlowchartLayout(
            graphResult: GraphLayoutResult(
                nodePositions: [:], edgePaths: [], totalSize: .zero
            ),
            flowchart: .empty,
            subgraphFrames: [:],
            nodeLabels: [:],
            nodeShapes: [:],
            edgeLabels: [:],
            edgeStyles: [:],
            edgeIds: [:],
            edgeKeys: [],
            edgeStyleDirectives: [:],
            edgeEndpointSubgraphs: [:],
            classDefs: [:],
            styleDirectives: [:],
            fontSize: fontSize,
            theme: theme,
            isPlaceholder: false,
            placeholderText: nil,
            customDraw: customDraw,
            customSize: size
        )
    }

    /// `text` cut at the end with an ellipsis to fit `width`; empty when not
    /// even the ellipsis fits.
    private static func truncated(_ text: String, toWidth width: CGFloat, font: CTFont, fontSize: CGFloat) -> String {
        let ellipsis = "…"
        guard MermaidTextUtils.lineWidth(ellipsis, font: font, fontSize: fontSize) <= width else { return "" }
        let characters = Array(text)
        func candidate(_ count: Int) -> String {
            String(characters[..<count]).trimmingCharacters(in: .whitespaces) + ellipsis
        }
        // Longest prefix whose truncated form fits.
        var low = 0
        var high = characters.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if MermaidTextUtils.lineWidth(candidate(mid), font: font, fontSize: fontSize) <= width {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low == 0 ? ellipsis : candidate(low)
    }

    /// Smallest 1, 2, 5 × 10ⁿ unit step that is at least `units` long.
    private static func niceStep(atLeast units: CGFloat) -> Int {
        var magnitude = 1
        while true {
            for factor in [1, 2, 5] where CGFloat(factor * magnitude) >= units {
                return factor * magnitude
            }
            magnitude *= 10
        }
    }

    private static func firstAvailableCompactRow(start: Int, rowEnds: [Int]) -> Int {
        rowEnds.firstIndex { start >= $0 } ?? rowEnds.count
    }

    // MARK: - Task position resolution

    /// Abstract position for a task on the timeline.
    private struct TaskPosition {
        let start: Int
        let length: Int
    }

    /// Resolve all tasks to sequential (start, length) positions.
    ///
    /// Tasks with `after` dependencies start after their reference.
    /// Tasks with no dependency start at the current cursor position.
    /// Duration strings like `3d` parse to integer units. Dates are
    /// assigned positions based on order of appearance.
    private static func resolveTasks(_ tasks: [GanttTask]) -> [String: TaskPosition] {
        var positions: [String: TaskPosition] = [:]
        // Map task id/name → index for dependency lookup.
        var idMap: [String: Int] = [:]
        for (i, task) in tasks.enumerated() {
            if let id = task.id {
                idMap[id] = i
            }
            idMap[task.name] = i
        }

        var cursor = 0

        for task in tasks {
            let length = task.status == .vert
                ? 0
                : parseDurationUnits(task.duration) ?? 3 // default 3 units

            var start = cursor
            // Handle one or more `after` dependencies by starting after the latest resolved reference.
            let dependencyEnds = task.afterIds.compactMap { ref -> Int? in
                guard let dep = findPosition(ref, in: positions, tasks: tasks) else { return nil }
                return dep.start + dep.length
            }
            if let maxDependencyEnd = dependencyEnds.max() {
                start = maxDependencyEnd
            } else if let dateStr = task.startDate {
                // Try to use start date to advance cursor if it looks later.
                // Since we don't parse real dates, just keep cursor advancing.
                _ = dateStr
                start = cursor
            }

            let pos = TaskPosition(start: start, length: length)
            if let id = task.id {
                positions[id] = pos
            }
            positions[task.name] = pos
            if task.status != .vert {
                cursor = max(cursor, start + length)
            }
        }

        return positions
    }

    private static func findPosition(
        _ ref: String,
        in positions: [String: TaskPosition],
        tasks: [GanttTask]
    ) -> TaskPosition? {
        if let pos = positions[ref] { return pos }
        // Try matching by task name.
        for task in tasks {
            if task.name == ref, let pos = positions[task.name] {
                return pos
            }
        }
        return nil
    }

    /// Parse Mermaid durations like `500ms`, `30s`, `4h`, `1.5d`, `2w`, `1M`, `1y` to abstract day units.
    private static func parseDurationUnits(_ duration: String?) -> Int? {
        guard let duration, !duration.isEmpty else { return nil }
        let trimmed = duration.trimmingCharacters(in: .whitespaces)
        guard let suffixStart = trimmed.firstIndex(where: { !$0.isNumber && $0 != "." }) else {
            return Int(trimmed)
        }

        let numberText = String(trimmed[..<suffixStart])
        let suffix = String(trimmed[suffixStart...])
        guard let value = Double(numberText) else { return nil }

        let units: Double
        switch suffix {
        case "ms", "s", "m": units = 1
        case "h": units = max(value / 8, 1)
        case "d": units = value
        case "w": units = value * 5
        case "M": units = value * 20
        case "y": units = value * 240
        default: return nil
        }
        return max(Int(ceil(units)), 0)
    }

    // MARK: - Colors

    private static func barColor(
        for status: GanttTaskStatus,
        theme: RenderTheme
    ) -> CGColor {
        switch status {
        case .normal:
            return theme.foregroundDim.copy(alpha: 0.28) ?? theme.foregroundDim
        case .active:
            return theme.accentBlue.copy(alpha: 0.78) ?? theme.accentBlue
        case .done:
            return theme.accentGreen.copy(alpha: 0.56) ?? theme.accentGreen
        case .critical:
            return theme.accentRed.copy(alpha: 0.78) ?? theme.accentRed
        case .milestone:
            // Milestones use diamond marker, not bars.
            return theme.accentPurple
        case .vert:
            return theme.foregroundDim.copy(alpha: 0.4) ?? theme.foregroundDim
        }
    }
}
