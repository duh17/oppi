import CoreGraphics
import CoreText
import Foundation

/// Renderer for Mermaid `kanban`.
///
/// Columns share `maxWidth`. Task cards show description, assigned,
/// ticket (parsed URL is stored, tapping stays inert), and official
/// priority. Leftover priority values fail visibly.
enum MermaidKanbanRenderer {

    private static let outerMargin: CGFloat = 12
    private static let columnGap: CGFloat = 8
    private static let cardGap: CGFloat = 6
    private static let corner: CGFloat = 6

    nonisolated static func layout(
        _ diagram: KanbanDiagram,
        configuration: RenderConfiguration
    ) -> MermaidFlowchartRenderer.FlowchartLayout {
        if let leftover = leftoverPriority(diagram) {
            return MermaidFlowchartRenderer().placeholderLayout(
                text: "Unsupported kanban priority: \(leftover)",
                configuration: configuration
            )
        }
        guard !diagram.columns.isEmpty else {
            return MermaidFlowchartRenderer().placeholderLayout(
                text: "Empty kanban",
                configuration: configuration
            )
        }

        let theme = configuration.theme
        let fontSize = configuration.fontSize
        let maxWidth = max(configuration.maxWidth, 1)
        let titleFont = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.95, nil)
        let bodyFont = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.8, nil)
        let metaFont = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.7, nil)

        let columnCount = max(diagram.columns.count, 1)
        let contentWidth = max(maxWidth - outerMargin * 2, 80)
        let columnWidth = max(
            (contentWidth - columnGap * CGFloat(columnCount - 1)) / CGFloat(columnCount),
            56
        )

        var nodePositions: [String: CGRect] = [:]
        var nodeLabels: [String: String] = [:]
        var columnHeights: [CGFloat] = []

        for (c, column) in diagram.columns.enumerated() {
            let x = outerMargin + CGFloat(c) * (columnWidth + columnGap)
            let title = MermaidTextUtils.wrapText(
                column.title, maxWidth: columnWidth - 8, font: titleFont, fontSize: fontSize * 0.95
            )
            let titleH = MermaidTextUtils.measureText(
                title, font: titleFont, fontSize: fontSize * 0.95
            ).height
            nodeLabels["$column-\(c)"] = title
            nodePositions["column-\(c)"] = CGRect(
                x: x, y: outerMargin, width: columnWidth, height: titleH + 8
            )
            nodePositions["column-\(c)-text"] = CGRect(
                x: x + 4, y: outerMargin + 4, width: columnWidth - 8, height: titleH
            )
            var y = outerMargin + titleH + 12
            for (t, task) in column.tasks.enumerated() {
                let desc = MermaidTextUtils.wrapText(
                    task.description, maxWidth: columnWidth - 12, font: bodyFont, fontSize: fontSize * 0.8
                )
                let descH = MermaidTextUtils.measureText(
                    desc, font: bodyFont, fontSize: fontSize * 0.8
                ).height
                var height = 8 + descH
                if task.assigned != nil { height += fontSize * 0.75 }
                if task.ticket != nil { height += fontSize * 0.75 }
                if task.priority != nil { height += fontSize * 0.7 }
                height += 8
                nodePositions["task-\(c)-\(t)"] = CGRect(
                    x: x, y: y, width: columnWidth, height: height
                )
                nodePositions["task-\(c)-\(t)-text"] = CGRect(
                    x: x + 6, y: y + 6, width: columnWidth - 12, height: descH
                )
                nodeLabels["$task-\(c)-\(t)"] = desc
                if let ticket = task.ticket {
                    nodeLabels["$ticket-\(c)-\(t)"] = ticket
                }
                y += height + cardGap
            }
            columnHeights.append(y)
        }

        let canvasHeight = (columnHeights.max() ?? outerMargin) + outerMargin
        let size = CGSize(width: min(maxWidth, outerMargin * 2 + contentWidth), height: canvasHeight)
        let capturedColumns = diagram.columns
        let capturedPositions = nodePositions
        let capturedLabels = nodeLabels

        let draw: @Sendable (CGContext, CGPoint) -> Void = { ctx, origin in
            let ox = origin.x
            let oy = origin.y
            for (c, column) in capturedColumns.enumerated() {
                let x = ox + outerMargin + CGFloat(c) * (columnWidth + columnGap)
                let header = capturedPositions["column-\(c)"]?.offsetBy(dx: ox, dy: oy)
                    ?? CGRect(x: x, y: oy + outerMargin, width: columnWidth, height: 20)
                ctx.setFillColor(theme.foregroundDim.copy(alpha: 0.12) ?? theme.foregroundDim)
                ctx.addPath(CGPath(
                    roundedRect: header, cornerWidth: corner, cornerHeight: corner, transform: nil
                ))
                ctx.fillPath()
                let headerText = capturedLabels["$column-\(c)"] ?? column.title
                MermaidTextUtils.drawText(
                    headerText,
                    at: CGPoint(x: header.minX + 4, y: header.minY + 4),
                    width: columnWidth - 8,
                    font: CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.95, nil),
                    fontSize: fontSize * 0.95,
                    foregroundColor: theme.foreground,
                    alignment: .left,
                    in: ctx
                )

                for (t, task) in column.tasks.enumerated() {
                    guard let frame = capturedPositions["task-\(c)-\(t)"] else { continue }
                    let rect = frame.offsetBy(dx: ox, dy: oy)
                    ctx.setFillColor(theme.foregroundDim.copy(alpha: 0.08) ?? theme.foregroundDim)
                    ctx.addPath(CGPath(
                        roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil
                    ))
                    ctx.fillPath()
                    ctx.setStrokeColor(priorityColor(task.priority, theme: theme).copy(alpha: 0.85)
                        ?? theme.foregroundDim)
                    ctx.setLineWidth(task.priority == nil ? 1 : 2)
                    ctx.addPath(CGPath(
                        roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil
                    ))
                    ctx.strokePath()

                    let desc = capturedLabels["$task-\(c)-\(t)"] ?? task.description
                    var innerY = rect.minY + 6
                    MermaidTextUtils.drawText(
                        desc,
                        at: CGPoint(x: rect.minX + 6, y: innerY),
                        width: columnWidth - 12,
                        font: CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.8, nil),
                        fontSize: fontSize * 0.8,
                        foregroundColor: theme.foreground,
                        alignment: .left,
                        in: ctx
                    )
                    innerY += MermaidTextUtils.measureText(
                        desc,
                        font: CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.8, nil),
                        fontSize: fontSize * 0.8
                    ).height + 2
                    if let assigned = task.assigned {
                        MermaidTextUtils.drawText(
                            assigned,
                            at: CGPoint(x: rect.minX + 6, y: innerY),
                            width: columnWidth - 12,
                            font: CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.7, nil),
                            fontSize: fontSize * 0.7,
                            foregroundColor: theme.foregroundDim,
                            in: ctx
                        )
                        innerY += fontSize * 0.75
                    }
                    if let ticket = task.ticket {
                        MermaidTextUtils.drawText(
                            ticket,
                            at: CGPoint(x: rect.minX + 6, y: innerY),
                            width: columnWidth - 12,
                            font: CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.7, nil),
                            fontSize: fontSize * 0.7,
                            foregroundColor: theme.link,
                            in: ctx
                        )
                    }
                }
            }
        }

        return .custom(
            size: size,
            nodePositions: nodePositions,
            nodeLabels: nodeLabels,
            configuration: configuration,
            draw: draw
        )
    }

    private static func leftoverPriority(_ diagram: KanbanDiagram) -> String? {
        for column in diagram.columns {
            for task in column.tasks {
                if case .unsupported(let value) = task.priority {
                    return value
                }
            }
        }
        return nil
    }

    private static func priorityColor(_ priority: KanbanPriority?, theme: RenderTheme) -> CGColor {
        switch priority {
        case .veryHigh: return theme.accentRed
        case .high: return theme.accentOrange
        case .low: return theme.accentBlue
        case .veryLow: return theme.accentCyan
        case .unsupported, nil: return theme.foregroundDim
        }
    }
}
