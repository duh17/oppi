import CoreGraphics
import CoreText
import Foundation

/// Renderer for Mermaid sequence diagrams.
///
/// Draws participants across the top, vertical lifelines, and horizontal
/// message arrows between them. Returns a `FlowchartLayout` with `customDraw`
/// and `customSize` set — the flowchart renderer delegates to these when drawing.
///
/// All methods are `nonisolated static`. The draw closure captures only value
/// types and the pre-computed layout, keeping everything `Sendable`.
enum MermaidSequenceRenderer {

    // MARK: - Layout constants

    private struct Constants {
        let fontSize: CGFloat
        /// Horizontal padding inside participant boxes.
        var boxPadH: CGFloat { fontSize * 1.2 }
        /// Vertical padding inside participant boxes.
        var boxPadV: CGFloat { fontSize * 0.6 }
        /// Minimum horizontal gap between participant boxes.
        var participantGap: CGFloat { fontSize * 4 }
        /// Vertical spacing between consecutive messages.
        var messageSpacing: CGFloat { fontSize * 3 }
        /// Top margin above participant boxes.
        var topMargin: CGFloat { fontSize }
        /// Space below participant boxes before first message.
        var headerGap: CGFloat { fontSize * 2 }
        /// Bottom margin below last message.
        var bottomMargin: CGFloat { fontSize * 2 }
        /// Left/right margin around the diagram.
        var sideMargin: CGFloat { fontSize * 1.5 }
        /// Height of the self-message loopback arc.
        var selfMessageHeight: CGFloat { fontSize * 2.5 }
        /// Horizontal offset for self-message loopback.
        var selfMessageWidth: CGFloat { fontSize * 3 }
        /// Dash pattern for dashed lines.
        var dashLengths: [CGFloat] { [fontSize * 0.4, fontSize * 0.3] }
        /// Lifeline dash pattern.
        var lifelineDash: [CGFloat] { [fontSize * 0.35, fontSize * 0.25] }
        /// Arrowhead size.
        var arrowSize: CGFloat { fontSize * 0.5 }
        /// Cross marker size.
        var crossSize: CGFloat { fontSize * 0.4 }
        /// Gap between message arrow and label text.
        var labelGap: CGFloat { fontSize * 0.3 }
        /// Actor stick-figure height.
        var actorHeight: CGFloat { fontSize * 2.5 }
    }

    /// Pre-computed positions for a single participant column.
    private struct ParticipantLayout: Sendable {
        let id: String
        let label: String
        let isActor: Bool
        /// Center-X of this participant's lifeline.
        let centerX: CGFloat
        /// Bounding rect of the participant box at the top.
        let boxRect: CGRect
    }

    /// Pre-computed position for a single message row.
    private struct MessageLayout: Sendable {
        let message: SequenceMessage
        /// Y coordinate of this message's arrow.
        let y: CGFloat
    }

    // MARK: - Public entry point

    nonisolated static func layout(
        _ diagram: SequenceDiagram,
        configuration: RenderConfiguration
    ) -> MermaidFlowchartRenderer.FlowchartLayout {
        guard !diagram.participants.isEmpty else {
            return emptyLayout(configuration: configuration)
        }

        let c = Constants(fontSize: configuration.fontSize)
        let font = CTFontCreateWithName("Helvetica" as CFString, c.fontSize, nil)

        // Measure all participant labels to determine box widths.
        var labelSizes: [String: CGSize] = [:]
        for p in diagram.participants {
            labelSizes[p.id] = measureText(p.label, font: font, fontSize: c.fontSize)
        }

        // Measure all message labels.
        var messageSizes: [CGSize] = []
        for msg in diagram.messages {
            messageSizes.append(measureText(msg.text, font: font, fontSize: c.fontSize))
        }

        // Compute box widths.
        var boxWidths: [String: CGFloat] = [:]
        for p in diagram.participants {
            let textW = labelSizes[p.id]?.width ?? 0
            boxWidths[p.id] = textW + c.boxPadH * 2
        }

        // Build index for participant ordering.
        var participantIndex: [String: Int] = [:]
        for (i, p) in diagram.participants.enumerated() {
            participantIndex[p.id] = i
        }

        // Ensure neighboring participants have enough gap for message labels.
        // For each message, the distance between from/to must fit the label.
        var minSpan: [Int: CGFloat] = [:] // min span index → minimum distance between centers
        for (i, msg) in diagram.messages.enumerated() {
            guard let fromIdx = participantIndex[msg.from],
                  let toIdx = participantIndex[msg.to] else { continue }
            if fromIdx == toIdx { continue } // self-message
            let lo = min(fromIdx, toIdx)
            let hi = max(fromIdx, toIdx)
            let labelW = messageSizes[i].width + c.labelGap * 2
            let neededPerSpan = labelW / CGFloat(hi - lo)
            for span in lo ..< hi {
                minSpan[span] = max(minSpan[span] ?? 0, neededPerSpan)
            }
        }

        // Position participants left-to-right.
        var participants: [ParticipantLayout] = []
        var currentX = c.sideMargin

        for (i, p) in diagram.participants.enumerated() {
            let boxW = boxWidths[p.id] ?? 0
            let halfW = boxW / 2

            if i == 0 {
                currentX += halfW
            } else {
                let prevHalfW = (boxWidths[diagram.participants[i - 1].id] ?? 0) / 2
                let gap = max(c.participantGap, minSpan[i - 1] ?? 0)
                currentX += prevHalfW + gap + halfW
            }

            let textSize = labelSizes[p.id] ?? .zero
            let boxH = textSize.height + c.boxPadV * 2
            let boxRect = CGRect(
                x: currentX - halfW,
                y: c.topMargin,
                width: boxW,
                height: boxH
            )

            participants.append(ParticipantLayout(
                id: p.id,
                label: p.label,
                isActor: p.isActor,
                centerX: currentX,
                boxRect: boxRect
            ))
        }

        // Max box height (all boxes same height for alignment).
        let maxBoxH = participants.map(\.boxRect.height).max() ?? 0

        // Normalize box heights.
        var normalizedParticipants: [ParticipantLayout] = []
        for p in participants {
            let newRect = CGRect(
                x: p.boxRect.origin.x,
                y: p.boxRect.origin.y,
                width: p.boxRect.width,
                height: maxBoxH
            )
            normalizedParticipants.append(ParticipantLayout(
                id: p.id, label: p.label, isActor: p.isActor,
                centerX: p.centerX, boxRect: newRect
            ))
        }
        participants = normalizedParticipants

        // Position messages vertically.
        var messageLayouts: [MessageLayout] = []
        var currentY = c.topMargin + maxBoxH + c.headerGap

        for msg in diagram.messages {
            let isSelf = msg.from == msg.to
            messageLayouts.append(MessageLayout(message: msg, y: currentY))
            currentY += isSelf ? c.selfMessageHeight : c.messageSpacing
        }

        // Compute total size.
        guard let lastParticipant = participants.last else {
            return emptyLayout(configuration: configuration)
        }
        let totalWidth = lastParticipant.centerX + (lastParticipant.boxRect.width / 2) + c.sideMargin
        let totalHeight = currentY + c.bottomMargin

        let size = CGSize(width: totalWidth, height: totalHeight)
        let theme = configuration.theme
        let fontSize = configuration.fontSize

        // Capture everything the draw closure needs as value types.
        let capturedParticipants = participants
        let capturedMessages = messageLayouts
        let capturedIndex = participantIndex
        let capturedConstants = c

        return MermaidFlowchartRenderer.FlowchartLayout(
            graphResult: GraphLayoutResult(nodePositions: [:], edgePaths: [], totalSize: .zero),
            flowchart: .empty,
            nodeLabels: [:], nodeShapes: [:], edgeLabels: [:], edgeStyles: [:],
            classDefs: [:], styleDirectives: [:],
            fontSize: fontSize,
            theme: theme,
            isPlaceholder: false, placeholderText: nil,
            customDraw: { ctx, origin in
                drawDiagram(
                    ctx: ctx, origin: origin,
                    participants: capturedParticipants,
                    messages: capturedMessages,
                    participantIndex: capturedIndex,
                    constants: capturedConstants,
                    fontSize: fontSize,
                    theme: theme,
                    totalHeight: totalHeight
                )
            },
            customSize: size
        )
    }

    // MARK: - Empty layout

    private static func emptyLayout(
        configuration: RenderConfiguration
    ) -> MermaidFlowchartRenderer.FlowchartLayout {
        let size = CGSize(width: 100, height: 40)
        let theme = configuration.theme
        let fontSize = configuration.fontSize
        return MermaidFlowchartRenderer.FlowchartLayout(
            graphResult: GraphLayoutResult(nodePositions: [:], edgePaths: [], totalSize: .zero),
            flowchart: .empty,
            nodeLabels: [:], nodeShapes: [:], edgeLabels: [:], edgeStyles: [:],
            classDefs: [:], styleDirectives: [:],
            fontSize: fontSize,
            theme: theme,
            isPlaceholder: false, placeholderText: nil,
            customDraw: { ctx, origin in
                let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: theme.foregroundDim,
                ]
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(string: "(empty sequence diagram)", attributes: attrs)
                )
                drawCTLine(line, at: CGPoint(x: origin.x + 8, y: origin.y + 8), fontSize: fontSize, in: ctx)
            },
            customSize: size
        )
    }

    // MARK: - Drawing

    private static func drawDiagram(
        ctx: CGContext,
        origin: CGPoint,
        participants: [ParticipantLayout],
        messages: [MessageLayout],
        participantIndex: [String: Int],
        constants c: Constants,
        fontSize: CGFloat,
        theme: RenderTheme,
        totalHeight: CGFloat
    ) {
        let ox = origin.x
        let oy = origin.y

        // Draw lifelines first (behind everything).
        drawLifelines(
            ctx: ctx, ox: ox, oy: oy,
            participants: participants,
            constants: c,
            theme: theme,
            totalHeight: totalHeight
        )

        // Draw participant boxes.
        for p in participants {
            drawParticipantBox(
                ctx: ctx, ox: ox, oy: oy,
                participant: p,
                constants: c,
                fontSize: fontSize,
                theme: theme
            )
        }

        // Draw messages.
        for ml in messages {
            drawMessage(
                ctx: ctx, ox: ox, oy: oy,
                message: ml,
                participants: participants,
                participantIndex: participantIndex,
                constants: c,
                fontSize: fontSize,
                theme: theme
            )
        }
    }

    // MARK: - Lifelines

    private static func drawLifelines(
        ctx: CGContext,
        ox: CGFloat, oy: CGFloat,
        participants: [ParticipantLayout],
        constants c: Constants,
        theme: RenderTheme,
        totalHeight: CGFloat
    ) {
        ctx.saveGState()
        ctx.setStrokeColor(theme.foregroundDim)
        ctx.setLineWidth(1.0)
        ctx.setLineDash(phase: 0, lengths: c.lifelineDash)

        for p in participants {
            let x = ox + p.centerX
            let startY = oy + p.boxRect.maxY
            let endY = oy + totalHeight - c.bottomMargin
            ctx.move(to: CGPoint(x: x, y: startY))
            ctx.addLine(to: CGPoint(x: x, y: endY))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Participant boxes

    private static func drawParticipantBox(
        ctx: CGContext,
        ox: CGFloat, oy: CGFloat,
        participant p: ParticipantLayout,
        constants c: Constants,
        fontSize: CGFloat,
        theme: RenderTheme
    ) {
        let rect = p.boxRect.offsetBy(dx: ox, dy: oy)

        if p.isActor {
            drawActorStickFigure(
                ctx: ctx,
                centerX: rect.midX,
                topY: rect.minY,
                constants: c,
                fontSize: fontSize,
                theme: theme,
                label: p.label
            )
        } else {
            // Fill + stroke box.
            ctx.saveGState()
            ctx.setFillColor(theme.background)
            ctx.setStrokeColor(theme.foreground)
            ctx.setLineWidth(1.5)

            let path = CGPath(
                roundedRect: rect,
                cornerWidth: 4, cornerHeight: 4,
                transform: nil
            )
            ctx.addPath(path)
            ctx.drawPath(using: .fillStroke)
            ctx.restoreGState()

            // Label centered in box.
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: theme.foreground,
            ]
            let attrStr = NSAttributedString(string: p.label, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrStr)
            let bounds = CTLineGetBoundsWithOptions(line, [])
            let textX = rect.midX - bounds.width / 2
            let textY = rect.midY - bounds.height / 2
            drawCTLine(line, at: CGPoint(x: textX, y: textY), fontSize: fontSize, in: ctx)
        }
    }

    // MARK: - Actor stick figure

    private static func drawActorStickFigure(
        ctx: CGContext,
        centerX: CGFloat,
        topY: CGFloat,
        constants c: Constants,
        fontSize: CGFloat,
        theme: RenderTheme,
        label: String
    ) {
        let headRadius = c.fontSize * 0.4
        let bodyLen = c.fontSize * 0.6
        let armSpan = c.fontSize * 0.5
        let legLen = c.fontSize * 0.5

        let headCenterY = topY + headRadius

        ctx.saveGState()
        ctx.setStrokeColor(theme.foreground)
        ctx.setLineWidth(1.5)

        // Head (circle).
        let headRect = CGRect(
            x: centerX - headRadius,
            y: headCenterY - headRadius,
            width: headRadius * 2,
            height: headRadius * 2
        )
        ctx.strokeEllipse(in: headRect)

        // Body (vertical line from bottom of head).
        let neckY = headCenterY + headRadius
        let bodyEndY = neckY + bodyLen
        ctx.move(to: CGPoint(x: centerX, y: neckY))
        ctx.addLine(to: CGPoint(x: centerX, y: bodyEndY))

        // Arms (horizontal line at mid-body).
        let armY = neckY + bodyLen * 0.3
        ctx.move(to: CGPoint(x: centerX - armSpan, y: armY))
        ctx.addLine(to: CGPoint(x: centerX + armSpan, y: armY))

        // Legs (two lines from body end).
        ctx.move(to: CGPoint(x: centerX, y: bodyEndY))
        ctx.addLine(to: CGPoint(x: centerX - armSpan * 0.7, y: bodyEndY + legLen))
        ctx.move(to: CGPoint(x: centerX, y: bodyEndY))
        ctx.addLine(to: CGPoint(x: centerX + armSpan * 0.7, y: bodyEndY + legLen))

        ctx.strokePath()
        ctx.restoreGState()

        // Label below the figure.
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: theme.foreground,
        ]
        let attrStr = NSAttributedString(string: label, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let labelY = bodyEndY + legLen + c.fontSize * 0.3
        let labelX = centerX - bounds.width / 2
        drawCTLine(line, at: CGPoint(x: labelX, y: labelY), fontSize: fontSize, in: ctx)
    }

    // MARK: - Messages

    private static func drawMessage(
        ctx: CGContext,
        ox: CGFloat, oy: CGFloat,
        message ml: MessageLayout,
        participants: [ParticipantLayout],
        participantIndex: [String: Int],
        constants c: Constants,
        fontSize: CGFloat,
        theme: RenderTheme
    ) {
        guard let fromIdx = participantIndex[ml.message.from],
              let toIdx = participantIndex[ml.message.to] else { return }

        let fromX = ox + participants[fromIdx].centerX
        let toX = ox + participants[toIdx].centerX
        let y = oy + ml.y

        let isSelf = fromIdx == toIdx

        if isSelf {
            drawSelfMessage(
                ctx: ctx,
                x: fromX, y: y,
                message: ml.message,
                constants: c,
                fontSize: fontSize,
                theme: theme
            )
        } else {
            drawStraightMessage(
                ctx: ctx,
                fromX: fromX, toX: toX, y: y,
                message: ml.message,
                constants: c,
                fontSize: fontSize,
                theme: theme
            )
        }
    }

    private static func drawStraightMessage(
        ctx: CGContext,
        fromX: CGFloat, toX: CGFloat, y: CGFloat,
        message: SequenceMessage,
        constants c: Constants,
        fontSize: CGFloat,
        theme: RenderTheme
    ) {
        let isDashed = isDashedStyle(message.arrowStyle)

        // Draw the line.
        ctx.saveGState()
        ctx.setStrokeColor(theme.foreground)
        ctx.setLineWidth(1.5)
        if isDashed {
            ctx.setLineDash(phase: 0, lengths: c.dashLengths)
        }
        ctx.move(to: CGPoint(x: fromX, y: y))
        ctx.addLine(to: CGPoint(x: toX, y: y))
        ctx.strokePath()
        ctx.restoreGState()

        // Draw the end marker.
        let goingRight = toX > fromX
        drawEndMarker(
            ctx: ctx,
            at: CGPoint(x: toX, y: y),
            pointingRight: goingRight,
            style: message.arrowStyle,
            constants: c,
            theme: theme
        )

        // Draw the label above the arrow.
        if !message.text.isEmpty {
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.85, nil)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: theme.foreground,
            ]
            let attrStr = NSAttributedString(string: message.text, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrStr)
            let bounds = CTLineGetBoundsWithOptions(line, [])
            let midX = (fromX + toX) / 2
            let textX = midX - bounds.width / 2
            let textY = y - bounds.height - c.labelGap
            drawCTLine(line, at: CGPoint(x: textX, y: textY), fontSize: fontSize * 0.85, in: ctx)
        }
    }

    private static func drawSelfMessage(
        ctx: CGContext,
        x: CGFloat, y: CGFloat,
        message: SequenceMessage,
        constants c: Constants,
        fontSize: CGFloat,
        theme: RenderTheme
    ) {
        let isDashed = isDashedStyle(message.arrowStyle)
        let loopW = c.selfMessageWidth
        let loopH = c.selfMessageHeight * 0.6

        // Draw the loopback path: right, down, left.
        ctx.saveGState()
        ctx.setStrokeColor(theme.foreground)
        ctx.setLineWidth(1.5)
        if isDashed {
            ctx.setLineDash(phase: 0, lengths: c.dashLengths)
        }

        let startPoint = CGPoint(x: x, y: y)
        let topRight = CGPoint(x: x + loopW, y: y)
        let bottomRight = CGPoint(x: x + loopW, y: y + loopH)
        let endPoint = CGPoint(x: x, y: y + loopH)

        ctx.move(to: startPoint)
        ctx.addLine(to: topRight)
        ctx.addLine(to: bottomRight)
        ctx.addLine(to: endPoint)
        ctx.strokePath()
        ctx.restoreGState()

        // End marker at the return point.
        drawEndMarker(
            ctx: ctx,
            at: endPoint,
            pointingRight: false,
            style: message.arrowStyle,
            constants: c,
            theme: theme
        )

        // Label to the right of the loopback.
        if !message.text.isEmpty {
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.85, nil)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: theme.foreground,
            ]
            let attrStr = NSAttributedString(string: message.text, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrStr)
            let textX = x + loopW + c.labelGap
            let textY = y + loopH * 0.3 - fontSize * 0.4
            drawCTLine(line, at: CGPoint(x: textX, y: textY), fontSize: fontSize * 0.85, in: ctx)
        }
    }

    // MARK: - End markers (arrowhead, open, cross)

    private static func drawEndMarker(
        ctx: CGContext,
        at tip: CGPoint,
        pointingRight: Bool,
        style: SequenceArrowStyle,
        constants c: Constants,
        theme: RenderTheme
    ) {
        switch style {
        case .solid, .dashed:
            drawFilledArrowhead(ctx: ctx, at: tip, pointingRight: pointingRight, size: c.arrowSize, theme: theme)
        case .solidOpen, .dashedOpen:
            // No end marker — open end.
            break
        case .solidCross, .dashedCross:
            drawCrossMarker(ctx: ctx, at: tip, size: c.crossSize, theme: theme)
        }
    }

    private static func drawFilledArrowhead(
        ctx: CGContext,
        at tip: CGPoint,
        pointingRight: Bool,
        size: CGFloat,
        theme: RenderTheme
    ) {
        let direction: CGFloat = pointingRight ? -1 : 1
        let spread: CGFloat = .pi / 6

        let left = CGPoint(
            x: tip.x + direction * size * cos(spread),
            y: tip.y - size * sin(spread)
        )
        let right = CGPoint(
            x: tip.x + direction * size * cos(spread),
            y: tip.y + size * sin(spread)
        )

        ctx.saveGState()
        ctx.setFillColor(theme.foreground)
        ctx.move(to: tip)
        ctx.addLine(to: left)
        ctx.addLine(to: right)
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func drawCrossMarker(
        ctx: CGContext,
        at center: CGPoint,
        size: CGFloat,
        theme: RenderTheme
    ) {
        ctx.saveGState()
        ctx.setStrokeColor(theme.foreground)
        ctx.setLineWidth(2.0)
        ctx.move(to: CGPoint(x: center.x - size, y: center.y - size))
        ctx.addLine(to: CGPoint(x: center.x + size, y: center.y + size))
        ctx.move(to: CGPoint(x: center.x + size, y: center.y - size))
        ctx.addLine(to: CGPoint(x: center.x - size, y: center.y + size))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Helpers

    private static func isDashedStyle(_ style: SequenceArrowStyle) -> Bool {
        switch style {
        case .dashed, .dashedOpen, .dashedCross: true
        case .solid, .solidOpen, .solidCross: false
        }
    }

    private static func measureText(_ text: String, font: CTFont, fontSize: CGFloat) -> CGSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        return CGSize(
            width: max(bounds.width, fontSize * 2),
            height: max(bounds.height, fontSize * 1.4)
        )
    }

    /// Draw a CTLine at (x, y) in UIKit top-left coordinates.
    ///
    /// Flips locally around the text position so text renders right-side-up
    /// in a Y-down coordinate system.
    private static func drawCTLine(_ line: CTLine, at point: CGPoint, fontSize: CGFloat, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y + fontSize)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
