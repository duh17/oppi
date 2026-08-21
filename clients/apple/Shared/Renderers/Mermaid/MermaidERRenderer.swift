import CoreGraphics
import CoreText
import Foundation

/// Renderer for Mermaid ER diagrams (`erDiagram`).
///
/// Draws entity boxes as attribute tables (header band + one row per
/// `type name keys` attribute), connected by crow's-foot relationship lines.
/// Identifying relationships (`--`) draw solid lines, non-identifying (`..`)
/// draw dashed lines. Node placement reuses the shared `SugiyamaLayout`
/// engine; this renderer owns only the ER-specific measuring and drawing.
///
/// Uses the `FlowchartLayout` container with `customDraw`/`customSize`, the
/// same pattern as the mindmap and gantt renderers. Until the integrator hook
/// lands, callers reach this through `MermaidERRenderer.layout(_:configuration:)`
/// directly.
///
/// Spec source (pinned): https://github.com/mermaid-js/mermaid/blob/mermaid%4011.17.0/packages/mermaid/src/docs/syntax/entityRelationshipDiagram.md
enum MermaidERRenderer {

    // MARK: - Layout constants

    private struct LayoutConstants: Sendable {
        let fontSize: CGFloat
        let rowPaddingH: CGFloat      // horizontal padding inside the table
        let rowPaddingV: CGFloat      // vertical padding per row
        let headerPaddingV: CGFloat
        let columnGap: CGFloat        // gap between type / name / key columns
        let outerMargin: CGFloat      // margin around the whole diagram
        let nodeSpacing: CGFloat      // Sugiyama sibling spacing
        let rankSpacing: CGFloat      // Sugiyama rank spacing
        let minTableWidth: CGFloat
        let maxTableWidth: CGFloat

        // CTFont is not Sendable; create fonts on demand like the mindmap renderer.
        var font: CTFont { CTFontCreateWithName("Helvetica" as CFString, fontSize, nil) }
        var headerFont: CTFont { CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil) }

        init(fontSize: CGFloat, maxWidth: CGFloat) {
            self.fontSize = fontSize
            self.rowPaddingH = fontSize * 0.7
            self.rowPaddingV = fontSize * 0.3
            self.headerPaddingV = fontSize * 0.4
            self.columnGap = fontSize * 0.8
            self.outerMargin = fontSize * 1.5
            self.nodeSpacing = fontSize * 3
            self.rankSpacing = fontSize * 4.5
            self.minTableWidth = fontSize * 8
            // Leave room for the outer margin; wide diagrams may still exceed
            // the bubble and scale to fit inline (fullscreen zoom is the
            // inspection path, per the fidelity contract).
            self.maxTableWidth = max(maxWidth - fontSize * 3, fontSize * 12)
        }
    }

    // MARK: - Prepared drawing model

    /// A measured attribute row, ready to draw relative to its table's origin.
    private struct PreparedRow: Sendable {
        let typeText: String
        let nameText: String          // may contain \n when wrapped
        let keysText: String          // e.g. "PK, FK"; empty when none
        let commentText: String?      // may contain \n when wrapped
        let nameHeight: CGFloat
        let commentHeight: CGFloat
        let rowHeight: CGFloat
        let top: CGFloat              // relative to table top
    }

    /// A measured entity table with its Sugiyama-assigned position.
    private struct PreparedTable: Sendable {
        let name: String
        let title: String             // may contain \n when wrapped
        let rect: CGRect
        let rows: [PreparedRow]
        let headerHeight: CGFloat
        let typeColumnWidth: CGFloat
        let keysColumnWidth: CGFloat
    }

    /// A relationship line with its routed polyline and crow's-foot ends.
    private struct PreparedEdge: Sendable {
        let points: [CGPoint]
        let fromCardinality: ERCardinality
        let toCardinality: ERCardinality
        let identifying: Bool
        let label: String?
    }

    // MARK: - Public entry point

    nonisolated static func layout(
        _ diagram: ERDiagram,
        configuration: RenderConfiguration
    ) -> MermaidFlowchartRenderer.FlowchartLayout {
        let constants = LayoutConstants(fontSize: configuration.fontSize, maxWidth: configuration.maxWidth)
        let theme = configuration.theme

        guard !diagram.entities.isEmpty else {
            return MermaidFlowchartRenderer.FlowchartLayout(
                graphResult: GraphLayoutResult(nodePositions: [:], edgePaths: [], totalSize: .zero),
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
                fontSize: configuration.fontSize,
                theme: theme,
                isPlaceholder: false,
                placeholderText: nil,
                customDraw: nil,
                customSize: CGSize(width: 1, height: 1)
            )
        }

        // Measure wrapped tables first so Sugiyama's rectangles match the ink.
        let measuredTables = Dictionary(uniqueKeysWithValues: diagram.entities.map { entity in
            (entity.name, measureTable(for: entity, constants: constants))
        })
        let graphResult = layoutGraph(
            diagram,
            tableSizes: measuredTables.mapValues(\.size),
            constants: constants
        )

        // Attach measured rows to each positioned table.
        let tables: [PreparedTable] = diagram.entities.compactMap { entity in
            guard let rect = graphResult.nodePositions[entity.name],
                  let measured = measuredTables[entity.name] else { return nil }
            return prepareTable(measured, name: entity.name, rect: rect)
        }

        // Sugiyama emits edge paths in input order; every relationship
        // references a registered entity, so the arrays stay aligned.
        let edges: [PreparedEdge] = zip(diagram.relationships, graphResult.edgePaths).map { relationship, path in
            PreparedEdge(
                points: path.points,
                fromCardinality: relationship.fromCardinality,
                toCardinality: relationship.toCardinality,
                identifying: relationship.identifying,
                label: wrappedLabel(relationship.label, constants: constants)
            )
        }

        let size = CGSize(
            width: graphResult.totalSize.width + constants.outerMargin * 2,
            height: graphResult.totalSize.height + constants.outerMargin * 2
        )

        let drawBlock: @Sendable (CGContext, CGPoint) -> Void = { ctx, origin in
            let offset = CGPoint(
                x: origin.x + constants.outerMargin,
                y: origin.y + constants.outerMargin
            )
            for edge in edges {
                drawRelationship(edge, at: offset, constants: constants, theme: theme, in: ctx)
            }
            for table in tables {
                drawTable(table, at: offset, constants: constants, theme: theme, in: ctx)
            }
        }

        return MermaidFlowchartRenderer.FlowchartLayout(
            graphResult: graphResult,
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
            fontSize: configuration.fontSize,
            theme: theme,
            isPlaceholder: false,
            placeholderText: nil,
            customDraw: drawBlock,
            customSize: size
        )
    }

    // MARK: - Graph layout

    private static func layoutGraph(
        _ diagram: ERDiagram,
        tableSizes: [String: CGSize],
        constants: LayoutConstants
    ) -> GraphLayoutResult {
        let nodes = diagram.entities.map { entity in
            GraphLayoutNode(
                id: entity.name,
                size: tableSizes[entity.name] ?? CGSize(width: constants.minTableWidth, height: constants.fontSize * 2)
            )
        }
        let edges = diagram.relationships.map { relationship in
            GraphLayoutEdge(from: relationship.from, to: relationship.to)
        }
        let input = GraphLayoutInput(
            nodes: nodes,
            edges: edges,
            direction: graphLayoutDirection(for: diagram.direction),
            nodeSpacing: constants.nodeSpacing,
            rankSpacing: constants.rankSpacing
        )
        let raw = SugiyamaLayout.layout(input)
        return refineRelationships(
            raw,
            relationships: diagram.relationships,
            direction: diagram.direction,
            constants: constants
        )
    }

    private static func graphLayoutDirection(for direction: FlowDirection) -> GraphLayoutDirection {
        switch direction {
        case .TB, .TD: return .topToBottom
        case .BT: return .bottomToTop
        case .LR: return .leftToRight
        case .RL: return .rightToLeft
        }
    }

    // MARK: - Relationship routing

    /// Replace through-the-box self-loops and overpainted parallel edges.
    private static func refineRelationships(
        _ result: GraphLayoutResult,
        relationships: [ERRelationship],
        direction: FlowDirection,
        constants: LayoutConstants
    ) -> GraphLayoutResult {
        let isHorizontal = direction == .LR || direction == .RL
        var pairTotals: [String: Int] = [:]
        for relationship in relationships {
            pairTotals[pairKey(relationship), default: 0] += 1
        }

        var pairOrdinals: [String: Int] = [:]
        var paths: [GraphLayoutEdgePath] = []
        paths.reserveCapacity(relationships.count)

        for (index, relationship) in relationships.enumerated() {
            let key = pairKey(relationship)
            let ordinal = pairOrdinals[key, default: 0]
            pairOrdinals[key] = ordinal + 1
            let total = pairTotals[key] ?? 1
            let sugiyama = index < result.edgePaths.count ? result.edgePaths[index] : nil

            if relationship.from == relationship.to,
               let rect = result.nodePositions[relationship.from] {
                paths.append(GraphLayoutEdgePath(
                    from: relationship.from,
                    to: relationship.to,
                    points: selfLoopPoints(rect: rect, lane: ordinal, constants: constants)
                ))
            } else if total > 1,
                      let base = sugiyama,
                      let fromRect = result.nodePositions[relationship.from],
                      let toRect = result.nodePositions[relationship.to] {
                paths.append(GraphLayoutEdgePath(
                    from: relationship.from,
                    to: relationship.to,
                    points: offsetPath(
                        base.points,
                        fromRect: fromRect,
                        toRect: toRect,
                        lane: ordinal,
                        total: total,
                        isHorizontal: isHorizontal
                    )
                ))
            } else if let base = sugiyama {
                paths.append(base)
            }
        }

        var maxX = result.totalSize.width
        var maxY = result.totalSize.height
        for path in paths {
            for point in path.points {
                maxX = max(maxX, point.x + constants.fontSize)
                maxY = max(maxY, point.y + constants.fontSize)
            }
        }

        return GraphLayoutResult(
            nodePositions: result.nodePositions,
            edgePaths: paths,
            totalSize: CGSize(width: maxX, height: maxY)
        )
    }

    private static func pairKey(_ relationship: ERRelationship) -> String {
        relationship.from <= relationship.to
            ? "\(relationship.from)\u{0}\(relationship.to)"
            : "\(relationship.to)\u{0}\(relationship.from)"
    }

    /// U-shaped loop on the right edge so recursive relationships stay visible.
    private static func selfLoopPoints(
        rect: CGRect,
        lane: Int,
        constants: LayoutConstants
    ) -> [CGPoint] {
        let spread = min(max(rect.height * 0.22, constants.fontSize * 0.55), constants.fontSize * 1.2)
        let laneShift = CGFloat(lane) * constants.fontSize * 0.4
        var top = rect.midY - spread - laneShift
        var bottom = rect.midY + spread + laneShift
        top = min(max(top, rect.minY + 2), rect.maxY - 2)
        bottom = min(max(bottom, rect.minY + 2), rect.maxY - 2)
        if bottom - top < constants.fontSize * 0.6 {
            bottom = min(rect.maxY - 2, top + constants.fontSize * 0.6)
        }
        let reach = constants.fontSize * 2.8 + CGFloat(lane) * constants.fontSize * 1.5
        let outerX = rect.maxX + reach
        return [
            CGPoint(x: rect.maxX, y: top),
            CGPoint(x: outerX, y: top),
            CGPoint(x: outerX, y: bottom),
            CGPoint(x: rect.maxX, y: bottom),
        ]
    }

    /// Spread parallel edges along the attachment sides so labels and markers do not stack.
    private static func offsetPath(
        _ points: [CGPoint],
        fromRect: CGRect,
        toRect: CGRect,
        lane: Int,
        total: Int,
        isHorizontal: Bool
    ) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        let fraction = total <= 1
            ? 0.5
            : (CGFloat(lane) + 1) / (CGFloat(total) + 1)
        let newFrom = portPoint(on: fromRect, original: points[0], fraction: fraction, isHorizontal: isHorizontal)
        let newTo = portPoint(
            on: toRect,
            original: points[points.count - 1],
            fraction: fraction,
            isHorizontal: isHorizontal
        )
        let deltaFrom = CGPoint(x: newFrom.x - points[0].x, y: newFrom.y - points[0].y)
        let deltaTo = CGPoint(x: newTo.x - points[points.count - 1].x, y: newTo.y - points[points.count - 1].y)
        let last = CGFloat(points.count - 1)
        return points.enumerated().map { index, point in
            let t = last > 0 ? CGFloat(index) / last : 0
            return CGPoint(
                x: point.x + deltaFrom.x * (1 - t) + deltaTo.x * t,
                y: point.y + deltaFrom.y * (1 - t) + deltaTo.y * t
            )
        }
    }

    private static func portPoint(
        on rect: CGRect,
        original: CGPoint,
        fraction: CGFloat,
        isHorizontal: Bool
    ) -> CGPoint {
        let clamped = min(max(fraction, 0.18), 0.82)
        if isHorizontal {
            let x = abs(original.x - rect.minX) <= abs(original.x - rect.maxX) ? rect.minX : rect.maxX
            return CGPoint(x: x, y: rect.minY + rect.height * clamped)
        }
        let y = abs(original.y - rect.minY) <= abs(original.y - rect.maxY) ? rect.minY : rect.maxY
        return CGPoint(x: rect.minX + rect.width * clamped, y: y)
    }

    // MARK: - Table measuring

    /// Natural (unwrapped) measurement of one attribute row.
    private struct RowMeasure {
        let typeWidth: CGFloat
        let nameWidth: CGFloat
        let keysWidth: CGFloat
        let commentWidth: CGFloat
    }

    /// Wrapped table used both as the Sugiyama node size and the draw model.
    private struct MeasuredTable {
        let size: CGSize
        let title: String
        let headerHeight: CGFloat
        let typeColumnWidth: CGFloat
        let keysColumnWidth: CGFloat
        let rows: [PreparedRow]
    }

    private static func measureRow(_ attribute: ERAttribute, constants: LayoutConstants) -> RowMeasure {
        let keysText = keysDisplayText(attribute.keys)
        return RowMeasure(
            typeWidth: measureText(attribute.type, font: constants.font, fontSize: constants.fontSize).width,
            nameWidth: measureText(attribute.name, font: constants.font, fontSize: constants.fontSize).width,
            keysWidth: keysText.isEmpty ? 0 : measureText(keysText, font: constants.font, fontSize: constants.fontSize).width,
            commentWidth: attribute.comment.map {
                measureText($0, font: constants.font, fontSize: constants.fontSize).width
            } ?? 0
        )
    }

    /// Measure a table after wrapping header / names / comments to the clamped width.
    private static func measureTable(for entity: EREntity, constants: LayoutConstants) -> MeasuredTable {
        let tableWidth = measuredTableWidth(for: entity, constants: constants)
        let rowMeasures = entity.attributes.map { measureRow($0, constants: constants) }
        let typeColumnWidth = rowMeasures.map(\.typeWidth).max() ?? 0
        let keysColumnWidth = rowMeasures.map(\.keysWidth).max() ?? 0

        let keysColumnSpace = keysColumnWidth > 0 ? constants.columnGap + keysColumnWidth : 0
        let nameBudget = tableWidth
            - constants.rowPaddingH * 2
            - (typeColumnWidth > 0 ? typeColumnWidth + constants.columnGap : 0)
            - keysColumnSpace
        let commentBudget = tableWidth - constants.rowPaddingH * 2
        let titleBudget = tableWidth - constants.rowPaddingH * 2

        let title = wrapIfNeeded(
            entity.displayName,
            budget: titleBudget,
            font: constants.headerFont,
            constants: constants
        )
        let headerHeight = measureText(title, font: constants.headerFont, fontSize: constants.fontSize).height
            + constants.headerPaddingV * 2

        var rows: [PreparedRow] = []
        var rowTop = headerHeight
        for attribute in entity.attributes {
            let nameText = wrapIfNeeded(
                attribute.name,
                budget: nameBudget,
                font: constants.font,
                constants: constants
            )
            let commentText = attribute.comment.map { comment in
                wrapIfNeeded(comment, budget: commentBudget, font: constants.font, constants: constants)
            }
            let nameHeight = nameText.isEmpty
                ? 0
                : measureText(nameText, font: constants.font, fontSize: constants.fontSize).height
            let commentHeight = commentText.map {
                measureText($0, font: constants.font, fontSize: constants.fontSize).height + constants.fontSize * 0.15
            } ?? 0
            let rowHeight = nameHeight + commentHeight + constants.rowPaddingV * 2
            rows.append(PreparedRow(
                typeText: attribute.type,
                nameText: nameText,
                keysText: keysDisplayText(attribute.keys),
                commentText: commentText,
                nameHeight: nameHeight,
                commentHeight: commentHeight,
                rowHeight: rowHeight,
                top: rowTop
            ))
            rowTop += rowHeight
        }

        return MeasuredTable(
            size: CGSize(width: tableWidth, height: rowTop),
            title: title,
            headerHeight: headerHeight,
            typeColumnWidth: typeColumnWidth,
            keysColumnWidth: keysColumnWidth,
            rows: rows
        )
    }

    /// Natural table width clamped to the mobile max-width budget.
    private static func measuredTableWidth(for entity: EREntity, constants: LayoutConstants) -> CGFloat {
        let rowMeasures = entity.attributes.map { measureRow($0, constants: constants) }
        let typeColumn = rowMeasures.map(\.typeWidth).max() ?? 0
        let keysColumn = rowMeasures.map(\.keysWidth).max() ?? 0
        let nameMax = rowMeasures.map(\.nameWidth).max() ?? 0
        let commentMax = rowMeasures.map(\.commentWidth).max() ?? 0
        let headerWidth = measureText(entity.displayName, font: constants.headerFont, fontSize: constants.fontSize).width

        let rowMax = typeColumn
            + (typeColumn > 0 ? constants.columnGap : 0)
            + nameMax
            + (keysColumn > 0 ? constants.columnGap + keysColumn : 0)
        let natural = max(headerWidth, rowMax, commentMax) + constants.rowPaddingH * 2
        return min(max(natural, constants.minTableWidth), constants.maxTableWidth)
    }

    // MARK: - Table preparation

    private static func prepareTable(
        _ measured: MeasuredTable,
        name: String,
        rect: CGRect
    ) -> PreparedTable {
        PreparedTable(
            name: name,
            title: measured.title,
            rect: rect,
            rows: measured.rows,
            headerHeight: measured.headerHeight,
            typeColumnWidth: measured.typeColumnWidth,
            keysColumnWidth: measured.keysColumnWidth
        )
    }

    private static func keysDisplayText(_ keys: [ERAttributeKey]) -> String {
        keys.map(\.rawValue).joined(separator: ", ")
    }

    private static func wrappedLabel(_ label: String?, constants: LayoutConstants) -> String? {
        guard let label, !label.isEmpty else { return nil }
        let budget = max(constants.fontSize * 12, constants.maxTableWidth * 0.7)
        return wrapIfNeeded(label, budget: budget, font: constants.font, constants: constants)
    }

    /// Wrap text to a width budget only when a single line would not fit.
    private static func wrapIfNeeded(
        _ text: String,
        budget: CGFloat,
        font: CTFont,
        constants: LayoutConstants
    ) -> String {
        guard budget > 0 else { return text }
        let single = measureText(text, font: font, fontSize: constants.fontSize)
        if single.width <= budget { return text }
        return wrap(text, to: budget, font: font, fontSize: constants.fontSize)
    }

    /// Greedy word wrap. Words longer than the budget keep their own line.
    private static func wrap(_ text: String, to maxWidth: CGFloat, font: CTFont, fontSize: CGFloat) -> String {
        var lines: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let words = paragraph.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if words.isEmpty {
                lines.append("")
                continue
            }
            var current = words[0]
            for word in words.dropFirst() {
                let candidate = current + " " + word
                if MermaidTextUtils.measureText(candidate, font: font, fontSize: fontSize).width <= maxWidth {
                    current = candidate
                } else {
                    lines.append(current)
                    current = word
                }
            }
            lines.append(current)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Table drawing

    private static func drawTable(
        _ table: PreparedTable,
        at offset: CGPoint,
        constants: LayoutConstants,
        theme: RenderTheme,
        in ctx: CGContext
    ) {
        let rect = table.rect.offsetBy(dx: offset.x, dy: offset.y)
        let cornerRadius: CGFloat = min(6, constants.fontSize * 0.4)

        // Box: opaque background so relationship lines never show through.
        ctx.saveGState()
        ctx.setFillColor(theme.background)
        ctx.setStrokeColor(theme.accentBlue)
        ctx.setLineWidth(1.5)
        let boxPath = CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        ctx.addPath(boxPath)
        ctx.drawPath(using: .fillStroke)

        // Header band (clipped to the rounded top corners).
        let headerRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: table.headerHeight)
        if let headerTint = theme.accentBlue.copy(alpha: 0.18) {
            ctx.saveGState()
            ctx.addPath(boxPath)
            ctx.clip()
            ctx.setFillColor(headerTint)
            ctx.fill(headerRect)
            ctx.restoreGState()
        }

        // Header separator.
        ctx.setStrokeColor(theme.accentBlue)
        ctx.setLineWidth(1.0)
        ctx.move(to: CGPoint(x: rect.minX, y: headerRect.maxY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: headerRect.maxY))
        ctx.strokePath()
        ctx.restoreGState()

        // Header title.
        MermaidTextUtils.drawText(
            table.title,
            centeredIn: headerRect.insetBy(dx: constants.rowPaddingH, dy: 0),
            font: constants.headerFont,
            fontSize: constants.fontSize,
            foregroundColor: theme.foreground,
            in: ctx
        )

        // Attribute rows.
        for row in table.rows {
            let rowRect = CGRect(
                x: rect.minX,
                y: rect.minY + row.top,
                width: rect.width,
                height: row.rowHeight
            )
            let textTop = rowRect.minY + constants.rowPaddingV
            let typeX = rect.minX + constants.rowPaddingH
            let nameX = typeX
                + (table.typeColumnWidth > 0 ? table.typeColumnWidth + constants.columnGap : 0)

            // Type (dim).
            MermaidTextUtils.drawText(
                row.typeText,
                at: CGPoint(x: typeX, y: textTop),
                font: constants.font,
                fontSize: constants.fontSize,
                foregroundColor: theme.foregroundDim,
                in: ctx
            )

            // Name (primary text).
            MermaidTextUtils.drawText(
                row.nameText,
                at: CGPoint(x: nameX, y: textTop),
                font: constants.font,
                fontSize: constants.fontSize,
                foregroundColor: theme.foreground,
                in: ctx
            )

            // Keys (right-aligned accent).
            if !row.keysText.isEmpty {
                let keysWidth = measureText(row.keysText, font: constants.font, fontSize: constants.fontSize).width
                MermaidTextUtils.drawText(
                    row.keysText,
                    at: CGPoint(
                        x: rect.maxX - constants.rowPaddingH - keysWidth,
                        y: textTop
                    ),
                    font: constants.font,
                    fontSize: constants.fontSize,
                    foregroundColor: theme.accentOrange,
                    in: ctx
                )
            }

            // Comment (dim, under the name).
            if let comment = row.commentText {
                MermaidTextUtils.drawText(
                    comment,
                    at: CGPoint(x: nameX, y: textTop + row.nameHeight + constants.fontSize * 0.15),
                    font: constants.font,
                    fontSize: constants.fontSize * 0.9,
                    foregroundColor: theme.comment,
                    in: ctx
                )
            }
        }
    }

    // MARK: - Relationship drawing

    private static func drawRelationship(
        _ edge: PreparedEdge,
        at offset: CGPoint,
        constants: LayoutConstants,
        theme: RenderTheme,
        in ctx: CGContext
    ) {
        guard edge.points.count >= 2 else { return }
        let points = edge.points.map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }

        ctx.saveGState()
        ctx.setStrokeColor(theme.foreground)
        ctx.setLineWidth(1.2)
        ctx.setLineCap(.round)
        if !edge.identifying {
            let dash = constants.fontSize * 0.45
            ctx.setLineDash(phase: 0, lengths: [dash, dash * 0.7])
        }

        ctx.move(to: points[0])
        for point in points.dropFirst() {
            ctx.addLine(to: point)
        }
        ctx.strokePath()
        ctx.restoreGState()

        // Crow's-foot markers at each entity end.
        drawMarker(
            edge.fromCardinality,
            at: points[0],
            away: points[1],
            theme: theme,
            constants: constants,
            in: ctx
        )
        drawMarker(
            edge.toCardinality,
            at: points[points.count - 1],
            away: points[points.count - 2],
            theme: theme,
            constants: constants,
            in: ctx
        )

        // Label at the polyline's arc-length midpoint.
        if let label = edge.label {
            drawLabel(label, on: points, theme: theme, constants: constants, in: ctx)
        }
    }

    /// Crow's-foot marker at an entity boundary.
    ///
    /// `point` sits on the entity edge; `away` is the next polyline vertex,
    /// so the marker extends back along the line, away from the entity.
    private static func drawMarker(
        _ cardinality: ERCardinality,
        at point: CGPoint,
        away: CGPoint,
        theme: RenderTheme,
        constants: LayoutConstants,
        in ctx: CGContext
    ) {
        let dx = away.x - point.x
        let dy = away.y - point.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0.001 else { return }
        let u = CGPoint(x: dx / length, y: dy / length) // away from entity
        let v = CGPoint(x: -u.y, y: u.x)                // perpendicular
        let fontSize = constants.fontSize

        func pointAt(_ distance: CGFloat, _ side: CGFloat) -> CGPoint {
            CGPoint(
                x: point.x + u.x * distance + v.x * side,
                y: point.y + u.y * distance + v.y * side
            )
        }

        ctx.saveGState()
        ctx.setStrokeColor(theme.foreground)
        ctx.setLineWidth(1.2)
        ctx.setLineCap(.round)

        func segment(_ a: CGPoint, _ b: CGPoint) {
            ctx.move(to: a)
            ctx.addLine(to: b)
        }

        let footLength = fontSize * 0.9
        let footSpread = fontSize * 0.42
        let tickHalf = fontSize * 0.35
        let ringRadius = fontSize * 0.28

        switch cardinality {
        case .exactlyOne:
            // Two perpendicular ticks: `||`
            for distance in [fontSize * 0.35, fontSize * 0.8] {
                segment(pointAt(distance, -tickHalf), pointAt(distance, tickHalf))
            }
        case .zeroOrOne:
            // One tick plus a ring: `|o`
            segment(pointAt(fontSize * 0.35, -tickHalf), pointAt(fontSize * 0.35, tickHalf))
            drawRing(at: pointAt(fontSize * 1.1, 0), radius: ringRadius, theme: theme, in: ctx)
        case .oneOrMore:
            // Crow's foot plus one tick: `}|` / `|{`
            let anchor = pointAt(footLength, 0)
            segment(anchor, point)
            segment(anchor, pointAt(0, footSpread))
            segment(anchor, pointAt(0, -footSpread))
            let tickDistance = footLength + fontSize * 0.45
            segment(pointAt(tickDistance, -tickHalf), pointAt(tickDistance, tickHalf))
        case .zeroOrMore:
            // Crow's foot plus a ring: `}o` / `o{`
            let anchor = pointAt(footLength, 0)
            segment(anchor, point)
            segment(anchor, pointAt(0, footSpread))
            segment(anchor, pointAt(0, -footSpread))
            drawRing(at: pointAt(footLength + fontSize * 0.55, 0), radius: ringRadius, theme: theme, in: ctx)
        }

        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Ring drawn with an opaque background fill so the line does not run through it.
    private static func drawRing(
        at center: CGPoint,
        radius: CGFloat,
        theme: RenderTheme,
        in ctx: CGContext
    ) {
        let bounds = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        ctx.saveGState()
        ctx.setFillColor(theme.background)
        ctx.setStrokeColor(theme.foreground)
        ctx.fillEllipse(in: bounds)
        ctx.strokeEllipse(in: bounds)
        ctx.restoreGState()
    }

    private static func drawLabel(
        _ label: String,
        on points: [CGPoint],
        theme: RenderTheme,
        constants: LayoutConstants,
        in ctx: CGContext
    ) {
        let mid = arcMidpoint(points)
        let labelFont = constants.font
        let textSize = measureText(label, font: labelFont, fontSize: constants.fontSize)
        let padding = constants.fontSize * 0.25
        let background = CGRect(
            x: mid.x - textSize.width / 2 - padding,
            y: mid.y - textSize.height / 2 - padding,
            width: textSize.width + padding * 2,
            height: textSize.height + padding * 2
        )

        ctx.saveGState()
        ctx.setFillColor(theme.background)
        ctx.fill(background)
        ctx.restoreGState()

        MermaidTextUtils.drawText(
            label,
            centeredIn: background,
            font: labelFont,
            fontSize: constants.fontSize,
            foregroundColor: theme.foregroundDim,
            in: ctx
        )
    }

    /// Point at half the polyline's total arc length.
    private static func arcMidpoint(_ points: [CGPoint]) -> CGPoint {
        guard points.count >= 2 else { return points.first ?? .zero }
        var total: CGFloat = 0
        for index in 0..<(points.count - 1) {
            total += hypot(
                points[index + 1].x - points[index].x,
                points[index + 1].y - points[index].y
            )
        }
        guard total > 0 else { return points[0] }
        var remaining = total / 2
        for index in 0..<(points.count - 1) {
            let dx = points[index + 1].x - points[index].x
            let dy = points[index + 1].y - points[index].y
            let length = hypot(dx, dy)
            if length >= remaining {
                let t = length > 0 ? remaining / length : 0
                return CGPoint(
                    x: points[index].x + dx * t,
                    y: points[index].y + dy * t
                )
            }
            remaining -= length
        }
        return points[points.count - 1]
    }

    // MARK: - Text helpers

    private static func measureText(_ text: String, font: CTFont, fontSize: CGFloat) -> CGSize {
        MermaidTextUtils.measureText(text, font: font, fontSize: fontSize)
    }
}
