import CoreGraphics
import CoreText
import Foundation

/// Renders `MermaidDiagram` flowcharts using Sugiyama layout + Core Graphics.
///
/// Conforms to `GraphicalDocumentRenderer`. Sequence diagrams return a
/// placeholder — only flowcharts are supported in this phase.
///
/// Pipeline: measure text → build layout input → Sugiyama → draw shapes + edges.
///
/// Thread safety: all methods are `nonisolated`. The draw closure captures only
/// value types and the pre-laid-out result. `CGContext` is not thread-safe itself
/// — callers must ensure the context is only used from one thread at a time
/// (which UIView.draw / NSView.draw guarantees).
struct MermaidFlowchartRenderer: GraphicalDocumentRenderer, Sendable {
    typealias Document = MermaidDiagram

    /// Laid-out flowchart ready for drawing.
    struct FlowchartLayout: Sendable {
        let graphResult: GraphLayoutResult
        let flowchart: FlowchartDiagram
        let nodeLabels: [String: String]       // id → display label
        let nodeShapes: [String: FlowNodeShape] // id → shape
        let edgeLabels: [String: String]       // "from->to" → label
        let edgeStyles: [String: FlowEdgeStyle] // "from->to" → style
        let classDefs: [String: [String: String]]
        let styleDirectives: [String: [String: String]] // nodeId → css props
        let fontSize: CGFloat
        let theme: RenderTheme
        let isPlaceholder: Bool
        let placeholderText: String?
    }

    typealias LayoutResult = FlowchartLayout

    nonisolated func layout(
        _ document: MermaidDiagram,
        configuration: RenderConfiguration
    ) -> FlowchartLayout {
        switch document {
        case .flowchart(let flowchart):
            return layoutFlowchart(flowchart, configuration: configuration)
        case .sequence:
            return placeholderLayout(
                text: "Sequence diagrams not yet supported",
                configuration: configuration
            )
        case .unsupported(let type):
            return placeholderLayout(
                text: "Unsupported diagram type: \(type)",
                configuration: configuration
            )
        }
    }

    nonisolated func draw(
        _ layout: FlowchartLayout,
        in ctx: CGContext,
        at origin: CGPoint
    ) {
        if layout.isPlaceholder {
            drawPlaceholder(layout, in: ctx, at: origin)
            return
        }
        drawFlowchart(layout, in: ctx, at: origin)
    }

    nonisolated func boundingBox(_ layout: FlowchartLayout) -> CGSize {
        if layout.isPlaceholder {
            return CGSize(width: 300, height: 40)
        }
        // Add padding around the graph.
        let padding: CGFloat = 20
        return CGSize(
            width: layout.graphResult.totalSize.width + padding * 2,
            height: layout.graphResult.totalSize.height + padding * 2
        )
    }

    // MARK: - Flowchart layout

    private func layoutFlowchart(
        _ flowchart: FlowchartDiagram,
        configuration: RenderConfiguration
    ) -> FlowchartLayout {
        let fontSize = configuration.fontSize

        // Build node labels and shapes.
        var nodeLabels: [String: String] = [:]
        var nodeShapes: [String: FlowNodeShape] = [:]
        for node in flowchart.nodes {
            nodeLabels[node.id] = node.label
            nodeShapes[node.id] = node.shape
        }

        // Measure node sizes.
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        var layoutNodes: [GraphLayoutNode] = []
        for node in flowchart.nodes {
            let textSize = measureText(node.label, font: font, fontSize: fontSize)
            let paddedSize = padForShape(textSize, shape: node.shape, fontSize: fontSize)
            layoutNodes.append(GraphLayoutNode(id: node.id, size: paddedSize))
        }

        // Build edges.
        let layoutEdges = flowchart.edges.map {
            GraphLayoutEdge(from: $0.from, to: $0.to)
        }

        // Map direction.
        let direction: GraphLayoutDirection
        switch flowchart.direction {
        case .TB, .TD: direction = .topToBottom
        case .BT: direction = .bottomToTop
        case .LR: direction = .leftToRight
        case .RL: direction = .rightToLeft
        }

        let input = GraphLayoutInput(
            nodes: layoutNodes,
            edges: layoutEdges,
            direction: direction,
            nodeSpacing: fontSize * 3,
            rankSpacing: fontSize * 4
        )

        let graphResult = SugiyamaLayout.layout(input)

        // Build edge metadata maps.
        var edgeLabels: [String: String] = [:]
        var edgeStyles: [String: FlowEdgeStyle] = [:]
        for edge in flowchart.edges {
            let key = "\(edge.from)->\(edge.to)"
            if let label = edge.label { edgeLabels[key] = label }
            edgeStyles[key] = edge.style
        }

        // Build style directive map.
        var styleMap: [String: [String: String]] = [:]
        for directive in flowchart.styleDirectives {
            styleMap[directive.nodeId] = directive.properties
        }

        return FlowchartLayout(
            graphResult: graphResult,
            flowchart: flowchart,
            nodeLabels: nodeLabels,
            nodeShapes: nodeShapes,
            edgeLabels: edgeLabels,
            edgeStyles: edgeStyles,
            classDefs: flowchart.classDefs,
            styleDirectives: styleMap,
            fontSize: fontSize,
            theme: configuration.theme,
            isPlaceholder: false,
            placeholderText: nil
        )
    }

    // MARK: - Text measurement

    /// Measure text size using CoreText. Returns the natural size without padding.
    private func measureText(_ text: String, font: CTFont, fontSize: CGFloat) -> CGSize {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        return CGSize(
            width: max(bounds.width, fontSize * 2),
            height: max(bounds.height, fontSize * 1.4)
        )
    }

    /// Add shape-specific padding around text.
    private func padForShape(_ textSize: CGSize, shape: FlowNodeShape, fontSize: CGFloat) -> CGSize {
        let hPad: CGFloat
        let vPad: CGFloat

        switch shape {
        case .diamond:
            // Diamonds need extra padding because text is inscribed in a rotated square.
            hPad = textSize.height + fontSize * 2
            vPad = textSize.width * 0.4 + fontSize
        case .hexagon:
            hPad = fontSize * 3
            vPad = fontSize * 1.5
        case .circle:
            // Circle: make it square with padding.
            let maxDim = max(textSize.width, textSize.height)
            return CGSize(width: maxDim + fontSize * 2, height: maxDim + fontSize * 2)
        case .stadium:
            hPad = fontSize * 2.5
            vPad = fontSize * 1.2
        default:
            hPad = fontSize * 1.5
            vPad = fontSize * 1.0
        }

        return CGSize(width: textSize.width + hPad, height: textSize.height + vPad)
    }

    // MARK: - Placeholder

    private func placeholderLayout(
        text: String,
        configuration: RenderConfiguration
    ) -> FlowchartLayout {
        FlowchartLayout(
            graphResult: GraphLayoutResult(nodePositions: [:], edgePaths: [], totalSize: .zero),
            flowchart: .empty,
            nodeLabels: [:],
            nodeShapes: [:],
            edgeLabels: [:],
            edgeStyles: [:],
            classDefs: [:],
            styleDirectives: [:],
            fontSize: configuration.fontSize,
            theme: configuration.theme,
            isPlaceholder: true,
            placeholderText: text
        )
    }

    // MARK: - Drawing: Placeholder

    private func drawPlaceholder(
        _ layout: FlowchartLayout,
        in ctx: CGContext,
        at origin: CGPoint
    ) {
        let text = layout.placeholderText ?? ""
        let font = CTFontCreateWithName("Helvetica" as CFString, layout.fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: layout.theme.foregroundDim,
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString)

        drawCTLine(line, at: CGPoint(x: origin.x + 10, y: origin.y + 10), fontSize: 14, in: ctx)
    }

    // MARK: - Drawing: Flowchart

    private func drawFlowchart(
        _ layout: FlowchartLayout,
        in ctx: CGContext,
        at origin: CGPoint
    ) {
        let padding: CGFloat = 20
        let offset = CGPoint(x: origin.x + padding, y: origin.y + padding)

        // Draw edges first (behind nodes).
        for edgePath in layout.graphResult.edgePaths {
            let key = "\(edgePath.from)->\(edgePath.to)"
            let style = layout.edgeStyles[key] ?? .arrow
            drawEdge(edgePath, style: style, layout: layout, in: ctx, offset: offset)

            // Edge label at midpoint.
            if let label = layout.edgeLabels[key] {
                drawEdgeLabel(label, path: edgePath, layout: layout, in: ctx, offset: offset)
            }
        }

        // Draw nodes.
        for (id, rect) in layout.graphResult.nodePositions {
            let shape = layout.nodeShapes[id] ?? .default
            let label = layout.nodeLabels[id] ?? id
            let offsetRect = rect.offsetBy(dx: offset.x, dy: offset.y)

            let styleProps = layout.styleDirectives[id] ?? [:]
            drawNodeShape(shape, rect: offsetRect, style: styleProps, layout: layout, in: ctx)
            drawNodeLabel(label, in: offsetRect, layout: layout, ctx: ctx)
        }
    }

    // MARK: - Node shapes

    private func drawNodeShape(
        _ shape: FlowNodeShape,
        rect: CGRect,
        style: [String: String],
        layout: FlowchartLayout,
        in ctx: CGContext
    ) {
        let fillColor = parseCSSColor(style["fill"]) ?? layout.theme.background
        let strokeColor = parseCSSColor(style["stroke"]) ?? layout.theme.foreground
        let lineWidth: CGFloat = parseLineWidth(style["stroke-width"]) ?? 1.5

        ctx.saveGState()
        ctx.setLineWidth(lineWidth)
        ctx.setStrokeColor(strokeColor)
        ctx.setFillColor(fillColor)

        let path: CGPath
        switch shape {
        case .rectangle, .default:
            path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        case .rounded:
            path = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        case .stadium:
            let radius = rect.height / 2
            path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .diamond:
            path = diamondPath(rect)
        case .hexagon:
            path = hexagonPath(rect)
        case .circle:
            path = CGPath(ellipseIn: rect, transform: nil)
        case .cylindrical:
            // Approximate as rounded rect with extra rounding.
            path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        case .subroutine:
            path = subroutinePath(rect)
        case .asymmetric:
            path = asymmetricPath(rect)
        }

        ctx.addPath(path)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
    }

    private func diamondPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let cx = rect.midX, cy = rect.midY
        path.move(to: CGPoint(x: cx, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: cy))
        path.addLine(to: CGPoint(x: cx, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: cy))
        path.closeSubpath()
        return path
    }

    private func hexagonPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let inset = rect.width * 0.15
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }

    private func subroutinePath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let inset: CGFloat = 6
        // Outer rectangle.
        path.addRect(rect)
        // Inner vertical lines on left and right.
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
        return path
    }

    private func asymmetricPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let notch = rect.height * 0.3
        path.move(to: CGPoint(x: rect.minX + notch, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + notch, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }

    // MARK: - Node label

    private func drawNodeLabel(
        _ text: String,
        in rect: CGRect,
        layout: FlowchartLayout,
        ctx: CGContext
    ) {
        let font = CTFontCreateWithName("Helvetica" as CFString, layout.fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: layout.theme.foreground,
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString)
        let bounds = CTLineGetBoundsWithOptions(line, [])

        // Center text in the rect.
        let textX = rect.midX - bounds.width / 2
        let textY = rect.midY - bounds.height / 2

        drawCTLine(line, at: CGPoint(x: textX, y: textY), fontSize: layout.fontSize, in: ctx)
    }

    // MARK: - Edges

    private func drawEdge(
        _ edgePath: GraphLayoutEdgePath,
        style: FlowEdgeStyle,
        layout: FlowchartLayout,
        in ctx: CGContext,
        offset: CGPoint
    ) {
        guard edgePath.points.count >= 2 else { return }

        let points = edgePath.points.map {
            CGPoint(x: $0.x + offset.x, y: $0.y + offset.y)
        }

        ctx.saveGState()
        ctx.setStrokeColor(layout.theme.foreground)

        switch style {
        case .arrow:
            ctx.setLineWidth(1.5)
        case .open:
            ctx.setLineWidth(1.5)
        case .dotted:
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [4, 4])
        case .thick:
            ctx.setLineWidth(3.0)
        case .invisible:
            ctx.restoreGState()
            return
        }

        // Draw the polyline.
        ctx.move(to: points[0])
        for i in 1 ..< points.count {
            ctx.addLine(to: points[i])
        }
        ctx.strokePath()

        // Draw arrowhead for arrow, dotted, and thick styles.
        if style == .arrow || style == .dotted || style == .thick {
            drawArrowhead(at: points[points.count - 1],
                          from: points[points.count - 2],
                          size: layout.fontSize * 0.6,
                          in: ctx,
                          color: layout.theme.foreground)
        }

        ctx.restoreGState()
    }

    private func drawArrowhead(
        at tip: CGPoint,
        from prev: CGPoint,
        size: CGFloat,
        in ctx: CGContext,
        color: CGColor
    ) {
        let angle = atan2(tip.y - prev.y, tip.x - prev.x)
        let spread: CGFloat = .pi / 6 // 30 degrees

        let left = CGPoint(
            x: tip.x - size * cos(angle - spread),
            y: tip.y - size * sin(angle - spread)
        )
        let right = CGPoint(
            x: tip.x - size * cos(angle + spread),
            y: tip.y - size * sin(angle + spread)
        )

        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.move(to: tip)
        ctx.addLine(to: left)
        ctx.addLine(to: right)
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }

    // MARK: - Edge labels

    private func drawEdgeLabel(
        _ text: String,
        path: GraphLayoutEdgePath,
        layout: FlowchartLayout,
        in ctx: CGContext,
        offset: CGPoint
    ) {
        guard path.points.count >= 2 else { return }

        // Place label at the midpoint of the edge path.
        let midIdx = path.points.count / 2
        let midPoint: CGPoint
        if path.points.count % 2 == 0 {
            let a = path.points[midIdx - 1]
            let b = path.points[midIdx]
            midPoint = CGPoint(x: (a.x + b.x) / 2 + offset.x,
                               y: (a.y + b.y) / 2 + offset.y)
        } else {
            let p = path.points[midIdx]
            midPoint = CGPoint(x: p.x + offset.x, y: p.y + offset.y)
        }

        let smallFontSize = layout.fontSize * 0.85
        let font = CTFontCreateWithName("Helvetica" as CFString, smallFontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: layout.theme.foreground,
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString)
        let bounds = CTLineGetBoundsWithOptions(line, [])

        // Draw background behind label for readability.
        let labelRect = CGRect(
            x: midPoint.x - bounds.width / 2 - 3,
            y: midPoint.y - bounds.height / 2 - 2,
            width: bounds.width + 6,
            height: bounds.height + 4
        )
        ctx.saveGState()
        ctx.setFillColor(layout.theme.background)
        ctx.fill(labelRect)

        // Draw text.
        drawCTLine(
            line,
            at: CGPoint(x: midPoint.x - bounds.width / 2, y: midPoint.y - bounds.height / 2),
            fontSize: layout.fontSize * 0.85,
            in: ctx
        )
        ctx.restoreGState()
    }

    // MARK: - CSS parsing helpers

    /// Parse a CSS hex color like `#f9f` or `#ff99ff` to CGColor.
    private func parseCSSColor(_ value: String?) -> CGColor? {
        guard let value, value.hasPrefix("#") else { return nil }
        let hex = String(value.dropFirst())
        let expanded: String
        if hex.count == 3 {
            expanded = hex.map { "\($0)\($0)" }.joined()
        } else if hex.count == 6 {
            expanded = hex
        } else {
            return nil
        }

        guard let val = UInt64(expanded, radix: 16) else { return nil }
        let r = CGFloat((val >> 16) & 0xFF) / 255.0
        let g = CGFloat((val >> 8) & 0xFF) / 255.0
        let b = CGFloat(val & 0xFF) / 255.0
        return CGColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    /// Parse stroke-width like "2px" or "2" to CGFloat.
    private func parseLineWidth(_ value: String?) -> CGFloat? {
        guard let value else { return nil }
        let numeric = value.replacingOccurrences(of: "px", with: "")
        return Double(numeric).map { CGFloat($0) }
    }

    /// Draw a CTLine at (x, y) in UIKit top-left coordinates.
    ///
    /// CTLineDraw expects standard CG coords (Y-up), but UIKit gives Y-down.
    /// This flips locally around the text position so text renders right-side-up.
    private func drawCTLine(_ line: CTLine, at point: CGPoint, fontSize: CGFloat, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y + fontSize)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
