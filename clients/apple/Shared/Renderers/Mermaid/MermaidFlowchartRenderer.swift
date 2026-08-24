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
        /// Final cluster frames after compound layout. Top-level subgraphs are
        /// laid out as graph units so these frames never overlap sibling units.
        let subgraphFrames: [String: CGRect]
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
        case .pie(let diagram):
            return MermaidPieRenderer.layout(diagram, configuration: configuration)
        case .timeline(let diagram):
            return MermaidTimelineRenderer.layout(diagram, configuration: configuration)
        case .classDiagram(let diagram):
            return MermaidClassRenderer.layout(diagram, configuration: configuration)
        case .erDiagram(let diagram):
            return MermaidERRenderer.layout(diagram, configuration: configuration)
        case .xyChart(let diagram):
            return MermaidXYChartRenderer.layout(diagram, configuration: configuration)
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
            let textSize = measureText(
                node.label,
                font: font,
                fontSize: fontSize,
                isMarkdown: node.isMarkdown
            )
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

        let positionedGraphResult: GraphLayoutResult
        if flowchart.subgraphs.isEmpty {
            positionedGraphResult = SugiyamaLayout.layout(input)
        } else {
            // A flat node layout followed by drawing cluster bounds causes large
            // subgraphs to overlap each other and unrelated nodes. Mermaid's
            // compound layout treats clusters as first-class graph units. Do the
            // same here: lay out each cluster internally, then lay out the
            // top-level clusters and ungrouped nodes as a second graph.
            positionedGraphResult = compoundGraphResult(
                flowchart: flowchart,
                layoutNodes: layoutNodes,
                layoutEdges: layoutEdges,
                direction: direction,
                fontSize: fontSize,
                maxWidth: configuration.maxWidth
            )
        }
        let subgraphFrames = makeSubgraphFrameMap(
            flowchart.subgraphs,
            positions: positionedGraphResult.nodePositions,
            fontSize: fontSize
        )
        let routedEdgePaths = routeEdgesRespectingSubgraphDirections(
            layoutEdges,
            positions: positionedGraphResult.nodePositions,
            flowchart: flowchart,
            rootDirection: direction,
            subgraphFrames: subgraphFrames,
            fontSize: fontSize
        )
        let finalEdgePaths = zip(routedEdgePaths, layoutEdgeSpecs).map { path, spec in
            edgePathAdjustedForSubgraphEndpoints(
                path,
                spec: spec,
                subgraphFrames: subgraphFrames
            )
        }
        let graphResult = GraphLayoutResult(
            nodePositions: positionedGraphResult.nodePositions,
            edgePaths: finalEdgePaths,
            totalSize: positionedGraphResult.totalSize
        )

        // Build edge metadata maps keyed by concrete edge instances. Keep
        // base `from->to` aliases for existing single-edge callers/tests, but
        // drawing uses edgeKeys so parallel edges do not overwrite each other.
        var edgeLabels: [String: String] = [:]
        var edgeStyles: [String: FlowEdgeStyle] = [:]
        var edgeIds: [String: String] = [:]
        var edgeKeys: [String] = []
        var edgeEndpointSubgraphs: [String: FlowEdgeEndpointSubgraphs] = [:]
        for (index, pair) in zip(flowchart.edges, layoutEdgeSpecs).enumerated() {
            let (edge, spec) = pair
            let baseKey = "\(spec.from)->\(spec.to)"
            let key = uniqueEdgeKey(baseKey, index: index)
            edgeKeys.append(key)
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
            subgraphFrames: subgraphFrames,
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

    private func compoundGraphResult(
        flowchart: FlowchartDiagram,
        layoutNodes: [GraphLayoutNode],
        layoutEdges: [GraphLayoutEdge],
        direction: GraphLayoutDirection,
        fontSize: CGFloat,
        maxWidth: CGFloat,
        directionEligibilityFlowchart: FlowchartDiagram? = nil
    ) -> GraphLayoutResult {
        let eligibilityFlowchart = directionEligibilityFlowchart ?? flowchart
        let nodesById = Dictionary(uniqueKeysWithValues: layoutNodes.map { ($0.id, $0) })
        let topLevelSubgraphs = flowchart.subgraphs
        let unitPrefix = "__oppi_mermaid_subgraph_unit__"

        var ownerUnitByNodeId: [String: String] = [:]
        var subgraphByUnitId: [String: FlowSubgraph] = [:]
        var localResultByUnitId: [String: GraphLayoutResult] = [:]
        var localFrameByUnitId: [String: CGRect] = [:]
        var unitNodes: [GraphLayoutNode] = []

        for subgraph in topLevelSubgraphs {
            let memberIds = Set(allNodeIds(in: subgraph)).intersection(nodesById.keys)
            guard !memberIds.isEmpty else { continue }

            let unitId = unitPrefix + subgraph.id
            for nodeId in memberIds where ownerUnitByNodeId[nodeId] == nil {
                ownerUnitByNodeId[nodeId] = unitId
            }

            let localNodes = memberIds.sorted().compactMap { nodesById[$0] }
            let localEdges = layoutEdges.filter {
                memberIds.contains($0.from) && memberIds.contains($0.to)
            }
            let localDirection: GraphLayoutDirection
            if let requestedDirection = subgraph.direction,
               canApplySubgraphDirection(subgraph, flowchart: eligibilityFlowchart) {
                localDirection = graphLayoutDirection(for: requestedDirection)
            } else {
                localDirection = direction
            }
            let localResult: GraphLayoutResult
            if subgraph.subgraphs.isEmpty {
                localResult = layoutSubgraphContents(
                    nodes: localNodes,
                    edges: localEdges,
                    direction: localDirection,
                    nodeSpacing: fontSize * 3,
                    rankSpacing: fontSize * 4,
                    maxWidth: maxWidth
                )
            } else {
                let nestedIds = Set(subgraph.subgraphs.flatMap(allSubgraphIds(in:)))
                let localFlowchart = FlowchartDiagram(
                    direction: flowDirection(for: localDirection),
                    nodes: flowchart.nodes.filter { memberIds.contains($0.id) },
                    edges: flowchart.edges.filter {
                        (memberIds.contains($0.from) || nestedIds.contains($0.from))
                            && (memberIds.contains($0.to) || nestedIds.contains($0.to))
                    },
                    subgraphs: subgraph.subgraphs,
                    classDefs: flowchart.classDefs,
                    styleDirectives: flowchart.styleDirectives,
                    classApplications: flowchart.classApplications
                )
                localResult = compoundGraphResult(
                    flowchart: localFlowchart,
                    layoutNodes: localNodes,
                    layoutEdges: localEdges,
                    direction: localDirection,
                    fontSize: fontSize,
                    maxWidth: maxWidth,
                    directionEligibilityFlowchart: eligibilityFlowchart
                )
            }
            let localFrames = makeSubgraphFrameMap(
                [subgraph],
                positions: localResult.nodePositions,
                fontSize: fontSize
            )
            let localFrame = localFrames[subgraph.id]
                ?? CGRect(origin: .zero, size: localResult.totalSize)

            subgraphByUnitId[unitId] = subgraph
            localResultByUnitId[unitId] = localResult
            localFrameByUnitId[unitId] = localFrame
            unitNodes.append(GraphLayoutNode(id: unitId, size: localFrame.size))
        }

        for node in layoutNodes where ownerUnitByNodeId[node.id] == nil {
            ownerUnitByNodeId[node.id] = node.id
            unitNodes.append(node)
        }

        var seenUnitEdges: Set<String> = []
        var unitEdges: [GraphLayoutEdge] = []
        for edge in layoutEdges {
            guard let fromUnit = ownerUnitByNodeId[edge.from],
                  let toUnit = ownerUnitByNodeId[edge.to],
                  fromUnit != toUnit else { continue }
            let key = "\(fromUnit)->\(toUnit)"
            guard seenUnitEdges.insert(key).inserted else { continue }
            unitEdges.append(GraphLayoutEdge(from: fromUnit, to: toUnit))
        }

        let unitResult = SugiyamaLayout.layout(GraphLayoutInput(
            nodes: unitNodes,
            edges: unitEdges,
            direction: direction,
            nodeSpacing: fontSize * 4,
            rankSpacing: fontSize * 5
        ))

        var positions: [String: CGRect] = [:]
        for (unitId, unitRect) in unitResult.nodePositions {
            if subgraphByUnitId[unitId] != nil,
               let localResult = localResultByUnitId[unitId],
               let localFrame = localFrameByUnitId[unitId] {
                let dx = unitRect.minX - localFrame.minX
                let dy = unitRect.minY - localFrame.minY
                for (nodeId, rect) in localResult.nodePositions {
                    positions[nodeId] = rect.offsetBy(dx: dx, dy: dy)
                }
            } else if nodesById[unitId] != nil {
                positions[unitId] = unitRect
            }
        }

        return GraphLayoutResult(
            nodePositions: positions,
            edgePaths: routeEdgesRespectingSubgraphDirections(
                layoutEdges,
                positions: positions,
                flowchart: flowchart,
                rootDirection: direction
            ),
            totalSize: totalSize(for: positions)
        )
    }

    private func flowDirection(for direction: GraphLayoutDirection) -> FlowDirection {
        switch direction {
        case .topToBottom: return .TB
        case .bottomToTop: return .BT
        case .leftToRight: return .LR
        case .rightToLeft: return .RL
        }
    }

    private struct SubgraphRoutingContext {
        let memberIds: Set<String>
        let direction: GraphLayoutDirection
        let depth: Int
    }

    private func routeEdgesRespectingSubgraphDirections(
        _ edges: [GraphLayoutEdge],
        positions: [String: CGRect],
        flowchart: FlowchartDiagram,
        rootDirection: GraphLayoutDirection,
        subgraphFrames: [String: CGRect] = [:],
        fontSize: CGFloat = 13
    ) -> [GraphLayoutEdgePath] {
        var contexts: [SubgraphRoutingContext] = []

        func collect(
            _ subgraph: FlowSubgraph,
            inheritedDirection: GraphLayoutDirection,
            depth: Int
        ) {
            let effectiveDirection: GraphLayoutDirection
            if let requestedDirection = subgraph.direction,
               canApplySubgraphDirection(subgraph, flowchart: flowchart) {
                effectiveDirection = graphLayoutDirection(for: requestedDirection)
            } else {
                effectiveDirection = inheritedDirection
            }
            contexts.append(SubgraphRoutingContext(
                memberIds: Set(allNodeIds(in: subgraph)),
                direction: effectiveDirection,
                depth: depth
            ))
            for child in subgraph.subgraphs {
                collect(child, inheritedDirection: effectiveDirection, depth: depth + 1)
            }
        }

        for subgraph in flowchart.subgraphs {
            collect(subgraph, inheritedDirection: rootDirection, depth: 0)
        }
        contexts.sort { $0.depth > $1.depth }

        let clearance = max(5, fontSize * 0.45)
        let titleHeight = subgraphTitleHeight(fontSize: fontSize) + 4
        let nodeShapes = Dictionary(uniqueKeysWithValues: flowchart.nodes.map { ($0.id, $0.shape) })
        let nodeSubgraphs = nodeSubgraphMembership(flowchart.subgraphs)
        var occupiedSegments = RouteSegmentUsage()
        var routedPairCounts: [String: Int] = [:]
        var routed: [GraphLayoutEdgePath?] = Array(repeating: nil, count: edges.count)
        var acceptedLabelRects: [CGRect] = []
        var acceptedArrowRects: [CGRect] = []

        func titleObstacles(for edge: GraphLayoutEdge) -> [CGRect] {
            let skip = (nodeSubgraphs[edge.from] ?? []).symmetricDifference(nodeSubgraphs[edge.to] ?? [])
            return subgraphFrames.compactMap { id, frame in
                // Entry/exit edges may cross their own subgraph title instead of
                // taking a perimeter detour around the cluster chrome.
                if skip.contains(id) { return nil }
                return CGRect(
                    x: frame.minX,
                    y: frame.minY,
                    width: frame.width,
                    height: min(titleHeight, frame.height)
                ).insetBy(dx: -clearance, dy: 0)
            }
        }

        func nodeObstacles(for edge: GraphLayoutEdge) -> [CGRect] {
            positions.map { id, rect in
                if id == edge.from || id == edge.to {
                    return rect
                }
                return rect.insetBy(dx: -clearance, dy: -clearance)
            }
        }

        func decorationObstacles() -> [CGRect] {
            acceptedLabelRects
        }

        func labelPeers() -> [GraphLayoutEdgePath] {
            var peers: [GraphLayoutEdgePath] = []
            for (index, points) in sharedTrunks {
                peers.append(GraphLayoutEdgePath(
                    from: edges[index].from,
                    to: edges[index].to,
                    points: points
                ))
            }
            for path in routed.compactMap({ $0 }) where path.points.count >= 2 {
                if !peers.contains(where: {
                    $0.from == path.from && $0.to == path.to && $0.points == path.points
                }) {
                    peers.append(path)
                }
            }
            return peers
        }

        func rememberDecorations(path: GraphLayoutEdgePath, label: String?) {
            acceptedArrowRects.append(edgeArrowheadRect(path, fontSize: fontSize))
            if let label, let labelLayout = edgeLabelLayout(
                label,
                path: path,
                fontSize: fontSize,
                among: labelPeers()
            ) {
                acceptedLabelRects.append(labelLayout.rect)
            }
        }

        func direction(for edge: GraphLayoutEdge) -> GraphLayoutDirection {
            contexts.first {
                $0.memberIds.contains(edge.from) && $0.memberIds.contains(edge.to)
            }?.direction ?? rootDirection
        }

        let edgeDirections = edges.map(direction(for:))
        let edgeLabels = flowchart.edges.map(\.label)
        let sharedTrunks = makeSharedTrunkPaths(
            edges: edges,
            positions: positions,
            edgeDirections: edgeDirections,
            nodeShapes: nodeShapes,
            clearance: clearance,
            fontSize: fontSize
        )

        for (index, edge) in edges.enumerated() {
            guard let trunk = sharedTrunks[index],
                  positions[edge.from] != nil, positions[edge.to] != nil,
                  !pathIntersectsObstacles(
                    trunk,
                    obstacles: nodeObstacles(for: edge) + titleObstacles(for: edge)
                  )
            else { continue }
            let path = GraphLayoutEdgePath(from: edge.from, to: edge.to, points: trunk)
            let label = index < edgeLabels.count ? edgeLabels[index] : nil
            if sharedTrunkObscuresLabelOrArrowhead(
                path,
                label: label,
                fontSize: fontSize,
                nodeObstacles: nodeObstacles(for: edge),
                acceptedLabelRects: acceptedLabelRects,
                acceptedArrowRects: acceptedArrowRects,
                among: labelPeers()
            ) {
                continue
            }
            rememberDecorations(path: path, label: label)
            occupiedSegments.register(trunk)
            routed[index] = path
        }

        for (index, edge) in edges.enumerated() where routed[index] == nil {
            guard positions[edge.from] != nil, positions[edge.to] != nil else {
                routed[index] = GraphLayoutEdgePath(from: edge.from, to: edge.to, points: [])
                continue
            }
            let edgeDirection = direction(for: edge)
            guard let fallback = routeEdges(
                [edge],
                positions: positions,
                direction: edgeDirection,
                laneSeed: index,
                nodeShapes: nodeShapes,
                allEdges: edges
            ).first else {
                routed[index] = GraphLayoutEdgePath(from: edge.from, to: edge.to, points: [])
                continue
            }

            let label = index < edgeLabels.count ? edgeLabels[index] : nil
            let obstacles = nodeObstacles(for: edge) + titleObstacles(for: edge) + decorationObstacles()
            let pairKey = "\(edge.from)->\(edge.to)"
            let parallelOrdinal = routedPairCounts[pairKey, default: 0]
            routedPairCounts[pairKey] = parallelOrdinal + 1
            let usesOccupied = pathUsesOccupiedSegment(fallback.points, usage: occupiedSegments)
            let needsParallelLane = (parallelOrdinal > 0 && usesOccupied) || usesOccupied
            let needsReroute = pathIntersectsObstacles(fallback.points, obstacles: obstacles)
                || needsParallelLane
            let sharedPenaltyMultiplier: CGFloat = needsParallelLane ? 6 : 0.5
            let points: [CGPoint]
            if needsReroute {
                var routedPoints = obstacleAwareRoute(
                    from: fallback.points[0],
                    to: fallback.points[fallback.points.count - 1],
                    direction: edgeDirection,
                    obstacles: obstacles,
                    occupiedSegments: occupiedSegments,
                    clearance: clearance,
                    bendPenalty: fontSize * 1.5,
                    sharedPenaltyMultiplier: sharedPenaltyMultiplier,
                    avoidOccupiedSegments: needsParallelLane
                )
                if let candidate = routedPoints,
                   pathIntersectsObstacles(candidate, obstacles: obstacles) {
                    routedPoints = obstacleAwareRoute(
                        from: fallback.points[0],
                        to: fallback.points[fallback.points.count - 1],
                        direction: edgeDirection,
                        obstacles: obstacles,
                        occupiedSegments: occupiedSegments,
                        clearance: clearance,
                        bendPenalty: fontSize * 1.5,
                        sharedPenaltyMultiplier: sharedPenaltyMultiplier,
                        avoidOccupiedSegments: needsParallelLane,
                        considerAllObstacles: true
                    )
                }
                if let routedPoints,
                   !pathIntersectsObstacles(routedPoints, obstacles: obstacles) {
                    points = routedPoints
                } else if let perimeter = safePerimeterRoute(
                    from: fallback.points[0],
                    to: fallback.points[fallback.points.count - 1],
                    direction: edgeDirection,
                    obstacles: obstacles,
                    clearance: clearance,
                    laneOrdinal: parallelOrdinal
                ) {
                    points = perimeter
                } else {
                    // A missing edge is safer than knowingly drawing through
                    // unrelated content when both bounded routing lanes fail.
                    points = []
                }
            } else {
                points = fallback.points
            }

            if !points.isEmpty {
                rememberDecorations(
                    path: GraphLayoutEdgePath(from: edge.from, to: edge.to, points: points),
                    label: label
                )
                occupiedSegments.register(points)
            }
            routed[index] = GraphLayoutEdgePath(from: edge.from, to: edge.to, points: points)
        }

        return routed.enumerated().map { index, path in
            path ?? GraphLayoutEdgePath(from: edges[index].from, to: edges[index].to, points: [])
        }
    }

    private func nodeSubgraphMembership(_ subgraphs: [FlowSubgraph]) -> [String: Set<String>] {
        var membership: [String: Set<String>] = [:]
        func collect(_ subgraph: FlowSubgraph, ancestors: Set<String>) {
            let ids = ancestors.union([subgraph.id])
            for nodeId in allNodeIds(in: subgraph) {
                membership[nodeId, default: []].formUnion(ids)
            }
            for child in subgraph.subgraphs {
                collect(child, ancestors: ids)
            }
        }
        for subgraph in subgraphs {
            collect(subgraph, ancestors: [])
        }
        return membership
    }

    private func makeSharedTrunkPaths(
        edges: [GraphLayoutEdge],
        positions: [String: CGRect],
        edgeDirections: [GraphLayoutDirection],
        nodeShapes: [String: FlowNodeShape],
        clearance: CGFloat,
        fontSize: CGFloat
    ) -> [Int: [CGPoint]] {
        var assigned: [Int: [CGPoint]] = [:]
        let sharedStub = max(10, clearance * 2)
        // Unique stubs must fit label height plus arrowhead without reaching the bus.
        let uniqueStub = max(sharedStub, fontSize * 2.8, 38)
        let corridorThreshold = max(36, clearance * 6)

        func isHorizontal(_ direction: GraphLayoutDirection) -> Bool {
            direction == .leftToRight || direction == .rightToLeft
        }

        func directionKey(_ direction: GraphLayoutDirection) -> Int {
            switch direction {
            case .topToBottom: return 0
            case .bottomToTop: return 1
            case .leftToRight: return 2
            case .rightToLeft: return 3
            }
        }

        func sign(from: CGRect, to: CGRect, direction: GraphLayoutDirection) -> Int {
            if isHorizontal(direction) {
                return to.midX >= from.midX ? 1 : -1
            }
            return to.midY >= from.midY ? 1 : -1
        }

        func port(on rect: CGRect, asSource: Bool, sign: Int, direction: GraphLayoutDirection) -> CGPoint {
            if isHorizontal(direction) {
                let useMax = asSource ? sign > 0 : sign < 0
                return CGPoint(x: useMax ? rect.maxX : rect.minX, y: rect.midY)
            }
            let useMax = asSource ? sign > 0 : sign < 0
            return CGPoint(x: rect.midX, y: useMax ? rect.maxY : rect.minY)
        }

        func qualifies(_ count: Int, shape: FlowNodeShape?) -> Bool {
            if shape == .diamond { return count >= 3 }
            return count >= 2
        }

        func corridorCoord(_ rect: CGRect, direction: GraphLayoutDirection) -> CGFloat {
            isHorizontal(direction) ? rect.midX : rect.midY
        }

        func clusterByCorridor(_ indexes: [Int], coord: (Int) -> CGFloat) -> [[Int]] {
            let sorted = indexes.sorted { coord($0) < coord($1) }
            var groups: [[Int]] = []
            var current: [Int] = []
            var last: CGFloat?
            for index in sorted {
                let value = coord(index)
                if let last, value - last > corridorThreshold, !current.isEmpty {
                    groups.append(current)
                    current = [index]
                } else {
                    current.append(index)
                }
                last = value
            }
            if !current.isEmpty {
                groups.append(current)
            }
            return groups
        }

        func emit(
            indexes: [Int],
            direction: GraphLayoutDirection,
            groupSign: Int,
            startRect: CGRect,
            endRects: [CGRect],
            fanOut: Bool
        ) {
            let horizontal = isHorizontal(direction)
            let start = fanOut
                ? port(on: startRect, asSource: true, sign: groupSign, direction: direction)
                : port(on: startRect, asSource: true, sign: groupSign, direction: direction)
            let endSample = fanOut
                ? port(on: endRects[0], asSource: false, sign: groupSign, direction: direction)
                : port(on: startRect, asSource: false, sign: groupSign, direction: direction)
            let bus: CGFloat
            if horizontal {
                if fanOut {
                    let edgeX = groupSign > 0
                        ? (endRects.map(\.minX).min() ?? start.x) - uniqueStub
                        : (endRects.map(\.maxX).max() ?? start.x) + uniqueStub
                    let limit = groupSign > 0 ? start.x + sharedStub : start.x - sharedStub
                    bus = groupSign > 0 ? max(edgeX, limit) : min(edgeX, limit)
                } else {
                    bus = groupSign > 0 ? endSample.x - sharedStub : endSample.x + sharedStub
                }
            } else if fanOut {
                let edgeY = groupSign > 0
                    ? (endRects.map(\.minY).min() ?? start.y) - uniqueStub
                    : (endRects.map(\.maxY).max() ?? start.y) + uniqueStub
                let limit = groupSign > 0 ? start.y + sharedStub : start.y - sharedStub
                bus = groupSign > 0 ? max(edgeY, limit) : min(edgeY, limit)
            } else {
                bus = groupSign > 0 ? endSample.y - sharedStub : endSample.y + sharedStub
            }
            for index in indexes {
                guard assigned[index] == nil else { continue }
                let fromRect = positions[edges[index].from]
                let toRect = positions[edges[index].to]
                guard let fromRect, let toRect else { continue }
                let fromPort = port(on: fromRect, asSource: true, sign: groupSign, direction: direction)
                let toPort = port(on: toRect, asSource: false, sign: groupSign, direction: direction)
                if horizontal {
                    assigned[index] = simplifiedOrthogonalPath([
                        fromPort,
                        CGPoint(x: bus, y: fromPort.y),
                        CGPoint(x: bus, y: toPort.y),
                        toPort,
                    ])
                } else {
                    assigned[index] = simplifiedOrthogonalPath([
                        fromPort,
                        CGPoint(x: fromPort.x, y: bus),
                        CGPoint(x: toPort.x, y: bus),
                        toPort,
                    ])
                }
            }
        }

        func assignFanOut(from id: String, indexes: [Int]) {
            guard let fromRect = positions[id] else { return }
            var buckets: [String: [Int]] = [:]
            for index in indexes {
                guard index < edgeDirections.count, let toRect = positions[edges[index].to] else { continue }
                let direction = edgeDirections[index]
                let groupSign = sign(from: fromRect, to: toRect, direction: direction)
                buckets["\(directionKey(direction)):\(groupSign)", default: []].append(index)
            }
            for (_, group) in buckets {
                guard let first = group.first else { continue }
                let direction = edgeDirections[first]
                let groupSign = sign(
                    from: fromRect,
                    to: positions[edges[first].to] ?? fromRect,
                    direction: direction
                )
                for cluster in clusterByCorridor(group, coord: { corridorCoord(positions[edges[$0].to] ?? .zero, direction: direction) }) {
                    let distinctTo = Set(cluster.map { edges[$0].to })
                    guard qualifies(distinctTo.count, shape: nodeShapes[id]) else { continue }
                    let targets = distinctTo.compactMap { positions[$0] }
                    guard !targets.isEmpty else { continue }
                    emit(
                        indexes: cluster,
                        direction: direction,
                        groupSign: groupSign,
                        startRect: fromRect,
                        endRects: targets,
                        fanOut: true
                    )
                }
            }
        }

        func assignFanIn(to id: String, indexes: [Int]) {
            guard let toRect = positions[id] else { return }
            var buckets: [String: [Int]] = [:]
            for index in indexes {
                guard index < edgeDirections.count, let fromRect = positions[edges[index].from] else { continue }
                let direction = edgeDirections[index]
                let groupSign = sign(from: fromRect, to: toRect, direction: direction)
                buckets["\(directionKey(direction)):\(groupSign)", default: []].append(index)
            }
            for (_, group) in buckets {
                guard let first = group.first else { continue }
                let direction = edgeDirections[first]
                let groupSign = sign(
                    from: positions[edges[first].from] ?? toRect,
                    to: toRect,
                    direction: direction
                )
                for cluster in clusterByCorridor(group, coord: { corridorCoord(positions[edges[$0].from] ?? .zero, direction: direction) }) {
                    let distinctFrom = Set(cluster.map { edges[$0].from })
                    guard qualifies(distinctFrom.count, shape: nodeShapes[id]) else { continue }
                    let sources = distinctFrom.compactMap { positions[$0] }
                    guard !sources.isEmpty else { continue }
                    emit(
                        indexes: cluster,
                        direction: direction,
                        groupSign: groupSign,
                        startRect: toRect,
                        endRects: sources,
                        fanOut: false
                    )
                }
            }
        }

        var outgoing: [String: [Int]] = [:]
        var incoming: [String: [Int]] = [:]
        for (index, edge) in edges.enumerated() {
            outgoing[edge.from, default: []].append(index)
            incoming[edge.to, default: []].append(index)
        }
        for (id, indexes) in outgoing {
            assignFanOut(from: id, indexes: indexes)
        }
        for (id, indexes) in incoming {
            assignFanIn(to: id, indexes: indexes)
        }
        return assigned
    }

    private func edgeArrowheadRect(_ path: GraphLayoutEdgePath, fontSize: CGFloat) -> CGRect {
        let size = fontSize * 0.6
        let tip = path.points.last ?? .zero
        return CGRect(
            x: tip.x - size,
            y: tip.y - size,
            width: size * 2,
            height: size * 2
        )
    }

    private func sharedTrunkObscuresLabelOrArrowhead(
        _ path: GraphLayoutEdgePath,
        label: String?,
        fontSize: CGFloat,
        nodeObstacles: [CGRect],
        acceptedLabelRects: [CGRect],
        acceptedArrowRects: [CGRect],
        among others: [GraphLayoutEdgePath]
    ) -> Bool {
        // Later unlabeled routes still have to miss earlier labels and other
        // arrowhead envelopes; returning early let shared trunks paint through both.
        if pathIntersectsObstacles(path.points, obstacles: acceptedLabelRects) {
            return true
        }
        let tip = path.points.last ?? .zero
        let foreignArrows = acceptedArrowRects.filter {
            abs($0.midX - tip.x) > 0.6 || abs($0.midY - tip.y) > 0.6
        }
        if pathIntersectsObstacles(path.points, obstacles: foreignArrows) {
            return true
        }
        guard let label, let labelLayout = edgeLabelLayout(
            label,
            path: path,
            fontSize: fontSize,
            among: others
        ) else {
            return false
        }
        let arrowRect = edgeArrowheadRect(path, fontSize: fontSize)
        if labelLayout.rect.intersects(arrowRect.insetBy(dx: -1, dy: -1)) {
            return true
        }
        if acceptedLabelRects.contains(where: { $0.intersects(labelLayout.rect.insetBy(dx: 1, dy: 1)) }) {
            return true
        }
        if acceptedArrowRects.contains(where: { $0.intersects(labelLayout.rect.insetBy(dx: 1, dy: 1)) }) {
            return true
        }
        let padded = labelLayout.rect.insetBy(dx: 2, dy: 2)
        let start = path.points.first ?? .zero
        return nodeObstacles.contains { obstacle in
            if obstacle.contains(start) || obstacle.contains(tip) { return false }
            return obstacle.intersects(padded)
        }
    }

    private enum RouteAxis: Int, Hashable {
        case none
        case horizontal
        case vertical
    }

    private struct RouteSearchState: Hashable {
        let pointIndex: Int
        let axis: RouteAxis
    }

    private struct RouteQueueEntry {
        let state: RouteSearchState
        let cost: CGFloat
        let estimate: CGFloat
        let serial: Int
    }

    private struct RouteNeighbor {
        let x: Int
        let y: Int
        let axis: RouteAxis
    }

    private struct RouteSegmentUsage {
        private var counts: [RouteSegmentKey: Int] = [:]
        private var horizontalByY: [Int: [RouteSegmentKey]] = [:]
        private var verticalByX: [Int: [RouteSegmentKey]] = [:]

        mutating func register(_ points: [CGPoint]) {
            for (first, second) in zip(points, points.dropFirst()) {
                let key = RouteSegmentKey(first, second)
                if counts[key] == nil {
                    if key.y1 == key.y2 {
                        horizontalByY[key.y1, default: []].append(key)
                    } else if key.x1 == key.x2 {
                        verticalByX[key.x1, default: []].append(key)
                    }
                }
                counts[key, default: 0] += 1
            }
        }

        func usage(from first: CGPoint, to second: CGPoint) -> Int {
            let firstX = Int((first.x * 2).rounded())
            let firstY = Int((first.y * 2).rounded())
            let secondX = Int((second.x * 2).rounded())
            let secondY = Int((second.y * 2).rounded())
            if firstY == secondY {
                let minX = min(firstX, secondX)
                let maxX = max(firstX, secondX)
                return (horizontalByY[firstY] ?? []).reduce(into: 0) { total, key in
                    if minX < key.x2, maxX > key.x1 {
                        total += counts[key] ?? 0
                    }
                }
            }
            if firstX == secondX {
                let minY = min(firstY, secondY)
                let maxY = max(firstY, secondY)
                return (verticalByX[firstX] ?? []).reduce(into: 0) { total, key in
                    if minY < key.y2, maxY > key.y1 {
                        total += counts[key] ?? 0
                    }
                }
            }
            return 0
        }
    }

    private struct RouteSegmentKey: Hashable {
        let x1: Int
        let y1: Int
        let x2: Int
        let y2: Int

        init(_ first: CGPoint, _ second: CGPoint) {
            let firstX = Int((first.x * 2).rounded())
            let firstY = Int((first.y * 2).rounded())
            let secondX = Int((second.x * 2).rounded())
            let secondY = Int((second.y * 2).rounded())
            if firstX < secondX || (firstX == secondX && firstY <= secondY) {
                x1 = firstX
                y1 = firstY
                x2 = secondX
                y2 = secondY
            } else {
                x1 = secondX
                y1 = secondY
                x2 = firstX
                y2 = firstY
            }
        }
    }

    private func obstacleAwareRoute(
        from start: CGPoint,
        to end: CGPoint,
        direction: GraphLayoutDirection,
        obstacles: [CGRect],
        occupiedSegments: RouteSegmentUsage,
        clearance: CGFloat,
        bendPenalty: CGFloat,
        sharedPenaltyMultiplier: CGFloat,
        avoidOccupiedSegments: Bool,
        considerAllObstacles: Bool = false
    ) -> [CGPoint]? {
        let (routeStart, routeEnd) = routePortStubs(
            from: start,
            to: end,
            direction: direction,
            distance: clearance
        )
        let relevantBounds = CGRect(
            x: min(routeStart.x, routeEnd.x),
            y: min(routeStart.y, routeEnd.y),
            width: abs(routeEnd.x - routeStart.x),
            height: abs(routeEnd.y - routeStart.y)
        ).insetBy(dx: -clearance * 12, dy: -clearance * 12)
        let relevantObstacles = considerAllObstacles
            ? obstacles
            : obstacles.filter { $0.intersects(relevantBounds) }

        var xCoordinates = [routeStart.x, routeEnd.x]
        var yCoordinates = [routeStart.y, routeEnd.y]
        for obstacle in relevantObstacles {
            xCoordinates.append(contentsOf: [obstacle.minX, obstacle.maxX])
            yCoordinates.append(contentsOf: [obstacle.minY, obstacle.maxY])
        }
        if let obstacleBounds = relevantObstacles.reduce(nil as CGRect?, { partial, rect in
            partial.map { $0.union(rect) } ?? rect
        }) {
            xCoordinates.append(contentsOf: [
                obstacleBounds.minX - clearance * 2,
                obstacleBounds.maxX + clearance * 2,
            ])
            yCoordinates.append(contentsOf: [
                obstacleBounds.minY - clearance * 2,
                obstacleBounds.maxY + clearance * 2,
            ])
        }

        let isHorizontal = direction == .leftToRight || direction == .rightToLeft
        if isHorizontal {
            yCoordinates.append(contentsOf: [
                routeStart.y - clearance * 2,
                routeStart.y + clearance * 2,
                routeEnd.y - clearance * 2,
                routeEnd.y + clearance * 2,
            ])
        } else {
            xCoordinates.append(contentsOf: [
                routeStart.x - clearance * 2,
                routeStart.x + clearance * 2,
                routeEnd.x - clearance * 2,
                routeEnd.x + clearance * 2,
            ])
        }

        let xs = normalizedRouteCoordinates(xCoordinates)
        let ys = normalizedRouteCoordinates(yCoordinates)
        guard xs.count >= 2, ys.count >= 2, xs.count * ys.count <= 6_400,
              let startX = xs.firstIndex(of: routeStart.x),
              let startY = ys.firstIndex(of: routeStart.y),
              let endX = xs.firstIndex(of: routeEnd.x),
              let endY = ys.firstIndex(of: routeEnd.y)
        else { return nil }

        let pointCount = xs.count * ys.count
        func pointIndex(x: Int, y: Int) -> Int { y * xs.count + x }
        func gridPoint(_ index: Int) -> CGPoint {
            CGPoint(x: xs[index % xs.count], y: ys[index / xs.count])
        }
        func isBlocked(_ point: CGPoint) -> Bool {
            relevantObstacles.contains { obstacleContainsInteriorPoint($0, point: point) }
        }

        var available = Array(repeating: true, count: pointCount)
        for index in 0..<pointCount {
            let point = gridPoint(index)
            available[index] = !isBlocked(point) || point == routeStart || point == routeEnd
        }

        let startIndex = pointIndex(x: startX, y: startY)
        let endIndex = pointIndex(x: endX, y: endY)
        let startState = RouteSearchState(pointIndex: startIndex, axis: .none)
        var distances: [RouteSearchState: CGFloat] = [startState: 0]
        var previous: [RouteSearchState: RouteSearchState] = [:]
        var queue: [RouteQueueEntry] = []
        var serial = 0

        func heuristic(_ point: CGPoint) -> CGFloat {
            abs(point.x - routeEnd.x) + abs(point.y - routeEnd.y)
        }
        pushRouteQueue(
            RouteQueueEntry(state: startState, cost: 0, estimate: heuristic(routeStart), serial: serial),
            into: &queue
        )

        var finalState: RouteSearchState?
        while let entry = popRouteQueue(from: &queue) {
            guard entry.cost <= (distances[entry.state] ?? .greatestFiniteMagnitude) else { continue }
            if entry.state.pointIndex == endIndex {
                finalState = entry.state
                break
            }

            let currentIndex = entry.state.pointIndex
            let xIndex = currentIndex % xs.count
            let yIndex = currentIndex / xs.count
            let candidates = [
                RouteNeighbor(x: xIndex - 1, y: yIndex, axis: .horizontal),
                RouteNeighbor(x: xIndex + 1, y: yIndex, axis: .horizontal),
                RouteNeighbor(x: xIndex, y: yIndex - 1, axis: .vertical),
                RouteNeighbor(x: xIndex, y: yIndex + 1, axis: .vertical),
            ]
            for candidate in candidates {
                let nextX = candidate.x
                let nextY = candidate.y
                let axis = candidate.axis
                guard nextX >= 0, nextX < xs.count, nextY >= 0, nextY < ys.count else { continue }
                let nextIndex = pointIndex(x: nextX, y: nextY)
                guard available[nextIndex] else { continue }
                let currentPoint = gridPoint(currentIndex)
                let nextPoint = gridPoint(nextIndex)
                guard !segmentIntersectsObstacles(currentPoint, nextPoint, obstacles: relevantObstacles) else {
                    continue
                }
                let occupiedUsage = occupiedSegments.usage(from: currentPoint, to: nextPoint)
                if avoidOccupiedSegments, occupiedUsage > 0 { continue }

                let segmentLength = abs(nextPoint.x - currentPoint.x) + abs(nextPoint.y - currentPoint.y)
                let bendCost = entry.state.axis == .none || entry.state.axis == axis ? 0 : bendPenalty
                let sharedCost = CGFloat(occupiedUsage) * bendPenalty * sharedPenaltyMultiplier
                let nextCost = entry.cost + segmentLength + bendCost + sharedCost
                let nextState = RouteSearchState(pointIndex: nextIndex, axis: axis)
                guard nextCost + 0.001 < (distances[nextState] ?? .greatestFiniteMagnitude) else { continue }

                distances[nextState] = nextCost
                previous[nextState] = entry.state
                serial += 1
                pushRouteQueue(
                    RouteQueueEntry(
                        state: nextState,
                        cost: nextCost,
                        estimate: nextCost + heuristic(nextPoint),
                        serial: serial
                    ),
                    into: &queue
                )
            }
        }

        guard var state = finalState else { return nil }
        var reversedPoints = [gridPoint(state.pointIndex)]
        while let predecessor = previous[state] {
            state = predecessor
            reversedPoints.append(gridPoint(state.pointIndex))
        }
        let gridPath = simplifiedOrthogonalPath(reversedPoints.reversed())
        return simplifiedOrthogonalPath([start] + gridPath + [end])
    }

    private func routePortStubs(
        from start: CGPoint,
        to end: CGPoint,
        direction: GraphLayoutDirection,
        distance: CGFloat
    ) -> (CGPoint, CGPoint) {
        switch direction {
        case .topToBottom, .bottomToTop:
            let sign: CGFloat = end.y >= start.y ? 1 : -1
            return (
                CGPoint(x: start.x, y: start.y + sign * distance),
                CGPoint(x: end.x, y: end.y - sign * distance)
            )
        case .leftToRight, .rightToLeft:
            let sign: CGFloat = end.x >= start.x ? 1 : -1
            return (
                CGPoint(x: start.x + sign * distance, y: start.y),
                CGPoint(x: end.x - sign * distance, y: end.y)
            )
        }
    }

    private func safePerimeterRoute(
        from start: CGPoint,
        to end: CGPoint,
        direction: GraphLayoutDirection,
        obstacles: [CGRect],
        clearance: CGFloat,
        laneOrdinal: Int
    ) -> [CGPoint]? {
        let (startStub, endStub) = routePortStubs(
            from: start,
            to: end,
            direction: direction,
            distance: clearance
        )
        let obstacleBounds = obstacles.reduce(nil as CGRect?) { partial, rect in
            partial.map { $0.union(rect) } ?? rect
        } ?? CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        let laneOffset = CGFloat(laneOrdinal) * clearance * 2
        let isHorizontal = direction == .leftToRight || direction == .rightToLeft
        let candidates: [[CGPoint]]
        if isHorizontal {
            let top = obstacleBounds.minY - clearance * 2 - laneOffset
            let bottom = obstacleBounds.maxY + clearance * 2 + laneOffset
            candidates = [top, bottom].map { corridorY in
                simplifiedOrthogonalPath([
                    start,
                    startStub,
                    CGPoint(x: startStub.x, y: corridorY),
                    CGPoint(x: endStub.x, y: corridorY),
                    endStub,
                    end,
                ])
            }
        } else {
            let left = obstacleBounds.minX - clearance * 2 - laneOffset
            let right = obstacleBounds.maxX + clearance * 2 + laneOffset
            candidates = [left, right].map { corridorX in
                simplifiedOrthogonalPath([
                    start,
                    startStub,
                    CGPoint(x: corridorX, y: startStub.y),
                    CGPoint(x: corridorX, y: endStub.y),
                    endStub,
                    end,
                ])
            }
        }

        return candidates
            .filter { !pathIntersectsObstacles($0, obstacles: obstacles) }
            .min { routeLength($0) < routeLength($1) }
    }

    private func routeLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) {
            $0 + abs($1.0.x - $1.1.x) + abs($1.0.y - $1.1.y)
        }
    }

    private func normalizedRouteCoordinates(_ values: [CGFloat]) -> [CGFloat] {
        Array(Set(values).sorted())
    }

    private func obstacleContainsInteriorPoint(_ obstacle: CGRect, point: CGPoint) -> Bool {
        let epsilon: CGFloat = 0.1
        return point.x > obstacle.minX + epsilon
            && point.x < obstacle.maxX - epsilon
            && point.y > obstacle.minY + epsilon
            && point.y < obstacle.maxY - epsilon
    }

    private func segmentIntersectsObstacles(
        _ first: CGPoint,
        _ second: CGPoint,
        obstacles: [CGRect]
    ) -> Bool {
        let epsilon: CGFloat = 0.1
        if abs(first.y - second.y) < epsilon {
            let minX = min(first.x, second.x)
            let maxX = max(first.x, second.x)
            return obstacles.contains {
                first.y > $0.minY + epsilon && first.y < $0.maxY - epsilon
                    && maxX > $0.minX + epsilon && minX < $0.maxX - epsilon
            }
        }
        if abs(first.x - second.x) < epsilon {
            let minY = min(first.y, second.y)
            let maxY = max(first.y, second.y)
            return obstacles.contains {
                first.x > $0.minX + epsilon && first.x < $0.maxX - epsilon
                    && maxY > $0.minY + epsilon && minY < $0.maxY - epsilon
            }
        }
        let dx = second.x - first.x
        let dy = second.y - first.y
        let steps = max(4, Int(hypot(dx, dy) / 2))
        return obstacles.contains { obstacle in
            for step in 1..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                let point = CGPoint(x: first.x + dx * t, y: first.y + dy * t)
                if obstacleContainsInteriorPoint(obstacle, point: point) {
                    return true
                }
            }
            return false
        }
    }

    private func pathIntersectsObstacles(_ points: [CGPoint], obstacles: [CGRect]) -> Bool {
        zip(points, points.dropFirst()).contains {
            segmentIntersectsObstacles($0.0, $0.1, obstacles: obstacles)
        }
    }

    private func isAxisAligned(_ first: CGPoint, _ second: CGPoint) -> Bool {
        abs(first.x - second.x) < 0.1 || abs(first.y - second.y) < 0.1
    }

    private func pathUsesOccupiedSegment(
        _ points: [CGPoint],
        usage: RouteSegmentUsage
    ) -> Bool {
        zip(points, points.dropFirst()).contains {
            usage.usage(from: $0.0, to: $0.1) > 0
        }
    }

    private func simplifiedOrthogonalPath<S: Sequence>(_ points: S) -> [CGPoint]
    where S.Element == CGPoint {
        var result: [CGPoint] = []
        for point in points {
            if result.count >= 2 {
                let first = result[result.count - 2]
                let second = result[result.count - 1]
                let isVertical = abs(first.x - second.x) < 0.1 && abs(second.x - point.x) < 0.1
                let isHorizontal = abs(first.y - second.y) < 0.1 && abs(second.y - point.y) < 0.1
                if isVertical || isHorizontal {
                    result[result.count - 1] = point
                    continue
                }
            }
            if result.last != point {
                result.append(point)
            }
        }
        return result
    }

    private func pushRouteQueue(_ entry: RouteQueueEntry, into queue: inout [RouteQueueEntry]) {
        queue.append(entry)
        var index = queue.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard routeQueueEntry(entry, sortsBefore: queue[parent]) else { break }
            queue[index] = queue[parent]
            index = parent
        }
        queue[index] = entry
    }

    private func popRouteQueue(from queue: inout [RouteQueueEntry]) -> RouteQueueEntry? {
        guard let first = queue.first else { return nil }
        let last = queue.removeLast()
        guard !queue.isEmpty else { return first }

        var index = 0
        while true {
            let left = index * 2 + 1
            guard left < queue.count else { break }
            let right = left + 1
            let child = right < queue.count && routeQueueEntry(queue[right], sortsBefore: queue[left])
                ? right
                : left
            guard routeQueueEntry(queue[child], sortsBefore: last) else { break }
            queue[index] = queue[child]
            index = child
        }
        queue[index] = last
        return first
    }

    private func routeQueueEntry(_ lhs: RouteQueueEntry, sortsBefore rhs: RouteQueueEntry) -> Bool {
        if abs(lhs.estimate - rhs.estimate) > 0.001 {
            return lhs.estimate < rhs.estimate
        }
        return lhs.serial < rhs.serial
    }

    private func layoutSubgraphContents(
        nodes: [GraphLayoutNode],
        edges: [GraphLayoutEdge],
        direction: GraphLayoutDirection,
        nodeSpacing: CGFloat,
        rankSpacing: CGFloat,
        maxWidth: CGFloat
    ) -> GraphLayoutResult {
        let input = GraphLayoutInput(
            nodes: nodes,
            edges: edges,
            direction: direction,
            nodeSpacing: nodeSpacing,
            rankSpacing: rankSpacing
        )
        guard direction == .topToBottom || direction == .bottomToTop else {
            return SugiyamaLayout.layout(input)
        }

        var neighbors = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, Set<String>()) })
        for edge in edges {
            neighbors[edge.from, default: []].insert(edge.to)
            neighbors[edge.to, default: []].insert(edge.from)
        }

        var visited: Set<String> = []
        var components: [[String]] = []
        for node in nodes where visited.insert(node.id).inserted {
            var component = [node.id]
            var head = 0
            while head < component.count {
                let current = component[head]
                head += 1
                for neighbor in (neighbors[current] ?? []).sorted()
                    where visited.insert(neighbor).inserted {
                    component.append(neighbor)
                }
            }
            components.append(component)
        }

        // One or two components remain compact on one rank. Larger groups are
        // shelf-packed to the document width instead of becoming a single very
        // wide row that is illegible when fit to an iPhone viewport.
        guard components.count > 2 else {
            return SugiyamaLayout.layout(input)
        }

        let nodesById = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let targetWidth = max(
            nodes.map(\.size.width).max() ?? 1,
            maxWidth - subgraphHorizontalPadding(fontSize: nodeSpacing / 3) * 2
        )
        var positions: [String: CGRect] = [:]
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var rowHeight: CGFloat = 0

        for component in components {
            let ids = Set(component)
            let componentNodes = component.compactMap { nodesById[$0] }
            let componentEdges = edges.filter { ids.contains($0.from) && ids.contains($0.to) }
            let result = SugiyamaLayout.layout(GraphLayoutInput(
                nodes: componentNodes,
                edges: componentEdges,
                direction: direction,
                nodeSpacing: nodeSpacing,
                rankSpacing: rankSpacing
            ))
            let size = result.totalSize

            if cursorX > 0, cursorX + size.width > targetWidth {
                cursorX = 0
                cursorY += rowHeight + rankSpacing
                rowHeight = 0
            }
            for (nodeId, rect) in result.nodePositions {
                positions[nodeId] = rect.offsetBy(dx: cursorX, dy: cursorY)
            }
            cursorX += size.width + nodeSpacing
            rowHeight = max(rowHeight, size.height)
        }

        return GraphLayoutResult(
            nodePositions: positions,
            edgePaths: routeEdges(edges, positions: positions, direction: direction),
            totalSize: totalSize(for: positions)
        )
    }

    private func makeSubgraphFrameMap(
        _ subgraphs: [FlowSubgraph],
        positions: [String: CGRect],
        fontSize: CGFloat
    ) -> [String: CGRect] {
        var frames: [String: CGRect] = [:]

        func collect(_ subgraph: FlowSubgraph) -> CGRect? {
            var contentRect: CGRect?
            for nodeId in subgraph.nodeIds {
                guard let nodeRect = positions[nodeId] else { continue }
                contentRect = contentRect.map { $0.union(nodeRect) } ?? nodeRect
            }
            for child in subgraph.subgraphs {
                guard let childFrame = collect(child) else { continue }
                contentRect = contentRect.map { $0.union(childFrame) } ?? childFrame
            }
            guard let contentRect else { return nil }

            let horizontalPadding = subgraphHorizontalPadding(fontSize: fontSize)
            let topPadding = subgraphTopPadding(fontSize: fontSize)
            let bottomPadding = subgraphBottomPadding(fontSize: fontSize)
            let frame = CGRect(
                x: contentRect.minX - horizontalPadding,
                y: contentRect.minY - topPadding,
                width: contentRect.width + horizontalPadding * 2,
                height: contentRect.height + topPadding + bottomPadding
            )
            frames[subgraph.id] = frame
            return frame
        }

        for subgraph in subgraphs {
            _ = collect(subgraph)
        }
        return frames
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

    private enum DiamondVertex {
        case top, right, bottom, left

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .top: return CGPoint(x: rect.midX, y: rect.minY)
            case .right: return CGPoint(x: rect.maxX, y: rect.midY)
            case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
            case .left: return CGPoint(x: rect.minX, y: rect.midY)
            }
        }
    }

    private func routeEdges(
        _ edges: [GraphLayoutEdge],
        positions: [String: CGRect],
        direction: GraphLayoutDirection,
        laneSeed: Int = 0,
        nodeShapes: [String: FlowNodeShape] = [:],
        allEdges: [GraphLayoutEdge]? = nil
    ) -> [GraphLayoutEdgePath] {
        let isHorizontal = direction == .leftToRight || direction == .rightToLeft
        let contextEdges = allEdges ?? edges
        var outgoingTargets: [String: [String]] = [:]
        for edge in contextEdges {
            outgoingTargets[edge.from, default: []].append(edge.to)
        }

        return edges.enumerated().compactMap { index, edge in
            guard let fromRect = positions[edge.from], let toRect = positions[edge.to] else { return nil }
            let fromCenter = CGPoint(x: fromRect.midX, y: fromRect.midY)
            let toCenter = CGPoint(x: toRect.midX, y: toRect.midY)
            let fromIsDiamond = nodeShapes[edge.from] == .diamond
            let toIsDiamond = nodeShapes[edge.to] == .diamond

            let fromPoint: CGPoint
            let toPoint: CGPoint
            var fromVertex: DiamondVertex?
            if fromIsDiamond {
                let vertex = diamondVertex(
                    from: fromRect,
                    to: toRect,
                    toward: edge.to,
                    siblingIds: outgoingTargets[edge.from] ?? [],
                    positions: positions
                )
                fromVertex = vertex
                fromPoint = vertex.point(in: fromRect)
            } else if isHorizontal {
                fromPoint = fromCenter.x < toCenter.x
                    ? CGPoint(x: fromRect.maxX, y: fromRect.midY)
                    : CGPoint(x: fromRect.minX, y: fromRect.midY)
            } else if fromCenter.y < toCenter.y {
                fromPoint = CGPoint(x: fromRect.midX, y: fromRect.maxY)
            } else {
                fromPoint = CGPoint(x: fromRect.midX, y: fromRect.minY)
            }

            if toIsDiamond {
                toPoint = diamondVertex(
                    from: toRect,
                    to: fromRect,
                    toward: edge.from,
                    siblingIds: [],
                    positions: positions
                ).point(in: toRect)
            } else if fromIsDiamond {
                toPoint = facingPort(on: toRect, from: fromPoint)
            } else if isHorizontal {
                toPoint = fromCenter.x < toCenter.x
                    ? CGPoint(x: toRect.minX, y: toRect.midY)
                    : CGPoint(x: toRect.maxX, y: toRect.midY)
            } else if fromCenter.y < toCenter.y {
                toPoint = CGPoint(x: toRect.midX, y: toRect.minY)
            } else {
                toPoint = CGPoint(x: toRect.midX, y: toRect.maxY)
            }

            if abs(fromPoint.x - toPoint.x) <= 1 || abs(fromPoint.y - toPoint.y) <= 1 {
                return GraphLayoutEdgePath(from: edge.from, to: edge.to, points: [fromPoint, toPoint])
            }

            if fromIsDiamond || toIsDiamond {
                let vertex = fromVertex ?? diamondVertex(
                    from: toRect,
                    to: fromRect,
                    toward: edge.from,
                    siblingIds: [],
                    positions: positions
                )
                return GraphLayoutEdgePath(
                    from: edge.from,
                    to: edge.to,
                    points: curvedConnector(from: fromPoint, to: toPoint, leaving: vertex)
                )
            }

            var points = [fromPoint]
            let laneStep: CGFloat = 4
            let lanePattern = [0, -1, 1, -2, 2]
            let laneIndex = CGFloat(lanePattern[(index + laneSeed) % lanePattern.count])
            if isHorizontal {
                let midpoint = (fromPoint.x + toPoint.x) / 2
                let maxOffset = abs(toPoint.x - fromPoint.x) * 0.2
                let midRank = midpoint + min(max(laneIndex * laneStep, -maxOffset), maxOffset)
                points.append(CGPoint(x: midRank, y: fromPoint.y))
                points.append(CGPoint(x: midRank, y: toPoint.y))
            } else {
                let midpoint = (fromPoint.y + toPoint.y) / 2
                let maxOffset = abs(toPoint.y - fromPoint.y) * 0.2
                let midRank = midpoint + min(max(laneIndex * laneStep, -maxOffset), maxOffset)
                points.append(CGPoint(x: fromPoint.x, y: midRank))
                points.append(CGPoint(x: toPoint.x, y: midRank))
            }
            points.append(toPoint)
            return GraphLayoutEdgePath(from: edge.from, to: edge.to, points: points)
        }
    }

    private func diamondVertex(
        from rect: CGRect,
        to other: CGRect,
        toward targetId: String,
        siblingIds: [String],
        positions: [String: CGRect]
    ) -> DiamondVertex {
        // Two or more branches always leave the side vertices so they cannot
        // share the bottom tip and then stair-step horizontally.
        if siblingIds.count >= 2 {
            let ranked = siblingIds.sorted { a, b in
                let ax = positions[a]?.midX ?? 0
                let bx = positions[b]?.midX ?? 0
                if abs(ax - bx) > 1 { return ax < bx }
                return a < b
            }
            if targetId == ranked.first { return .left }
            if targetId == ranked.last { return .right }
        }
        let dx = other.midX - rect.midX
        let dy = other.midY - rect.midY
        let heightAlign = max(8, min(rect.height, other.height) * 0.35)
        let widthAlign = max(8, min(rect.width, other.width) * 0.35)
        if abs(dy) <= heightAlign {
            return dx < 0 ? .left : .right
        }
        if abs(dx) <= widthAlign {
            return dy < 0 ? .top : .bottom
        }
        if abs(dx) >= abs(dy) * 0.35 {
            return dx < 0 ? .left : .right
        }
        return dy < 0 ? .top : .bottom
    }

    private func facingPort(on rect: CGRect, from point: CGPoint) -> CGPoint {
        let dx = point.x - rect.midX
        let dy = point.y - rect.midY
        if abs(dx) > abs(dy) {
            return CGPoint(x: point.x < rect.midX ? rect.minX : rect.maxX, y: rect.midY)
        }
        return CGPoint(x: rect.midX, y: point.y < rect.midY ? rect.minY : rect.maxY)
    }

    private func curvedConnector(from: CGPoint, to: CGPoint, leaving vertex: DiamondVertex) -> [CGPoint] {
        let stub = max(16, hypot(to.x - from.x, to.y - from.y) * 0.25)
        let control: CGPoint
        switch vertex {
        case .left:
            control = CGPoint(x: from.x - stub, y: (from.y + to.y) / 2)
        case .right:
            control = CGPoint(x: from.x + stub, y: (from.y + to.y) / 2)
        case .top:
            control = CGPoint(x: (from.x + to.x) / 2, y: from.y - stub)
        case .bottom:
            control = CGPoint(x: (from.x + to.x) / 2, y: from.y + stub)
        }
        return [from, control, to]
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
    private func measureText(
        _ text: String,
        font: CTFont,
        fontSize: CGFloat,
        isMarkdown: Bool = false
    ) -> CGSize {
        MermaidTextUtils.measureText(text, font: font, fontSize: fontSize, isMarkdown: isMarkdown)
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

        // Strokes, then arrowheads, then labels. Interleaving let later shared
        // trunks paint across earlier labels and other arrowhead envelopes.
        for (index, edgePath) in layout.graphResult.edgePaths.enumerated() {
            let key = index < layout.edgeKeys.count
                ? layout.edgeKeys[index]
                : "\(edgePath.from)->\(edgePath.to)"
            let style = layout.edgeStyles[key] ?? .arrow
            let styleProperties = layout.edgeStyleDirectives[key] ?? [:]
            drawEdge(
                edgePath,
                style: style,
                styleProperties: styleProperties,
                layout: layout,
                in: ctx,
                offset: offset,
                includeArrowhead: false
            )
        }
        for (index, edgePath) in layout.graphResult.edgePaths.enumerated() {
            let key = index < layout.edgeKeys.count
                ? layout.edgeKeys[index]
                : "\(edgePath.from)->\(edgePath.to)"
            let style = layout.edgeStyles[key] ?? .arrow
            let styleProperties = layout.edgeStyleDirectives[key] ?? [:]
            drawEdgeArrowhead(
                edgePath,
                style: style,
                styleProperties: styleProperties,
                layout: layout,
                in: ctx,
                offset: offset
            )
        }
        for (index, edgePath) in layout.graphResult.edgePaths.enumerated() {
            let key = index < layout.edgeKeys.count
                ? layout.edgeKeys[index]
                : "\(edgePath.from)->\(edgePath.to)"
            if let label = layout.edgeLabels[key] {
                let isMarkdown = index < layout.flowchart.edges.count
                    && layout.flowchart.edges[index].isMarkdown
                drawEdgeLabel(
                    label,
                    path: edgePath,
                    isMarkdown: isMarkdown,
                    layout: layout,
                    in: ctx,
                    offset: offset
                )
            }
        }

        // Draw nodes.
        for (id, rect) in layout.graphResult.nodePositions {
            let shape = layout.nodeShapes[id] ?? .default
            let label = layout.nodeLabels[id] ?? id
            let offsetRect = rect.offsetBy(dx: offset.x, dy: offset.y)

            let styleProps = layout.styleDirectives[id] ?? [:]
            drawNodeShape(shape, rect: offsetRect, style: styleProps, layout: layout, in: ctx)
            let isMarkdown = layout.flowchart.nodes.first { $0.id == id }?.isMarkdown ?? false
            drawNodeLabel(
                label,
                in: offsetRect,
                style: styleProps,
                isMarkdown: isMarkdown,
                layout: layout,
                ctx: ctx
            )
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
                isMarkdown: subgraph.isMarkdown,
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
        let edgeMargin = max(2, layout.fontSize * 0.7)
        for point in layout.graphResult.edgePaths.flatMap(\.points) {
            bounds = bounds.union(CGRect(
                x: point.x - edgeMargin,
                y: point.y - edgeMargin,
                width: edgeMargin * 2,
                height: edgeMargin * 2
            ))
        }
        for (index, path) in layout.graphResult.edgePaths.enumerated() {
            let key = index < layout.edgeKeys.count
                ? layout.edgeKeys[index]
                : "\(path.from)->\(path.to)"
            guard let label = layout.edgeLabels[key],
                  let labelLayout = edgeLabelLayout(
                      label,
                      path: path,
                      fontSize: layout.fontSize,
                      isMarkdown: index < layout.flowchart.edges.count
                          && layout.flowchart.edges[index].isMarkdown,
                      among: layout.graphResult.edgePaths
                  ) else { continue }
            bounds = bounds.union(labelLayout.rect)
        }
        return bounds
    }

    private func subgraphFrame(_ subgraph: FlowSubgraph, layout: FlowchartLayout) -> CGRect? {
        layout.subgraphFrames[subgraph.id]
    }

    private func subgraphHorizontalPadding(fontSize: CGFloat) -> CGFloat {
        max(24, fontSize * 2)
    }

    private func subgraphTopPadding(fontSize: CGFloat) -> CGFloat {
        max(32, subgraphTitleHeight(fontSize: fontSize) + fontSize)
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
        spec: LayoutEdgeSpec,
        subgraphFrames: [String: CGRect]
    ) -> GraphLayoutEdgePath {
        var points = edgePath.points
        if let fromSubgraph = spec.fromSubgraph,
           let frame = subgraphFrames[fromSubgraph] {
            points = pathClippedLeavingFrame(points, frame: frame)
        }
        if let toSubgraph = spec.toSubgraph,
           let frame = subgraphFrames[toSubgraph] {
            points = Array(pathClippedLeavingFrame(Array(points.reversed()), frame: frame).reversed())
        }
        return GraphLayoutEdgePath(
            from: edgePath.from,
            to: edgePath.to,
            points: simplifiedOrthogonalPath(points)
        )
    }

    private func pathClippedLeavingFrame(_ points: [CGPoint], frame: CGRect) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        for index in 0..<(points.count - 1) {
            let first = points[index]
            let second = points[index + 1]
            guard frame.contains(first), !frame.contains(second),
                  let boundary = orthogonalBoundaryIntersection(
                      from: first,
                      to: second,
                      frame: frame
                  ) else { continue }
            return [boundary] + Array(points[(index + 1)...])
        }
        return points
    }

    private func orthogonalBoundaryIntersection(
        from first: CGPoint,
        to second: CGPoint,
        frame: CGRect
    ) -> CGPoint? {
        let epsilon: CGFloat = 0.1
        if abs(first.x - second.x) < epsilon {
            return CGPoint(
                x: first.x,
                y: second.y < frame.minY ? frame.minY : frame.maxY
            )
        }
        if abs(first.y - second.y) < epsilon {
            return CGPoint(
                x: second.x < frame.minX ? frame.minX : frame.maxX,
                y: first.y
            )
        }
        return nil
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
        isMarkdown: Bool,
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
            isMarkdown: isMarkdown,
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
        offset: CGPoint,
        includeArrowhead: Bool = true
    ) {
        guard edgePath.points.count >= 2 else { return }
        if style == .invisible { return }

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

        ctx.move(to: points[0])
        if points.count == 3, !isAxisAligned(points[0], points[1]) || !isAxisAligned(points[1], points[2]) {
            ctx.addQuadCurve(to: points[2], control: points[1])
        } else {
            for i in 1 ..< points.count {
                ctx.addLine(to: points[i])
            }
        }
        ctx.strokePath()
        ctx.restoreGState()

        if includeArrowhead {
            drawEdgeArrowhead(
                edgePath,
                style: style,
                styleProperties: styleProperties,
                layout: layout,
                in: ctx,
                offset: offset
            )
        }
    }

    private func drawEdgeArrowhead(
        _ edgePath: GraphLayoutEdgePath,
        style: FlowEdgeStyle,
        styleProperties: [String: String],
        layout: FlowchartLayout,
        in ctx: CGContext,
        offset: CGPoint
    ) {
        guard edgePath.points.count >= 2 else { return }
        guard style == .arrow || style == .dotted || style == .thick
            || style == .biArrow || style == .cross || style == .biCross
            || style == .circle || style == .biCircle else { return }

        let points = edgePath.points.map {
            CGPoint(x: $0.x + offset.x, y: $0.y + offset.y)
        }
        let strokeColor = parseStyleColor(styleProperties["stroke"], theme: layout.theme)
            ?? layout.theme.foreground
        drawArrowhead(
            at: points[points.count - 1],
            from: points[points.count - 2],
            size: layout.fontSize * 0.6,
            in: ctx,
            color: strokeColor
        )
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

    private struct EdgeLabelLayout {
        let rect: CGRect
        let textSize: CGSize
        let font: CTFont
        let fontSize: CGFloat
    }

    private func edgeLabelLayout(
        _ text: String,
        path: GraphLayoutEdgePath,
        fontSize: CGFloat,
        isMarkdown: Bool = false,
        among others: [GraphLayoutEdgePath]
    ) -> EdgeLabelLayout? {
        guard path.points.count >= 2 else { return nil }
        let anchor = edgeLabelAnchor(on: path, fontSize: fontSize, among: others)
        let labelFontSize = fontSize * 0.85
        let font = CTFontCreateWithName("Helvetica" as CFString, labelFontSize, nil)
        let textSize = MermaidTextUtils.measureText(
            text,
            font: font,
            fontSize: labelFontSize,
            isMarkdown: isMarkdown
        )
        return EdgeLabelLayout(
            rect: CGRect(
                x: anchor.x - textSize.width / 2 - 3,
                y: anchor.y - textSize.height / 2 - 2,
                width: textSize.width + 6,
                height: textSize.height + 4
            ),
            textSize: textSize,
            font: font,
            fontSize: labelFontSize
        )
    }

    /// Prefer the unique first or last stub so shared trunks do not run through
    /// sibling labels. Fan-out uses the destination stub; fan-in uses the source stub.
    private func edgeLabelAnchor(
        on path: GraphLayoutEdgePath,
        fontSize: CGFloat,
        among others: [GraphLayoutEdgePath]
    ) -> CGPoint {
        let points = path.points
        let tip = points[points.count - 1]
        let prev = points[points.count - 2]
        let lastDX = tip.x - prev.x
        let lastDY = tip.y - prev.y
        let lastLen = hypot(lastDX, lastDY)
        let inset = max(fontSize * 1.7, 22)
        let peers = others.filter {
            $0.from != path.from || $0.to != path.to || $0.points != path.points
        }
        if points.count >= 3 {
            let firstLen = hypot(points[1].x - points[0].x, points[1].y - points[0].y)
            let firstShared = peers.filter {
                pathSharesSegment($0, from: points[0], to: points[1])
            }.count
            let lastShared = peers.filter {
                pathSharesSegment($0, from: prev, to: tip)
            }.count
            if lastLen > 8, firstShared > lastShared {
                if lastLen > inset + 4 {
                    let t = 1 - inset / lastLen
                    return CGPoint(x: prev.x + lastDX * t, y: prev.y + lastDY * t)
                }
                return CGPoint(x: (prev.x + tip.x) / 2, y: (prev.y + tip.y) / 2)
            }
            if firstLen > 8, lastShared > firstShared {
                return CGPoint(
                    x: (points[0].x + points[1].x) / 2,
                    y: (points[0].y + points[1].y) / 2
                )
            }
            let candidates = zip(points, points.dropFirst()).dropLast()
            if let best = candidates.max(by: {
                hypot($0.1.x - $0.0.x, $0.1.y - $0.0.y) < hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)
            }) {
                let length = hypot(best.1.x - best.0.x, best.1.y - best.0.y)
                if length > 8 {
                    return CGPoint(x: (best.0.x + best.1.x) / 2, y: (best.0.y + best.1.y) / 2)
                }
            }
        }
        if lastLen > inset + 4 {
            let t = 1 - inset / lastLen
            return CGPoint(x: prev.x + lastDX * t, y: prev.y + lastDY * t)
        }
        return CGPoint(x: (prev.x + tip.x) / 2, y: (prev.y + tip.y) / 2)
    }

    private func pathSharesSegment(
        _ path: GraphLayoutEdgePath,
        from first: CGPoint,
        to second: CGPoint
    ) -> Bool {
        let epsilon: CGFloat = 0.6
        return zip(path.points, path.points.dropFirst()).contains { start, end in
            if abs(first.y - second.y) < epsilon,
               abs(start.y - end.y) < epsilon,
               abs(first.y - start.y) < epsilon {
                return max(first.x, second.x) > min(start.x, end.x) + 1
                    && min(first.x, second.x) < max(start.x, end.x) - 1
            }
            if abs(first.x - second.x) < epsilon,
               abs(start.x - end.x) < epsilon,
               abs(first.x - start.x) < epsilon {
                return max(first.y, second.y) > min(start.y, end.y) + 1
                    && min(first.y, second.y) < max(start.y, end.y) - 1
            }
            return false
        }
    }

    private func drawEdgeLabel(
        _ text: String,
        path: GraphLayoutEdgePath,
        isMarkdown: Bool,
        layout: FlowchartLayout,
        in ctx: CGContext,
        offset: CGPoint
    ) {
        guard let labelLayout = edgeLabelLayout(
            text,
            path: path,
            fontSize: layout.fontSize,
            isMarkdown: isMarkdown,
            among: layout.graphResult.edgePaths
        ) else { return }
        let labelRect = labelLayout.rect.offsetBy(dx: offset.x, dy: offset.y)

        // Draw background behind label for readability.
        ctx.saveGState()
        ctx.setFillColor(layout.theme.background)
        ctx.fill(labelRect)

        // Draw text.
        MermaidTextUtils.drawText(
            text,
            at: CGPoint(x: labelRect.minX + 3, y: labelRect.minY + 2),
            width: labelLayout.textSize.width,
            font: labelLayout.font,
            fontSize: labelLayout.fontSize,
            foregroundColor: layout.theme.foreground,
            alignment: .center,
            isMarkdown: isMarkdown,
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
