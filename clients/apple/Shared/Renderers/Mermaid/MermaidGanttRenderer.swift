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
    private static let pixelsPerUnit: CGFloat = 30
    private static let milestoneSize: CGFloat = 14

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

        // Dimensions.
        let timelineWidth = CGFloat(timelineUnits) * pixelsPerUnit
        let chartLeft = leftMargin + sectionLabelWidth + taskLabelWidth
        let totalWidth = chartLeft + timelineWidth + rightMargin

        var y: CGFloat = leftMargin

        // Title.
        if diagram.title != nil {
            y += titleHeight
        }

        // Axis.
        let axisY = y
        y += axisHeight

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
        }

        var sectionInfos: [SectionInfo] = []
        for section in diagram.sections {
            let headerY = y
            y += sectionHeaderHeight

            var rows: [RowInfo] = []
            for task in section.tasks {
                let pos = resolved[task.name] ?? TaskPosition(start: 0, length: 1)
                rows.append(RowInfo(task: task, y: y, start: pos.start, length: pos.length))
                y += barHeight + rowSpacing
            }
            sectionInfos.append(SectionInfo(name: section.name, headerY: headerY, rows: rows))
        }

        let totalHeight = y + leftMargin

        let size = CGSize(width: totalWidth, height: totalHeight)
        let capturedSections = sectionInfos

        let customDraw: @Sendable (CGContext, CGPoint) -> Void = { ctx, origin in
            let ox = origin.x
            let oy = origin.y

            // Background.
            ctx.setFillColor(theme.background)
            ctx.fill(CGRect(origin: origin, size: size))

            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let smallFont = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.85, nil)

            // Title.
            if let title = diagram.title {
                let titleLine = makeLine(title, font: font, color: theme.foreground)
                drawCTLine(
                    titleLine,
                    at: CGPoint(x: ox + leftMargin, y: oy + leftMargin),
                    fontSize: fontSize,
                    in: ctx
                )
            }

            // Grid lines.
            ctx.saveGState()
            ctx.setStrokeColor(CGColor(gray: 0.3, alpha: 0.4))
            ctx.setLineWidth(0.5)
            for unit in 0...timelineUnits {
                let x = ox + chartLeft + CGFloat(unit) * pixelsPerUnit
                ctx.move(to: CGPoint(x: x, y: oy + axisY))
                ctx.addLine(to: CGPoint(x: x, y: oy + totalHeight - leftMargin))
            }
            ctx.strokePath()
            ctx.restoreGState()

            // Axis labels.
            let axisStep = max(1, timelineUnits / 10)
            for unit in stride(from: 0, through: timelineUnits, by: axisStep) {
                let x = ox + chartLeft + CGFloat(unit) * pixelsPerUnit
                let label = "\(unit)"
                let line = makeLine(label, font: smallFont, color: theme.foregroundDim)
                drawCTLine(
                    line,
                    at: CGPoint(x: x, y: oy + axisY + 2),
                    fontSize: fontSize * 0.85,
                    in: ctx
                )
            }

            // Sections and tasks.
            for section in capturedSections {
                // Section label.
                let sectionLine = makeLine(
                    section.name, font: font, color: theme.foreground
                )
                drawCTLine(
                    sectionLine,
                    at: CGPoint(
                        x: ox + leftMargin,
                        y: oy + section.headerY + 4
                    ),
                    fontSize: fontSize,
                    in: ctx
                )

                // Section separator line.
                ctx.saveGState()
                ctx.setStrokeColor(CGColor(gray: 0.3, alpha: 0.3))
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

                    // Task label.
                    let taskLine = makeLine(
                        task.name, font: smallFont, color: theme.foregroundDim
                    )
                    drawCTLine(
                        taskLine,
                        at: CGPoint(
                            x: ox + leftMargin + sectionLabelWidth,
                            y: oy + row.y + 2
                        ),
                        fontSize: fontSize * 0.85,
                        in: ctx
                    )

                    // Task bar or milestone.
                    let barX = ox + chartLeft + CGFloat(row.start) * pixelsPerUnit
                    let barW = CGFloat(max(row.length, 1)) * pixelsPerUnit

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
                        ctx.setFillColor(theme.keyword)
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
                        let rounded = CGPath(
                            roundedRect: barRect,
                            cornerWidth: 4,
                            cornerHeight: 4,
                            transform: nil
                        )
                        ctx.addPath(rounded)
                        ctx.fillPath()
                        ctx.restoreGState()
                    }
                }
            }
        }

        return MermaidFlowchartRenderer.FlowchartLayout(
            graphResult: GraphLayoutResult(
                nodePositions: [:], edgePaths: [], totalSize: .zero
            ),
            flowchart: .empty,
            nodeLabels: [:],
            nodeShapes: [:],
            edgeLabels: [:],
            edgeStyles: [:],
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
            let length = parseDurationUnits(task.duration) ?? 3 // default 3 units

            var start = cursor
            // Handle "after" dependency.
            if let afterRef = task.afterId,
               let dep = findPosition(afterRef, in: positions, tasks: tasks)
            {
                start = dep.start + dep.length
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
            cursor = max(cursor, start + length)
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

    /// Parse duration like `3d`, `1w`, `2h` to abstract units.
    /// `d` = 1, `w` = 5, `h` = 0.125 (round up to 1), `m` = 1 (months treated as ~20d).
    private static func parseDurationUnits(_ duration: String?) -> Int? {
        guard let duration, !duration.isEmpty else { return nil }
        let lower = duration.lowercased()

        guard let numEnd = lower.lastIndex(where: \.isNumber) else { return nil }
        let numStr = String(lower[lower.startIndex...numEnd])
        let suffix = String(lower[lower.index(after: numEnd)...])

        guard let num = Int(numStr) else { return nil }
        switch suffix {
        case "d": return max(num, 0)
        case "w": return num * 5
        case "h": return max(num / 8, 1)
        case "m": return num * 20
        case "s": return 1
        default: return num
        }
    }

    // MARK: - Colors

    private static func barColor(
        for status: GanttTaskStatus,
        theme: RenderTheme
    ) -> CGColor {
        switch status {
        case .normal:
            return CGColor(
                red: 0.5, green: 0.6, blue: 0.7, alpha: 0.4
            )
        case .active:
            return CGColor(
                red: 0.25, green: 0.55, blue: 0.9, alpha: 0.8
            )
        case .done:
            return CGColor(
                red: 0.35, green: 0.65, blue: 0.35, alpha: 0.5
            )
        case .critical:
            return CGColor(
                red: 0.9, green: 0.35, blue: 0.25, alpha: 0.8
            )
        case .milestone:
            // Milestones use diamond marker, not bars.
            return theme.keyword
        }
    }

    // MARK: - Text helpers

    private static func makeLine(
        _ text: String,
        font: CTFont,
        color: CGColor
    ) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        return CTLineCreateWithAttributedString(attrString)
    }

    /// Draw a CTLine at (x, y) in UIKit Y-down coordinates.
    ///
    /// CTLineDraw expects CG coords (Y-up). This flips locally so text
    /// renders right-side-up in the UIKit coordinate space.
    private static func drawCTLine(
        _ line: CTLine,
        at point: CGPoint,
        fontSize: CGFloat,
        in ctx: CGContext
    ) {
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y + fontSize)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
