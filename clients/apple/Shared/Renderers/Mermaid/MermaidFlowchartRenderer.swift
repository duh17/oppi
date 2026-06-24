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
        let edgeLabels: [String: String]       // edge key → label
        let edgeStyles: [String: FlowEdgeStyle] // edge key → style
        let edgeIds: [String: String]          // edge key → edge id
        let edgeKeys: [String]                 // edge path index → edge key
        let edgeStyleDirectives: [String: [String: String]] // edge key → css props
        let edgeEndpointSubgraphs: [String: FlowEdgeEndpointSubgraphs] // edge key → original subgraph endpoints
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

    struct FlowEdgeEndpointSubgraphs: Sendable {
        let from: String?
        let to: String?
    }

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

    nonisolated private func flowchart(from diagram: StateDiagram) -> FlowchartDiagram {
        let compositeIds = Set(diagram.composites.flatMap(stateCompositeIds(in:)))
        var nodes = diagram.states
            .filter { !compositeIds.contains($0.id) }
            .map { state in
                FlowNode(id: state.id, label: state.label, shape: flowShape(for: state.kind))
            }
        var edges: [FlowEdge] = []
        var styleDirectives: [FlowStyleDirective] = []
        var terminalIndex = 0
        var extraStateIdsByComposite: [String: [String]] = [:]

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

        func nodeId(for endpoint: StateEndpoint, isSource: Bool, scopeId: String?) -> String {
            switch endpoint {
            case .state(let id):
                return id
            case .terminal:
                terminalIndex += 1
                let id = isSource ? "__state_start_\(terminalIndex)" : "__state_end_\(terminalIndex)"
                nodes.append(FlowNode(id: id, label: "", shape: isSource ? .circle : .doubleCircle))
                if let scopeId {
                    extraStateIdsByComposite[scopeId, default: []].append(id)
                }
                return id
            }
        }

        for transition in diagram.transitions {
            edges.append(FlowEdge(
                from: nodeId(for: transition.from, isSource: true, scopeId: transition.scopeId),
                to: nodeId(for: transition.to, isSource: false, scopeId: transition.scopeId),
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

        var classApplications: [String: [String]] = [:]
        for state in diagram.states where !state.classes.isEmpty {
            classApplications[state.id] = state.classes
        }
        return FlowchartDiagram(
            direction: diagram.direction,
            nodes: nodes,
            edges: edges,
            subgraphs: diagram.composites.map {
                flowSubgraph(
                    from: $0,
                    extraStateIdsByComposite: extraStateIdsByComposite,
                    compositeIds: compositeIds
                )
            },
            classDefs: diagram.classDefs,
            styleDirectives: styleDirectives,
            classApplications: classApplications
        )
    }

    nonisolated private func flowShape(for kind: StateNodeKind) -> FlowNodeShape {
        switch kind {
        case .normal: return .rounded
        case .choice: return .diamond
        case .fork, .join: return .rectangle
        }
    }

    nonisolated private func flowSubgraph(
        from composite: StateComposite,
        extraStateIdsByComposite: [String: [String]],
        compositeIds: Set<String>
    ) -> FlowSubgraph {
        let nodeIds = (composite.stateIds + (extraStateIdsByComposite[composite.id] ?? []))
            .filter { !compositeIds.contains($0) }
        return FlowSubgraph(
            id: composite.id,
            title: composite.label,
            direction: composite.direction,
            nodeIds: nodeIds,
            regionCount: composite.regions.count,
            subgraphs: composite.children.map {
                flowSubgraph(
                    from: $0,
                    extraStateIdsByComposite: extraStateIdsByComposite,
                    compositeIds: compositeIds
                )
            }
        )
    }

    nonisolated private func stateCompositeIds(in composite: StateComposite) -> [String] {
        [composite.id] + composite.children.flatMap(stateCompositeIds(in:))
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
        let padding: CGFloat = flowchartOuterPadding
        let contentBounds = flowchartContentBounds(layout)
        return CGSize(
            width: contentBounds.width + padding * 2,
            height: contentBounds.height + padding * 2
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

        // Build edges. Mermaid allows edges to use subgraph IDs; the layout
        // engine only knows concrete nodes, so use a representative member node
        // as the layout anchor and draw the visible endpoint at the subgraph frame.
        let subgraphAnchors = makeSubgraphAnchors(flowchart.subgraphs, edges: flowchart.edges)
        let layoutEdgeSpecs = flowchart.edges.map { edge in
            resolvedLayoutEdgeSpec(edge, anchors: subgraphAnchors)
        }
        let layoutEdges = layoutEdgeSpecs.map { spec in
            GraphLayoutEdge(from: spec.from, to: spec.to)
        }

        // Map direction.
        let direction = graphLayoutDirection(for: flowchart.direction)

        let input = GraphLayoutInput(
            nodes: layoutNodes,
            edges: layoutEdges,
            direction: direction,
            nodeSpacing: fontSize * 3,
            rankSpacing: fontSize * 4
        )

        let initialGraphResult = SugiyamaLayout.layout(input)
        let graphResult = graphResultApplyingSubgraphDirections(
            initialGraphResult,
            flowchart: flowchart,
            layoutNodes: layoutNodes,
            layoutEdges: layoutEdges,
            direction: direction,
            fontSize: fontSize
        )

        // Build edge metadata maps keyed by concrete edge instances. Keep
        // base `from->to` aliases for existing single-edge callers/tests, but
        // drawing uses edgeKeys so parallel edges do not overwrite each other.
        var edgeLabels: [String: String] = [:]
        var edgeStyles: [String: FlowEdgeStyle] = [:]
        var edgeIds: [String: String] = [:]
        var edgeKeys: [String] = []
        var edgeEndpointSubgraphs: [String: FlowEdgeEndpointSubgraphs] = [:]
        let layoutNodeIds = Set(layoutNodes.map(\.id))
        for (index, pair) in zip(flowchart.edges, layoutEdgeSpecs).enumerated() {
            let (edge, spec) = pair
            let baseKey = "\(spec.from)->\(spec.to)"
            let key = uniqueEdgeKey(baseKey, index: index)
            if layoutNodeIds.contains(spec.from), layoutNodeIds.contains(spec.to) {
                edgeKeys.append(key)
            }
            if let label = edge.label {
                edgeLabels[key] = label
                edgeLabels[baseKey] = edgeLabels[baseKey] ?? label
            }
            edgeStyles[key] = edge.style
            edgeStyles[baseKey] = edgeStyles[baseKey] ?? edge.style
            if let id = edge.id {
                edgeIds[key] = id
                edgeIds[baseKey] = edgeIds[baseKey] ?? id
            }
            if spec.fromSubgraph != nil || spec.toSubgraph != nil {
                let endpoints = FlowEdgeEndpointSubgraphs(
                    from: spec.fromSubgraph,
                    to: spec.toSubgraph
                )
                edgeEndpointSubgraphs[key] = endpoints
                edgeEndpointSubgraphs[baseKey] = edgeEndpointSubgraphs[baseKey] ?? endpoints
            }
        }

        // Build style map. Mermaid classDef/class styles apply first;
        // explicit `style` directives override class properties.
        var styleMap: [String: [String: String]] = [:]
        for node in flowchart.nodes {
            var merged: [String: String] = [:]
            if let defaultClass = flowchart.classDefs["default"] {
                mergeStyle(defaultClass, into: &merged)
            }
            for className in flowchart.classApplications[node.id] ?? [] {
                if let classStyle = flowchart.classDefs[className] {
                    mergeStyle(classStyle, into: &merged)
                }
            }
            if !merged.isEmpty {
                styleMap[node.id] = merged
            }
        }
        var styleById: [String: [String: String]] = [:]
        for (id, classNames) in flowchart.classApplications {
            var merged: [String: String] = [:]
            if let defaultClass = flowchart.classDefs["default"] {
                mergeStyle(defaultClass, into: &merged)
            }
            for className in classNames {
                if let classStyle = flowchart.classDefs[className] {
                    mergeStyle(classStyle, into: &merged)
                }
            }
            if !merged.isEmpty {
                styleById[id] = merged
            }
        }
        for directive in flowchart.styleDirectives {
            var merged = styleById[directive.nodeId] ?? [:]
            mergeStyle(directive.properties, into: &merged)
            styleById[directive.nodeId] = merged
        }
        for node in flowchart.nodes {
            if let nodeStyle = styleById[node.id] {
                styleMap[node.id] = nodeStyle
            }
        }
        for subgraphId in flowchart.subgraphs.flatMap(allSubgraphIds(in:)) {
            if let subgraphStyle = styleById[subgraphId] {
                styleMap[subgraphId] = subgraphStyle
            }
        }

        var edgeStyleMap: [String: [String: String]] = [:]
        for (key, id) in edgeIds {
            if let edgeStyle = styleById[id] {
                edgeStyleMap[key] = edgeStyle
            }
        }

        return FlowchartLayout(
            graphResult: graphResult,
            flowchart: flowchart,
            nodeLabels: nodeLabels,
            nodeShapes: nodeShapes,
            edgeLabels: edgeLabels,
            edgeStyles: edgeStyles,
            edgeIds: edgeIds,
            edgeKeys: edgeKeys,
            edgeStyleDirectives: edgeStyleMap,
            edgeEndpointSubgraphs: edgeEndpointSubgraphs,
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

    private struct SubgraphAnchors {
        let sourceBySubgraphId: [String: String]
        let sinkBySubgraphId: [String: String]

        func anchor(for id: String, isSource: Bool) -> String? {
            if isSource {
                return sinkBySubgraphId[id] ?? sourceBySubgraphId[id]
            }
            return sourceBySubgraphId[id] ?? sinkBySubgraphId[id]
        }
    }

    private struct LayoutEdgeSpec {
        let from: String
        let to: String
        let fromSubgraph: String?
        let toSubgraph: String?
    }

    private func makeSubgraphAnchors(_ subgraphs: [FlowSubgraph], edges: [FlowEdge]) -> SubgraphAnchors {
        var sourceBySubgraphId: [String: String] = [:]
        var sinkBySubgraphId: [String: String] = [:]

        func collect(_ subgraph: FlowSubgraph) {
            let memberIds = Set(allNodeIds(in: subgraph))
            let sortedMembers = memberIds.sorted()
            if let fallback = sortedMembers.first {
                let incomingIds = Set(edges.filter { memberIds.contains($0.to) && memberIds.contains($0.from) }.map(\.to))
                let outgoingIds = Set(edges.filter { memberIds.contains($0.from) && memberIds.contains($0.to) }.map(\.from))
                sourceBySubgraphId[subgraph.id] = sortedMembers.first { !incomingIds.contains($0) } ?? fallback
                sinkBySubgraphId[subgraph.id] = sortedMembers.first { !outgoingIds.contains($0) } ?? fallback
            }
            for child in subgraph.subgraphs {
                collect(child)
            }
        }

        for subgraph in subgraphs {
            collect(subgraph)
        }

        return SubgraphAnchors(sourceBySubgraphId: sourceBySubgraphId, sinkBySubgraphId: sinkBySubgraphId)
    }

    private func resolvedLayoutEdgeSpec(_ edge: FlowEdge, anchors: SubgraphAnchors) -> LayoutEdgeSpec {
        let resolvedFrom = anchors.anchor(for: edge.from, isSource: true)
        let resolvedTo = anchors.anchor(for: edge.to, isSource: false)
        return LayoutEdgeSpec(
            from: resolvedFrom ?? edge.from,
            to: resolvedTo ?? edge.to,
            fromSubgraph: resolvedFrom == nil ? nil : edge.from,
            toSubgraph: resolvedTo == nil ? nil : edge.to
        )
    }

    private func uniqueEdgeKey(_ baseKey: String, index: Int) -> String {
        "\(baseKey)#\(index)"
    }

    private func allNodeIds(in subgraph: FlowSubgraph) -> [String] {
        subgraph.nodeIds + subgraph.subgraphs.flatMap(allNodeIds(in:))
    }

    private func allSubgraphIds(in subgraph: FlowSubgraph) -> [String] {
        [subgraph.id] + subgraph.subgraphs.flatMap(allSubgraphIds(in:))
    }

    private func graphLayoutDirection(for flowDirection: FlowDirection) -> GraphLayoutDirection {
        switch flowDirection {
        case .TB, .TD:
            return .topToBottom
        case .BT:
            return .bottomToTop
        case .LR:
            return .leftToRight
        case .RL:
            return .rightToLeft
        }
    }

    private func graphResultApplyingSubgraphDirections(
        _ graphResult: GraphLayoutResult,
        flowchart: FlowchartDiagram,
        layoutNodes: [GraphLayoutNode],
        layoutEdges: [GraphLayoutEdge],
        direction: GraphLayoutDirection,
        fontSize: CGFloat
    ) -> GraphLayoutResult {
        guard !flowchart.subgraphs.isEmpty else { return graphResult }
        var positions = graphResult.nodePositions
        let nodesById = Dictionary(uniqueKeysWithValues: layoutNodes.map { ($0.id, $0) })

        func apply(_ subgraph: FlowSubgraph) {
            if let localDirection = subgraph.direction,
               canApplySubgraphDirection(subgraph, flowchart: flowchart) {
                let memberIds = Set(allNodeIds(in: subgraph))
                let localNodes = memberIds.sorted().compactMap { nodesById[$0] }
                let localEdges = layoutEdges.filter { memberIds.contains($0.from) && memberIds.contains($0.to) }
                if localNodes.count > 1,
                   let currentBounds = bounds(for: memberIds, positions: positions) {
                    let localInput = GraphLayoutInput(
                        nodes: localNodes,
                        edges: localEdges,
                        direction: graphLayoutDirection(for: localDirection),
                        nodeSpacing: fontSize * 3,
                        rankSpacing: fontSize * 4
                    )
                    let localResult = SugiyamaLayout.layout(localInput)
                    let dx = currentBounds.midX - localResult.totalSize.width / 2
                    let dy = currentBounds.midY - localResult.totalSize.height / 2
                    for (id, rect) in localResult.nodePositions {
                        positions[id] = rect.offsetBy(dx: dx, dy: dy)
                    }
                }
            }

            for child in subgraph.subgraphs {
                apply(child)
            }
        }

        for subgraph in flowchart.subgraphs {
            apply(subgraph)
        }

        let normalizedPositions = positionsShiftedToPositive(positions)
        return GraphLayoutResult(
            nodePositions: normalizedPositions,
            edgePaths: routeEdges(layoutEdges, positions: normalizedPositions, direction: direction),
            totalSize: totalSize(for: normalizedPositions)
        )
    }

    private func canApplySubgraphDirection(_ subgraph: FlowSubgraph, flowchart: FlowchartDiagram) -> Bool {
        let memberIds = Set(allNodeIds(in: subgraph))
        guard memberIds.count > 1 else { return false }
        for edge in flowchart.edges {
            let fromIsMember = memberIds.contains(edge.from)
            let toIsMember = memberIds.contains(edge.to)
            if fromIsMember != toIsMember {
                return false
            }
        }
        return true
    }

    private func bounds(for ids: Set<String>, positions: [String: CGRect]) -> CGRect? {
        var result: CGRect?
        for id in ids {
            guard let rect = positions[id] else { continue }
            result = result.map { $0.union(rect) } ?? rect
        }
        return result
    }

    private func routeEdges(
        _ edges: [GraphLayoutEdge],
        positions: [String: CGRect],
        direction: GraphLayoutDirection
    ) -> [GraphLayoutEdgePath] {
        let isHorizontal = direction == .leftToRight || direction == .rightToLeft
        return edges.compactMap { edge in
            guard let fromRect = positions[edge.from], let toRect = positions[edge.to] else { return nil }
            let fromCenter = CGPoint(x: fromRect.midX, y: fromRect.midY)
            let toCenter = CGPoint(x: toRect.midX, y: toRect.midY)

            let fromPoint: CGPoint
            let toPoint: CGPoint
            if isHorizontal {
                if fromCenter.x < toCenter.x {
                    fromPoint = CGPoint(x: fromRect.maxX, y: fromRect.midY)
                    toPoint = CGPoint(x: toRect.minX, y: toRect.midY)
                } else {
                    fromPoint = CGPoint(x: fromRect.minX, y: fromRect.midY)
                    toPoint = CGPoint(x: toRect.maxX, y: toRect.midY)
                }
            } else if fromCenter.y < toCenter.y {
                fromPoint = CGPoint(x: fromRect.midX, y: fromRect.maxY)
                toPoint = CGPoint(x: toRect.midX, y: toRect.minY)
            } else {
                fromPoint = CGPoint(x: fromRect.midX, y: fromRect.minY)
                toPoint = CGPoint(x: toRect.midX, y: toRect.maxY)
            }

            var points = [fromPoint]
            let needsBend = isHorizontal
                ? abs(fromPoint.y - toPoint.y) > 1
                : abs(fromPoint.x - toPoint.x) > 1
            if needsBend {
                if isHorizontal {
                    let midRank = (fromPoint.x + toPoint.x) / 2
                    points.append(CGPoint(x: midRank, y: fromPoint.y))
                    points.append(CGPoint(x: midRank, y: toPoint.y))
                } else {
                    let midRank = (fromPoint.y + toPoint.y) / 2
                    points.append(CGPoint(x: fromPoint.x, y: midRank))
                    points.append(CGPoint(x: toPoint.x, y: midRank))
                }
            }
            points.append(toPoint)
            return GraphLayoutEdgePath(from: edge.from, to: edge.to, points: points)
        }
    }

    private func positionsShiftedToPositive(_ positions: [String: CGRect]) -> [String: CGRect] {
        guard let minX = positions.values.map(\.minX).min(),
              let minY = positions.values.map(\.minY).min()
        else { return positions }
        let dx = minX < 0 ? -minX : 0
        let dy = minY < 0 ? -minY : 0
        guard dx > 0 || dy > 0 else { return positions }
        return positions.mapValues { $0.offsetBy(dx: dx, dy: dy) }
    }

    private func totalSize(for positions: [String: CGRect]) -> CGSize {
        var maxX: CGFloat = 0
        var maxY: CGFloat = 0
        for rect in positions.values {
            maxX = max(maxX, rect.maxX)
            maxY = max(maxY, rect.maxY)
        }
        return CGSize(width: maxX, height: maxY)
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
            edgeIds: [:],
            edgeKeys: [],
            edgeStyleDirectives: [:],
            edgeEndpointSubgraphs: [:],
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
        let contentBounds = flowchartContentBounds(layout)
        let padding: CGFloat = flowchartOuterPadding
        let offset = CGPoint(
            x: origin.x + padding - contentBounds.minX,
            y: origin.y + padding - contentBounds.minY
        )

        // Draw subgraph/composite-state containers behind the graph content.
        for subgraph in layout.flowchart.subgraphs {
            drawSubgraph(subgraph, layout: layout, in: ctx, offset: offset)
        }

        // Draw edges first (behind nodes).
        for (index, edgePath) in layout.graphResult.edgePaths.enumerated() {
            let key = index < layout.edgeKeys.count
                ? layout.edgeKeys[index]
                : "\(edgePath.from)->\(edgePath.to)"
            let adjustedPath = edgePathAdjustedForSubgraphEndpoints(edgePath, key: key, layout: layout)
            let style = layout.edgeStyles[key] ?? .arrow
            let styleProperties = layout.edgeStyleDirectives[key] ?? [:]
            drawEdge(adjustedPath, style: style, styleProperties: styleProperties, layout: layout, in: ctx, offset: offset)

            // Edge label at midpoint.
            if let label = layout.edgeLabels[key] {
                drawEdgeLabel(label, path: adjustedPath, layout: layout, in: ctx, offset: offset)
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
        guard let rect = subgraphFrame(subgraph, layout: layout) else { return }
        let offsetRect = rect.offsetBy(dx: offset.x, dy: offset.y)
        let style = layout.styleDirectives[subgraph.id] ?? [:]

        ctx.saveGState()
        let fillColor = parseStyleColor(style["fill"], theme: layout.theme)
            ?? subgraphFillColor(theme: layout.theme)
        let strokeColor = parseStyleColor(style["stroke"], theme: layout.theme)
            ?? subgraphStrokeColor(theme: layout.theme)
        ctx.setFillColor(fillColor)
        ctx.setStrokeColor(strokeColor)
        ctx.setLineWidth(parseLineWidth(style["stroke-width"]) ?? 1)
        // Mermaid v11 flowchart clusters render as solid filled rectangles with
        // a top label. Keep subgraphs visually like clusters, not callout boxes.
        let path = CGPath(rect: offsetRect, transform: nil)
        ctx.addPath(path)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()

        if subgraph.regionCount > 0 {
            drawSubgraphRegions(count: subgraph.regionCount, in: offsetRect, layout: layout, ctx: ctx)
        }

        let title = subgraph.title ?? subgraph.id
        if !title.isEmpty {
            let titleColor = parseStyleColor(style["color"], theme: layout.theme) ?? layout.theme.foreground
            let titleFontSize = layout.fontSize * 0.85
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, titleFontSize, nil)
            let titleRect = CGRect(
                x: offsetRect.minX + 10,
                y: offsetRect.minY + 4,
                width: max(1, offsetRect.width - 20),
                height: max(layout.fontSize * 1.4, subgraphTitleHeight(fontSize: layout.fontSize) - 6)
            )
            MermaidTextUtils.drawText(
                title,
                centeredIn: titleRect,
                font: font,
                fontSize: titleFontSize,
                foregroundColor: titleColor,
                in: ctx
            )
        }

        for child in subgraph.subgraphs {
            drawSubgraph(child, layout: layout, in: ctx, offset: offset)
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

    private var flowchartOuterPadding: CGFloat { 20 }

    private func flowchartContentBounds(_ layout: FlowchartLayout) -> CGRect {
        guard !layout.graphResult.nodePositions.isEmpty else { return .zero }
        var bounds = CGRect(origin: .zero, size: layout.graphResult.totalSize)
        for subgraph in layout.flowchart.subgraphs {
            guard let frame = subgraphFrame(subgraph, layout: layout) else { continue }
            bounds = bounds.union(frame)
        }
        return bounds
    }

    private func subgraphContentRect(_ subgraph: FlowSubgraph, layout: FlowchartLayout) -> CGRect? {
        var rect: CGRect?
        for nodeId in subgraph.nodeIds {
            guard let nodeRect = layout.graphResult.nodePositions[nodeId] else { continue }
            rect = rect.map { $0.union(nodeRect) } ?? nodeRect
        }
        for child in subgraph.subgraphs {
            guard let childFrame = subgraphFrame(child, layout: layout) else { continue }
            rect = rect.map { $0.union(childFrame) } ?? childFrame
        }
        return rect
    }

    private func subgraphFrame(_ subgraph: FlowSubgraph, layout: FlowchartLayout) -> CGRect? {
        guard let contentRect = subgraphContentRect(subgraph, layout: layout) else { return nil }
        let horizontalPadding = subgraphHorizontalPadding(fontSize: layout.fontSize)
        let topPadding = subgraphTopPadding(fontSize: layout.fontSize)
        let bottomPadding = subgraphBottomPadding(fontSize: layout.fontSize)
        return CGRect(
            x: contentRect.minX - horizontalPadding,
            y: contentRect.minY - topPadding,
            width: contentRect.width + horizontalPadding * 2,
            height: contentRect.height + topPadding + bottomPadding
        )
    }

    private func subgraphHorizontalPadding(fontSize: CGFloat) -> CGFloat {
        max(24, fontSize * 2)
    }

    private func subgraphTopPadding(fontSize: CGFloat) -> CGFloat {
        max(28, subgraphTitleHeight(fontSize: fontSize) + fontSize * 0.5)
    }

    private func subgraphBottomPadding(fontSize: CGFloat) -> CGFloat {
        max(24, fontSize * 1.8)
    }

    private func subgraphTitleHeight(fontSize: CGFloat) -> CGFloat {
        max(22, fontSize * 1.7)
    }

    private func subgraphFillColor(theme: RenderTheme) -> CGColor {
        guard let background = sRGBComponents(theme.background) else {
            return theme.background
        }
        let luminance = relativeLuminance(
            red: background.red,
            green: background.green,
            blue: background.blue
        )
        let amount: CGFloat = luminance < 0.5 ? 0.18 : 0.06
        return blendColor(theme.foreground, over: theme.background, amount: amount) ?? theme.background
    }

    private func subgraphStrokeColor(theme: RenderTheme) -> CGColor {
        theme.foregroundDim.copy(alpha: 0.55) ?? theme.foregroundDim
    }

    private func edgePathAdjustedForSubgraphEndpoints(
        _ edgePath: GraphLayoutEdgePath,
        key: String,
        layout: FlowchartLayout
    ) -> GraphLayoutEdgePath {
        guard let endpoints = layout.edgeEndpointSubgraphs[key], edgePath.points.count >= 2 else {
            return edgePath
        }
        var points = edgePath.points
        if let fromSubgraph = endpoints.from,
           let frame = subgraphFrame(id: fromSubgraph, in: layout.flowchart.subgraphs, layout: layout) {
            points[0] = boundaryPoint(on: frame, toward: points[1])
        }
        if let toSubgraph = endpoints.to,
           let frame = subgraphFrame(id: toSubgraph, in: layout.flowchart.subgraphs, layout: layout) {
            points[points.count - 1] = boundaryPoint(on: frame, toward: points[points.count - 2])
        }
        return GraphLayoutEdgePath(from: edgePath.from, to: edgePath.to, points: points)
    }

    private func subgraphFrame(
        id: String,
        in subgraphs: [FlowSubgraph],
        layout: FlowchartLayout
    ) -> CGRect? {
        for subgraph in subgraphs {
            if subgraph.id == id {
                return subgraphFrame(subgraph, layout: layout)
            }
            if let frame = subgraphFrame(id: id, in: subgraph.subgraphs, layout: layout) {
                return frame
            }
        }
        return nil
    }

    private func boundaryPoint(on rect: CGRect, toward point: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = point.x - center.x
        let dy = point.y - center.y
        guard abs(dx) > 0.0001 || abs(dy) > 0.0001 else { return center }

        let xScale: CGFloat
        if abs(dx) < 0.0001 {
            xScale = .greatestFiniteMagnitude
        } else if dx > 0 {
            xScale = (rect.maxX - center.x) / dx
        } else {
            xScale = (rect.minX - center.x) / dx
        }

        let yScale: CGFloat
        if abs(dy) < 0.0001 {
            yScale = .greatestFiniteMagnitude
        } else if dy > 0 {
            yScale = (rect.maxY - center.y) / dy
        } else {
            yScale = (rect.minY - center.y) / dy
        }

        let scale = min(xScale, yScale)
        return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
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
        case .rectangle, .default, .dividedRectangle, .windowPane:
            path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        case .rounded:
            path = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        case .stadium, .delay:
            let radius = rect.height / 2
            path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .diamond:
            path = diamondPath(rect)
        case .hexagon:
            path = hexagonPath(rect)
        case .circle, .filledCircle:
            path = CGPath(ellipseIn: rect, transform: nil)
        case .cylindrical:
            path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        case .horizontalCylinder:
            path = CGPath(roundedRect: rect, cornerWidth: rect.height * 0.5, cornerHeight: rect.height * 0.5, transform: nil)
        case .linedCylinder:
            path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        case .subroutine:
            path = subroutinePath(rect)
        case .asymmetric, .odd:
            path = asymmetricPath(rect)
        case .parallelogram:
            path = parallelogramPath(rect)
        case .parallelogramAlt, .slopedRectangle:
            path = parallelogramAltPath(rect)
        case .trapezoid:
            path = trapezoidPath(rect)
        case .trapezoidAlt:
            path = trapezoidAltPath(rect)
        case .doubleCircle, .crossedCircle:
            path = CGPath(ellipseIn: rect, transform: nil)
        case .bang:
            path = bangPath(rect)
        case .notchedRectangle:
            path = notchedRectanglePath(rect)
        case .cloud:
            path = cloudPath(rect)
        case .hourglass, .bowTieRectangle:
            path = hourglassPath(rect)
        case .bolt:
            path = boltPath(rect)
        case .brace:
            path = bracePath(rect, rightSide: false)
        case .braceRight:
            path = bracePath(rect, rightSide: true)
        case .braces:
            path = bracesPath(rect)
        case .datastore:
            path = datastorePath(rect)
        case .curvedTrapezoid:
            path = curvedTrapezoidPath(rect)
        case .document:
            path = documentPath(rect)
        case .triangle:
            path = trianglePath(rect)
        case .forkJoin:
            path = CGPath(roundedRect: rect.insetBy(dx: 0, dy: rect.height * 0.32), cornerWidth: 2, cornerHeight: 2, transform: nil)
        case .linedDocument:
            path = documentPath(rect)
        case .notchedPentagon:
            path = notchedPentagonPath(rect)
        case .flippedTriangle:
            path = flippedTrianglePath(rect)
        case .stackedDocument:
            path = stackedDocumentPath(rect)
        case .stackedRectangle:
            path = stackedRectanglePath(rect)
        case .flag:
            path = flagPath(rect)
        case .taggedDocument:
            path = taggedDocumentPath(rect)
        case .taggedRectangle:
            path = taggedRectanglePath(rect)
        case .textBlock:
            path = CGMutablePath()
        }

        ctx.addPath(path)
        ctx.drawPath(using: .fillStroke)

        drawNodeShapeOverlays(shape, rect: rect, in: ctx)

        ctx.restoreGState()
    }

    private func drawNodeShapeOverlays(_ shape: FlowNodeShape, rect: CGRect, in ctx: CGContext) {
        switch shape {
        case .doubleCircle:
            ctx.addEllipse(in: rect.insetBy(dx: 4, dy: 4))
            ctx.strokePath()
        case .crossedCircle:
            ctx.move(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.28))
            ctx.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.28, y: rect.maxY - rect.height * 0.28))
            ctx.move(to: CGPoint(x: rect.maxX - rect.width * 0.28, y: rect.minY + rect.height * 0.28))
            ctx.addLine(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.maxY - rect.height * 0.28))
            ctx.strokePath()
        case .dividedRectangle:
            ctx.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.35))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.35))
            ctx.strokePath()
        case .windowPane:
            ctx.move(to: CGPoint(x: rect.midX, y: rect.minY))
            ctx.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            ctx.move(to: CGPoint(x: rect.minX, y: rect.midY))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            ctx.strokePath()
        case .datastore:
            ctx.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.2))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.2))
            ctx.move(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.2))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.2))
            ctx.strokePath()
        case .linedCylinder, .linedDocument:
            for fraction in [CGFloat(0.35), CGFloat(0.5), CGFloat(0.65)] {
                let y = rect.minY + rect.height * fraction
                ctx.move(to: CGPoint(x: rect.minX + rect.width * 0.18, y: y))
                ctx.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.18, y: y))
            }
            ctx.strokePath()
        default:
            break
        }
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

    private func bangPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let points = 10
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for index in 0 ..< points {
            let angle = CGFloat(index) * 2 * .pi / CGFloat(points) - .pi / 2
            let radius = index.isMultiple(of: 2) ? min(rect.width, rect.height) * 0.5 : min(rect.width, rect.height) * 0.32
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }

    private func notchedRectanglePath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let notch = min(rect.width, rect.height) * 0.18
        path.move(to: CGPoint(x: rect.minX + notch, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + notch))
        path.closeSubpath()
        return path
    }

    private func cloudPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.maxX - rect.width * 0.2, y: rect.maxY),
            control1: CGPoint(x: rect.minX, y: rect.maxY),
            control2: CGPoint(x: rect.maxX - rect.width * 0.1, y: rect.maxY)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX - rect.width * 0.15, y: rect.minY + rect.height * 0.35),
            control1: CGPoint(x: rect.maxX, y: rect.maxY),
            control2: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.45)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.18),
            control1: CGPoint(x: rect.maxX - rect.width * 0.2, y: rect.minY),
            control2: CGPoint(x: rect.minX + rect.width * 0.58, y: rect.minY)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.maxY),
            control1: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.15),
            control2: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }

    private func hourglassPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.midY))
        path.closeSubpath()
        return path
    }

    private func boltPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.58, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.52, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.18, y: rect.minY + rect.height * 0.38))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.55, y: rect.minY + rect.height * 0.38))
        path.closeSubpath()
        return path
    }

    private func bracePath(_ rect: CGRect, rightSide: Bool) -> CGPath {
        let path = CGMutablePath()
        let x = rightSide ? rect.maxX : rect.minX
        let direction: CGFloat = rightSide ? -1 : 1
        let w = rect.width * 0.18 * direction
        path.move(to: CGPoint(x: x + w, y: rect.minY))
        path.addCurve(to: CGPoint(x: x, y: rect.midY), control1: CGPoint(x: x, y: rect.minY), control2: CGPoint(x: x, y: rect.midY - rect.height * 0.18))
        path.addCurve(to: CGPoint(x: x + w, y: rect.maxY), control1: CGPoint(x: x, y: rect.midY + rect.height * 0.18), control2: CGPoint(x: x, y: rect.maxY))
        return path
    }

    private func bracesPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addPath(bracePath(rect, rightSide: false))
        path.addPath(bracePath(rect, rightSide: true))
        return path
    }

    private func datastorePath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addRect(rect)
        return path
    }

    private func curvedTrapezoidPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let skew = rect.width * 0.16
        path.move(to: CGPoint(x: rect.minX + skew, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.maxX - skew, y: rect.maxY), control1: CGPoint(x: rect.maxX - skew * 0.25, y: rect.midY), control2: CGPoint(x: rect.maxX - skew * 0.25, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.minX + skew, y: rect.minY), control1: CGPoint(x: rect.minX + skew * 0.25, y: rect.midY), control2: CGPoint(x: rect.minX + skew * 0.25, y: rect.midY))
        path.closeSubpath()
        return path
    }

    private func documentPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: rect.origin)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.15))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.05), control1: CGPoint(x: rect.maxX - rect.width * 0.3, y: rect.maxY), control2: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.maxY - rect.height * 0.2))
        path.closeSubpath()
        return path
    }

    private func trianglePath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    private func notchedPentagonPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let notch = rect.width * 0.16
        path.move(to: CGPoint(x: rect.minX + notch, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - notch, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - notch, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + notch, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }

    private func flippedTrianglePath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    private func stackedDocumentPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addRect(rect.offsetBy(dx: 6, dy: -6))
        path.addRect(rect.offsetBy(dx: 3, dy: -3))
        path.addPath(documentPath(rect))
        return path
    }

    private func stackedRectanglePath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addRect(rect.offsetBy(dx: 6, dy: -6))
        path.addRect(rect.offsetBy(dx: 3, dy: -3))
        path.addRect(rect)
        return path
    }

    private func flagPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: rect.origin)
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.maxY), control1: CGPoint(x: rect.maxX, y: rect.midY - rect.height * 0.2), control2: CGPoint(x: rect.maxX - rect.width * 0.24, y: rect.midY + rect.height * 0.2))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    private func taggedDocumentPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addPath(documentPath(rect))
        let tag = min(rect.width, rect.height) * 0.22
        path.addRect(CGRect(x: rect.maxX - tag, y: rect.minY, width: tag, height: tag))
        return path
    }

    private func taggedRectanglePath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addRect(rect)
        let tag = min(rect.width, rect.height) * 0.22
        path.addRect(CGRect(x: rect.maxX - tag, y: rect.minY, width: tag, height: tag))
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
        styleProperties: [String: String],
        layout: FlowchartLayout,
        in ctx: CGContext,
        offset: CGPoint
    ) {
        guard edgePath.points.count >= 2 else { return }

        let points = edgePath.points.map {
            CGPoint(x: $0.x + offset.x, y: $0.y + offset.y)
        }

        ctx.saveGState()
        let strokeColor = parseStyleColor(styleProperties["stroke"], theme: layout.theme)
            ?? layout.theme.foreground
        ctx.setStrokeColor(strokeColor)

        switch style {
        case .arrow, .circle, .cross, .biArrow, .biCircle, .biCross:
            ctx.setLineWidth(parseLineWidth(styleProperties["stroke-width"]) ?? 1.5)
        case .open:
            ctx.setLineWidth(parseLineWidth(styleProperties["stroke-width"]) ?? 1.5)
        case .dotted:
            ctx.setLineWidth(parseLineWidth(styleProperties["stroke-width"]) ?? 1.5)
            ctx.setLineDash(phase: 0, lengths: parseDashArray(styleProperties["stroke-dasharray"]) ?? [4, 4])
        case .thick:
            ctx.setLineWidth(parseLineWidth(styleProperties["stroke-width"]) ?? 3.0)
        case .invisible:
            ctx.restoreGState()
            return
        }
        if style != .dotted, let dashArray = parseDashArray(styleProperties["stroke-dasharray"]) {
            ctx.setLineDash(phase: 0, lengths: dashArray)
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
            || style == .circle || style == .biCircle {
            drawArrowhead(at: points[points.count - 1],
                          from: points[points.count - 2],
                          size: layout.fontSize * 0.6,
                          in: ctx,
                          color: strokeColor)
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

    private func mergeStyle(_ source: [String: String], into target: inout [String: String]) {
        for (key, value) in source {
            target[key] = value
        }
    }

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

    private struct SRGBComponents {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
    }

    private func sRGBComponents(_ color: CGColor) -> SRGBComponents? {
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

    private func blendColor(_ foreground: CGColor, over background: CGColor, amount: CGFloat) -> CGColor? {
        guard let foreground = sRGBComponents(foreground),
              let background = sRGBComponents(background)
        else { return nil }
        let clampedAmount = min(max(amount, 0), 1)
        let inverse = 1 - clampedAmount
        return CGColor(
            red: background.red * inverse + foreground.red * clampedAmount,
            green: background.green * inverse + foreground.green * clampedAmount,
            blue: background.blue * inverse + foreground.blue * clampedAmount,
            alpha: 1
        )
    }

    /// Parse stroke-width like "2px" or "2" to CGFloat.
    private func parseLineWidth(_ value: String?) -> CGFloat? {
        guard let value else { return nil }
        let numeric = value.replacingOccurrences(of: "px", with: "")
        return Double(numeric).map { CGFloat($0) }
    }

    private func parseDashArray(_ value: String?) -> [CGFloat]? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: #"\,"#, with: ",")
            .replacingOccurrences(of: ",", with: " ")
        let values = normalized
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .compactMap { value -> CGFloat? in
                guard let number = Double(value) else { return nil }
                return CGFloat(number)
            }
        return values.isEmpty ? nil : values
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
