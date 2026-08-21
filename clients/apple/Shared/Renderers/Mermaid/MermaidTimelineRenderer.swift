import CoreGraphics
import CoreText
import Foundation

/// Renderer for Mermaid timeline diagrams.
///
/// Draws a horizontal spine per section with period labels above the spine,
/// event boxes stacked under each period, and color bands around named
/// sections. Uses the shared `FlowchartLayout` container with
/// `customDraw`/`customSize` like the gantt renderer.
///
/// Visual reference (meaning, not pixels):
/// https://github.com/mermaid-js/mermaid/blob/develop/packages/mermaid/src/diagrams/timeline/timelineRenderer.ts
///
/// Column widths derive from `RenderConfiguration.maxWidth` so a small
/// timeline fills the chat bubble and long event text wraps and truncates
/// with an ellipsis instead of overflowing. Diagrams with many periods are
/// allowed to grow wider than `maxWidth`; the inline view scales to fit and
/// fullscreen pinch-zoom is the inspection path.
enum MermaidTimelineRenderer {

    // MARK: - Layout constants

    private static let margin: CGFloat = 16
    private static let titleToBandGap: CGFloat = 10
    private static let bandPadX: CGFloat = 10
    private static let bandPaddingTop: CGFloat = 10
    private static let bandPaddingBottom: CGFloat = 14
    private static let sectionLabelGap: CGFloat = 8
    private static let labelToSpineGap: CGFloat = 10
    private static let spineToEventsGap: CGFloat = 14
    private static let columnGap: CGFloat = 22
    private static let sectionGap: CGFloat = 34
    private static let eventGap: CGFloat = 6
    private static let boxPaddingH: CGFloat = 8
    private static let boxPaddingV: CGFloat = 6
    private static let boxCornerRadius: CGFloat = 6
    private static let minColumnWidth: CGFloat = 100
    private static let maxColumnWidth: CGFloat = 240
    private static let maxTitleLines = 3
    private static let maxSectionHeadingLines = 2
    private static let maxPeriodLabelLines = 2
    private static let maxEventLines = 4
    private static let spineDotRadius: CGFloat = 4
    private static let spineArrowLength: CGFloat = 10
    private static let spineArrowHalf: CGFloat = 4

    // MARK: - Layout model (inspectable in tests)

    struct EventBoxPlacement: Equatable, Sendable {
        /// Final wrapped text, `\n`-separated, truncated with an ellipsis
        /// when it exceeds the line budget.
        let text: String
        let frame: CGRect
    }

    struct PeriodPlacement: Equatable, Sendable {
        let label: String
        let events: [String]
        let wrappedLabel: String
        let colorIndex: Int
        let centerX: CGFloat
        let columnFrame: CGRect
        let labelFrame: CGRect
        /// One box per event, stacked top to bottom under the spine.
        let eventBoxes: [EventBoxPlacement]
    }

    struct SectionPlacement: Equatable, Sendable {
        let name: String?
        let wrappedName: String?
        let headingFrame: CGRect?
        let colorIndex: Int
        let bandFrame: CGRect
        let periods: [PeriodPlacement]
    }

    struct LayoutModel: Equatable, Sendable {
        let title: String?
        let wrappedTitle: String?
        let titleFrame: CGRect?
        let size: CGSize
        let spineY: CGFloat
        let spineStartX: CGFloat
        let spineEndX: CGFloat
        let spineArrowTipX: CGFloat
        let sections: [SectionPlacement]
    }

    // MARK: - Public entry point

    nonisolated static func layout(
        _ diagram: TimelineDiagram,
        configuration: RenderConfiguration
    ) -> MermaidFlowchartRenderer.FlowchartLayout {
        let hasContent = diagram.sections.contains { !$0.periods.isEmpty }
        guard hasContent else {
            return MermaidFlowchartRenderer().placeholderLayout(
                text: "Empty timeline",
                configuration: configuration
            )
        }

        let theme = configuration.theme
        let fontSize = configuration.fontSize
        let model = buildLayout(diagram, configuration: configuration)
        let size = model.size

        let customDraw: @Sendable (CGContext, CGPoint) -> Void = { ctx, origin in
            draw(model, size: size, theme: theme, fontSize: fontSize, origin: origin, in: ctx)
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

    // MARK: - Layout computation

    nonisolated static func buildLayout(
        _ diagram: TimelineDiagram,
        configuration: RenderConfiguration
    ) -> LayoutModel {
        let fontSize = configuration.fontSize
        let maxWidth = configuration.maxWidth
        let titleFont = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize * 1.1, nil)
        let sectionFont = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize * 0.85, nil)
        let periodFont = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize * 0.9, nil)
        let eventFont = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.85, nil)

        let sections = diagram.sections.filter { !$0.periods.isEmpty }
        let totalPeriods = max(sections.reduce(0) { $0 + $1.periods.count }, 1)

        // Column width from the available width, clamped so phones stay
        // readable and wide timelines stay bounded per column.
        let usable = max(maxWidth, 320) - margin * 2
        let gaps = CGFloat(max(totalPeriods - 1, 0)) * columnGap
        let ideal = (usable - gaps) / CGFloat(totalPeriods)
        let columnWidth = min(max(ideal, minColumnWidth), maxColumnWidth)
        let labelWrapWidth = columnWidth
        let eventWrapWidth = columnWidth - boxPaddingH * 2

        let hasNamedSections = sections.contains { $0.name != nil }

        // Pre-wrap every label and event at the target column width.
        struct WrappedPeriod {
            let period: TimelinePeriod
            let colorIndex: Int
            let wrappedLabel: String
            let labelSize: CGSize
            let eventTexts: [String]
            let eventSizes: [CGSize]
        }
        struct WrappedSection {
            let name: String?
            let colorIndex: Int
            let periods: [WrappedPeriod]
        }

        var wrappedSections: [WrappedSection] = []
        var maxLabelHeight = MermaidTextUtils.measureText(
            " ", font: periodFont, fontSize: fontSize * 0.9
        ).height
        var maxStackHeight: CGFloat = 0

        for (sectionIndex, section) in sections.enumerated() {
            let sectionColor = sectionIndex % accentCount
            var wrappedPeriods: [WrappedPeriod] = []

            for (periodIndex, period) in section.periods.enumerated() {
                // Official multicolor: section color bands when sections
                // exist, otherwise each period gets its own color.
                let colorIndex = hasNamedSections ? sectionColor : periodIndex % accentCount

                let wrappedLabel = wrapTruncated(
                    period.label, font: periodFont,
                    maxWidth: labelWrapWidth, maxLines: maxPeriodLabelLines
                )
                let labelSize = MermaidTextUtils.measureText(
                    wrappedLabel, font: periodFont, fontSize: fontSize * 0.9
                )
                maxLabelHeight = max(maxLabelHeight, labelSize.height)

                var eventTexts: [String] = []
                var eventSizes: [CGSize] = []
                var stackHeight: CGFloat = 0
                for (i, event) in period.events.enumerated() {
                    let text = wrapTruncated(
                        event, font: eventFont,
                        maxWidth: eventWrapWidth, maxLines: maxEventLines
                    )
                    let textSize = MermaidTextUtils.measureText(
                        text, font: eventFont, fontSize: fontSize * 0.85
                    )
                    let boxSize = CGSize(
                        width: columnWidth,
                        height: textSize.height + boxPaddingV * 2
                    )
                    eventTexts.append(text)
                    eventSizes.append(boxSize)
                    stackHeight += boxSize.height
                    if i < period.events.count - 1 { stackHeight += eventGap }
                }
                maxStackHeight = max(maxStackHeight, stackHeight)

                wrappedPeriods.append(WrappedPeriod(
                    period: period,
                    colorIndex: colorIndex,
                    wrappedLabel: wrappedLabel,
                    labelSize: labelSize,
                    eventTexts: eventTexts,
                    eventSizes: eventSizes
                ))
            }

            wrappedSections.append(WrappedSection(
                name: section.name,
                colorIndex: sectionColor,
                periods: wrappedPeriods
            ))
        }

        // Horizontal geometry first so title and section headings can wrap
        // to the final canvas / band widths.
        let sectionWidths = wrappedSections.map { section in
            CGFloat(section.periods.count) * columnWidth
                + CGFloat(max(section.periods.count - 1, 0)) * columnGap
                + bandPadX * 2
        }
        let naturalWidth = sectionWidths.reduce(0, +)
            + CGFloat(max(sectionWidths.count - 1, 0)) * sectionGap
            + margin * 2
        let totalWidth = max(naturalWidth, maxWidth)
        let offsetX = (totalWidth - naturalWidth) / 2

        // Title wraps to the bubble even when the period row is wider.
        let titleWrapWidth = max(min(totalWidth, maxWidth) - margin * 2, 40)
        var wrappedTitle: String?
        var titleSize = CGSize.zero
        if let title = diagram.title {
            let wrapped = wrapTruncated(
                title, font: titleFont,
                maxWidth: titleWrapWidth, maxLines: maxTitleLines
            )
            wrappedTitle = wrapped
            titleSize = MermaidTextUtils.measureText(
                wrapped, font: titleFont, fontSize: fontSize * 1.1
            )
        }
        let titleFrame = wrappedTitle.map { _ in
            CGRect(x: margin, y: margin, width: titleWrapWidth, height: titleSize.height)
        }
        let titleBlock = wrappedTitle == nil ? 0 : titleSize.height + titleToBandGap

        var wrappedNames: [String?] = []
        var headingSizes: [CGSize] = []
        var maxHeadingHeight: CGFloat = 0
        for (sectionIndex, section) in wrappedSections.enumerated() {
            guard let name = section.name else {
                wrappedNames.append(nil)
                headingSizes.append(.zero)
                continue
            }
            let wrapWidth = max(sectionWidths[sectionIndex] - bandPadX * 2, 40)
            let wrapped = wrapTruncated(
                name, font: sectionFont,
                maxWidth: wrapWidth, maxLines: maxSectionHeadingLines
            )
            let size = MermaidTextUtils.measureText(
                wrapped, font: sectionFont, fontSize: fontSize * 0.85
            )
            wrappedNames.append(wrapped)
            headingSizes.append(size)
            maxHeadingHeight = max(maxHeadingHeight, size.height)
        }

        let bandTop = margin + titleBlock
        let sectionHeaderBlock = hasNamedSections
            ? maxHeadingHeight + sectionLabelGap
            : 0
        let spineInBand = bandPaddingTop + sectionHeaderBlock + maxLabelHeight + labelToSpineGap
        let spineY = bandTop + spineInBand
        let bandHeight = spineInBand + spineToEventsGap + maxStackHeight + bandPaddingBottom
        let labelTopY = bandTop + bandPaddingTop + sectionHeaderBlock

        var placements: [SectionPlacement] = []
        var x = margin + offsetX

        for (sectionIndex, section) in wrappedSections.enumerated() {
            let bandFrame = CGRect(
                x: x, y: bandTop,
                width: sectionWidths[sectionIndex], height: bandHeight
            )
            let headingFrame: CGRect? = section.name == nil ? nil : CGRect(
                x: x + bandPadX,
                y: bandTop + bandPaddingTop,
                width: sectionWidths[sectionIndex] - bandPadX * 2,
                height: headingSizes[sectionIndex].height
            )

            var periodPlacements: [PeriodPlacement] = []
            var periodX = x + bandPadX

            for wrapped in section.periods {
                let centerX = periodX + columnWidth / 2
                let columnFrame = CGRect(
                    x: periodX, y: bandTop,
                    width: columnWidth, height: bandHeight
                )
                let labelFrame = CGRect(
                    x: periodX, y: labelTopY,
                    width: columnWidth, height: wrapped.labelSize.height
                )

                var eventBoxes: [EventBoxPlacement] = []
                var boxY = spineY + spineToEventsGap
                for (text, boxSize) in zip(wrapped.eventTexts, wrapped.eventSizes) {
                    eventBoxes.append(EventBoxPlacement(
                        text: text,
                        frame: CGRect(x: periodX, y: boxY, width: boxSize.width, height: boxSize.height)
                    ))
                    boxY += boxSize.height + eventGap
                }

                periodPlacements.append(PeriodPlacement(
                    label: wrapped.period.label,
                    events: wrapped.period.events,
                    wrappedLabel: wrapped.wrappedLabel,
                    colorIndex: wrapped.colorIndex,
                    centerX: centerX,
                    columnFrame: columnFrame,
                    labelFrame: labelFrame,
                    eventBoxes: eventBoxes
                ))
                periodX += columnWidth + columnGap
            }

            placements.append(SectionPlacement(
                name: section.name,
                wrappedName: wrappedNames[sectionIndex],
                headingFrame: headingFrame,
                colorIndex: section.colorIndex,
                bandFrame: bandFrame,
                periods: periodPlacements
            ))
            x += sectionWidths[sectionIndex] + sectionGap
        }

        let spineStartX = placements.first?.periods.first?.columnFrame.minX ?? margin
        let spineEndX = placements.last?.periods.last?.columnFrame.maxX ?? spineStartX
        let spineArrowTipX = spineEndX + spineArrowLength
        let canvasWidth = max(totalWidth, spineArrowTipX + margin)

        return LayoutModel(
            title: diagram.title,
            wrappedTitle: wrappedTitle,
            titleFrame: titleFrame,
            size: CGSize(width: canvasWidth, height: bandTop + bandHeight + margin),
            spineY: spineY,
            spineStartX: spineStartX,
            spineEndX: spineEndX,
            spineArrowTipX: spineArrowTipX,
            sections: placements
        )
    }

    // MARK: - Drawing

    private static func draw(
        _ model: LayoutModel,
        size: CGSize,
        theme: RenderTheme,
        fontSize: CGFloat,
        origin: CGPoint,
        in ctx: CGContext
    ) {
        let ox = origin.x
        let oy = origin.y

        // Background.
        ctx.setFillColor(theme.background)
        ctx.fill(CGRect(origin: origin, size: size))

        let titleFont = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize * 1.1, nil)
        let sectionFont = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize * 0.85, nil)
        let periodFont = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize * 0.9, nil)
        let eventFont = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.85, nil)
        let accents = accentColors(theme)

        if let wrappedTitle = model.wrappedTitle, let titleFrame = model.titleFrame {
            MermaidTextUtils.drawText(
                wrappedTitle,
                at: CGPoint(x: ox + titleFrame.minX, y: oy + titleFrame.minY),
                width: titleFrame.width,
                font: titleFont,
                fontSize: fontSize * 1.1,
                foregroundColor: theme.foreground,
                in: ctx
            )
        }

        for section in model.sections {
            let sectionColor = accents[section.colorIndex % accents.count]
            let band = section.bandFrame.offsetBy(dx: ox, dy: oy)

            // Section color band (named sections only).
            if let name = section.wrappedName ?? section.name {
                ctx.saveGState()
                let bandPath = CGPath(
                    roundedRect: band,
                    cornerWidth: 8, cornerHeight: 8,
                    transform: nil
                )
                ctx.setFillColor(sectionColor.copy(alpha: 0.07) ?? sectionColor)
                ctx.addPath(bandPath)
                ctx.fillPath()
                ctx.setStrokeColor(sectionColor.copy(alpha: 0.22) ?? sectionColor)
                ctx.setLineWidth(0.75)
                ctx.addPath(bandPath)
                ctx.strokePath()
                ctx.restoreGState()

                let headingOrigin: CGPoint
                let headingWidth: CGFloat
                if let headingFrame = section.headingFrame {
                    headingOrigin = CGPoint(
                        x: ox + headingFrame.minX,
                        y: oy + headingFrame.minY
                    )
                    headingWidth = headingFrame.width
                } else {
                    headingOrigin = CGPoint(x: band.minX + bandPadX, y: band.minY + bandPaddingTop)
                    headingWidth = band.width - bandPadX * 2
                }
                MermaidTextUtils.drawText(
                    name,
                    at: headingOrigin,
                    width: headingWidth,
                    font: sectionFont,
                    fontSize: fontSize * 0.85,
                    foregroundColor: sectionColor,
                    in: ctx
                )
            }
        }

        // One continuous spine across every section, plus a terminal arrow
        // so chronology still reads left-to-right through the gaps.
        if !model.sections.isEmpty {
            ctx.saveGState()
            ctx.setStrokeColor(theme.comment.copy(alpha: 0.6) ?? theme.comment)
            ctx.setLineWidth(1.5)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: ox + model.spineStartX, y: oy + model.spineY))
            ctx.addLine(to: CGPoint(x: ox + model.spineArrowTipX, y: oy + model.spineY))
            ctx.strokePath()

            let tip = CGPoint(x: ox + model.spineArrowTipX, y: oy + model.spineY)
            ctx.move(to: tip)
            ctx.addLine(to: CGPoint(
                x: tip.x - spineArrowLength,
                y: tip.y - spineArrowHalf
            ))
            ctx.move(to: tip)
            ctx.addLine(to: CGPoint(
                x: tip.x - spineArrowLength,
                y: tip.y + spineArrowHalf
            ))
            ctx.strokePath()
            ctx.restoreGState()
        }

        for section in model.sections {
            for period in section.periods {
                let color = accents[period.colorIndex % accents.count]

                // Period label above the spine.
                MermaidTextUtils.drawText(
                    period.wrappedLabel,
                    at: CGPoint(x: ox + period.labelFrame.minX, y: oy + period.labelFrame.minY),
                    width: period.labelFrame.width,
                    font: periodFont,
                    fontSize: fontSize * 0.9,
                    foregroundColor: color,
                    alignment: .center,
                    in: ctx
                )

                // Spine dot.
                ctx.saveGState()
                ctx.setFillColor(color)
                ctx.fillEllipse(in: CGRect(
                    x: ox + period.centerX - spineDotRadius,
                    y: oy + model.spineY - spineDotRadius,
                    width: spineDotRadius * 2,
                    height: spineDotRadius * 2
                ))
                ctx.restoreGState()

                // Connector from the spine to the first event box.
                if let firstBox = period.eventBoxes.first {
                    ctx.saveGState()
                    ctx.setStrokeColor(color.copy(alpha: 0.45) ?? color)
                    ctx.setLineWidth(1)
                    ctx.move(to: CGPoint(
                        x: ox + period.centerX,
                        y: oy + model.spineY + spineDotRadius + 1
                    ))
                    ctx.addLine(to: CGPoint(x: ox + period.centerX, y: oy + firstBox.frame.minY))
                    ctx.strokePath()
                    ctx.restoreGState()
                }

                // Event boxes stacked under the period.
                for (i, box) in period.eventBoxes.enumerated() {
                    let rect = box.frame.offsetBy(dx: ox, dy: oy)

                    // Connector from the previous box.
                    if i > 0 {
                        let previous = period.eventBoxes[i - 1].frame
                        ctx.saveGState()
                        ctx.setStrokeColor(color.copy(alpha: 0.35) ?? color)
                        ctx.setLineWidth(1)
                        ctx.move(to: CGPoint(x: ox + period.centerX, y: oy + previous.maxY))
                        ctx.addLine(to: CGPoint(x: ox + period.centerX, y: oy + rect.minY))
                        ctx.strokePath()
                        ctx.restoreGState()
                    }

                    ctx.saveGState()
                    let boxPath = CGPath(
                        roundedRect: rect,
                        cornerWidth: boxCornerRadius, cornerHeight: boxCornerRadius,
                        transform: nil
                    )
                    ctx.setFillColor(color.copy(alpha: 0.16) ?? color)
                    ctx.addPath(boxPath)
                    ctx.fillPath()
                    ctx.setStrokeColor(color.copy(alpha: 0.5) ?? color)
                    ctx.setLineWidth(0.75)
                    ctx.addPath(boxPath)
                    ctx.strokePath()
                    ctx.restoreGState()

                    MermaidTextUtils.drawText(
                        box.text,
                        centeredIn: rect.insetBy(dx: boxPaddingH, dy: boxPaddingV),
                        font: eventFont,
                        fontSize: fontSize * 0.85,
                        foregroundColor: theme.foreground,
                        in: ctx
                    )
                }
            }
        }
    }

    // MARK: - Colors

    private static let accentCount = 6

    /// Oppi-theme cycle standing in for Mermaid's `cScale0`..`cScale11`.
    private static func accentColors(_ theme: RenderTheme) -> [CGColor] {
        [
            theme.accentBlue,
            theme.accentGreen,
            theme.accentPurple,
            theme.accentOrange,
            theme.accentCyan,
            theme.accentRed,
        ]
    }

    // MARK: - Text wrapping

    /// Wrap text to a width and cap the line count, truncating the last
    /// kept line with an ellipsis when text is dropped.
    ///
    /// Existing newlines from `<br>` are kept as hard breaks, then each
    /// paragraph is wrapped independently.
    private static func wrapTruncated(
        _ text: String,
        font: CTFont,
        maxWidth: CGFloat,
        maxLines: Int
    ) -> String {
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lines: [String] = []
        for paragraph in paragraphs {
            if paragraph.isEmpty {
                lines.append("")
            } else {
                lines.append(contentsOf: suggestLineBreaks(paragraph, font: font, maxWidth: maxWidth))
            }
        }
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

        // Unbreakable tokens can still exceed the width after line breaking;
        // clamp every line so boxes never overflow.
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
}
