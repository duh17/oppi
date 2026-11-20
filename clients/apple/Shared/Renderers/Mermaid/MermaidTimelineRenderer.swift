import CoreGraphics
import CoreText
import Foundation

/// Renderer for Mermaid timeline diagrams.
///
/// Draws official `LR` (default) and `TD` chronology.
///
/// LR: horizontal spine, period labels above, events stacked under each
/// period, named-section bands side by side.
/// TD: vertical spine, period labels to the left, events stacked to the
/// right, named-section bands stacked top to bottom.
/// Uses the shared `FlowchartLayout` container with
/// `customDraw`/`customSize` like the gantt renderer.
///
/// Visual reference (meaning, not pixels):
/// https://github.com/mermaid-js/mermaid/blob/develop/packages/mermaid/src/diagrams/timeline/timelineRenderer.ts
///
/// Column widths derive from `RenderConfiguration.maxWidth` so a small
/// timeline fills the chat bubble and long event text wraps and truncates
/// with an ellipsis instead of overflowing. An LR timeline with too many
/// periods to fit `maxWidth` side by side is drawn top-down instead, which
/// always fits the width and grows in height, unless the surface's height
/// cap would then shrink it more than the side-by-side layout.
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
    private static let periodRowGap: CGFloat = 12
    private static let tdSpineGap: CGFloat = 12
    private static let tdEventLead: CGFloat = 16

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
        let centerY: CGFloat
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
        let direction: TimelineDirection
        let spineY: CGFloat
        let spineX: CGFloat
        let spineStartX: CGFloat
        let spineEndX: CGFloat
        let spineArrowTipX: CGFloat
        let spineStartY: CGFloat
        let spineEndY: CGFloat
        let spineArrowTipY: CGFloat
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
        return .custom(size: model.size, configuration: configuration) { ctx, origin in
            draw(model, theme: theme, fontSize: fontSize, origin: origin, in: ctx)
        }
    }

    private struct Fonts {
        let title: CTFont
        let section: CTFont
        let period: CTFont
        let event: CTFont

        init(fontSize: CGFloat) {
            title = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize * 1.1, nil)
            section = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize * 0.85, nil)
            period = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize * 0.9, nil)
            event = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.85, nil)
        }
    }

    // MARK: - Layout computation

    nonisolated static func buildLayout(
        _ diagram: TimelineDiagram,
        configuration: RenderConfiguration
    ) -> LayoutModel {
        if diagram.direction == .TD {
            return buildLayoutTD(diagram, configuration: configuration)
        }
        // Top-down is used only when it shows larger on screen: a long
        // timeline the inline height cap would shrink more stays across.
        let across = buildLayoutLR(diagram, configuration: configuration)
        var choice = RenderFitChoice(natural: across, size: across.size, configuration: configuration)
        guard choice.canImprove(minimumWidth: 0) else { return across }
        let down = buildLayoutTD(diagram, configuration: configuration)
        choice.consider(down, size: down.size)
        return choice.best
    }

    private static func buildLayoutLR(
        _ diagram: TimelineDiagram,
        configuration: RenderConfiguration
    ) -> LayoutModel {
        let fontSize = configuration.fontSize
        let maxWidth = configuration.maxWidth
        let fonts = Fonts(fontSize: fontSize)

        let sections = diagram.sections.filter { !$0.periods.isEmpty }
        let totalPeriods = max(sections.reduce(0) { $0 + $1.periods.count }, 1)

        // Column width from the available width, clamped so phones stay
        // readable and wide timelines stay bounded per column.
        // Fixed space between columns: column gaps inside each section band,
        // band padding, and the gaps between bands.
        let usable = max(maxWidth, 320) - margin * 2
        let sectionCount = max(sections.count, 1)
        let gaps = CGFloat(max(totalPeriods - sectionCount, 0)) * columnGap
            + CGFloat(sectionCount - 1) * sectionGap
            + CGFloat(sectionCount) * bandPadX * 2
        let ideal = (usable - gaps) / CGFloat(totalPeriods)
        let columnWidth = min(max(ideal, minColumnWidth), maxColumnWidth)

        // Pre-wrap every label and event at the target column width.
        let wrappedSections = wrapSections(
            sections,
            fonts: fonts,
            fontSize: fontSize,
            labelWidth: columnWidth,
            eventWrapWidth: columnWidth - boxPaddingH * 2,
            boxWidth: columnWidth
        )
        let hasNamedSections = sections.contains { $0.name != nil }
        let allPeriods = wrappedSections.flatMap(\.periods)
        let maxLabelHeight = allPeriods.reduce(
            MermaidTextUtils.measureText(" ", font: fonts.period, fontSize: fontSize * 0.9).height
        ) { max($0, $1.labelSize.height) }
        let maxStackHeight = allPeriods.reduce(CGFloat(0)) { max($0, $1.stackHeight) }

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
        let title = layoutTitle(
            diagram.title,
            fonts: fonts,
            fontSize: fontSize,
            wrapWidth: max(min(totalWidth, maxWidth) - margin * 2, 40)
        )

        var headings: [(text: String, size: CGSize)?] = []
        var maxHeadingHeight: CGFloat = 0
        for (sectionIndex, section) in wrappedSections.enumerated() {
            guard let name = section.name else {
                headings.append(nil)
                continue
            }
            let heading = wrap(
                name, font: fonts.section, fontSize: fontSize * 0.85,
                maxWidth: max(sectionWidths[sectionIndex] - bandPadX * 2, 40),
                maxLines: maxSectionHeadingLines
            )
            headings.append(heading)
            maxHeadingHeight = max(maxHeadingHeight, heading.size.height)
        }

        let bandTop = margin + title.block
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
                height: headings[sectionIndex]?.size.height ?? 0
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
                periodPlacements.append(wrapped.placement(
                    centerX: centerX,
                    centerY: spineY,
                    columnFrame: columnFrame,
                    labelFrame: labelFrame,
                    boxX: periodX,
                    boxTop: spineY + spineToEventsGap
                ))
                periodX += columnWidth + columnGap
            }

            placements.append(SectionPlacement(
                name: section.name,
                wrappedName: headings[sectionIndex]?.text,
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
            wrappedTitle: title.wrapped,
            titleFrame: title.frame,
            size: CGSize(width: canvasWidth, height: bandTop + bandHeight + margin),
            direction: diagram.direction,
            spineY: spineY,
            spineX: 0,
            spineStartX: spineStartX,
            spineEndX: spineEndX,
            spineArrowTipX: spineArrowTipX,
            spineStartY: spineY,
            spineEndY: spineY,
            spineArrowTipY: spineY,
            sections: placements
        )
    }

    /// Top-down chronology: one vertical spine, periods stacked in source
    /// order, labels on the left, events on the right. Stays within
    /// `maxWidth`; height grows with content.
    private static func buildLayoutTD(
        _ diagram: TimelineDiagram,
        configuration: RenderConfiguration
    ) -> LayoutModel {
        let fontSize = configuration.fontSize
        let maxWidth = configuration.maxWidth
        let fonts = Fonts(fontSize: fontSize)

        let sections = diagram.sections.filter { !$0.periods.isEmpty }

        let totalWidth = max(maxWidth, 320)
        let inner = max(totalWidth - margin * 2, 80)
        var labelCol = min(max(96, inner * 0.30), 140)
        var eventWidth = inner - bandPadX * 2 - labelCol - tdSpineGap - tdEventLead
        if eventWidth < 80 {
            labelCol = max(72, labelCol - (80 - eventWidth))
            eventWidth = inner - bandPadX * 2 - labelCol - tdSpineGap - tdEventLead
        }
        eventWidth = max(eventWidth, 72)

        let wrappedSections = wrapSections(
            sections,
            fonts: fonts,
            fontSize: fontSize,
            labelWidth: labelCol,
            eventWrapWidth: max(eventWidth - boxPaddingH * 2, 40),
            boxWidth: eventWidth
        )

        let title = layoutTitle(diagram.title, fonts: fonts, fontSize: fontSize, wrapWidth: max(inner, 40))

        let spineX = margin + bandPadX + labelCol + tdSpineGap
        let eventX = spineX + tdEventLead
        var y = margin + title.block
        var placements: [SectionPlacement] = []

        for section in wrappedSections {
            let bandTop = y
            let headingWrapWidth = max(inner - bandPadX * 2, 40)
            var headingFrame: CGRect?
            var wrappedName: String?
            var headingHeight: CGFloat = 0
            if let name = section.name {
                let heading = wrap(
                    name, font: fonts.section, fontSize: fontSize * 0.85,
                    maxWidth: headingWrapWidth, maxLines: maxSectionHeadingLines
                )
                wrappedName = heading.text
                headingHeight = heading.size.height
                headingFrame = CGRect(
                    x: margin + bandPadX,
                    y: bandTop + bandPaddingTop,
                    width: headingWrapWidth,
                    height: headingHeight
                )
            }

            var periodY = bandTop + bandPaddingTop
                + (headingHeight == 0 ? 0 : headingHeight + sectionLabelGap)
            var periodPlacements: [PeriodPlacement] = []

            for wrapped in section.periods {
                let rowHeight = max(wrapped.labelSize.height, wrapped.stackHeight, 16)
                let columnFrame = CGRect(
                    x: margin, y: periodY, width: inner, height: rowHeight
                )
                let labelFrame = CGRect(
                    x: margin + bandPadX,
                    y: periodY + (rowHeight - wrapped.labelSize.height) / 2,
                    width: labelCol,
                    height: wrapped.labelSize.height
                )
                periodPlacements.append(wrapped.placement(
                    centerX: spineX,
                    centerY: periodY + rowHeight / 2,
                    columnFrame: columnFrame,
                    labelFrame: labelFrame,
                    boxX: eventX,
                    boxTop: periodY + max(rowHeight - wrapped.stackHeight, 0) / 2
                ))
                periodY += rowHeight + periodRowGap
            }
            if !section.periods.isEmpty {
                periodY -= periodRowGap
            }

            let bandHeight = max(periodY - bandTop, headingHeight) + bandPaddingBottom
            placements.append(SectionPlacement(
                name: section.name,
                wrappedName: wrappedName,
                headingFrame: headingFrame,
                colorIndex: section.colorIndex,
                bandFrame: CGRect(x: margin, y: bandTop, width: inner, height: bandHeight),
                periods: periodPlacements
            ))
            y = bandTop + bandHeight + sectionGap
        }
        if !placements.isEmpty {
            y -= sectionGap
        }

        let spineStartY = placements.first?.periods.first?.centerY ?? y
        let spineEndY = placements.last?.periods.last?.centerY ?? spineStartY
        let spineArrowTipY = spineEndY + spineArrowLength
        let canvasHeight = max(y + margin, spineArrowTipY + margin)

        return LayoutModel(
            title: diagram.title,
            wrappedTitle: title.wrapped,
            titleFrame: title.frame,
            size: CGSize(width: totalWidth, height: canvasHeight),
            direction: .TD,
            spineY: spineStartY,
            spineX: spineX,
            spineStartX: spineX,
            spineEndX: spineX,
            spineArrowTipX: spineX,
            spineStartY: spineStartY,
            spineEndY: spineEndY,
            spineArrowTipY: spineArrowTipY,
            sections: placements
        )
    }

    // MARK: - Wrapping (both directions)

    private struct WrappedPeriod {
        let period: TimelinePeriod
        let colorIndex: Int
        let wrappedLabel: String
        let labelSize: CGSize
        let eventTexts: [String]
        let eventSizes: [CGSize]
        let stackHeight: CGFloat

        /// Event boxes stack down from `boxTop` at `boxX`.
        func placement(
            centerX: CGFloat,
            centerY: CGFloat,
            columnFrame: CGRect,
            labelFrame: CGRect,
            boxX: CGFloat,
            boxTop: CGFloat
        ) -> PeriodPlacement {
            var eventBoxes: [EventBoxPlacement] = []
            var boxY = boxTop
            for (text, boxSize) in zip(eventTexts, eventSizes) {
                eventBoxes.append(EventBoxPlacement(
                    text: text,
                    frame: CGRect(x: boxX, y: boxY, width: boxSize.width, height: boxSize.height)
                ))
                boxY += boxSize.height + eventGap
            }
            return PeriodPlacement(
                label: period.label,
                events: period.events,
                wrappedLabel: wrappedLabel,
                colorIndex: colorIndex,
                centerX: centerX,
                centerY: centerY,
                columnFrame: columnFrame,
                labelFrame: labelFrame,
                eventBoxes: eventBoxes
            )
        }
    }

    private struct WrappedSection {
        let name: String?
        let colorIndex: Int
        let periods: [WrappedPeriod]
    }

    /// Wrap every period label and event. Official multicolor: section
    /// color bands when sections are named, otherwise each period gets its
    /// own color.
    private static func wrapSections(
        _ sections: [TimelineSection],
        fonts: Fonts,
        fontSize: CGFloat,
        labelWidth: CGFloat,
        eventWrapWidth: CGFloat,
        boxWidth: CGFloat
    ) -> [WrappedSection] {
        let hasNamedSections = sections.contains { $0.name != nil }
        return sections.enumerated().map { sectionIndex, section in
            let sectionColor = sectionIndex % accentCount
            let periods = section.periods.enumerated().map { periodIndex, period in
                let label = wrap(
                    period.label, font: fonts.period, fontSize: fontSize * 0.9,
                    maxWidth: labelWidth, maxLines: maxPeriodLabelLines
                )
                var eventTexts: [String] = []
                var eventSizes: [CGSize] = []
                var stackHeight: CGFloat = 0
                for (i, event) in period.events.enumerated() {
                    let text = wrap(
                        event, font: fonts.event, fontSize: fontSize * 0.85,
                        maxWidth: eventWrapWidth, maxLines: maxEventLines
                    )
                    let boxSize = CGSize(width: boxWidth, height: text.size.height + boxPaddingV * 2)
                    eventTexts.append(text.text)
                    eventSizes.append(boxSize)
                    stackHeight += boxSize.height
                    if i < period.events.count - 1 { stackHeight += eventGap }
                }
                return WrappedPeriod(
                    period: period,
                    colorIndex: hasNamedSections ? sectionColor : periodIndex % accentCount,
                    wrappedLabel: label.text,
                    labelSize: label.size,
                    eventTexts: eventTexts,
                    eventSizes: eventSizes,
                    stackHeight: stackHeight
                )
            }
            return WrappedSection(name: section.name, colorIndex: sectionColor, periods: periods)
        }
    }

    private static func layoutTitle(
        _ title: String?,
        fonts: Fonts,
        fontSize: CGFloat,
        wrapWidth: CGFloat
    ) -> (wrapped: String?, frame: CGRect?, block: CGFloat) {
        guard let title else { return (nil, nil, 0) }
        let wrapped = wrap(
            title, font: fonts.title, fontSize: fontSize * 1.1,
            maxWidth: wrapWidth, maxLines: maxTitleLines
        )
        return (
            wrapped.text,
            CGRect(x: margin, y: margin, width: wrapWidth, height: wrapped.size.height),
            wrapped.size.height + titleToBandGap
        )
    }

    /// Word-wrapped to `maxWidth`, at most `maxLines` (ellipsized), `<br>`
    /// breaks kept, and measured.
    private static func wrap(
        _ text: String,
        font: CTFont,
        fontSize: CGFloat,
        maxWidth: CGFloat,
        maxLines: Int
    ) -> (text: String, size: CGSize) {
        let wrapped = MermaidTextUtils.wrapTruncated(
            text, font: font,
            maxWidth: maxWidth, maxLines: maxLines,
            preservesHardBreaks: true, breaksOnWords: true
        )
        return (wrapped, MermaidTextUtils.measureText(wrapped, font: font, fontSize: fontSize))
    }

    // MARK: - Drawing

    /// One drawing pass for both directions. LR: spine across, labels above
    /// it, events stacked below. TD: spine down, labels left, events right.
    private static func draw(
        _ model: LayoutModel,
        theme: RenderTheme,
        fontSize: CGFloat,
        origin: CGPoint,
        in ctx: CGContext
    ) {
        let ox = origin.x
        let oy = origin.y
        let isTD = model.direction == .TD
        let fonts = Fonts(fontSize: fontSize)
        let accents = accentColors(theme)

        if let wrappedTitle = model.wrappedTitle, let titleFrame = model.titleFrame {
            MermaidTextUtils.drawText(
                wrappedTitle,
                at: CGPoint(x: ox + titleFrame.minX, y: oy + titleFrame.minY),
                width: titleFrame.width,
                font: fonts.title,
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
                    font: fonts.section,
                    fontSize: fontSize * 0.85,
                    foregroundColor: sectionColor,
                    in: ctx
                )
            }
        }

        // One continuous spine across every section, plus a terminal arrow
        // so chronology still reads through the gaps.
        if !model.sections.isEmpty {
            ctx.saveGState()
            ctx.setStrokeColor(theme.comment.copy(alpha: 0.6) ?? theme.comment)
            ctx.setLineWidth(1.5)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            let tip = CGPoint(x: ox + model.spineArrowTipX, y: oy + model.spineArrowTipY)
            ctx.move(to: CGPoint(x: ox + model.spineStartX, y: oy + model.spineStartY))
            ctx.addLine(to: tip)
            ctx.strokePath()

            ctx.move(to: tip)
            if isTD {
                ctx.addLine(to: CGPoint(x: tip.x - spineArrowHalf, y: tip.y - spineArrowLength))
                ctx.move(to: tip)
                ctx.addLine(to: CGPoint(x: tip.x + spineArrowHalf, y: tip.y - spineArrowLength))
            } else {
                ctx.addLine(to: CGPoint(x: tip.x - spineArrowLength, y: tip.y - spineArrowHalf))
                ctx.move(to: tip)
                ctx.addLine(to: CGPoint(x: tip.x - spineArrowLength, y: tip.y + spineArrowHalf))
            }
            ctx.strokePath()
            ctx.restoreGState()
        }

        for section in model.sections {
            for period in section.periods {
                let color = accents[period.colorIndex % accents.count]

                MermaidTextUtils.drawText(
                    period.wrappedLabel,
                    at: CGPoint(x: ox + period.labelFrame.minX, y: oy + period.labelFrame.minY),
                    width: period.labelFrame.width,
                    font: fonts.period,
                    fontSize: fontSize * 0.9,
                    foregroundColor: color,
                    alignment: isTD ? .right : .center,
                    in: ctx
                )

                // Spine dot.
                ctx.saveGState()
                ctx.setFillColor(color)
                ctx.fillEllipse(in: CGRect(
                    x: ox + period.centerX - spineDotRadius,
                    y: oy + period.centerY - spineDotRadius,
                    width: spineDotRadius * 2,
                    height: spineDotRadius * 2
                ))
                ctx.restoreGState()

                // Connector from the spine to the first event box.
                if let firstBox = period.eventBoxes.first {
                    ctx.saveGState()
                    ctx.setStrokeColor(color.copy(alpha: 0.45) ?? color)
                    ctx.setLineWidth(1)
                    if isTD {
                        ctx.move(to: CGPoint(
                            x: ox + period.centerX + spineDotRadius + 1,
                            y: oy + period.centerY
                        ))
                        ctx.addLine(to: CGPoint(x: ox + firstBox.frame.minX, y: oy + firstBox.frame.midY))
                    } else {
                        ctx.move(to: CGPoint(
                            x: ox + period.centerX,
                            y: oy + period.centerY + spineDotRadius + 1
                        ))
                        ctx.addLine(to: CGPoint(x: ox + period.centerX, y: oy + firstBox.frame.minY))
                    }
                    ctx.strokePath()
                    ctx.restoreGState()
                }

                // Event boxes stacked under (LR) or beside (TD) the period.
                for (i, box) in period.eventBoxes.enumerated() {
                    let rect = box.frame.offsetBy(dx: ox, dy: oy)

                    // Connector from the previous box.
                    if i > 0 {
                        let previous = period.eventBoxes[i - 1].frame
                        ctx.saveGState()
                        ctx.setStrokeColor(color.copy(alpha: 0.35) ?? color)
                        ctx.setLineWidth(1)
                        ctx.move(to: CGPoint(x: ox + (isTD ? previous.midX : period.centerX), y: oy + previous.maxY))
                        ctx.addLine(to: CGPoint(x: ox + (isTD ? rect.midX : period.centerX), y: oy + rect.minY))
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
                        font: fonts.event,
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
}
