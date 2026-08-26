import CoreGraphics
import CoreText
import Foundation

/// Renderer for Mermaid `sankey` / `sankey-beta`.
///
/// Phone-first layered flow: nodes are 4pt-rounded theme-accent rects,
/// links are thin stacked translucent bands. `nodeAlignment` / `nodeWidth`
/// / `nodePadding` affect layout. Mermaid `linkColor` / page themes are ignored.
enum MermaidSankeyRenderer {

    private static let outerMargin: CGFloat = 16
    private static let inset: CGFloat = 8
    private static let labelGap: CGFloat = 8
    private static let minNodeHeight: CGFloat = 8
    /// 4pt rects, never a stadium. Half the short side would turn thin
    /// nodes into pills and the gallery into an organism.
    static let nodeCornerRadius: CGFloat = 4
    static let ribbonAlpha: CGFloat = 0.22
    static let ribbonThicknessFactor: CGFloat = 0.55

    static func cornerRadius(for rect: CGRect) -> CGFloat {
        let halfShort = min(rect.width, rect.height) / 2
        return min(nodeCornerRadius, max(0, halfShort - 1))
    }

    nonisolated static func layout(
        _ diagram: SankeyDiagram,
        configuration: RenderConfiguration
    ) -> MermaidFlowchartRenderer.FlowchartLayout {
        if case .unsupported(let token) = diagram.options.nodeAlignment {
            return MermaidFlowchartRenderer().placeholderLayout(
                text: "Unsupported sankey node alignment: \(token)",
                configuration: configuration
            )
        }
        guard !diagram.links.isEmpty else {
            return MermaidFlowchartRenderer().placeholderLayout(
                text: "Empty sankey",
                configuration: configuration
            )
        }

        let theme = configuration.theme
        let fontSize = configuration.fontSize
        let maxWidth = max(configuration.maxWidth, 1)
        let prepared = prepare(diagram)
        guard !prepared.nodes.isEmpty else {
            return MermaidFlowchartRenderer().placeholderLayout(
                text: "Empty sankey",
                configuration: configuration
            )
        }

        let contentWidth = max(maxWidth - outerMargin * 2, 80)
        let nodeWidth = CGFloat(max(diagram.options.nodeWidth, 8))
        let nodePadding = CGFloat(max(diagram.options.nodePadding, 8))
        let labelFont = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.8, nil)
        let labelFontSize = fontSize * 0.8
        // Official mermaid sankey is LTR. Trailing-layer labels sit beside
        // those nodes; earlier labels sit over the ribbons. Do not reserve a
        // 32% right column — that starves the plot.
        let trailingNodes: [Node]
        switch diagram.options.nodeAlignment {
        case .right:
            trailingNodes = prepared.layers.first ?? []
        default:
            trailingNodes = prepared.layers.last ?? []
        }
        let longestTrailingLabel = trailingNodes.map {
            MermaidTextUtils.measureText($0.id, font: labelFont, fontSize: labelFontSize).width
        }.max() ?? 24
        let trailingLabelWidth = min(longestTrailingLabel, max(maxWidth * 0.18, 48))
        let reservedRight = trailingLabelWidth + labelGap
        let plotWidth = max(maxWidth - outerMargin - inset - reservedRight, nodeWidth + 32)

        let layerCount = (prepared.nodes.map(\.layer).max() ?? 0) + 1
        let layerGap = layerCount > 1
            ? (plotWidth - nodeWidth) / CGFloat(layerCount - 1)
            : 0
        let intermediateLabelWidth = max(layerGap - nodeWidth - labelGap, 48)

        let maxLayerValue = prepared.layers.map { layer in
            layer.reduce(0.0) { $0 + $1.value }
        }.max() ?? 1
        // Scale values for readability, then grow height to the stacked
        // node+padding bounds. A fixed 280pt cap drops later sinks.
        let preferredBand = max(160, CGFloat(prepared.nodes.count) * 24)
        let valueScale = preferredBand / CGFloat(max(maxLayerValue, 0.001))
        let plotHeight = prepared.layers.map { layer in
            layer.reduce(CGFloat(0)) { $0 + max(CGFloat($1.value) * valueScale, minNodeHeight) }
                + nodePadding * CGFloat(max(layer.count - 1, 0))
        }.max() ?? preferredBand

        var nodeFrames: [String: CGRect] = [:]
        var nodeLabels: [String: String] = [:]
        var yCursor: [Int: CGFloat] = [:]
        for layer in 0..<layerCount {
            let nodes = prepared.layers[layer]
            let totalHeight = nodes.reduce(CGFloat(0)) { $0 + CGFloat($1.value) * valueScale }
                + nodePadding * CGFloat(max(nodes.count - 1, 0))
            let extra = max(plotHeight - totalHeight, 0)
            let startY: CGFloat
            switch diagram.options.nodeAlignment {
            case .left, .justify:
                startY = 0
            case .center:
                startY = extra / 2
            case .right:
                startY = extra
            case .unsupported:
                startY = 0
            }
            yCursor[layer] = startY
        }

        for node in prepared.nodes {
            let height = max(CGFloat(node.value) * valueScale, minNodeHeight)
            let y = yCursor[node.layer] ?? 0
            let x: CGFloat
            if layerCount == 1 {
                x = 0
            } else {
                switch diagram.options.nodeAlignment {
                case .right:
                    x = CGFloat(layerCount - 1 - node.layer) * layerGap
                default:
                    x = CGFloat(node.layer) * layerGap
                }
            }
            let frame = CGRect(x: outerMargin + x, y: outerMargin + y, width: nodeWidth, height: height)
            nodeFrames["node-\(node.id)"] = frame
            nodeLabels["$node-\(node.id)"] = node.id
            let isTrailing: Bool
            switch diagram.options.nodeAlignment {
            case .right:
                isTrailing = node.layer == 0
            default:
                isTrailing = node.layer == layerCount - 1
            }
            let labelWrapWidth = isTrailing ? trailingLabelWidth : intermediateLabelWidth
            let wrapped = MermaidTextUtils.wrapText(
                node.id, maxWidth: labelWrapWidth, font: labelFont, fontSize: labelFontSize
            )
            let labelSize = MermaidTextUtils.measureText(
                wrapped, font: labelFont, fontSize: labelFontSize
            )
            let labelFrame = CGRect(
                x: frame.maxX + labelGap,
                y: frame.midY - labelSize.height / 2,
                width: min(labelSize.width, labelWrapWidth),
                height: labelSize.height
            )
            nodeFrames["label-\(node.id)"] = labelFrame
            nodeLabels["$label-\(node.id)"] = wrapped
            yCursor[node.layer] = y + height + nodePadding
        }

        var contentMinY = CGFloat.greatestFiniteMagnitude
        var contentMaxY: CGFloat = 0
        var contentMaxX: CGFloat = 0
        for frame in nodeFrames.values {
            contentMinY = min(contentMinY, frame.minY)
            contentMaxY = max(contentMaxY, frame.maxY)
            contentMaxX = max(contentMaxX, frame.maxX)
        }
        var thicknesses: [CGFloat] = []
        var outTotal: [String: CGFloat] = [:]
        var inTotal: [String: CGFloat] = [:]
        for link in prepared.links {
            guard let from = nodeFrames["node-\(link.source)"],
                  let to = nodeFrames["node-\(link.target)"]
            else {
                thicknesses.append(0)
                continue
            }
            let thickness = min(
                max(CGFloat(link.value) * valueScale * ribbonThicknessFactor, 1.5),
                from.height * ribbonThicknessFactor,
                to.height * ribbonThicknessFactor
            )
            thicknesses.append(thickness)
            outTotal[link.source, default: 0] += thickness
            inTotal[link.target, default: 0] += thickness
        }
        var outCursor: [String: CGFloat] = [:]
        var inCursor: [String: CGFloat] = [:]
        for node in prepared.nodes {
            guard let frame = nodeFrames["node-\(node.id)"] else { continue }
            outCursor[node.id] = max(0, frame.height - (outTotal[node.id] ?? 0)) / 2
            inCursor[node.id] = max(0, frame.height - (inTotal[node.id] ?? 0)) / 2
        }
        var ribbonSlots: [RibbonSlot] = []
        for (link, thickness) in zip(prepared.links, thicknesses) where thickness > 0 {
            guard let from = nodeFrames["node-\(link.source)"],
                  let to = nodeFrames["node-\(link.target)"]
            else { continue }
            let sourceY = from.minY + (outCursor[link.source] ?? 0) + thickness / 2
            let targetY = to.minY + (inCursor[link.target] ?? 0) + thickness / 2
            outCursor[link.source] = (outCursor[link.source] ?? 0) + thickness
            inCursor[link.target] = (inCursor[link.target] ?? 0) + thickness
            ribbonSlots.append(RibbonSlot(
                link: link, sourceY: sourceY, targetY: targetY, thickness: thickness
            ))
            contentMinY = min(contentMinY, sourceY - thickness / 2, targetY - thickness / 2)
            contentMaxY = max(contentMaxY, sourceY + thickness / 2, targetY + thickness / 2)
        }
        if contentMinY == .greatestFiniteMagnitude { contentMinY = outerMargin }

        let shiftY = max(0, inset - contentMinY)
        if shiftY > 0 {
            for key in nodeFrames.keys {
                nodeFrames[key] = nodeFrames[key]?.offsetBy(dx: 0, dy: shiftY)
            }
            ribbonSlots = ribbonSlots.map { slot in
                RibbonSlot(
                    link: slot.link,
                    sourceY: slot.sourceY + shiftY,
                    targetY: slot.targetY + shiftY,
                    thickness: slot.thickness
                )
            }
            contentMinY += shiftY
            contentMaxY += shiftY
        }

        let canvasWidth = min(maxWidth, max(contentMaxX + inset, outerMargin * 2 + contentWidth))
        let canvasHeight = max(contentMaxY + inset, outerMargin * 2 + plotHeight)
        let size = CGSize(width: canvasWidth, height: canvasHeight)

        var nodePositions = nodeFrames
        nodePositions["plot"] = CGRect(
            x: outerMargin,
            y: max(inset, outerMargin + shiftY),
            width: plotWidth,
            height: max(plotHeight, contentMaxY - contentMinY)
        )
        var edgePaths: [GraphLayoutEdgePath] = []
        for slot in ribbonSlots {
            guard let from = nodeFrames["node-\(slot.link.source)"],
                  let to = nodeFrames["node-\(slot.link.target)"]
            else { continue }
            let start = CGPoint(x: from.maxX, y: slot.sourceY)
            let end = CGPoint(x: to.minX, y: slot.targetY)
            let points = ribbonCenterline(from: start, to: end)
            edgePaths.append(GraphLayoutEdgePath(
                from: slot.link.source, to: slot.link.target, points: points
            ))
            nodePositions["ribbon-\(slot.link.source)-\(slot.link.target)"] = CGRect(
                x: from.maxX,
                y: slot.sourceY - slot.thickness / 2,
                width: max(to.minX - from.maxX, 0),
                height: slot.thickness
            )
        }

        let capturedNodes = prepared.nodes
        let capturedSlots = ribbonSlots
        let capturedFrames = nodeFrames
        let capturedLabels = nodeLabels
        let capturedLabelWidth = trailingLabelWidth
        let capturedSize = size
        let colors = theme.diagramAccents

        let draw: @Sendable (CGContext, CGPoint) -> Void = { ctx, origin in
            let ox = origin.x
            let oy = origin.y
            ctx.saveGState()
            ctx.clip(to: CGRect(origin: origin, size: capturedSize))
            var colorIndex: [String: Int] = [:]
            for (i, node) in capturedNodes.enumerated() {
                colorIndex[node.id] = i
            }

            for slot in capturedSlots {
                guard let from = capturedFrames["node-\(slot.link.source)"],
                      let to = capturedFrames["node-\(slot.link.target)"]
                else { continue }
                let start = CGPoint(x: ox + from.maxX, y: oy + slot.sourceY)
                let end = CGPoint(x: ox + to.minX, y: oy + slot.targetY)
                let color = colors[(colorIndex[slot.link.source] ?? 0) % colors.count]
                fillRibbon(
                    from: start,
                    to: end,
                    thickness: slot.thickness,
                    color: color.copy(alpha: ribbonAlpha) ?? color,
                    in: ctx
                )
            }

            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.8, nil)
            for (i, node) in capturedNodes.enumerated() {
                guard let frame = capturedFrames["node-\(node.id)"] else { continue }
                let rect = frame.offsetBy(dx: ox, dy: oy)
                ctx.setFillColor(colors[i % colors.count])
                let corner = cornerRadius(for: rect)
                ctx.addPath(CGPath(
                    roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil
                ))
                ctx.fillPath()
                let label = capturedLabels["$label-\(node.id)"] ?? node.id
                let labelFrame = capturedFrames["label-\(node.id)"]?.offsetBy(dx: ox, dy: oy)
                    ?? CGRect(
                        x: rect.maxX + labelGap,
                        y: rect.midY - fontSize * 0.4,
                        width: capturedLabelWidth,
                        height: fontSize
                    )
                MermaidTextUtils.drawText(
                    label,
                    at: CGPoint(x: labelFrame.minX, y: labelFrame.minY),
                    width: max(labelFrame.width, capturedLabelWidth),
                    font: font,
                    fontSize: fontSize * 0.8,
                    foregroundColor: theme.foreground,
                    in: ctx
                )
            }
            ctx.restoreGState()
        }

        return .custom(
            size: size,
            nodePositions: nodePositions,
            nodeLabels: nodeLabels,
            configuration: configuration,
            edgePaths: edgePaths,
            draw: draw
        )
    }

    private struct RibbonSlot {
        let link: SankeyLink
        let sourceY: CGFloat
        let targetY: CGFloat
        let thickness: CGFloat
    }

    private struct Node {
        let id: String
        let layer: Int
        let value: Double
    }

    private struct Prepared {
        let nodes: [Node]
        let layers: [[Node]]
        let links: [SankeyLink]
    }

    private static func prepare(_ diagram: SankeyDiagram) -> Prepared {
        var incoming: [String: [String]] = [:]
        var outgoing: [String: [String]] = [:]
        var values: [String: Double] = [:]
        var order: [String] = []

        for link in diagram.links {
            if values[link.source] == nil { order.append(link.source) }
            if values[link.target] == nil { order.append(link.target) }
            values[link.source, default: 0] += link.value
            values[link.target, default: 0] += link.value
            outgoing[link.source, default: []].append(link.target)
            incoming[link.target, default: []].append(link.source)
        }

        var layer: [String: Int] = [:]
        let sources = order.filter { incoming[$0] == nil }
        var queue = sources
        for source in sources { layer[source] = 0 }
        var guardCount = 0
        while !queue.isEmpty, guardCount < order.count * 4 {
            let node = queue.removeFirst()
            let nodeLayer = layer[node] ?? 0
            for target in outgoing[node] ?? [] {
                let next = nodeLayer + 1
                if layer[target] == nil || next > (layer[target] ?? 0) {
                    layer[target] = next
                    queue.append(target)
                }
            }
            guardCount += 1
        }
        for id in order where layer[id] == nil {
            layer[id] = 0
        }

        let nodes = order.map { id in
            Node(id: id, layer: layer[id] ?? 0, value: values[id] ?? 0)
        }
        let maxLayer = nodes.map(\.layer).max() ?? 0
        var layers: [[Node]] = Array(repeating: [], count: maxLayer + 1)
        for node in nodes {
            layers[node.layer].append(node)
        }
        return Prepared(nodes: nodes, layers: layers, links: diagram.links)
    }

    /// Flatter than a mid-X S-curve so stacked bands stay more parallel.
    private static func ribbonCenterline(from start: CGPoint, to end: CGPoint) -> [CGPoint] {
        let span = end.x - start.x
        return [
            start,
            CGPoint(x: start.x + span * 0.35, y: start.y),
            CGPoint(x: start.x + span * 0.65, y: end.y),
            end,
        ]
    }

    private static func fillRibbon(
        from start: CGPoint,
        to end: CGPoint,
        thickness: CGFloat,
        color: CGColor,
        in ctx: CGContext
    ) {
        let half = thickness / 2
        let points = ribbonCenterline(from: start, to: end)
        let c1 = points[1]
        let c2 = points[2]
        ctx.setFillColor(color)
        ctx.move(to: CGPoint(x: start.x, y: start.y - half))
        ctx.addCurve(
            to: CGPoint(x: end.x, y: end.y - half),
            control1: CGPoint(x: c1.x, y: start.y - half),
            control2: CGPoint(x: c2.x, y: end.y - half)
        )
        ctx.addLine(to: CGPoint(x: end.x, y: end.y + half))
        ctx.addCurve(
            to: CGPoint(x: start.x, y: start.y + half),
            control1: CGPoint(x: c2.x, y: end.y + half),
            control2: CGPoint(x: c1.x, y: start.y + half)
        )
        ctx.closePath()
        ctx.fillPath()
    }
}
