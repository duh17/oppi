import CoreGraphics
import CoreText
import Foundation

/// Renderer for Mermaid `xychart` / `xychart-beta` diagrams.
///
/// Phone-first Core Graphics chart: data is the hero, chrome stays quiet.
/// Layout bag is `MermaidFlowchartRenderer.FlowchartLayout` with
/// `customDraw` / `customSize`, same pattern as pie and gantt.
///
/// - Stay within `maxWidth`. Title and axis titles wrap/truncate.
/// - X labels skip rather than overlap. First/last shrink (ellipsis)
///   to stay inside the bitmap; last is dropped if they still collide.
/// - Values outside the declared y-range clip; they do not expand layout.
/// - Bars draw behind lines. Legend only for named series.
/// - Theme tokens only: foreground / foregroundDim / background / accents.
enum MermaidXYChartRenderer {

    // MARK: - Layout constants (8pt rhythm, pie-like outer margin)

    private static let outerMargin: CGFloat = 16
    private static let titleGap: CGFloat = 8
    private static let axisTitleGap: CGFloat = 6
    private static let yLabelGap: CGFloat = 8
    private static let xLabelGap: CGFloat = 6
    private static let legendGap: CGFloat = 12
    private static let swatchSize: CGFloat = 10
    private static let swatchTextGap: CGFloat = 6
    private static let legendItemGap: CGFloat = 12
    private static let legendRowSpacing: CGFloat = 6
    private static let plotHeight: CGFloat = 168
    private static let barCornerRadius: CGFloat = 3
    private static let barSlotFraction: CGFloat = 0.56
    private static let lineWidth: CGFloat = 2
    private static let pointRadius: CGFloat = 3
    private static let xLabelMinGap: CGFloat = 6
    private static let titleMaxLines = 2
    private static let axisTitleMaxLines = 2
    private static let legendMaxLines = 2

    // MARK: - Public entry point

    nonisolated static func layout(
        _ diagram: XYChartDiagram,
        configuration: RenderConfiguration
    ) -> MermaidFlowchartRenderer.FlowchartLayout {
        let theme = configuration.theme
        let fontSize = configuration.fontSize

        let prepared = prepare(diagram)
        guard !prepared.categories.isEmpty, !prepared.series.isEmpty else {
            return MermaidFlowchartRenderer().placeholderLayout(
                text: "Empty XY chart",
                configuration: configuration
            )
        }

        let maxWidth = max(configuration.maxWidth, 1)
        let contentWidth = max(maxWidth - outerMargin * 2, 40)

        let titleFont = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let axisTitleFont = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.85, nil)
        let labelFont = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.75, nil)
        let legendFont = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.85, nil)

        var y: CGFloat = outerMargin
        var nodePositions: [String: CGRect] = [:]
        var nodeLabels: [String: String] = [:]

        let resolvedTitle = (diagram.title?.isEmpty == false) ? diagram.title : nil
        var wrappedTitle: String?
        if let title = resolvedTitle {
            let wrapped = wrapTruncated(
                title, font: titleFont, fontSize: fontSize, maxWidth: contentWidth, maxLines: titleMaxLines
            )
            wrappedTitle = wrapped
            let titleSize = MermaidTextUtils.measureText(
                wrapped, font: titleFont, fontSize: fontSize
            )
            nodeLabels["$title"] = wrapped
            nodePositions["title"] = CGRect(
                x: outerMargin, y: y, width: contentWidth, height: titleSize.height
            )
            y += titleSize.height + titleGap
        }

        if let yTitle = prepared.yTitle {
            let wrapped = wrapTruncated(
                yTitle,
                font: axisTitleFont,
                fontSize: fontSize * 0.85,
                maxWidth: contentWidth,
                maxLines: axisTitleMaxLines
            )
            let size = MermaidTextUtils.measureText(
                wrapped, font: axisTitleFont, fontSize: fontSize * 0.85
            )
            nodeLabels["$yTitle"] = wrapped
            nodePositions["yTitle"] = CGRect(
                x: outerMargin, y: y, width: contentWidth, height: size.height
            )
            y += size.height + axisTitleGap
        }

        let yTicks = niceTicks(min: prepared.yMin, max: prepared.yMax)
        let yTickLabels = yTicks.map { formatAxisNumber($0) }
        let yLabelWidth = yTickLabels.reduce(CGFloat(0)) { widest, label in
            max(widest, textWidth(label, font: labelFont))
        }
        let plotLeft = outerMargin + yLabelWidth + yLabelGap
        let plotWidth = max(maxWidth - plotLeft - outerMargin, 40)
        let plotTop = y
        let plotRect = CGRect(x: plotLeft, y: plotTop, width: plotWidth, height: plotHeight)
        nodePositions["plot"] = plotRect
        nodePositions["yAxis"] = CGRect(
            x: outerMargin,
            y: plotTop,
            width: yLabelWidth,
            height: plotHeight
        )
        let yTickHeight = fontSize * 0.75 * 1.4
        for (index, label) in yTickLabels.enumerated() {
            let width = textWidth(label, font: labelFont)
            let tickY = yPosition(
                yTicks[index], min: prepared.yMin, max: prepared.yMax, plot: plotRect
            )
            nodeLabels["$y-\(index)"] = label
            nodePositions["y-\(index)"] = CGRect(
                x: outerMargin + yLabelWidth - width,
                y: tickY - yTickHeight / 2,
                width: width,
                height: yTickHeight
            )
        }
        y = plotRect.maxY + xLabelGap

        let slotWidth = plotWidth / CGFloat(prepared.categories.count)
        let xLabelSizes = prepared.categories.map { label in
            textWidth(label, font: labelFont)
        }
        let slotCenters = prepared.categories.indices.map { index in
            plotLeft + (CGFloat(index) + 0.5) * slotWidth
        }
        let shownX = xLabelsToShow(
            labels: prepared.categories,
            widths: xLabelSizes,
            slotCenters: slotCenters,
            minGap: xLabelMinGap,
            maxWidth: maxWidth,
            font: labelFont
        )
        let xLabelHeight = fontSize * 0.75 * 1.4
        for item in shownX {
            nodeLabels["$x-\(item.index)"] = item.text
            nodePositions["x-\(item.index)"] = CGRect(
                x: item.x,
                y: y,
                width: item.width,
                height: xLabelHeight
            )
        }
        nodeLabels["$xLabels"] = shownX.map(\.text).joined(separator: "\n")
        nodePositions["xAxis"] = CGRect(
            x: plotLeft, y: y, width: plotWidth, height: xLabelHeight
        )
        y += xLabelHeight

        if let xTitle = prepared.xTitle {
            y += axisTitleGap
            let wrapped = wrapTruncated(
                xTitle,
                font: axisTitleFont,
                fontSize: fontSize * 0.85,
                maxWidth: plotWidth,
                maxLines: axisTitleMaxLines
            )
            let size = MermaidTextUtils.measureText(
                wrapped, font: axisTitleFont, fontSize: fontSize * 0.85
            )
            nodeLabels["$xTitle"] = wrapped
            nodePositions["xTitle"] = CGRect(
                x: plotLeft, y: y, width: plotWidth, height: size.height
            )
            y += size.height
        }

        let named = prepared.series.enumerated().compactMap { index, series -> (Int, String)? in
            guard let name = series.name, !name.isEmpty else { return nil }
            return (index, name)
        }
        var legendRows: [LegendRow] = []
        if !named.isEmpty {
            y += legendGap
            let rows = wrapLegend(
                items: named,
                font: legendFont,
                fontSize: fontSize * 0.85,
                maxWidth: contentWidth
            )
            legendRows = rows
            let legendHeight = rows.reduce(CGFloat(0)) { $0 + $1.height }
            nodePositions["legend"] = CGRect(
                x: outerMargin, y: y, width: contentWidth, height: legendHeight
            )
            for (index, name) in named {
                nodeLabels["$legend-\(index)"] = name
            }
            y += legendHeight
        }

        let totalHeight = y + outerMargin
        let size = CGSize(width: maxWidth, height: totalHeight)

        let capturedTitle = wrappedTitle
        let capturedTitleRect = nodePositions["title"]
        let capturedYTitle = nodeLabels["$yTitle"]
        let capturedYTitleRect = nodePositions["yTitle"]
        let capturedXTitle = nodeLabels["$xTitle"]
        let capturedXTitleRect = nodePositions["xTitle"]
        let capturedLegendOrigin = nodePositions["legend"]?.origin ?? .zero
        let capturedColors = seriesColors(theme: theme)
        let capturedPrepared = prepared
        let capturedYTicks = yTicks
        let capturedYTickLabels = yTickLabels
        let capturedShownX = shownX
        let capturedSlotCenters = slotCenters
        let capturedSlotWidth = slotWidth
        let capturedLegendRows = legendRows

        let customDraw: @Sendable (CGContext, CGPoint) -> Void = { ctx, origin in
            let ox = origin.x
            let oy = origin.y

            ctx.setFillColor(theme.background)
            ctx.fill(CGRect(origin: origin, size: size))

            if let title = capturedTitle, let rect = capturedTitleRect {
                let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
                MermaidTextUtils.drawText(
                    title,
                    at: CGPoint(x: ox + rect.minX, y: oy + rect.minY),
                    width: rect.width,
                    font: font,
                    fontSize: fontSize,
                    foregroundColor: theme.foreground,
                    alignment: .left,
                    in: ctx
                )
            }

            if let yTitle = capturedYTitle, let rect = capturedYTitleRect {
                let font = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.85, nil)
                MermaidTextUtils.drawText(
                    yTitle,
                    at: CGPoint(x: ox + rect.minX, y: oy + rect.minY),
                    width: rect.width,
                    font: font,
                    fontSize: fontSize * 0.85,
                    foregroundColor: theme.foregroundDim,
                    alignment: .left,
                    in: ctx
                )
            }

            let plot = plotRect.offsetBy(dx: ox, dy: oy)
            drawGridAndAxes(
                ctx: ctx,
                plot: plot,
                yTicks: capturedYTicks,
                yMin: capturedPrepared.yMin,
                yMax: capturedPrepared.yMax,
                theme: theme
            )

            let labelFontLocal = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.75, nil)
            for (tick, label) in zip(capturedYTicks, capturedYTickLabels) {
                let tickY = yPosition(
                    tick, min: capturedPrepared.yMin, max: capturedPrepared.yMax, plot: plot
                )
                let labelSize = MermaidTextUtils.measureText(
                    label, font: labelFontLocal, fontSize: fontSize * 0.75
                )
                let labelWidth = textWidth(label, font: labelFontLocal)
                MermaidTextUtils.drawText(
                    label,
                    at: CGPoint(
                        x: ox + outerMargin + yLabelWidth - labelWidth,
                        y: tickY - labelSize.height / 2
                    ),
                    width: labelWidth,
                    font: labelFontLocal,
                    fontSize: fontSize * 0.75,
                    foregroundColor: theme.foregroundDim,
                    alignment: .left,
                    in: ctx
                )
            }

            let bars = capturedPrepared.series.enumerated().filter { $0.element.kind == .bar }
            let barCount = max(bars.count, 1)
            let groupWidth = capturedSlotWidth * barSlotFraction
            let singleBarWidth = groupWidth / CGFloat(barCount)
            for (groupIndex, item) in bars.enumerated() {
                let color = capturedColors[item.offset % capturedColors.count]
                for (categoryIndex, value) in item.element.values.enumerated()
                where categoryIndex < capturedPrepared.categories.count {
                    let center = ox + capturedSlotCenters[categoryIndex]
                    let groupLeft = center - groupWidth / 2
                    let barX = groupLeft + CGFloat(groupIndex) * singleBarWidth
                    let barRect = barRectForValue(
                        value,
                        x: barX,
                        width: max(singleBarWidth - 1, 1),
                        yMin: capturedPrepared.yMin,
                        yMax: capturedPrepared.yMax,
                        plot: plot
                    )
                    guard barRect.height > 0.5 else { continue }
                    let radius = min(barCornerRadius, barRect.width / 2, barRect.height / 2)
                    ctx.saveGState()
                    ctx.setFillColor(color.copy(alpha: 0.82) ?? color)
                    ctx.addPath(CGPath(
                        roundedRect: barRect,
                        cornerWidth: radius,
                        cornerHeight: radius,
                        transform: nil
                    ))
                    ctx.fillPath()
                    ctx.restoreGState()
                }
            }

            let lines = capturedPrepared.series.enumerated().filter { $0.element.kind == .line }
            for item in lines {
                let color = capturedColors[item.offset % capturedColors.count]
                var points: [CGPoint] = []
                for (categoryIndex, value) in item.element.values.enumerated()
                where categoryIndex < capturedPrepared.categories.count {
                    let x = ox + capturedSlotCenters[categoryIndex]
                    let yPoint = yPosition(
                        value, min: capturedPrepared.yMin, max: capturedPrepared.yMax, plot: plot
                    )
                    points.append(CGPoint(x: x, y: yPoint))
                }
                guard points.count >= 1 else { continue }
                ctx.saveGState()
                ctx.setStrokeColor(color)
                ctx.setLineWidth(lineWidth)
                ctx.setLineJoin(.round)
                ctx.setLineCap(.round)
                ctx.addLines(between: points)
                ctx.strokePath()
                ctx.setFillColor(color)
                ctx.setStrokeColor(theme.background)
                ctx.setLineWidth(1)
                for point in points {
                    let dot = CGRect(
                        x: point.x - pointRadius,
                        y: point.y - pointRadius,
                        width: pointRadius * 2,
                        height: pointRadius * 2
                    )
                    ctx.fillEllipse(in: dot)
                    ctx.strokeEllipse(in: dot)
                }
                ctx.restoreGState()
            }

            for item in capturedShownX {
                MermaidTextUtils.drawText(
                    item.text,
                    at: CGPoint(
                        x: ox + item.x,
                        y: oy + plotRect.maxY + xLabelGap
                    ),
                    width: item.width,
                    font: labelFontLocal,
                    fontSize: fontSize * 0.75,
                    foregroundColor: theme.foregroundDim,
                    alignment: .center,
                    in: ctx
                )
            }

            if let xTitle = capturedXTitle, let rect = capturedXTitleRect {
                let font = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.85, nil)
                MermaidTextUtils.drawText(
                    xTitle,
                    at: CGPoint(x: ox + rect.minX, y: oy + rect.minY),
                    width: rect.width,
                    font: font,
                    fontSize: fontSize * 0.85,
                    foregroundColor: theme.foregroundDim,
                    alignment: .center,
                    in: ctx
                )
            }

            if !capturedLegendRows.isEmpty {
                var legendY = oy + capturedLegendOrigin.y
                let font = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.85, nil)
                for row in capturedLegendRows {
                    var x = ox + capturedLegendOrigin.x
                    for item in row.items {
                        let color = capturedColors[item.seriesIndex % capturedColors.count]
                        let swatch = CGRect(
                            x: x,
                            y: legendY + 1,
                            width: swatchSize,
                            height: swatchSize
                        )
                        ctx.saveGState()
                        ctx.setFillColor(color)
                        ctx.addPath(CGPath(
                            roundedRect: swatch, cornerWidth: 2, cornerHeight: 2, transform: nil
                        ))
                        ctx.fillPath()
                        ctx.restoreGState()
                        MermaidTextUtils.drawText(
                            item.text,
                            at: CGPoint(x: swatch.maxX + swatchTextGap, y: legendY),
                            font: font,
                            fontSize: fontSize * 0.85,
                            foregroundColor: theme.foreground,
                            in: ctx
                        )
                        x += item.width + legendItemGap
                    }
                    legendY += row.height
                }
            }
        }

        return MermaidFlowchartRenderer.FlowchartLayout(
            graphResult: GraphLayoutResult(
                nodePositions: nodePositions, edgePaths: [], totalSize: size
            ),
            flowchart: .empty,
            subgraphFrames: [:],
            nodeLabels: nodeLabels,
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

    // MARK: - Prepared chart

    struct PreparedChart: Equatable, Sendable {
        let categories: [String]
        let series: [XYChartSeries]
        let xTitle: String?
        let yTitle: String?
        let yMin: Double
        let yMax: Double
    }

    /// Resolve categories, trim series to the x-axis length, and lock the y-range.
    /// Declared y bounds win even when data sits outside them.
    nonisolated static func prepare(_ diagram: XYChartDiagram) -> PreparedChart {
        let rawSeries = diagram.series.map { series in
            XYChartSeries(
                kind: series.kind,
                name: series.name,
                values: series.values.filter(\.isFinite)
            )
        }.filter { !$0.values.isEmpty }

        let longest = rawSeries.map(\.values.count).max() ?? 0
        let categories: [String]
        let xTitle: String?
        switch diagram.xAxis {
        case .categorical(let title, let labels):
            xTitle = emptyToNil(title)
            if labels.isEmpty {
                categories = (0..<longest).map { "\($0 + 1)" }
            } else {
                categories = labels
            }
        case .numeric(let title, let lowerBound, let upperBound):
            xTitle = emptyToNil(title)
            let count = Swift.max(longest, 1)
            if count == 1 {
                categories = [formatAxisNumber(lowerBound)]
            } else {
                let step = (upperBound - lowerBound) / Double(count - 1)
                categories = (0..<count).map { formatAxisNumber(lowerBound + Double($0) * step) }
            }
        }

        let trimmed = rawSeries.map { series in
            XYChartSeries(
                kind: series.kind,
                name: series.name,
                values: Array(series.values.prefix(categories.count))
            )
        }

        let dataValues = trimmed.flatMap(\.values)
        let (yMin, yMax) = resolveYRange(declared: diagram.yAxis, data: dataValues)
        return PreparedChart(
            categories: categories,
            series: trimmed,
            xTitle: xTitle,
            yTitle: emptyToNil(diagram.yAxis.title),
            yMin: yMin,
            yMax: yMax
        )
    }

    /// Declared range is used as-is (after swap/pad). Auto range includes 0.
    nonisolated static func resolveYRange(
        declared: XYChartYAxis,
        data: [Double]
    ) -> (Double, Double) {
        if let min = declared.min, let max = declared.max, min.isFinite, max.isFinite {
            return paddedRange(min, max)
        }

        let finite = data.filter(\.isFinite)
        let dataMin = finite.min() ?? 0
        let dataMax = finite.max() ?? 1
        var min = declared.min ?? Swift.min(0, dataMin)
        var max = declared.max ?? Swift.max(0, dataMax)
        if let declaredMin = declared.min { min = declaredMin }
        if let declaredMax = declared.max { max = declaredMax }
        return paddedRange(min, max)
    }

    private static func paddedRange(_ minValue: Double, _ maxValue: Double) -> (Double, Double) {
        var min = minValue
        var max = maxValue
        if min > max { swap(&min, &max) }
        if min == max {
            if min == 0 {
                max = 1
            } else {
                let pad = abs(min) * 0.1
                min -= pad
                max += pad
            }
        }
        return (min, max)
    }

    // MARK: - Axis labels

    /// Pick a short increasing tick list that includes the range ends.
    nonisolated static func niceTicks(min: Double, max: Double, target: Int = 5) -> [Double] {
        let span = max - min
        guard span.isFinite, span > 0 else { return [min, max] }
        let desired = Swift.max(target, 2)
        let rough = span / Double(desired - 1)
        let exponent = floor(log10(rough))
        let magnitude = pow(10, exponent)
        let residual = rough / magnitude
        let step: Double
        if residual <= 1 {
            step = magnitude
        } else if residual <= 2 {
            step = 2 * magnitude
        } else if residual <= 5 {
            step = 5 * magnitude
        } else {
            step = 10 * magnitude
        }

        var ticks: [Double] = [min]
        var value = (floor(min / step) * step) + step
        // Step off exact-min duplicates caused by float residue.
        if abs(value - min) < step * 0.01 {
            value += step
        }
        while value < max - step * 0.01 {
            ticks.append(value)
            value += step
        }
        ticks.append(max)
        return ticks
    }

    /// Compact axis numbers so 120000 stays short on a phone (`120k`).
    nonisolated static func formatAxisNumber(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == 0 { return "0" }
        let absValue = abs(value)
        if absValue >= 10_000 {
            let thousands = value / 1_000
            if abs(thousands - thousands.rounded()) < 0.05 {
                return "\(formatDataValue(thousands.rounded()))k"
            }
            return "\(formatDataValue(thousands))k"
        }
        return formatDataValue(value)
    }

    nonisolated static func formatDataValue(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(format: "%.0f", rounded)
        }
        var text = String(format: "%.2f", rounded)
        while text.contains("."), text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text
    }

    /// One visible x-axis label after skip / clamp / ellipsis.
    struct ShownXLabel: Equatable, Sendable {
        let index: Int
        let text: String
        let x: CGFloat
        let width: CGFloat
    }

    /// Greedy first-and-last x labels; skip any middle label that would overlap.
    /// First and last stay inside `[0, maxWidth]` by shifting and ellipsizing.
    /// If they still collide after shrinking, last is dropped.
    nonisolated static func xLabelsToShow(
        labels: [String],
        widths: [CGFloat],
        slotCenters: [CGFloat],
        minGap: CGFloat,
        maxWidth: CGFloat = .greatestFiniteMagnitude,
        font: CTFont? = nil
    ) -> [ShownXLabel] {
        guard !labels.isEmpty, labels.count == widths.count, labels.count == slotCenters.count else {
            return labels.indices.map { index in
                ShownXLabel(
                    index: index,
                    text: labels[index],
                    x: 0,
                    width: 0
                )
            }
        }

        let minLabelWidth = font.map { textWidth("…", font: $0) } ?? 0

        func fit(_ index: Int, _ minBound: CGFloat, _ maxBound: CGFloat) -> ShownXLabel? {
            let available = maxBound - minBound
            guard available > 0.5 else { return nil }
            var text = labels[index]
            var width = min(widths[index], available)
            if let font {
                text = truncateToWidth(labels[index], maxWidth: width, font: font)
                width = min(textWidth(text, font: font), available)
            }
            guard width <= available + 0.01, width > 0 || minLabelWidth == 0 else { return nil }
            var x = slotCenters[index] - width / 2
            if x < minBound { x = minBound }
            if x + width > maxBound { x = maxBound - width }
            if x < minBound - 0.01 { return nil }
            return ShownXLabel(index: index, text: text, x: x, width: width)
        }

        guard var first = fit(0, 0, maxWidth) else { return [] }
        if labels.count == 1 { return [first] }

        let lastIndex = labels.count - 1
        var last = fit(lastIndex, 0, maxWidth)
        if let lastLabel = last, first.x + first.width + minGap > lastLabel.x {
            let span = lastLabel.x + lastLabel.width - first.x - minGap
            if span >= minLabelWidth * (minLabelWidth > 0 ? 2 : 0) || span > 0 {
                let firstBudget = min(first.width, max(minLabelWidth, span / 2))
                if let shrunkFirst = fit(0, first.x, first.x + firstBudget) {
                    first = shrunkFirst
                }
                last = fit(lastIndex, first.x + first.width + minGap, maxWidth)
            } else {
                last = nil
            }
        }

        var shown: [ShownXLabel] = [first]
        let middleLimit = last.map { $0.x - minGap } ?? maxWidth
        for index in 1..<lastIndex {
            guard let candidate = fit(index, 0, maxWidth) else { continue }
            let previous = shown[shown.count - 1]
            if candidate.x < previous.x + previous.width + minGap { continue }
            if candidate.x + candidate.width > middleLimit { continue }
            shown.append(candidate)
        }
        if let last {
            let previous = shown[shown.count - 1]
            if last.x + 0.01 >= previous.x + previous.width + minGap {
                shown.append(last)
            }
        }
        return shown
    }

    private static func truncateToWidth(_ text: String, maxWidth: CGFloat, font: CTFont) -> String {
        if textWidth(text, font: font) <= maxWidth { return text }
        if textWidth("…", font: font) > maxWidth { return "…" }
        var stem = text
        while !stem.isEmpty, textWidth(stem + "…", font: font) > maxWidth {
            stem.removeLast()
        }
        return stem.isEmpty ? "…" : stem + "…"
    }

    // MARK: - Geometry

    nonisolated static func clipY(_ value: Double, min: Double, max: Double) -> Double {
        Swift.min(Swift.max(value, min), max)
    }

    private static func yPosition(
        _ value: Double,
        min: Double,
        max: Double,
        plot: CGRect
    ) -> CGFloat {
        let span = max - min
        guard span > 0 else { return plot.midY }
        let clipped = clipY(value, min: min, max: max)
        let t = (clipped - min) / span
        return plot.maxY - CGFloat(t) * plot.height
    }

    private static func barRectForValue(
        _ value: Double,
        x: CGFloat,
        width: CGFloat,
        yMin: Double,
        yMax: Double,
        plot: CGRect
    ) -> CGRect {
        let baseline: Double
        if yMin <= 0 && yMax >= 0 {
            baseline = 0
        } else {
            baseline = yMin
        }
        let top = yPosition(value, min: yMin, max: yMax, plot: plot)
        let bottom = yPosition(baseline, min: yMin, max: yMax, plot: plot)
        let minY = Swift.min(top, bottom)
        let height = abs(bottom - top)
        return CGRect(x: x, y: minY, width: width, height: height)
    }

    private static func drawGridAndAxes(
        ctx: CGContext,
        plot: CGRect,
        yTicks: [Double],
        yMin: Double,
        yMax: Double,
        theme: RenderTheme
    ) {
        ctx.saveGState()
        ctx.setStrokeColor(theme.foregroundDim.copy(alpha: 0.22) ?? theme.foregroundDim)
        ctx.setLineWidth(0.5)
        for tick in yTicks {
            let y = yPosition(tick, min: yMin, max: yMax, plot: plot)
            ctx.move(to: CGPoint(x: plot.minX, y: y))
            ctx.addLine(to: CGPoint(x: plot.maxX, y: y))
        }
        ctx.strokePath()

        ctx.setStrokeColor(theme.foregroundDim.copy(alpha: 0.45) ?? theme.foregroundDim)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: plot.minX, y: plot.minY))
        ctx.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        ctx.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Colors / legend

    private static func seriesColors(theme: RenderTheme) -> [CGColor] {
        [
            theme.accentBlue,
            theme.accentOrange,
            theme.accentGreen,
            theme.accentPurple,
            theme.accentRed,
            theme.accentYellow,
            theme.accentCyan,
        ]
    }

    private struct LegendItem {
        let seriesIndex: Int
        let text: String
        let width: CGFloat
    }

    private struct LegendRow {
        let items: [LegendItem]
        let height: CGFloat
    }

    private static func wrapLegend(
        items: [(Int, String)],
        font: CTFont,
        fontSize: CGFloat,
        maxWidth: CGFloat
    ) -> [LegendRow] {
        var rows: [LegendRow] = []
        var current: [LegendItem] = []
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = swatchSize

        for (index, name) in items {
            let text = wrapTruncated(
                name, font: font, fontSize: fontSize, maxWidth: maxWidth, maxLines: legendMaxLines
            )
            let textSize = MermaidTextUtils.measureText(text, font: font, fontSize: fontSize)
            let width = swatchSize + swatchTextGap + textSize.width
            let item = LegendItem(seriesIndex: index, text: text, width: width)
            let extra = current.isEmpty ? width : width + legendItemGap
            if !current.isEmpty, rowWidth + extra > maxWidth {
                rows.append(LegendRow(items: current, height: rowHeight + legendRowSpacing))
                current = [item]
                rowWidth = width
                rowHeight = max(swatchSize, textSize.height)
            } else {
                current.append(item)
                rowWidth += extra
                rowHeight = max(rowHeight, textSize.height)
            }
        }
        if !current.isEmpty {
            rows.append(LegendRow(items: current, height: rowHeight + legendRowSpacing))
        }
        return rows
    }

    // MARK: - Text

    private static func wrapTruncated(
        _ text: String,
        font: CTFont,
        fontSize: CGFloat,
        maxWidth: CGFloat,
        maxLines: Int
    ) -> String {
        let wrapped = MermaidTextUtils.wrapText(
            text, maxWidth: maxWidth, font: font, fontSize: fontSize
        )
        var lines = wrapped.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return "" }
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            var last = lines[maxLines - 1]
            while !last.isEmpty,
                  textWidth(last + "…", font: font) > maxWidth
            {
                last.removeLast()
            }
            lines[maxLines - 1] = last.isEmpty ? "…" : last + "…"
        }
        return lines.joined(separator: "\n")
    }

    private static func textWidth(_ text: String, font: CTFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        return CTLineGetBoundsWithOptions(line, []).width
    }

    private static func emptyToNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
