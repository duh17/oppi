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
        /// Custom draw block for non-flowchart diagram types (sequence, gantt, mindmap).
        /// When set, `draw()` calls this instead of the flowchart drawing logic.
        let customDraw: (@Sendable (CGContext, CGPoint) -> Void)?
        /// Total size for custom-drawn diagrams.
        let customSize: CGSize?
    }

    typealias LayoutResult = FlowchartLayout

    nonisolated func layout(
        _ document: MermaidDiagram,
        configuration: RenderConfiguration
    ) -> FlowchartLayout {
        switch document {
        case .flowchart(let flowchart):
            return layoutFlowchart(flowchart, configuration: configuration)
        case .sequence(let diagram):
            return MermaidSequenceRenderer.layout(diagram, configuration: configuration)
        case .gantt(let diagram):
            return MermaidGanttRenderer.layout(diagram, configuration: configuration)
        case .mindmap(let diagram):
            return MermaidMindmapRenderer.layout(diagram, configuration: configuration)
        case .state(let diagram):
            return layoutFlowchart(flowchart(from: diagram), configuration: configuration)
        case .unsupported(let type):
            return placeholderLayout(
                text: "Unsupported diagram type: \(type)",
                configuration: configuration
            )
        }
    }

    private nonisolated func flowchart(from diagram: StateDiagram) -> FlowchartDiagram {
        var nodes = diagram.states.map { state in
            FlowNode(id: state.id, label: state.label, shape: flowShape(for: state.kind))
        }
        var edges: [FlowEdge] = []
        var styleDirectives: [FlowStyleDirective] = []
        var terminalIndex = 0

        for state in diagram.states {
            var merged: [String: String] = [:]
            for className in state.classes {
                for (key, value) in diagram.classDefs[className] ?? [:] {
                    merged[key] = value
                }
            }
            if !merged.isEmpty {
                styleDirectives.append(FlowStyleDirective(nodeId: state.id, properties: merged))
            }
        }

        func nodeId(for endpoint: StateEndpoint, isSource: Bool) -> String {
            switch endpoint {
            case .state(let id):
                return id
            case .terminal:
                terminalIndex += 1
                let id = isSource ? "__state_start_\(terminalIndex)" : "__state_end_\(terminalIndex)"
                nodes.append(FlowNode(id: id, label: "", shape: isSource ? .circle : .doubleCircle))
                return id
            }
        }

        for transition in diagram.transitions {
            edges.append(FlowEdge(
                from: nodeId(for: transition.from, isSource: true),
                to: nodeId(for: transition.to, isSource: false),
                label: transition.label,
                style: .arrow
            ))
        }

        for (index, note) in diagram.notes.enumerated() {
            let noteId = "__state_note_\(index)"
            nodes.append(FlowNode(id: noteId, label: note.text, shape: .rectangle))
            edges.append(FlowEdge(from: note.stateId, to: noteId, label: nil, style: .dotted))
            styleDirectives.append(FlowStyleDirective(
                nodeId: noteId,
                properties: ["fill": "theme.accentYellow", "stroke": "theme.accentOrange"]
            ))
        }

        return FlowchartDiagram(
            direction: diagram.direction,
            nodes: nodes,
            edges: edges,
            subgraphs: diagram.composites.map(flowSubgraph(from:)),
            classDefs: diagram.classDefs,
            styleDirectives: styleDirectives
        )
    }

    private nonisolated func flowShape(for kind: StateNodeKind) -> FlowNodeShape {
        switch kind {
        case .normal: return .rounded
        case .choice: return .diamond
        case .fork, .join: return .rectangle
        }
    }

    private nonisolated func flowSubgraph(from composite: StateComposite) -> FlowSubgraph {
        FlowSubgraph(
            id: composite.id,
            title: composite.label,
            direction: composite.direction,
            nodeIds: composite.stateIds,
            regionCount: composite.regions.count,
            subgraphs: composite.children.map(flowSubgraph(from:))
        )
    }

    nonisolated func draw(
        _ layout: FlowchartLayout,
        in ctx: CGContext,
        at origin: CGPoint
    ) {
        if let customDraw = layout.customDraw {
            customDraw(ctx, origin)
            return
        }
        if layout.isPlaceholder {
            drawPlaceholder(layout, in: ctx, at: origin)
            return
        }
        drawFlowchart(layout, in: ctx, at: origin)
    }

    nonisolated func boundingBox(_ layout: FlowchartLayout) -> CGSize {
        if let size = layout.customSize {
            return size
        }
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
            placeholderText: nil,
            customDraw: nil,
            customSize: nil
        )
    }

    // MARK: - Text measurement

    /// Measure text size using CoreText. Returns the natural size without padding.
    private func measureText(_ text: String, font: CTFont, fontSize: CGFloat) -> CGSize {
        MermaidTextUtils.measureText(text, font: font, fontSize: fontSize)
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

    func placeholderLayout(
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
            placeholderText: text,
            customDraw: nil,
            customSize: nil
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

        // Draw subgraph/composite-state containers behind the graph content.
        for subgraph in layout.flowchart.subgraphs {
            drawSubgraph(subgraph, layout: layout, in: ctx, offset: offset)
        }

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
            drawNodeLabel(label, in: offsetRect, style: styleProps, layout: layout, ctx: ctx)
        }
    }

    private func drawSubgraph(
        _ subgraph: FlowSubgraph,
        layout: FlowchartLayout,
        in ctx: CGContext,
        offset: CGPoint
    ) {
        for child in subgraph.subgraphs {
            drawSubgraph(child, layout: layout, in: ctx, offset: offset)
        }

        guard let rect = subgraphRect(subgraph, layout: layout)?.insetBy(dx: -20, dy: -28) else { return }
        let offsetRect = rect.offsetBy(dx: offset.x, dy: offset.y)

        ctx.saveGState()
        ctx.setFillColor(layout.theme.background.copy(alpha: 0.35) ?? layout.theme.background)
        ctx.setStrokeColor(layout.theme.foregroundDim)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        let path = CGPath(roundedRect: offsetRect, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.addPath(path)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()

        if subgraph.regionCount > 0 {
            drawSubgraphRegions(count: subgraph.regionCount, in: offsetRect, layout: layout, ctx: ctx)
        }

        let title = subgraph.title ?? subgraph.id
        if !title.isEmpty {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, layout.fontSize * 0.85, nil)
            let titleRect = CGRect(
                x: offsetRect.minX + 10,
                y: offsetRect.minY + 4,
                width: max(1, offsetRect.width - 20),
                height: layout.fontSize * 1.4
            )
            MermaidTextUtils.drawText(
                title,
                centeredIn: titleRect,
                font: font,
                fontSize: layout.fontSize * 0.85,
                foregroundColor: layout.theme.foregroundDim,
                in: ctx
            )
        }
    }

    private func drawSubgraphRegions(
        count: Int,
        in rect: CGRect,
        layout: FlowchartLayout,
        ctx: CGContext
    ) {
        guard count > 0 else { return }
        ctx.saveGState()
        ctx.setStrokeColor(layout.theme.foregroundDim)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 4])

        let contentTop = rect.minY + layout.fontSize * 2
        let availableHeight = max(1, rect.maxY - contentTop)
        for index in 1 ... count {
            let y = contentTop + availableHeight * CGFloat(index) / CGFloat(count + 1)
            ctx.move(to: CGPoint(x: rect.minX + 8, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX - 8, y: y))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func subgraphRect(_ subgraph: FlowSubgraph, layout: FlowchartLayout) -> CGRect? {
        var rect: CGRect?
        for nodeId in subgraph.nodeIds {
            guard let nodeRect = layout.graphResult.nodePositions[nodeId] else { continue }
            rect = rect.map { $0.union(nodeRect) } ?? nodeRect
        }
        for child in subgraph.subgraphs {
            guard let childRect = subgraphRect(child, layout: layout) else { continue }
            rect = rect.map { $0.union(childRect) } ?? childRect
        }
        return rect
    }

    // MARK: - Node shapes

    private func drawNodeShape(
        _ shape: FlowNodeShape,
        rect: CGRect,
        style: [String: String],
        layout: FlowchartLayout,
        in ctx: CGContext
    ) {
        let fillColor = parseStyleColor(style["fill"], theme: layout.theme) ?? layout.theme.background
        let strokeColor = parseStyleColor(style["stroke"], theme: layout.theme) ?? layout.theme.foreground
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
        case .parallelogram:
            path = parallelogramPath(rect)
        case .parallelogramAlt:
            path = parallelogramAltPath(rect)
        case .trapezoid:
            path = trapezoidPath(rect)
        case .trapezoidAlt:
            path = trapezoidAltPath(rect)
        case .doubleCircle:
            path = CGPath(ellipseIn: rect, transform: nil)
        }

        ctx.addPath(path)
        ctx.drawPath(using: .fillStroke)

        // Double circle: draw inner circle.
        if shape == .doubleCircle {
            let inset: CGFloat = 4
            let innerRect = rect.insetBy(dx: inset, dy: inset)
            let innerPath = CGPath(ellipseIn: innerRect, transform: nil)
            ctx.addPath(innerPath)
            ctx.strokePath()
        }

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
        MermaidTextUtils.hexagonPath(rect)
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

    private func parallelogramPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let skew = rect.width * 0.15
        path.move(to: CGPoint(x: rect.minX + skew, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - skew, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    private func parallelogramAltPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let skew = rect.width * 0.15
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - skew, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + skew, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    private func trapezoidPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let inset = rect.width * 0.15
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    private func trapezoidAltPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let inset = rect.width * 0.15
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    // MARK: - Node label

    private func drawNodeLabel(
        _ text: String,
        in rect: CGRect,
        style: [String: String],
        layout: FlowchartLayout,
        ctx: CGContext
    ) {
        let font = CTFontCreateWithName("Helvetica" as CFString, layout.fontSize, nil)
        let fillColor = parseStyleColor(style["fill"], theme: layout.theme) ?? layout.theme.background
        let foreground = contrastingTextColor(on: fillColor, theme: layout.theme)
        MermaidTextUtils.drawText(
            text,
            centeredIn: rect,
            font: font,
            fontSize: layout.fontSize,
            foregroundColor: foreground,
            in: ctx
        )
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
        case .arrow, .circle, .cross, .biArrow, .biCircle, .biCross:
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

        // Draw arrowhead for arrow, dotted, thick, and directional styles.
        if style == .arrow || style == .dotted || style == .thick
            || style == .biArrow || style == .cross || style == .biCross
            || style == .circle || style == .biCircle
        {
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
        let textSize = MermaidTextUtils.measureText(text, font: font, fontSize: smallFontSize)

        // Draw background behind label for readability.
        let labelRect = CGRect(
            x: midPoint.x - textSize.width / 2 - 3,
            y: midPoint.y - textSize.height / 2 - 2,
            width: textSize.width + 6,
            height: textSize.height + 4
        )
        ctx.saveGState()
        ctx.setFillColor(layout.theme.background)
        ctx.fill(labelRect)

        // Draw text.
        MermaidTextUtils.drawText(
            text,
            at: CGPoint(x: midPoint.x - textSize.width / 2, y: midPoint.y - textSize.height / 2),
            width: textSize.width,
            font: font,
            fontSize: smallFontSize,
            foregroundColor: layout.theme.foreground,
            alignment: .center,
            in: ctx
        )
        ctx.restoreGState()
    }

    // MARK: - CSS parsing helpers

    /// Parse Mermaid style colors. Hex colors are supported for Mermaid
    /// conformance; `theme.*` values are used by Oppi-owned synthetic nodes so
    /// generated diagram chrome stays aligned with the active app theme.
    private func parseStyleColor(_ value: String?, theme: RenderTheme) -> CGColor? {
        guard let value else { return nil }
        switch value {
        case "theme.foreground": return theme.foreground
        case "theme.foregroundDim": return theme.foregroundDim
        case "theme.background": return theme.background
        case "theme.backgroundDark": return theme.backgroundDark
        case "theme.accentBlue": return theme.accentBlue
        case "theme.accentCyan": return theme.accentCyan
        case "theme.accentGreen": return theme.accentGreen
        case "theme.accentOrange": return theme.accentOrange
        case "theme.accentPurple": return theme.accentPurple
        case "theme.accentRed": return theme.accentRed
        case "theme.accentYellow": return theme.accentYellow
        default: break
        }

        guard value.hasPrefix("#") else { return nil }
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

    private func contrastingTextColor(on fill: CGColor, theme: RenderTheme) -> CGColor {
        let candidates = [theme.foreground, theme.background, theme.backgroundDark]
        return candidates.max { lhs, rhs in
            contrastRatio(foreground: lhs, background: fill) < contrastRatio(foreground: rhs, background: fill)
        } ?? theme.foreground
    }

    private func contrastRatio(foreground: CGColor, background: CGColor) -> CGFloat {
        guard let fg = sRGBComponents(foreground), let bg = sRGBComponents(background) else { return 1 }
        let fgLuminance = relativeLuminance(red: fg.red, green: fg.green, blue: fg.blue)
        let bgLuminance = relativeLuminance(red: bg.red, green: bg.green, blue: bg.blue)
        let lighter = max(fgLuminance, bgLuminance)
        let darker = min(fgLuminance, bgLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        func linearized(_ component: CGFloat) -> CGFloat {
            component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearized(red) + 0.7152 * linearized(green) + 0.0722 * linearized(blue)
    }

    private func sRGBComponents(_ color: CGColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        let converted = color.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            intent: .defaultIntent,
            options: nil
        ) ?? color
        guard let components = converted.components else { return nil }
        if components.count >= 3 {
            return (components[0], components[1], components[2])
        }
        if components.count >= 1 {
            return (components[0], components[0], components[0])
        }
        return nil
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
