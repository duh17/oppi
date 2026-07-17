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
        /// Horizontal padding inside note boxes.
        var notePadH: CGFloat { fontSize * 1.0 }
        /// Vertical padding inside note boxes.
        var notePadV: CGFloat { fontSize * 0.65 }
    }

    /// Pre-computed positions for a single participant column.
    private struct ParticipantLayout: Sendable {
        let id: String
        let label: String
        let isActor: Bool
        let kind: SequenceParticipantKind
        /// Center-X of this participant's lifeline.
        let centerX: CGFloat
        /// Bounding rect of the participant box at the top.
        let boxRect: CGRect
    }

    /// Pre-computed position for a single message row.
    private struct MessageLayout: Sendable {
        let message: SequenceMessage
        let sequenceNumber: String?
        /// Y coordinate of this message's arrow.
        let y: CGFloat
    }

    /// Pre-computed position for a single note row.
    private struct NoteLayout: Sendable {
        let note: SequenceNote
        /// Y coordinate of the top of this note box.
        let y: CGFloat
        let size: CGSize
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

        let sequenceNumbers = sequenceNumberLabels(for: diagram)

        // Measure all message labels.
        var messageSizes: [CGSize] = []
        for (index, msg) in diagram.messages.enumerated() {
            let text = messageDisplayText(msg.text, sequenceNumber: sequenceNumbers[index])
            messageSizes.append(measureText(text, font: font, fontSize: c.fontSize))
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
                kind: p.kind,
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
                id: p.id, label: p.label, isActor: p.isActor, kind: p.kind,
                centerX: p.centerX, boxRect: newRect
            ))
        }
        participants = normalizedParticipants

        // Position messages and notes vertically.
        var messageLayouts: [MessageLayout] = []
        var noteLayouts: [NoteLayout] = []
        var currentY = c.topMargin + maxBoxH + c.headerGap

        for (index, msg) in diagram.messages.enumerated() {
            let isSelf = msg.from == msg.to
            messageLayouts.append(MessageLayout(
                message: msg,
                sequenceNumber: sequenceNumbers[index],
                y: currentY
            ))
            currentY += isSelf ? c.selfMessageHeight : c.messageSpacing
        }

        let noteFontSize = c.fontSize * 0.85
        let noteFont = CTFontCreateWithName("Helvetica" as CFString, noteFontSize, nil)
        for note in diagram.notes {
            let textSize = measureText(note.text, font: noteFont, fontSize: noteFontSize)
            let noteSize = CGSize(
                width: textSize.width + c.notePadH * 2,
                height: textSize.height + c.notePadV * 2
            )
            noteLayouts.append(NoteLayout(note: note, y: currentY, size: noteSize))
            currentY += max(noteSize.height + c.messageSpacing * 0.35, c.messageSpacing)
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
        let capturedNotes = noteLayouts
        let capturedBlocks = diagram.blocks
        let capturedBoxes = diagram.boxes
        let capturedIndex = participantIndex
        let capturedConstants = c

        return MermaidFlowchartRenderer.FlowchartLayout(
            graphResult: GraphLayoutResult(nodePositions: [:], edgePaths: [], totalSize: .zero),
            flowchart: .empty,
            subgraphFrames: [:],
            nodeLabels: [:], nodeShapes: [:], edgeLabels: [:], edgeStyles: [:],
            edgeIds: [:], edgeKeys: [], edgeStyleDirectives: [:], edgeEndpointSubgraphs: [:],
            classDefs: [:], styleDirectives: [:],
            fontSize: fontSize,
            theme: theme,
            isPlaceholder: false, placeholderText: nil,
            customDraw: { ctx, origin in
                drawDiagram(
                    ctx: ctx, origin: origin,
                    participants: capturedParticipants,
                    messages: capturedMessages,
                    notes: capturedNotes,
                    blocks: capturedBlocks,
                    boxes: capturedBoxes,
                    participantIndex: capturedIndex,
                    constants: capturedConstants,
                    fontSize: fontSize,
                    theme: theme,
                    totalWidth: totalWidth,
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
            subgraphFrames: [:],
            nodeLabels: [:], nodeShapes: [:], edgeLabels: [:], edgeStyles: [:],
            edgeIds: [:], edgeKeys: [], edgeStyleDirectives: [:], edgeEndpointSubgraphs: [:],
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
        notes: [NoteLayout],
        blocks: [SequenceBlock],
        boxes: [SequenceBox],
        participantIndex: [String: Int],
        constants c: Constants,
        fontSize: CGFloat,
        theme: RenderTheme,
        totalWidth: CGFloat,
        totalHeight: CGFloat
    ) {
        let ox = origin.x
        let oy = origin.y

        // Draw participant grouping boxes behind everything else.
        for box in boxes {
            drawSequenceBox(
                ctx: ctx,
                ox: ox,
                oy: oy,
                box: box,
                participants: participants,
                participantIndex: participantIndex,
                constants: c,
                fontSize: fontSize,
                theme: theme,
                totalHeight: totalHeight
            )
        }

        // Draw lifelines first (behind foreground diagram content).
        drawLifelines(
            ctx: ctx, ox: ox, oy: oy,
            participants: participants,
            constants: c,
            theme: theme,
            totalHeight: totalHeight
        )

        // Draw sequence blocks/background rects behind participant boxes and messages.
        for block in blocks {
            drawSequenceBlock(
                ctx: ctx,
                ox: ox,
                oy: oy,
                block: block,
                messages: messages,
                constants: c,
                fontSize: fontSize,
                theme: theme,
                totalWidth: totalWidth
            )
        }

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

        // Draw notes after messages so note boxes stay readable.
        for note in notes {
            drawNote(
                ctx: ctx, ox: ox, oy: oy,
                noteLayout: note,
                participants: participants,
                participantIndex: participantIndex,
                constants: c,
                fontSize: fontSize,
                theme: theme,
                totalWidth: totalWidth
            )
        }
    }

    // MARK: - Participant grouping boxes

    private static func drawSequenceBox(
        ctx: CGContext,
        ox: CGFloat,
        oy: CGFloat,
        box: SequenceBox,
        participants: [ParticipantLayout],
        participantIndex: [String: Int],
        constants c: Constants,
        fontSize: CGFloat,
        theme: RenderTheme,
        totalHeight: CGFloat
    ) {
        let indices = box.participantIds.compactMap { participantIndex[$0] }
        guard let first = indices.min(), let last = indices.max() else { return }

        let minParticipantX = participants[first...last].map(\.boxRect.minX).min() ?? participants[first].boxRect.minX
        let maxParticipantX = participants[first...last].map(\.boxRect.maxX).max() ?? participants[last].boxRect.maxX
        let horizontalPadding = c.fontSize * 0.9
        let titleHeight = box.label == nil ? c.fontSize * 0.4 : c.fontSize * 1.7
        let rect = CGRect(
            x: ox + minParticipantX - horizontalPadding,
            y: oy + c.topMargin * 0.45,
            width: maxParticipantX - minParticipantX + horizontalPadding * 2,
            height: max(1, totalHeight - c.topMargin - c.bottomMargin * 0.25)
        )

        ctx.saveGState()
        let fillColor = box.color.flatMap { parseSequenceColor($0, theme: theme) }
            ?? theme.foregroundDim.copy(alpha: 0.06)
            ?? theme.background
        ctx.setFillColor(fillColor)
        ctx.setStrokeColor(theme.foregroundDim.copy(alpha: 0.25) ?? theme.foregroundDim)
        ctx.setLineWidth(1.0)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()

        guard let label = box.label, !label.isEmpty else { return }
        let titleFontSize = fontSize * 0.78
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, titleFontSize, nil)
        MermaidTextUtils.drawText(
            label,
            centeredIn: CGRect(
                x: rect.minX + 8,
                y: rect.minY + 3,
                width: max(1, rect.width - 16),
                height: titleHeight
            ),
            font: font,
            fontSize: titleFontSize,
            foregroundColor: theme.foreground,
            in: ctx
        )
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

        if p.isActor || p.kind == .actor {
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
            drawParticipantSymbol(
                kind: p.kind,
                rect: rect,
                fontSize: fontSize,
                theme: theme,
                in: ctx
            )

            // Label centered in box.
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            MermaidTextUtils.drawText(
                p.label,
                centeredIn: rect.insetBy(dx: c.boxPadH * 0.25, dy: 0),
                font: font,
                fontSize: fontSize,
                foregroundColor: theme.foreground,
                in: ctx
            )
        }
    }

    private static func drawParticipantSymbol(
        kind: SequenceParticipantKind,
        rect: CGRect,
        fontSize: CGFloat,
        theme: RenderTheme,
        in ctx: CGContext
    ) {
        ctx.saveGState()
        ctx.setFillColor(theme.background)
        ctx.setStrokeColor(theme.foreground)
        ctx.setLineWidth(1.5)

        switch kind {
        case .database:
            drawDatabaseParticipant(rect: rect, theme: theme, in: ctx)
        case .collections:
            drawStackedParticipant(rect: rect, theme: theme, in: ctx)
        case .queue:
            drawQueueParticipant(rect: rect, theme: theme, in: ctx)
        case .boundary:
            drawBoundaryParticipant(rect: rect, fontSize: fontSize, theme: theme, in: ctx)
        case .control:
            drawControlParticipant(rect: rect, fontSize: fontSize, theme: theme, in: ctx)
        case .entity:
            drawEntityParticipant(rect: rect, fontSize: fontSize, theme: theme, in: ctx)
        case .participant, .actor:
            let path = CGPath(
                roundedRect: rect,
                cornerWidth: 4,
                cornerHeight: 4,
                transform: nil
            )
            ctx.addPath(path)
            ctx.drawPath(using: .fillStroke)
        }

        ctx.restoreGState()
    }

    private static func drawDatabaseParticipant(
        rect: CGRect,
        theme: RenderTheme,
        in ctx: CGContext
    ) {
        let ellipseHeight = min(rect.height * 0.32, 16)
        let bodyRect = rect.insetBy(dx: 0, dy: ellipseHeight / 2)
        ctx.fill(bodyRect)
        ctx.stroke(bodyRect)
        ctx.fillEllipse(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: ellipseHeight))
        ctx.strokeEllipse(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: ellipseHeight))
        ctx.strokeEllipse(in: CGRect(x: rect.minX, y: rect.maxY - ellipseHeight, width: rect.width, height: ellipseHeight))
        ctx.setStrokeColor(theme.foregroundDim)
        ctx.move(to: CGPoint(x: rect.minX, y: rect.minY + ellipseHeight / 2))
        ctx.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - ellipseHeight / 2))
        ctx.move(to: CGPoint(x: rect.maxX, y: rect.minY + ellipseHeight / 2))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - ellipseHeight / 2))
        ctx.strokePath()
    }

    private static func drawStackedParticipant(
        rect: CGRect,
        theme: RenderTheme,
        in ctx: CGContext
    ) {
        let offset = min(rect.height * 0.16, 8)
        let back = rect.offsetBy(dx: offset, dy: -offset).insetBy(dx: 0, dy: offset)
        let front = rect.insetBy(dx: offset, dy: 0)
        ctx.addPath(CGPath(roundedRect: back, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.drawPath(using: .fillStroke)
        ctx.setFillColor(theme.background)
        ctx.addPath(CGPath(roundedRect: front, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.drawPath(using: .fillStroke)
    }

    private static func drawQueueParticipant(
        rect: CGRect,
        theme: RenderTheme,
        in ctx: CGContext
    ) {
        let radius = rect.height / 2
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.drawPath(using: .fillStroke)
        ctx.setStrokeColor(theme.foregroundDim)
        let inset = rect.width * 0.12
        for fraction in [0.33, 0.66] {
            let x = rect.minX + rect.width * fraction
            ctx.move(to: CGPoint(x: x, y: rect.minY + inset * 0.25))
            ctx.addLine(to: CGPoint(x: x, y: rect.maxY - inset * 0.25))
        }
        ctx.strokePath()
    }

    private static func drawBoundaryParticipant(
        rect: CGRect,
        fontSize: CGFloat,
        theme: RenderTheme,
        in ctx: CGContext
    ) {
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.drawPath(using: .fillStroke)
        ctx.setStrokeColor(theme.foregroundDim)
        ctx.setLineWidth(2)
        let x = rect.minX + fontSize * 0.65
        ctx.move(to: CGPoint(x: x, y: rect.minY + 4))
        ctx.addLine(to: CGPoint(x: x, y: rect.maxY - 4))
        ctx.strokePath()
    }

    private static func drawControlParticipant(
        rect: CGRect,
        fontSize: CGFloat,
        theme: RenderTheme,
        in ctx: CGContext
    ) {
        let radius = min(rect.height * 0.35, fontSize)
        let box = rect.insetBy(dx: radius * 0.25, dy: 0)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.drawPath(using: .fillStroke)
        ctx.setStrokeColor(theme.foregroundDim)
        ctx.move(to: CGPoint(x: box.midX - radius * 0.5, y: box.minY + radius * 0.7))
        ctx.addLine(to: CGPoint(x: box.midX, y: box.minY + radius * 0.25))
        ctx.addLine(to: CGPoint(x: box.midX + radius * 0.5, y: box.minY + radius * 0.7))
        ctx.strokePath()
    }

    private static func drawEntityParticipant(
        rect: CGRect,
        fontSize: CGFloat,
        theme: RenderTheme,
        in ctx: CGContext
    ) {
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.drawPath(using: .fillStroke)
        ctx.setStrokeColor(theme.foregroundDim)
        let underlineY = rect.maxY - max(5, fontSize * 0.35)
        ctx.move(to: CGPoint(x: rect.minX + 8, y: underlineY))
        ctx.addLine(to: CGPoint(x: rect.maxX - 8, y: underlineY))
        ctx.strokePath()
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
        let textSize = MermaidTextUtils.measureText(label, font: font, fontSize: fontSize)
        let labelY = bodyEndY + legLen + c.fontSize * 0.3
        let labelX = centerX - textSize.width / 2
        MermaidTextUtils.drawText(
            label,
            at: CGPoint(x: labelX, y: labelY),
            width: textSize.width,
            font: font,
            fontSize: fontSize,
            foregroundColor: theme.foreground,
            alignment: .center,
            in: ctx
        )
    }

    // MARK: - Blocks and background rects

    private static func drawSequenceBlock(
        ctx: CGContext,
        ox: CGFloat,
        oy: CGFloat,
        block: SequenceBlock,
        messages: [MessageLayout],
        constants c: Constants,
        fontSize: CGFloat,
        theme: RenderTheme,
        totalWidth: CGFloat
    ) {
        guard let startIndex = block.startMessageIndex,
              let endIndex = block.endMessageIndex,
              startIndex >= 0,
              startIndex < messages.count
        else { return }

        let clampedEnd = min(max(endIndex, startIndex), messages.count - 1)
        let startY = oy + messages[startIndex].y - c.messageSpacing * 0.55
        let endMessage = messages[clampedEnd].message
        let endPadding = endMessage.from == endMessage.to ? c.selfMessageHeight * 0.85 : c.messageSpacing * 0.55
        let endY = oy + messages[clampedEnd].y + endPadding
        let rect = CGRect(
            x: ox + c.sideMargin * 0.35,
            y: startY,
            width: max(1, totalWidth - c.sideMargin * 0.7),
            height: max(c.messageSpacing, endY - startY)
        )

        ctx.saveGState()
        ctx.setLineWidth(1.1)
        ctx.setStrokeColor(sequenceBlockStrokeColor(block.kind, theme: theme))
        ctx.setFillColor(sequenceBlockFillColor(block, theme: theme))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 7, cornerHeight: 7, transform: nil))
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()

        let title = sequenceBlockTitle(block)
        guard !title.isEmpty else { return }
        let titleFontSize = fontSize * 0.78
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, titleFontSize, nil)
        MermaidTextUtils.drawText(
            title,
            at: CGPoint(x: rect.minX + 8, y: rect.minY + 4),
            font: font,
            fontSize: titleFontSize,
            foregroundColor: theme.foreground,
            in: ctx
        )
    }

    private static func sequenceBlockTitle(_ block: SequenceBlock) -> String {
        switch block.kind {
        case .rect:
            return ""
        case .loop:
            return block.label.isEmpty ? "loop" : "loop \(block.label)"
        case .alt:
            return block.label.isEmpty ? "alt" : "alt \(block.label)"
        case .opt:
            return block.label.isEmpty ? "opt" : "opt \(block.label)"
        case .par:
            return block.label.isEmpty ? "par" : "par \(block.label)"
        case .critical:
            return block.label.isEmpty ? "critical" : "critical \(block.label)"
        case .break:
            return block.label.isEmpty ? "break" : "break \(block.label)"
        }
    }

    private static func sequenceBlockFillColor(_ block: SequenceBlock, theme: RenderTheme) -> CGColor {
        if block.kind == .rect {
            return parseSequenceColor(block.label, theme: theme)
                ?? theme.accentBlue.copy(alpha: 0.12)
                ?? theme.background
        }
        return theme.foregroundDim.copy(alpha: 0.06) ?? theme.background
    }

    private static func sequenceBlockStrokeColor(_ kind: SequenceBlockKind, theme: RenderTheme) -> CGColor {
        if kind == .rect {
            return theme.accentBlue.copy(alpha: 0.25) ?? theme.foregroundDim
        }
        return theme.foregroundDim.copy(alpha: 0.35) ?? theme.foregroundDim
    }

    private static func parseSequenceColor(_ raw: String, theme: RenderTheme) -> CGColor? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.lowercased() == "transparent" {
            return theme.background.copy(alpha: 0.0)
        }
        if value.lowercased().hasPrefix("rgb") {
            return parseRGBColor(value)
        }
        if value.lowercased().hasPrefix("hsl") {
            return parseHSLColor(value)
        }
        if let named = namedSequenceColor(value.lowercased()) {
            return named
        }
        return nil
    }

    private static func namedSequenceColor(_ name: String) -> CGColor? {
        let alpha: CGFloat = 0.16
        switch name {
        case "aqua", "cyan":
            return CGColor(srgbRed: 0, green: 1, blue: 1, alpha: alpha)
        case "black":
            return CGColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha)
        case "blue":
            return CGColor(srgbRed: 0, green: 0.2, blue: 1, alpha: alpha)
        case "brown":
            return CGColor(srgbRed: 0.6, green: 0.3, blue: 0.1, alpha: alpha)
        case "gray", "grey":
            return CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: alpha)
        case "green", "lime":
            return CGColor(srgbRed: 0, green: 0.75, blue: 0.2, alpha: alpha)
        case "magenta", "purple", "violet":
            return CGColor(srgbRed: 0.55, green: 0.25, blue: 0.9, alpha: alpha)
        case "orange":
            return CGColor(srgbRed: 1, green: 0.55, blue: 0, alpha: alpha)
        case "pink":
            return CGColor(srgbRed: 1, green: 0.45, blue: 0.75, alpha: alpha)
        case "red":
            return CGColor(srgbRed: 1, green: 0.1, blue: 0.1, alpha: alpha)
        case "white":
            return CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha)
        case "yellow":
            return CGColor(srgbRed: 1, green: 0.9, blue: 0, alpha: alpha)
        default:
            return nil
        }
    }

    private static func parseRGBColor(_ value: String) -> CGColor? {
        guard let colorParts = functionalColorParts(value),
              colorParts.count == 3 || colorParts.count == 4,
              let red = Double(colorParts[0]),
              let green = Double(colorParts[1]),
              let blue = Double(colorParts[2])
        else { return nil }
        let alpha = colorParts.count == 4 ? (Double(colorParts[3]) ?? 1.0) : 1.0
        return CGColor(
            srgbRed: CGFloat(red / 255.0),
            green: CGFloat(green / 255.0),
            blue: CGFloat(blue / 255.0),
            alpha: CGFloat(alpha) * 0.22
        )
    }

    private static func parseHSLColor(_ value: String) -> CGColor? {
        guard let colorParts = functionalColorParts(value),
              colorParts.count == 3 || colorParts.count == 4,
              let hueValue = Double(colorParts[0]),
              let saturation = percentageValue(colorParts[1]),
              let lightness = percentageValue(colorParts[2])
        else { return nil }
        let alpha = colorParts.count == 4 ? alphaValue(colorParts[3]) : 1.0
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let hue = (hueValue.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 60
        let x = chroma * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
        let match = lightness - chroma / 2
        let rgbPrime: [Double]
        switch hue {
        case 0..<1:
            rgbPrime = [chroma, x, 0]
        case 1..<2:
            rgbPrime = [x, chroma, 0]
        case 2..<3:
            rgbPrime = [0, chroma, x]
        case 3..<4:
            rgbPrime = [0, x, chroma]
        case 4..<5:
            rgbPrime = [x, 0, chroma]
        default:
            rgbPrime = [chroma, 0, x]
        }
        return CGColor(
            srgbRed: CGFloat(rgbPrime[0] + match),
            green: CGFloat(rgbPrime[1] + match),
            blue: CGFloat(rgbPrime[2] + match),
            alpha: CGFloat(alpha) * 0.22
        )
    }

    private static func functionalColorParts(_ value: String) -> [String]? {
        guard let open = value.firstIndex(of: "("),
              let close = value.lastIndex(of: ")"),
              open < close
        else { return nil }
        let bodyStart = value.index(after: open)
        return value[bodyStart..<close]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func percentageValue(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("%") {
            return Double(trimmed.dropLast()).map { min(max($0 / 100.0, 0), 1) }
        }
        return Double(trimmed).map { min(max($0, 0), 1) }
    }

    private static func alphaValue(_ value: String) -> Double {
        percentageValue(value) ?? Double(value.trimmingCharacters(in: .whitespaces)) ?? 1.0
    }

    // MARK: - Notes

    private static func drawNote(
        ctx: CGContext,
        ox: CGFloat, oy: CGFloat,
        noteLayout: NoteLayout,
        participants: [ParticipantLayout],
        participantIndex: [String: Int],
        constants c: Constants,
        fontSize: CGFloat,
        theme: RenderTheme,
        totalWidth: CGFloat
    ) {
        let rect = noteRect(
            noteLayout,
            participants: participants,
            participantIndex: participantIndex,
            constants: c,
            ox: ox,
            oy: oy,
            totalWidth: totalWidth
        )

        ctx.saveGState()
        ctx.setFillColor(theme.accentYellow.copy(alpha: 0.22) ?? theme.background)
        ctx.setStrokeColor(theme.accentOrange.copy(alpha: 0.78) ?? theme.foregroundDim)
        ctx.setLineWidth(1.2)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()

        let noteFontSize = fontSize * 0.85
        let font = CTFontCreateWithName("Helvetica" as CFString, noteFontSize, nil)
        MermaidTextUtils.drawText(
            noteLayout.note.text,
            centeredIn: rect.insetBy(dx: c.notePadH * 0.5, dy: c.notePadV * 0.35),
            font: font,
            fontSize: noteFontSize,
            foregroundColor: theme.foreground,
            in: ctx
        )
    }

    private static func noteRect(
        _ noteLayout: NoteLayout,
        participants: [ParticipantLayout],
        participantIndex: [String: Int],
        constants c: Constants,
        ox: CGFloat,
        oy: CGFloat,
        totalWidth: CGFloat
    ) -> CGRect {
        let note = noteLayout.note
        let width = noteLayout.size.width
        let height = noteLayout.size.height
        let y = oy + noteLayout.y
        let gap = c.fontSize * 0.8

        let rawX: CGFloat
        switch note.position {
        case .rightOf:
            rawX = note.actors.first
                .flatMap { participantIndex[$0] }
                .map { ox + participants[$0].centerX + gap }
                ?? ox + c.sideMargin
        case .leftOf:
            rawX = note.actors.first
                .flatMap { participantIndex[$0] }
                .map { ox + participants[$0].centerX - width - gap }
                ?? ox + c.sideMargin
        case .over:
            let indices = note.actors.compactMap { participantIndex[$0] }
            if let first = indices.first, let last = indices.last {
                let minX = min(participants[first].centerX, participants[last].centerX)
                let maxX = max(participants[first].centerX, participants[last].centerX)
                rawX = ox + (minX + maxX) / 2 - width / 2
            } else {
                rawX = ox + c.sideMargin
            }
        }

        let minX = ox + c.sideMargin * 0.25
        let maxX = max(minX, ox + totalWidth - c.sideMargin * 0.25 - width)
        let clampedX = min(max(rawX, minX), maxX)
        return CGRect(x: clampedX, y: y, width: width, height: height)
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
                sequenceNumber: ml.sequenceNumber,
                constants: c,
                fontSize: fontSize,
                theme: theme
            )
        } else {
            drawStraightMessage(
                ctx: ctx,
                fromX: fromX, toX: toX, y: y,
                message: ml.message,
                sequenceNumber: ml.sequenceNumber,
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
        sequenceNumber: String?,
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

        // Draw the arrow markers.
        let goingRight = toX > fromX
        drawEndMarker(
            ctx: ctx,
            at: CGPoint(x: toX, y: y),
            pointingRight: goingRight,
            style: message.arrowStyle,
            constants: c,
            theme: theme
        )
        drawStartMarker(
            ctx: ctx,
            at: CGPoint(x: fromX, y: y),
            pointingRight: !goingRight,
            style: message.arrowStyle,
            constants: c,
            theme: theme
        )
        drawCentralConnectionMarkers(
            ctx: ctx,
            from: CGPoint(x: fromX, y: y),
            to: CGPoint(x: toX, y: y),
            message: message,
            constants: c,
            theme: theme
        )

        // Draw the label above the arrow.
        let labelText = messageDisplayText(message.text, sequenceNumber: sequenceNumber)
        if !labelText.isEmpty {
            let msgFontSize = fontSize * 0.85
            let font = CTFontCreateWithName("Helvetica" as CFString, msgFontSize, nil)
            let textSize = MermaidTextUtils.measureText(labelText, font: font, fontSize: msgFontSize)
            let midX = (fromX + toX) / 2
            let textX = midX - textSize.width / 2
            let textY = y - textSize.height - c.labelGap
            MermaidTextUtils.drawText(
                labelText,
                at: CGPoint(x: textX, y: textY),
                width: textSize.width,
                font: font,
                fontSize: msgFontSize,
                foregroundColor: theme.foreground,
                alignment: .center,
                in: ctx
            )
        }
    }

    private static func drawSelfMessage(
        ctx: CGContext,
        x: CGFloat, y: CGFloat,
        message: SequenceMessage,
        sequenceNumber: String?,
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

        // Arrow markers at the return point and optional reverse/bidirectional start point.
        drawEndMarker(
            ctx: ctx,
            at: endPoint,
            pointingRight: false,
            style: message.arrowStyle,
            constants: c,
            theme: theme
        )
        drawStartMarker(
            ctx: ctx,
            at: startPoint,
            pointingRight: false,
            style: message.arrowStyle,
            constants: c,
            theme: theme
        )
        drawCentralConnectionMarkers(
            ctx: ctx,
            from: startPoint,
            to: endPoint,
            message: message,
            constants: c,
            theme: theme
        )

        // Label to the right of the loopback.
        let labelText = messageDisplayText(message.text, sequenceNumber: sequenceNumber)
        if !labelText.isEmpty {
            let msgFontSize = fontSize * 0.85
            let font = CTFontCreateWithName("Helvetica" as CFString, msgFontSize, nil)
            let textX = x + loopW + c.labelGap
            let textY = y + loopH * 0.3 - fontSize * 0.4
            MermaidTextUtils.drawText(
                labelText,
                at: CGPoint(x: textX, y: textY),
                font: font,
                fontSize: msgFontSize,
                foregroundColor: theme.foreground,
                in: ctx
            )
        }
    }

    // MARK: - Markers (arrowhead, open, cross)

    private enum HalfMarkerSide {
        case top
        case bottom
    }

    private static func drawEndMarker(
        ctx: CGContext,
        at tip: CGPoint,
        pointingRight: Bool,
        style: SequenceArrowStyle,
        constants c: Constants,
        theme: RenderTheme
    ) {
        switch style {
        case .solid, .dashed, .solidBidirectional, .dashedBidirectional:
            drawFilledArrowhead(ctx: ctx, at: tip, pointingRight: pointingRight, size: c.arrowSize, theme: theme)
        case .solidTopHalfArrow, .dashedTopHalfArrow:
            drawHalfArrowhead(ctx: ctx, at: tip, pointingRight: pointingRight, side: .top, filled: true, size: c.arrowSize, theme: theme)
        case .solidBottomHalfArrow, .dashedBottomHalfArrow:
            drawHalfArrowhead(ctx: ctx, at: tip, pointingRight: pointingRight, side: .bottom, filled: true, size: c.arrowSize, theme: theme)
        case .solidTopStickHalfArrow, .dashedTopStickHalfArrow:
            drawHalfArrowhead(ctx: ctx, at: tip, pointingRight: pointingRight, side: .top, filled: false, size: c.arrowSize, theme: theme)
        case .solidBottomStickHalfArrow, .dashedBottomStickHalfArrow:
            drawHalfArrowhead(ctx: ctx, at: tip, pointingRight: pointingRight, side: .bottom, filled: false, size: c.arrowSize, theme: theme)
        case .solidOpen, .dashedOpen, .solidAsync, .dashedAsync,
             .solidReverseTopHalfArrow, .dashedReverseTopHalfArrow,
             .solidReverseBottomHalfArrow, .dashedReverseBottomHalfArrow,
             .solidReverseTopStickHalfArrow, .dashedReverseTopStickHalfArrow:
            // No end marker — open or reverse-only end.
            break
        case .solidCross, .dashedCross:
            drawCrossMarker(ctx: ctx, at: tip, size: c.crossSize, theme: theme)
        }
    }

    private static func drawStartMarker(
        ctx: CGContext,
        at tip: CGPoint,
        pointingRight: Bool,
        style: SequenceArrowStyle,
        constants c: Constants,
        theme: RenderTheme
    ) {
        switch style {
        case .solidBidirectional, .dashedBidirectional:
            drawFilledArrowhead(ctx: ctx, at: tip, pointingRight: pointingRight, size: c.arrowSize, theme: theme)
        case .solidReverseTopHalfArrow, .dashedReverseTopHalfArrow:
            drawHalfArrowhead(ctx: ctx, at: tip, pointingRight: pointingRight, side: .top, filled: true, size: c.arrowSize, theme: theme)
        case .solidReverseBottomHalfArrow, .dashedReverseBottomHalfArrow:
            drawHalfArrowhead(ctx: ctx, at: tip, pointingRight: pointingRight, side: .bottom, filled: true, size: c.arrowSize, theme: theme)
        case .solidReverseTopStickHalfArrow, .dashedReverseTopStickHalfArrow:
            drawHalfArrowhead(ctx: ctx, at: tip, pointingRight: pointingRight, side: .top, filled: false, size: c.arrowSize, theme: theme)
        case .solid, .dashed, .solidOpen, .dashedOpen,
             .solidCross, .dashedCross, .solidAsync, .dashedAsync,
             .solidTopHalfArrow, .dashedTopHalfArrow,
             .solidBottomHalfArrow, .dashedBottomHalfArrow,
             .solidTopStickHalfArrow, .dashedTopStickHalfArrow,
             .solidBottomStickHalfArrow, .dashedBottomStickHalfArrow:
            break
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

    private static func drawHalfArrowhead(
        ctx: CGContext,
        at tip: CGPoint,
        pointingRight: Bool,
        side: HalfMarkerSide,
        filled: Bool,
        size: CGFloat,
        theme: RenderTheme
    ) {
        let direction: CGFloat = pointingRight ? -1 : 1
        let vertical: CGFloat = side == .top ? -1 : 1
        let spread: CGFloat = .pi / 6
        let wing = CGPoint(
            x: tip.x + direction * size * cos(spread),
            y: tip.y + vertical * size * sin(spread)
        )

        ctx.saveGState()
        if filled {
            let base = CGPoint(x: tip.x + direction * size * 0.55, y: tip.y)
            ctx.setFillColor(theme.foreground)
            ctx.move(to: tip)
            ctx.addLine(to: wing)
            ctx.addLine(to: base)
            ctx.closePath()
            ctx.fillPath()
        } else {
            ctx.setStrokeColor(theme.foreground)
            ctx.setLineWidth(1.5)
            ctx.move(to: tip)
            ctx.addLine(to: wing)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private static func drawCentralConnectionMarkers(
        ctx: CGContext,
        from: CGPoint,
        to: CGPoint,
        message: SequenceMessage,
        constants c: Constants,
        theme: RenderTheme
    ) {
        guard message.fromCentral || message.toCentral else { return }
        let radius = c.arrowSize * 0.45
        ctx.saveGState()
        ctx.setFillColor(theme.background)
        ctx.setStrokeColor(theme.foreground)
        ctx.setLineWidth(1.5)
        if message.fromCentral {
            ctx.fillEllipse(in: CGRect(x: from.x - radius, y: from.y - radius, width: radius * 2, height: radius * 2))
            ctx.strokeEllipse(in: CGRect(x: from.x - radius, y: from.y - radius, width: radius * 2, height: radius * 2))
        }
        if message.toCentral {
            ctx.fillEllipse(in: CGRect(x: to.x - radius, y: to.y - radius, width: radius * 2, height: radius * 2))
            ctx.strokeEllipse(in: CGRect(x: to.x - radius, y: to.y - radius, width: radius * 2, height: radius * 2))
        }
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

    private static func sequenceNumberLabels(for diagram: SequenceDiagram) -> [String?] {
        guard diagram.autonumber else {
            return Array(repeating: nil, count: diagram.messages.count)
        }

        var labels: [String?] = []
        var value = diagram.autonumberStart
        for _ in diagram.messages {
            labels.append(formatSequenceNumber(value))
            value += diagram.autonumberIncrement
        }
        return labels
    }

    private static func messageDisplayText(_ text: String, sequenceNumber: String?) -> String {
        guard let sequenceNumber else { return text }
        if text.isEmpty { return "\(sequenceNumber)." }
        return "\(sequenceNumber). \(text)"
    }

    private static func formatSequenceNumber(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded.rounded(.towardZero) == rounded {
            return String(Int(rounded))
        }

        var text = String(format: "%.2f", rounded)
        while text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text
    }

    private static func isDashedStyle(_ style: SequenceArrowStyle) -> Bool {
        switch style {
        case .dashed, .dashedOpen, .dashedCross, .dashedAsync,
             .dashedBidirectional,
             .dashedTopHalfArrow, .dashedBottomHalfArrow,
             .dashedReverseTopHalfArrow, .dashedReverseBottomHalfArrow,
             .dashedTopStickHalfArrow, .dashedBottomStickHalfArrow,
             .dashedReverseTopStickHalfArrow:
            true
        case .solid, .solidOpen, .solidCross, .solidAsync,
             .solidBidirectional,
             .solidTopHalfArrow, .solidBottomHalfArrow,
             .solidReverseTopHalfArrow, .solidReverseBottomHalfArrow,
             .solidTopStickHalfArrow, .solidBottomStickHalfArrow,
             .solidReverseTopStickHalfArrow:
            false
        }
    }

    private static func measureText(_ text: String, font: CTFont, fontSize: CGFloat) -> CGSize {
        MermaidTextUtils.measureText(text, font: font, fontSize: fontSize)
    }

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
