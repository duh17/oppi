import CoreGraphics
import CoreText
import Foundation

/// Renderer for Mermaid `journey` diagrams.
///
/// Phone-first: sections share `maxWidth`, tasks are stacked cards with a
/// 1...5 score bar. Actors cycle theme accents. No page fill.
enum MermaidJourneyRenderer {

    private static let outerMargin: CGFloat = 16
    private static let titleGap: CGFloat = 8
    private static let sectionGap: CGFloat = 10
    private static let taskGap: CGFloat = 6
    private static let scoreBarHeight: CGFloat = 6
    private static let corner: CGFloat = 6

    nonisolated static func layout(
        _ diagram: JourneyDiagram,
        configuration: RenderConfiguration
    ) -> MermaidFlowchartRenderer.FlowchartLayout {
        if let error = diagram.error {
            return MermaidFlowchartRenderer().placeholderLayout(
                text: error,
                configuration: configuration
            )
        }
        let tasksExist = diagram.sections.contains { !$0.tasks.isEmpty }
        guard tasksExist || diagram.title != nil else {
            return MermaidFlowchartRenderer().placeholderLayout(
                text: "Empty journey",
                configuration: configuration
            )
        }

        let theme = configuration.theme
        let fontSize = configuration.fontSize
        let maxWidth = max(configuration.maxWidth, 1)
        let contentWidth = max(maxWidth - outerMargin * 2, 40)
        let titleFont = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let sectionFont = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.95, nil)
        let taskFont = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.85, nil)

        var y = outerMargin
        var nodePositions: [String: CGRect] = [:]
        var nodeLabels: [String: String] = [:]

        var titleText: String?
        var titleHeight: CGFloat = 0
        if let title = diagram.title, !title.isEmpty {
            let wrapped = MermaidTextUtils.wrapText(
                title, maxWidth: contentWidth, font: titleFont, fontSize: fontSize
            )
            titleText = wrapped
            titleHeight = MermaidTextUtils.measureText(
                wrapped, font: titleFont, fontSize: fontSize
            ).height
            nodeLabels["$title"] = wrapped
            nodePositions["title"] = CGRect(
                x: outerMargin, y: y, width: contentWidth, height: titleHeight
            )
            y += titleHeight + titleGap
        }

        let sectionCount = max(diagram.sections.count, 1)
        let sectionWidth = max(
            (contentWidth - sectionGap * CGFloat(max(sectionCount - 1, 0))) / CGFloat(sectionCount),
            48
        )

        struct PreparedTask {
            let name: String
            let score: Int
            let actors: String
            let height: CGFloat
        }

        var prepared: [[PreparedTask]] = []
        var maxSectionHeight: CGFloat = 0
        for (s, section) in diagram.sections.enumerated() {
            let header = MermaidTextUtils.wrapText(
                section.name, maxWidth: sectionWidth - 8, font: sectionFont, fontSize: fontSize * 0.95
            )
            nodeLabels["$section-\(s)"] = header
            var column: [PreparedTask] = []
            var columnHeight = MermaidTextUtils.measureText(
                header, font: sectionFont, fontSize: fontSize * 0.95
            ).height + 8
            for (t, task) in section.tasks.enumerated() {
                let name = MermaidTextUtils.wrapText(
                    task.name, maxWidth: sectionWidth - 12, font: taskFont, fontSize: fontSize * 0.85
                )
                let actors = task.actors.joined(separator: ", ")
                let nameH = MermaidTextUtils.measureText(
                    name, font: taskFont, fontSize: fontSize * 0.85
                ).height
                let actorH: CGFloat = actors.isEmpty ? 0 : fontSize * 0.8
                let height = 8 + nameH + 4 + scoreBarHeight + (actorH == 0 ? 0 : 4 + actorH) + 8
                column.append(PreparedTask(name: name, score: task.score, actors: actors, height: height))
                nodeLabels["$task-\(s)-\(t)"] = name
                columnHeight += height + taskGap
            }
            prepared.append(column)
            maxSectionHeight = max(maxSectionHeight, columnHeight)
        }

        let actors = uniqueActors(diagram)
        let legendHeight: CGFloat = actors.isEmpty ? 0 : fontSize + 10
        let totalHeight = y + maxSectionHeight + (legendHeight == 0 ? 0 : legendHeight + 8) + outerMargin
        let size = CGSize(width: min(maxWidth, outerMargin * 2 + contentWidth), height: totalHeight)

        let sectionTop = y
        for (s, section) in diagram.sections.enumerated() {
            let x = outerMargin + CGFloat(s) * (sectionWidth + sectionGap)
            var ty = sectionTop
            let header = nodeLabels["$section-\(s)"] ?? section.name
            let headerH = MermaidTextUtils.measureText(
                header, font: sectionFont, fontSize: fontSize * 0.95
            ).height
            nodePositions["section-\(s)"] = CGRect(x: x, y: ty, width: sectionWidth, height: headerH)
            ty += headerH + 8
            for (t, task) in prepared[s].enumerated() {
                nodePositions["task-\(s)-\(t)"] = CGRect(
                    x: x, y: ty, width: sectionWidth, height: task.height
                )
                ty += task.height + taskGap
            }
        }

        if !actors.isEmpty {
            nodePositions["legend"] = CGRect(
                x: outerMargin,
                y: size.height - outerMargin - legendHeight,
                width: contentWidth,
                height: legendHeight
            )
        }

        let capturedSections = diagram.sections
        let capturedPrepared = prepared
        let capturedTitle = titleText
        let capturedActors = actors
        let capturedSectionWidth = sectionWidth
        let capturedSectionTop = sectionTop

        let draw: @Sendable (CGContext, CGPoint) -> Void = { ctx, origin in
            let ox = origin.x
            let oy = origin.y
            if let title = capturedTitle {
                MermaidTextUtils.drawText(
                    title,
                    at: CGPoint(x: ox + outerMargin, y: oy + outerMargin),
                    width: contentWidth,
                    font: CTFontCreateWithName("Helvetica" as CFString, fontSize, nil),
                    fontSize: fontSize,
                    foregroundColor: theme.foreground,
                    alignment: .left,
                    in: ctx
                )
            }

            let colors = actorColors(theme)
            for (s, section) in capturedSections.enumerated() {
                let x = ox + outerMargin + CGFloat(s) * (capturedSectionWidth + sectionGap)
                var ty = oy + capturedSectionTop
                let header = section.name
                MermaidTextUtils.drawText(
                    header,
                    at: CGPoint(x: x + 4, y: ty),
                    width: capturedSectionWidth - 8,
                    font: CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.95, nil),
                    fontSize: fontSize * 0.95,
                    foregroundColor: theme.foreground,
                    alignment: .left,
                    in: ctx
                )
                ty += MermaidTextUtils.measureText(
                    header,
                    font: CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.95, nil),
                    fontSize: fontSize * 0.95
                ).height + 8

                for (t, task) in capturedPrepared[s].enumerated() {
                    let rect = CGRect(x: x, y: ty, width: capturedSectionWidth, height: task.height)
                    let fill = colors[t % colors.count].copy(alpha: 0.16) ?? colors[t % colors.count]
                    ctx.setFillColor(fill)
                    ctx.addPath(CGPath(
                        roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil
                    ))
                    ctx.fillPath()
                    ctx.setStrokeColor(theme.foregroundDim.copy(alpha: 0.35) ?? theme.foregroundDim)
                    ctx.setLineWidth(1)
                    ctx.addPath(CGPath(
                        roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil
                    ))
                    ctx.strokePath()

                    var innerY = ty + 8
                    MermaidTextUtils.drawText(
                        task.name,
                        at: CGPoint(x: x + 6, y: innerY),
                        width: capturedSectionWidth - 12,
                        font: CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.85, nil),
                        fontSize: fontSize * 0.85,
                        foregroundColor: theme.foreground,
                        alignment: .left,
                        in: ctx
                    )
                    innerY += MermaidTextUtils.measureText(
                        task.name,
                        font: CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.85, nil),
                        fontSize: fontSize * 0.85
                    ).height + 4

                    let barWidth = capturedSectionWidth - 12
                    let unit = barWidth / 5
                    let filled = unit * CGFloat(max(1, min(task.score, 5)))
                    let bar = CGRect(x: x + 6, y: innerY, width: filled, height: scoreBarHeight)
                    ctx.setFillColor(colors[t % colors.count])
                    ctx.addPath(CGPath(
                        roundedRect: bar, cornerWidth: 2, cornerHeight: 2, transform: nil
                    ))
                    ctx.fillPath()
                    innerY += scoreBarHeight + 4
                    if !task.actors.isEmpty {
                        MermaidTextUtils.drawText(
                            task.actors,
                            at: CGPoint(x: x + 6, y: innerY),
                            width: capturedSectionWidth - 12,
                            font: CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.75, nil),
                            fontSize: fontSize * 0.75,
                            foregroundColor: theme.foregroundDim,
                            alignment: .left,
                            in: ctx
                        )
                    }
                    ty += task.height + taskGap
                }
            }

            if !capturedActors.isEmpty {
                var lx = ox + outerMargin
                let ly = oy + size.height - outerMargin - legendHeight + 2
                for (i, actor) in capturedActors.enumerated() {
                    let swatch = CGRect(x: lx, y: ly + 2, width: 8, height: 8)
                    ctx.setFillColor(colors[i % colors.count])
                    ctx.fillEllipse(in: swatch)
                    let labelW = MermaidTextUtils.measureText(
                        actor,
                        font: CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.75, nil),
                        fontSize: fontSize * 0.75
                    ).width
                    MermaidTextUtils.drawText(
                        actor,
                        at: CGPoint(x: swatch.maxX + 4, y: ly),
                        font: CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.75, nil),
                        fontSize: fontSize * 0.75,
                        foregroundColor: theme.foregroundDim,
                        in: ctx
                    )
                    lx += 8 + 4 + labelW + 12
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

    private static func uniqueActors(_ diagram: JourneyDiagram) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for section in diagram.sections {
            for task in section.tasks {
                for actor in task.actors where seen.insert(actor).inserted {
                    result.append(actor)
                }
            }
        }
        return result
    }

    private static func actorColors(_ theme: RenderTheme) -> [CGColor] {
        theme.diagramAccents
    }
}
