import CoreGraphics
import CoreText
import Foundation

/// Renderer for Mermaid `pie` diagrams.
///
/// Draws a Core Graphics pie chart with a side (or stacked) legend and an
/// optional title. When `showData` is set, the raw data value is appended
/// to each legend row (spec: "render the actual data values after the
/// legend text").
///
/// Layout bag: `MermaidFlowchartRenderer.FlowchartLayout` with
/// `customDraw` / `customSize`, the same pattern used by the gantt
/// renderer. Slices keep declaration order (Mermaid draws clockwise in
/// label order).
///
/// Title and legend wrap/truncate to `RenderConfiguration.maxWidth`. At
/// narrow widths the legend stacks below the pie instead of overflowing.
///
/// Not modeled here: `donutHole`, `legendPosition`, `highlightSlice`
/// (v11.16.0+ frontmatter config). The stable page body only specifies
/// `pie`, `showData`, `title`, and `"label" : value`.
enum MermaidPieRenderer {

    // MARK: - Layout constants

    private static let outerMargin: CGFloat = 16
    private static let titleGap: CGFloat = 8
    private static let legendGap: CGFloat = 16
    private static let swatchSize: CGFloat = 12
    private static let swatchTextGap: CGFloat = 6
    private static let rowSpacing: CGFloat = 6
    private static let minPieDiameter: CGFloat = 120
    private static let maxPieDiameter: CGFloat = 220
    /// Side legend needs at least this much text width or we stack below.
    private static let minSideLegendWidth: CGFloat = 100
    private static let titleMaxLines = 2
    private static let legendMaxLines = 3
    /// Axial position of slice labels, matching spec default `textPosition`.
    private static let textPosition: CGFloat = 0.72

    // MARK: - Public entry point

    nonisolated static func layout(
        _ diagram: PieDiagram,
        configuration: RenderConfiguration
    ) -> MermaidFlowchartRenderer.FlowchartLayout {
        let theme = configuration.theme
        let fontSize = configuration.fontSize

        guard !diagram.slices.isEmpty else {
            return MermaidFlowchartRenderer().placeholderLayout(
                text: "Empty pie chart",
                configuration: configuration
            )
        }

        let total = diagram.slices.reduce(0.0) { $0 + $1.value }
        guard total > 0 else {
            return MermaidFlowchartRenderer().placeholderLayout(
                text: "Empty pie chart",
                configuration: configuration
            )
        }

        let maxWidth = max(configuration.maxWidth, 1)
        let contentWidth = max(maxWidth - outerMargin * 2, 40)

        // Fonts stay local to layout(); CTFont is not Sendable and cannot
        // be captured by the @Sendable draw closure.
        let titleFont = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let legendFont = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.9, nil)

        var y: CGFloat = outerMargin
        let resolvedTitle = (diagram.title?.isEmpty == false) ? diagram.title : nil
        var wrappedTitle: String?
        var titleSize = CGSize.zero
        if let title = resolvedTitle {
            let wrapped = wrapTruncated(
                title, font: titleFont, maxWidth: contentWidth, maxLines: titleMaxLines
            )
            wrappedTitle = wrapped
            titleSize = MermaidTextUtils.measureText(
                wrapped, font: titleFont, fontSize: fontSize
            )
            y += titleSize.height + titleGap
        }

        // Chat keeps the 120–220 diameter. Do not grow the hero with unused
        // document canvas the way XY `plotHeight(forMaxWidth:)` does.
        let pieDiameter = min(
            max(minPieDiameter, maxWidth * 0.45),
            maxPieDiameter
        )
        let pieRadius = pieDiameter / 2
        let sideLegendWidth = maxWidth - outerMargin - pieDiameter - legendGap - outerMargin
        let stacked = sideLegendWidth < minSideLegendWidth
        let legendAvailableWidth = stacked ? contentWidth : max(sideLegendWidth, 1)
        let legendTextWidth = max(legendAvailableWidth - swatchSize - swatchTextGap, 20)

        let rows = preparedLegendRows(
            diagram: diagram,
            font: legendFont,
            fontSize: fontSize * 0.9,
            textWidth: legendTextWidth
        )
        let legendHeight = rows.reduce(CGFloat(0)) { $0 + $1.height }
        let measuredLegendWidth = rows.map { row in
            swatchSize + swatchTextGap + MermaidTextUtils.measureText(
                row.displayText, font: legendFont, fontSize: fontSize * 0.9
            ).width
        }.max() ?? (swatchSize + swatchTextGap)
        let usedLegendWidth = min(
            legendAvailableWidth,
            max(measuredLegendWidth, swatchSize)
        )

        // Size the bitmap to pie + legend + margins. maxWidth is a cap, not
        // a stretch target — padding to 800pt flattens the fullscreen ratio.
        let pieLegendWidth = stacked
            ? max(pieDiameter, usedLegendWidth) + outerMargin * 2
            : outerMargin + pieDiameter + legendGap + usedLegendWidth + outerMargin
        let titleNeededWidth = wrappedTitle == nil ? 0 : titleSize.width + outerMargin * 2
        let canvasWidth = min(maxWidth, max(pieLegendWidth, titleNeededWidth, 1))
        let canvasContentWidth = max(canvasWidth - outerMargin * 2, 40)

        let pieCenter: CGPoint
        let legendOrigin: CGPoint
        if stacked {
            pieCenter = CGPoint(x: canvasWidth / 2, y: y + pieRadius)
            legendOrigin = CGPoint(
                x: outerMargin,
                y: pieCenter.y + pieRadius + legendGap
            )
        } else {
            pieCenter = CGPoint(x: outerMargin + pieRadius, y: y + pieRadius)
            legendOrigin = CGPoint(
                x: pieCenter.x + pieRadius + legendGap,
                y: y
            )
        }

        let contentBottom = stacked
            ? legendOrigin.y + legendHeight
            : max(pieCenter.y + pieRadius, legendOrigin.y + legendHeight)
        let totalHeight = contentBottom + outerMargin
        let size = CGSize(width: canvasWidth, height: totalHeight)

        let titleRect = wrappedTitle.map { _ in
            CGRect(x: outerMargin, y: outerMargin, width: canvasContentWidth, height: titleSize.height)
        }
        let pieRect = CGRect(
            x: pieCenter.x - pieRadius,
            y: pieCenter.y - pieRadius,
            width: pieDiameter,
            height: pieDiameter
        )
        let legendRect = CGRect(
            x: legendOrigin.x,
            y: legendOrigin.y,
            width: usedLegendWidth,
            height: legendHeight
        )

        var nodePositions: [String: CGRect] = [
            "pie": pieRect,
            "legend": legendRect,
        ]
        if let titleRect {
            nodePositions["title"] = titleRect
        }

        var nodeLabels: [String: String] = [:]
        if let wrappedTitle {
            nodeLabels["$title"] = wrappedTitle
        }
        for row in rows {
            nodeLabels[row.label] = row.displayText
        }

        let capturedTitle = wrappedTitle
        let capturedSlices = diagram.slices
        let capturedRows = rows
        let capturedPieCenter = pieCenter
        let capturedPieRadius = pieRadius
        let capturedLegendOrigin = legendOrigin
        let capturedLegendTextWidth = legendTextWidth
        let capturedColors = sliceColors(theme: theme)
        let capturedTotal = total

        let customDraw: @Sendable (CGContext, CGPoint) -> Void = { ctx, origin in
            let ox = origin.x
            let oy = origin.y

            if let title = capturedTitle {
                let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
                MermaidTextUtils.drawText(
                    title,
                    at: CGPoint(x: ox + outerMargin, y: oy + outerMargin),
                    width: canvasContentWidth,
                    font: font,
                    fontSize: fontSize,
                    foregroundColor: theme.foreground,
                    alignment: .left,
                    in: ctx
                )
            }

            // Pie slices. Mermaid draws slices clockwise in label order,
            // starting at the top (-π/2). In UIKit's Y-down coordinate
            // space, increasing the angle sweeps clockwise.
            var startAngle: CGFloat = -.pi / 2
            ctx.saveGState()
            for (i, slice) in capturedSlices.enumerated() {
                let fraction = slice.value / capturedTotal
                let angle = CGFloat(fraction) * 2 * .pi
                let endAngle = startAngle + angle
                let color = capturedColors[i % capturedColors.count]
                let center = capturedPieCenter.offsetBy(dx: ox, dy: oy)

                ctx.setFillColor(color)
                ctx.setStrokeColor(theme.background.copy(alpha: 0.6) ?? theme.background)
                ctx.setLineWidth(1)
                ctx.move(to: center)
                ctx.addArc(
                    center: center,
                    radius: capturedPieRadius,
                    startAngle: startAngle,
                    endAngle: endAngle,
                    clockwise: false
                )
                ctx.closePath()
                // fillPath() consumes the path, so stroke must share it.
                ctx.drawPath(using: .fillStroke)

                // Slice percentage at axial `textPosition`. Skip tiny
                // slices to avoid overlapping clutter.
                if fraction >= 0.06 {
                    let midAngle = startAngle + angle / 2
                    let labelRadius = capturedPieRadius * textPosition
                    let lx = capturedPieCenter.x + cos(midAngle) * labelRadius
                    let ly = capturedPieCenter.y + sin(midAngle) * labelRadius
                    let pctText = "\(roundedPercentString(fraction))%"
                    let smallFont = CTFontCreateWithName(
                        "Helvetica" as CFString, fontSize * 0.9, nil
                    )
                    let pctSize = lineSize(pctText, font: smallFont, fontSize: fontSize * 0.9)
                    let textOrigin = CGPoint(
                        x: ox + lx - pctSize.width / 2,
                        y: oy + ly - pctSize.height / 2
                    )
                    let textColor = contrastingTextColor(on: color, theme: theme)
                    let ratio = contrastRatio(foreground: textColor, background: color)
                    if ratio < 4.5 {
                        let pad: CGFloat = 2
                        let backing = CGRect(
                            x: textOrigin.x - pad,
                            y: textOrigin.y - pad,
                            width: pctSize.width + pad * 2,
                            height: pctSize.height + pad * 2
                        )
                        ctx.setFillColor(theme.background.copy(alpha: 0.78) ?? theme.background)
                        ctx.fill(backing)
                        MermaidTextUtils.drawText(
                            pctText,
                            at: textOrigin,
                            font: smallFont,
                            fontSize: fontSize * 0.9,
                            foregroundColor: contrastingTextColor(
                                on: theme.background, theme: theme
                            ),
                            in: ctx
                        )
                    } else {
                        MermaidTextUtils.drawText(
                            pctText,
                            at: textOrigin,
                            font: smallFont,
                            fontSize: fontSize * 0.9,
                            foregroundColor: textColor,
                            in: ctx
                        )
                    }
                }

                startAngle = endAngle
            }
            ctx.restoreGState()

            var legendY = oy + capturedLegendOrigin.y
            for (i, row) in capturedRows.enumerated() {
                let color = capturedColors[i % capturedColors.count]
                let swatchRect = CGRect(
                    x: ox + capturedLegendOrigin.x,
                    y: legendY,
                    width: swatchSize,
                    height: swatchSize
                )
                ctx.saveGState()
                ctx.setFillColor(color)
                ctx.addPath(CGPath(
                    roundedRect: swatchRect, cornerWidth: 2, cornerHeight: 2, transform: nil
                ))
                ctx.fillPath()
                ctx.restoreGState()

                let font = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.9, nil)
                MermaidTextUtils.drawText(
                    row.displayText,
                    at: CGPoint(x: swatchRect.maxX + swatchTextGap, y: legendY),
                    width: capturedLegendTextWidth,
                    font: font,
                    fontSize: fontSize * 0.9,
                    foregroundColor: theme.foreground,
                    alignment: .left,
                    in: ctx
                )
                legendY += row.height
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

    // MARK: - Legend rows

    private struct LegendRow {
        let label: String
        let displayText: String
        let height: CGFloat
    }

    /// Build wrapped legend display text. Per spec, `showData` renders
    /// the actual data value after the legend label.
    private static func preparedLegendRows(
        diagram: PieDiagram,
        font: CTFont,
        fontSize: CGFloat,
        textWidth: CGFloat
    ) -> [LegendRow] {
        diagram.slices.map { slice in
            let raw: String
            if diagram.showData {
                raw = "\(slice.label) : \(formatDataValue(slice.value))"
            } else {
                raw = slice.label
            }
            let wrapped = wrapTruncated(
                raw, font: font, maxWidth: textWidth, maxLines: legendMaxLines
            )
            let measured = MermaidTextUtils.measureText(
                wrapped, font: font, fontSize: fontSize
            )
            return LegendRow(
                label: slice.label,
                displayText: wrapped,
                height: max(measured.height, swatchSize) + rowSpacing
            )
        }
    }

    // MARK: - Colors

    /// Cycle through Oppi theme accents in a fixed order for stable,
    /// distinguishable slice colors.
    private static func sliceColors(theme: RenderTheme) -> [CGColor] {
        [
            theme.accentBlue,
            theme.accentGreen,
            theme.accentOrange,
            theme.accentPurple,
            theme.accentRed,
            theme.accentYellow,
            theme.accentCyan,
        ]
    }

    /// Pick the most readable of theme foreground / background against a
    /// slice fill so percentage labels stay visible in light and dark.
    nonisolated static func sliceLabelColor(on fill: CGColor, theme: RenderTheme) -> CGColor {
        contrastingTextColor(on: fill, theme: theme)
    }

    private static func contrastingTextColor(on fill: CGColor, theme: RenderTheme) -> CGColor {
        let candidates = [theme.foreground, theme.background, theme.backgroundDark]
        return candidates.max { lhs, rhs in
            contrastRatio(foreground: lhs, background: fill)
                < contrastRatio(foreground: rhs, background: fill)
        } ?? theme.foreground
    }

    private static func contrastRatio(foreground: CGColor, background: CGColor) -> CGFloat {
        guard let fg = sRGBComponents(foreground), let bg = sRGBComponents(background) else {
            return 1
        }
        let fgLuminance = relativeLuminance(red: fg.red, green: fg.green, blue: fg.blue)
        let bgLuminance = relativeLuminance(red: bg.red, green: bg.green, blue: bg.blue)
        let lighter = max(fgLuminance, bgLuminance)
        let darker = min(fgLuminance, bgLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        func linearized(_ component: CGFloat) -> CGFloat {
            component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearized(red) + 0.7152 * linearized(green) + 0.0722 * linearized(blue)
    }

    private struct SRGBComponents {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
    }

    private static func sRGBComponents(_ color: CGColor) -> SRGBComponents? {
        let converted = color.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            intent: .defaultIntent,
            options: nil
        ) ?? color
        guard let components = converted.components else { return nil }
        if components.count >= 3 {
            return SRGBComponents(red: components[0], green: components[1], blue: components[2])
        }
        if components.count >= 1 {
            return SRGBComponents(red: components[0], green: components[0], blue: components[0])
        }
        return nil
    }

    // MARK: - Number formatting

    /// Format a `showData` value without narrowing to `Int`, which traps
    /// for finite Doubles above `Int.max` (e.g. 1e20).
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

    private static func roundedPercentString(_ fraction: Double) -> String {
        let pct = (fraction * 100).rounded()
        return String(format: "%.0f", pct)
    }

    // MARK: - Text wrapping

    /// Wrap to `maxWidth` and cap the line count, truncating the last
    /// kept line with an ellipsis when text is dropped.
    private static func wrapTruncated(
        _ text: String,
        font: CTFont,
        maxWidth: CGFloat,
        maxLines: Int
    ) -> String {
        var lines = suggestLineBreaks(text, font: font, maxWidth: maxWidth)
        guard !lines.isEmpty else { return "" }

        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            var last = lines[maxLines - 1]
            while !last.isEmpty, textWidth(last + "…", font: font) > maxWidth {
                if let space = last.range(of: " ", options: .backwards) {
                    last = String(last[..<space.lowerBound])
                } else {
                    last.removeLast()
                }
            }
            lines[maxLines - 1] = last.isEmpty ? "…" : last + "…"
        }

        return lines
            .map { fitLine($0, font: font, maxWidth: maxWidth) }
            .joined(separator: "\n")
    }

    private static func fitLine(_ line: String, font: CTFont, maxWidth: CGFloat) -> String {
        guard textWidth(line, font: font) > maxWidth else { return line }
        var text = line
        while !text.isEmpty, textWidth(text + "…", font: font) > maxWidth {
            text.removeLast()
        }
        return text.isEmpty ? "…" : text + "…"
    }

    private static func suggestLineBreaks(
        _ text: String,
        font: CTFont,
        maxWidth: CGFloat
    ) -> [String] {
        guard !text.isEmpty else { return [] }
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let nsText = text as NSString
        var lines: [String] = []
        var location = 0
        while location < nsText.length {
            let suggested = CTTypesetterSuggestLineBreak(typesetter, location, Double(maxWidth))
            let length = max(suggested, 1)
            let clamped = min(length, nsText.length - location)
            let piece = nsText
                .substring(with: NSRange(location: location, length: clamped))
                .trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { lines.append(piece) }
            location += length
        }
        return lines
    }

    private static func textWidth(_ text: String, font: CTFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        return CTLineGetBoundsWithOptions(line, []).width
    }

    private static func lineSize(_ text: String, font: CTFont, fontSize: CGFloat) -> CGSize {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        return CGSize(width: bounds.width, height: max(bounds.height, fontSize))
    }
}

// MARK: - CGPoint helper

private extension CGPoint {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGPoint {
        CGPoint(x: x + dx, y: y + dy)
    }
}
