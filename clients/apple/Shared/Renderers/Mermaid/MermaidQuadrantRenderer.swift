import CoreGraphics
import CoreText
import Foundation

/// Renderer for Mermaid `quadrantChart`.
///
/// Spec: https://mermaid.js.org/syntax/quadrantChart.html
///
/// Empty charts put axis + quadrant labels in the center of each
/// respective quadrant and keep the x-axis on top. Populated charts
/// move the x-axis to the bottom and pin quadrant labels to the top
/// of each quadrant. Fills are theme accents at low alpha — never a
/// page background — so canvas corners stay transparent.
enum MermaidQuadrantRenderer {

    private static let outerMargin: CGFloat = 16
    private static let titleGap: CGFloat = 8
    private static let axisGap: CGFloat = 6
    private static let pointRadius: CGFloat = 5
    private static let pointTextPadding: CGFloat = 5

    nonisolated static func layout(
        _ diagram: QuadrantChartDiagram,
        configuration: RenderConfiguration
    ) -> MermaidFlowchartRenderer.FlowchartLayout {
        guard !diagram.isEmpty else {
            return MermaidFlowchartRenderer().placeholderLayout(
                text: "Empty quadrant chart",
                configuration: configuration
            )
        }

        let theme = configuration.theme
        let fontSize = configuration.fontSize
        let maxWidth = max(configuration.maxWidth, 1)
        let populated = !diagram.points.isEmpty
        let titleFont = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let labelFont = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.9, nil)

        let contentWidth = max(maxWidth - outerMargin * 2, 80)
        var y = outerMargin
        var nodePositions: [String: CGRect] = [:]
        var nodeLabels: [String: String] = [:]

        var titleHeight: CGFloat = 0
        if let title = diagram.title, !title.isEmpty {
            let wrapped = MermaidTextUtils.wrapText(
                title, maxWidth: contentWidth, font: titleFont, fontSize: fontSize
            )
            titleHeight = MermaidTextUtils.measureText(
                wrapped, font: titleFont, fontSize: fontSize
            ).height
            nodeLabels["$title"] = wrapped
            nodePositions["title"] = CGRect(
                x: outerMargin, y: y, width: contentWidth, height: titleHeight
            )
            y += titleHeight + titleGap
        }

        let axisFontSize = fontSize * 0.85
        let axisFont = CTFontCreateWithName("Helvetica" as CFString, axisFontSize, nil)
        let axisHeight = axisFontSize + axisGap
        let yAxisWidth = axisFontSize + axisGap + 8
        let xAxisOnTop = !populated
        if xAxisOnTop, hasXAxis(diagram) {
            nodePositions["x-axis"] = CGRect(
                x: outerMargin + yAxisWidth,
                y: y,
                width: contentWidth - yAxisWidth,
                height: axisHeight
            )
            y += axisHeight
        }

        let plotSide = min(contentWidth - yAxisWidth, maxWidth - outerMargin * 2 - yAxisWidth)
        let plotSize = max(min(plotSide, 280), 140)
        let plot = CGRect(
            x: outerMargin + yAxisWidth,
            y: y,
            width: plotSize,
            height: plotSize
        )
        nodePositions["plot"] = plot
        let halfW = plot.width / 2
        let halfH = plot.height / 2
        let q2 = CGRect(x: plot.minX, y: plot.minY, width: halfW, height: halfH)
        let q1 = CGRect(x: plot.minX + halfW, y: plot.minY, width: halfW, height: halfH)
        let q3 = CGRect(x: plot.minX, y: plot.minY + halfH, width: halfW, height: halfH)
        let q4 = CGRect(x: plot.minX + halfW, y: plot.minY + halfH, width: halfW, height: halfH)
        nodePositions["quadrant-2"] = q2
        nodePositions["quadrant-1"] = q1
        nodePositions["quadrant-3"] = q3
        nodePositions["quadrant-4"] = q4

        func labelFrame(_ text: String?, in rect: CGRect, top: Bool) -> CGRect? {
            guard let text, !text.isEmpty else { return nil }
            let size = MermaidTextUtils.measureText(
                text, font: labelFont, fontSize: fontSize * 0.9
            )
            let x = rect.midX - min(size.width, rect.width - 8) / 2
            let y = top ? rect.minY + 4 : rect.midY - size.height / 2
            return CGRect(
                x: x,
                y: y,
                width: min(size.width, rect.width - 8),
                height: size.height
            )
        }

        if let frame = labelFrame(diagram.quadrant1, in: q1, top: populated) {
            nodePositions["quadrant-1-label"] = frame
            nodeLabels["$quadrant-1"] = diagram.quadrant1
        }
        if let frame = labelFrame(diagram.quadrant2, in: q2, top: populated) {
            nodePositions["quadrant-2-label"] = frame
            nodeLabels["$quadrant-2"] = diagram.quadrant2
        }
        if let frame = labelFrame(diagram.quadrant3, in: q3, top: populated) {
            nodePositions["quadrant-3-label"] = frame
            nodeLabels["$quadrant-3"] = diagram.quadrant3
        }
        if let frame = labelFrame(diagram.quadrant4, in: q4, top: populated) {
            nodePositions["quadrant-4-label"] = frame
            nodeLabels["$quadrant-4"] = diagram.quadrant4
        }

        var bottom = plot.maxY
        if !xAxisOnTop, hasXAxis(diagram) {
            let xAxis = CGRect(x: plot.minX, y: plot.maxY + 2, width: plot.width, height: axisHeight)
            nodePositions["x-axis"] = xAxis
            bottom = xAxis.maxY
        }
        if hasYAxis(diagram) {
            nodePositions["y-axis"] = CGRect(
                x: outerMargin,
                y: plot.minY,
                width: yAxisWidth - 4,
                height: plot.height
            )
            let axisX = outerMargin + 4
            if let topLabel = diagram.yAxisTop, !topLabel.isEmpty {
                let textWidth = MermaidTextUtils.measureText(
                    topLabel, font: axisFont, fontSize: axisFontSize
                ).width
                let frame = rotatedYAxisFrame(
                    textWidth: textWidth,
                    fontSize: axisFontSize,
                    axisX: axisX,
                    centerY: plot.minY + plot.height / 4,
                    minY: plot.minY,
                    maxY: plot.midY
                )
                nodePositions["y-axis-top"] = frame
                nodeLabels["$y-axis-top"] = topLabel
            }
            if let bottomLabel = diagram.yAxisBottom, !bottomLabel.isEmpty {
                let textWidth = MermaidTextUtils.measureText(
                    bottomLabel, font: axisFont, fontSize: axisFontSize
                ).width
                let frame = rotatedYAxisFrame(
                    textWidth: textWidth,
                    fontSize: axisFontSize,
                    axisX: axisX,
                    centerY: plot.maxY - plot.height / 4,
                    minY: plot.midY,
                    maxY: plot.maxY
                )
                nodePositions["y-axis-bottom"] = frame
                nodeLabels["$y-axis-bottom"] = bottomLabel
            }
        }

        let clippedPoints = diagram.points.map { point in
            QuadrantChartPoint(
                name: point.name,
                x: min(max(point.x, 0), 1),
                y: min(max(point.y, 0), 1)
            )
        }
        for (index, point) in clippedPoints.enumerated() {
            let cx = plot.minX + CGFloat(point.x) * plot.width
            let cy = plot.maxY - CGFloat(point.y) * plot.height
            nodePositions["point-\(index)"] = CGRect(
                x: cx - pointRadius,
                y: cy - pointRadius,
                width: pointRadius * 2,
                height: pointRadius * 2
            )
            nodeLabels["$point-\(index)"] = point.name
        }

        let canvasWidth = min(maxWidth, max(plot.maxX, nodePositions["title"]?.maxX ?? 0) + outerMargin)
        let canvasHeight = bottom + outerMargin
        let size = CGSize(width: canvasWidth, height: canvasHeight)

        let capturedTitle = nodeLabels["$title"]
        let capturedDiagram = diagram
        let capturedPoints = clippedPoints
        let capturedPlot = plot
        let capturedQ1 = q1
        let capturedQ2 = q2
        let capturedQ3 = q3
        let capturedQ4 = q4
        let capturedPopulated = populated
        let capturedTitleHeight = titleHeight
        let capturedHasTitle = nodePositions["title"] != nil
        let capturedYTop = nodePositions["y-axis-top"]
        let capturedYBottom = nodePositions["y-axis-bottom"]

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

            func fill(_ rect: CGRect, color: CGColor) {
                ctx.setFillColor(color.copy(alpha: 0.18) ?? color)
                ctx.fill(rect.offsetBy(dx: ox, dy: oy))
            }
            fill(capturedQ1, color: theme.accentBlue)
            fill(capturedQ2, color: theme.accentGreen)
            fill(capturedQ3, color: theme.accentOrange)
            fill(capturedQ4, color: theme.accentPurple)

            ctx.setStrokeColor(theme.foregroundDim.copy(alpha: 0.55) ?? theme.foregroundDim)
            ctx.setLineWidth(2)
            ctx.stroke(capturedPlot.offsetBy(dx: ox, dy: oy))
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: ox + capturedPlot.midX, y: oy + capturedPlot.minY))
            ctx.addLine(to: CGPoint(x: ox + capturedPlot.midX, y: oy + capturedPlot.maxY))
            ctx.move(to: CGPoint(x: ox + capturedPlot.minX, y: oy + capturedPlot.midY))
            ctx.addLine(to: CGPoint(x: ox + capturedPlot.maxX, y: oy + capturedPlot.midY))
            ctx.strokePath()

            let qFont = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.9, nil)
            func drawQuadrantLabel(_ text: String?, in rect: CGRect) {
                guard let text, !text.isEmpty else { return }
                let wrapped = MermaidTextUtils.wrapText(
                    text, maxWidth: rect.width - 8, font: qFont, fontSize: fontSize * 0.9
                )
                let measured = MermaidTextUtils.measureText(
                    wrapped, font: qFont, fontSize: fontSize * 0.9
                )
                let y = capturedPopulated
                    ? rect.minY + 4
                    : rect.midY - measured.height / 2
                MermaidTextUtils.drawText(
                    wrapped,
                    at: CGPoint(x: ox + rect.minX + 4, y: oy + y),
                    width: rect.width - 8,
                    font: qFont,
                    fontSize: fontSize * 0.9,
                    foregroundColor: theme.foreground,
                    alignment: .center,
                    in: ctx
                )
            }
            drawQuadrantLabel(capturedDiagram.quadrant1, in: capturedQ1)
            drawQuadrantLabel(capturedDiagram.quadrant2, in: capturedQ2)
            drawQuadrantLabel(capturedDiagram.quadrant3, in: capturedQ3)
            drawQuadrantLabel(capturedDiagram.quadrant4, in: capturedQ4)

            let aFont = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.85, nil)
            if hasXAxis(capturedDiagram) {
                let yPos: CGFloat = capturedPopulated
                    ? capturedPlot.maxY + 4
                    : (capturedHasTitle ? outerMargin + capturedTitleHeight + titleGap : outerMargin)
                if let left = capturedDiagram.xAxisLeft {
                    MermaidTextUtils.drawText(
                        left,
                        at: CGPoint(x: ox + capturedPlot.minX, y: oy + yPos),
                        width: capturedPlot.width / 2,
                        font: aFont,
                        fontSize: fontSize * 0.85,
                        foregroundColor: theme.foregroundDim,
                        alignment: capturedDiagram.xAxisRight == nil ? .left : .center,
                        in: ctx
                    )
                }
                if let right = capturedDiagram.xAxisRight {
                    MermaidTextUtils.drawText(
                        right,
                        at: CGPoint(x: ox + capturedPlot.midX, y: oy + yPos),
                        width: capturedPlot.width / 2,
                        font: aFont,
                        fontSize: fontSize * 0.85,
                        foregroundColor: theme.foregroundDim,
                        alignment: .center,
                        in: ctx
                    )
                }
            }

            if hasYAxis(capturedDiagram) {
                if let topLabel = capturedDiagram.yAxisTop, let frame = capturedYTop {
                    drawRotated(
                        topLabel,
                        at: CGPoint(x: ox + frame.maxX, y: oy + frame.maxY),
                        font: aFont,
                        fontSize: fontSize * 0.85,
                        color: theme.foregroundDim,
                        in: ctx
                    )
                }
                if let bottomLabel = capturedDiagram.yAxisBottom, let frame = capturedYBottom {
                    drawRotated(
                        bottomLabel,
                        at: CGPoint(x: ox + frame.maxX, y: oy + frame.maxY),
                        font: aFont,
                        fontSize: fontSize * 0.85,
                        color: theme.foregroundDim,
                        in: ctx
                    )
                }
            }

            let pFont = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.75, nil)
            for point in capturedPoints {
                let cx = ox + capturedPlot.minX + CGFloat(point.x) * capturedPlot.width
                let cy = oy + capturedPlot.maxY - CGFloat(point.y) * capturedPlot.height
                ctx.setFillColor(theme.accentCyan)
                ctx.fillEllipse(in: CGRect(
                    x: cx - pointRadius, y: cy - pointRadius,
                    width: pointRadius * 2, height: pointRadius * 2
                ))
                MermaidTextUtils.drawText(
                    point.name,
                    at: CGPoint(x: cx - 30, y: cy + pointTextPadding),
                    width: 60,
                    font: pFont,
                    fontSize: fontSize * 0.75,
                    foregroundColor: theme.foreground,
                    alignment: .center,
                    in: ctx
                )
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

    private static func hasXAxis(_ diagram: QuadrantChartDiagram) -> Bool {
        (diagram.xAxisLeft?.isEmpty == false) || (diagram.xAxisRight?.isEmpty == false)
    }

    private static func hasYAxis(_ diagram: QuadrantChartDiagram) -> Bool {
        (diagram.yAxisBottom?.isEmpty == false) || (diagram.yAxisTop?.isEmpty == false)
    }

    /// Axis-aligned box of a `-π/2` Y-axis label drawn at `(axisX, maxY)`.
    private static func rotatedYAxisFrame(
        textWidth: CGFloat,
        fontSize: CGFloat,
        axisX: CGFloat,
        centerY: CGFloat,
        minY: CGFloat,
        maxY: CGFloat
    ) -> CGRect {
        let height = max(textWidth, fontSize)
        var originY = centerY - height / 2
        if originY < minY { originY = minY }
        if originY + height > maxY { originY = max(minY, maxY - height) }
        return CGRect(
            x: axisX - fontSize,
            y: originY,
            width: fontSize,
            height: min(height, max(maxY - originY, fontSize))
        )
    }

    private static func drawRotated(
        _ text: String,
        at point: CGPoint,
        font: CTFont,
        fontSize: CGFloat,
        color: CGColor,
        in ctx: CGContext
    ) {
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y)
        ctx.rotate(by: -.pi / 2)
        MermaidTextUtils.drawText(
            text,
            at: CGPoint(x: 0, y: -fontSize),
            font: font,
            fontSize: fontSize,
            foregroundColor: color,
            alignment: .left,
            in: ctx
        )
        ctx.restoreGState()
    }
}
