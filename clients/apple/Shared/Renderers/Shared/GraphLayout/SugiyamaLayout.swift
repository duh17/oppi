import CoreGraphics
import Foundation

// MARK: - Input types

/// Input to the generic directed graph layout engine.
///
/// Caller provides pre-measured node sizes and edge connectivity.
/// The layout engine assigns positions — it never measures text.
struct GraphLayoutInput: Sendable {
    let nodes: [GraphLayoutNode]
    let edges: [GraphLayoutEdge]
    let direction: GraphLayoutDirection
    let nodeSpacing: CGFloat
    let rankSpacing: CGFloat
}

/// A node with a pre-computed bounding size.
struct GraphLayoutNode: Sendable {
    let id: String
    let size: CGSize
}

/// A directed edge between two node IDs.
struct GraphLayoutEdge: Sendable {
    let from: String
    let to: String
    /// Minimum gap for every rank gap this edge crosses, e.g. room for its
    /// label or a shared trunk. `rankSpacing` applies when this is smaller.
    var minRankGap: CGFloat = 0
}

/// Flow direction for the layered layout.
enum GraphLayoutDirection: Sendable {
    case topToBottom, bottomToTop, leftToRight, rightToLeft
}

// MARK: - Output types

/// Positioned graph ready for rendering.
struct GraphLayoutResult: Sendable {
    /// Map from node ID to its positioned rectangle.
    let nodePositions: [String: CGRect]
    /// Routed edge paths with waypoints.
    let edgePaths: [GraphLayoutEdgePath]
    /// Bounding box of the entire layout.
    let totalSize: CGSize
}

/// A routed edge as a polyline through waypoints.
struct GraphLayoutEdgePath: Sendable {
    let from: String
    let to: String
    let points: [CGPoint]
}

// MARK: - Layout engine

/// Layered graph layout using the Sugiyama algorithm.
///
/// Phases:
/// 1. Cycle removal — DFS-based back-edge reversal
/// 2. Layer assignment — longest path from sources
/// 3. Crossing minimization — barycenter heuristic (3 passes)
/// 4. Coordinate assignment — center nodes within layers
/// 5. Edge routing — polyline waypoints through layers
///
/// Generic — knows nothing about Mermaid, DOT, or any diagram format.
enum SugiyamaLayout {

    static func layout(_ input: GraphLayoutInput) -> GraphLayoutResult {
        guard !input.nodes.isEmpty else {
            return GraphLayoutResult(nodePositions: [:], edgePaths: [], totalSize: .zero)
        }

        let nodeMap = Dictionary(uniqueKeysWithValues: input.nodes.map { ($0.id, $0) })
        let nodeIds = input.nodes.map(\.id)

        // Build adjacency from edges, filtering out references to unknown nodes.
        var adjacency: [String: [String]] = [:]
        var reverseAdj: [String: [String]] = [:]
        for id in nodeIds {
            adjacency[id] = []
            reverseAdj[id] = []
        }
        let validEdges = input.edges.filter { nodeMap[$0.from] != nil && nodeMap[$0.to] != nil }
        for edge in validEdges {
            adjacency[edge.from, default: []].append(edge.to)
            reverseAdj[edge.to, default: []].append(edge.from)
        }

        // Phase 1: Cycle removal — reverse back-edges.
        let acyclicEdges = removeBackEdges(nodeIds: nodeIds, edges: validEdges, adjacency: adjacency)
        var acyclicAdj: [String: [String]] = [:]
        var acyclicRev: [String: [String]] = [:]
        for id in nodeIds {
            acyclicAdj[id] = []
            acyclicRev[id] = []
        }
        for edge in acyclicEdges {
            acyclicAdj[edge.from, default: []].append(edge.to)
            acyclicRev[edge.to, default: []].append(edge.from)
        }

        // Phase 2: Layer assignment — longest path from sources.
        let layers = assignLayers(nodeIds: nodeIds, adjacency: acyclicAdj, reverseAdj: acyclicRev)

        // Phase 3: Crossing minimization — barycenter heuristic.
        let orderedLayers = minimizeCrossings(layers: layers, adjacency: acyclicAdj, reverseAdj: acyclicRev)

        // Phase 4: Coordinate assignment.
        var layerIndexById: [String: Int] = [:]
        for (index, layer) in orderedLayers.enumerated() {
            for id in layer { layerIndexById[id] = index }
        }
        var rankGaps = [CGFloat](repeating: input.rankSpacing, count: max(orderedLayers.count - 1, 0))
        for edge in acyclicEdges where edge.minRankGap > input.rankSpacing {
            guard let a = layerIndexById[edge.from], let b = layerIndexById[edge.to] else { continue }
            for gap in min(a, b) ..< max(a, b) {
                rankGaps[gap] = max(rankGaps[gap], edge.minRankGap)
            }
        }
        let positions = assignCoordinates(
            layers: orderedLayers,
            nodeMap: nodeMap,
            adjacency: acyclicAdj,
            reverseAdj: acyclicRev,
            direction: input.direction,
            nodeSpacing: input.nodeSpacing,
            rankGaps: rankGaps
        )

        // Phase 5: Edge routing.
        let edgePaths = routeEdges(
            originalEdges: validEdges,
            positions: positions,
            nodeMap: nodeMap,
            direction: input.direction
        )

        // Compute bounding box.
        var maxX: CGFloat = 0
        var maxY: CGFloat = 0
        for rect in positions.values {
            maxX = max(maxX, rect.maxX)
            maxY = max(maxY, rect.maxY)
        }

        return GraphLayoutResult(
            nodePositions: positions,
            edgePaths: edgePaths,
            totalSize: CGSize(width: maxX, height: maxY)
        )
    }

    // MARK: - Phase 1: Cycle removal

    /// Remove back-edges by DFS. Back-edges are reversed so the graph becomes acyclic.
    private static func removeBackEdges(
        nodeIds: [String],
        edges: [GraphLayoutEdge],
        adjacency: [String: [String]]
    ) -> [GraphLayoutEdge] {
        enum Color { case white, gray, black }
        var color: [String: Color] = [:]
        for id in nodeIds { color[id] = .white }
        var backEdges: Set<String> = [] // "from->to" keys

        func dfs(_ u: String) {
            color[u] = .gray
            for v in adjacency[u] ?? [] {
                switch color[v] {
                case .white:
                    dfs(v)
                case .gray:
                    backEdges.insert("\(u)->\(v)")
                case .black, .none:
                    break
                }
            }
            color[u] = .black
        }

        // Input order, like dagre's DFS acyclicer: with source-ordered nodes,
        // an authored loop back to an earlier step is the reversed edge.
        for id in nodeIds where color[id] == .white {
            dfs(id)
        }

        return edges.map { edge in
            if backEdges.contains("\(edge.from)->\(edge.to)") {
                return GraphLayoutEdge(from: edge.to, to: edge.from, minRankGap: edge.minRankGap)
            }
            return edge
        }
    }

    // MARK: - Phase 2: Layer assignment

    /// Assign layers using longest-path-from-sources method.
    /// Returns layers as [[nodeId]], layer 0 is the top/left.
    private static func assignLayers(
        nodeIds: [String],
        adjacency: [String: [String]],
        reverseAdj: [String: [String]]
    ) -> [[String]] {
        // Kahn topological traversal with longest-path relaxation. A plain BFS
        // can process a converging node before its deepest predecessor and then
        // fail to propagate the corrected depth to that node's descendants.
        var indegree = Dictionary(uniqueKeysWithValues: nodeIds.map {
            ($0, (reverseAdj[$0] ?? []).count)
        })
        var depth = Dictionary(uniqueKeysWithValues: nodeIds.map { ($0, 0) })
        var queue = nodeIds.filter { indegree[$0] == 0 }
        var head = 0

        while head < queue.count {
            let nodeId = queue[head]
            head += 1
            for successor in adjacency[nodeId] ?? [] {
                depth[successor] = max(depth[successor] ?? 0, (depth[nodeId] ?? 0) + 1)
                indegree[successor, default: 0] -= 1
                if indegree[successor] == 0 {
                    queue.append(successor)
                }
            }
        }

        // Cycle removal should make every component acyclic. Keep malformed or
        // disconnected leftovers visible at layer zero rather than dropping them.
        if head < nodeIds.count {
            let processed = Set(queue)
            for id in nodeIds where !processed.contains(id) {
                depth[id] = 0
            }
        }

        // Group by layer.
        let maxLayer = depth.values.max() ?? 0
        var layers: [[String]] = Array(repeating: [], count: maxLayer + 1)
        for id in nodeIds {
            layers[depth[id] ?? 0].append(id)
        }

        return layers
    }

    // MARK: - Phase 3: Crossing minimization

    /// Barycenter heuristic — reorder nodes within each layer to reduce edge crossings.
    /// Runs 3 down-sweep passes (good enough for most diagrams).
    private static func minimizeCrossings(
        layers: [[String]],
        adjacency: [String: [String]],
        reverseAdj: [String: [String]]
    ) -> [[String]] {
        guard layers.count > 1 else { return layers }

        var result = layers

        // Build position indices for barycenter computation.
        for _ in 0 ..< 3 {
            // Down sweep: fix layer i, reorder layer i+1
            for i in 0 ..< (result.count - 1) {
                let fixedPositions = Dictionary(uniqueKeysWithValues:
                    result[i].enumerated().map { ($0.element, Double($0.offset)) }
                )
                result[i + 1] = reorderByBarycenter(
                    layer: result[i + 1],
                    neighborPositions: fixedPositions,
                    getNeighbors: { reverseAdj[$0] ?? [] }
                )
            }

            // Up sweep: fix layer i+1, reorder layer i
            for i in stride(from: result.count - 1, through: 1, by: -1) {
                let fixedPositions = Dictionary(uniqueKeysWithValues:
                    result[i].enumerated().map { ($0.element, Double($0.offset)) }
                )
                result[i - 1] = reorderByBarycenter(
                    layer: result[i - 1],
                    neighborPositions: fixedPositions,
                    getNeighbors: { adjacency[$0] ?? [] }
                )
            }
        }

        return result
    }

    /// Reorder a layer's nodes by the average position of their neighbors in the adjacent layer.
    private static func reorderByBarycenter(
        layer: [String],
        neighborPositions: [String: Double],
        getNeighbors: (String) -> [String]
    ) -> [String] {
        var barycenters: [(String, Double)] = []
        for (originalIndex, nodeId) in layer.enumerated() {
            let neighbors = getNeighbors(nodeId)
            let positions = neighbors.compactMap { neighborPositions[$0] }
            if positions.isEmpty {
                // No neighbors — keep original relative position.
                barycenters.append((nodeId, Double(originalIndex)))
            } else {
                let avg = positions.reduce(0, +) / Double(positions.count)
                barycenters.append((nodeId, avg))
            }
        }
        // Stable sort by barycenter value.
        barycenters.sort { $0.1 < $1.1 }
        return barycenters.map(\.0)
    }

    // MARK: - Phase 4: Coordinate assignment

    /// Assign x/y positions to nodes.
    ///
    /// Cross axis: each node moves toward the median of its neighbors while
    /// its rank keeps order and spacing. Alternating sweeps keep chains
    /// straight and center parents over their children instead of centering
    /// every rank on the widest one. Main axis: nodes center in their rank.
    private static func assignCoordinates(
        layers: [[String]],
        nodeMap: [String: GraphLayoutNode],
        adjacency: [String: [String]],
        reverseAdj: [String: [String]],
        direction: GraphLayoutDirection,
        nodeSpacing: CGFloat,
        rankGaps: [CGFloat]
    ) -> [String: CGRect] {
        let isHorizontal = direction == .leftToRight || direction == .rightToLeft
        func size(_ id: String) -> CGSize { nodeMap[id]?.size ?? CGSize(width: 40, height: 30) }
        func crossSize(_ id: String) -> CGFloat { isHorizontal ? size(id).height : size(id).width }
        func mainSize(_ id: String) -> CGFloat { isHorizontal ? size(id).width : size(id).height }

        var center: [String: CGFloat] = [:]
        for layer in layers {
            let span = layer.map(crossSize).reduce(0, +)
                + nodeSpacing * CGFloat(max(layer.count - 1, 0))
            var cursor = -span / 2
            for id in layer {
                center[id] = cursor + crossSize(id) / 2
                cursor += crossSize(id) + nodeSpacing
            }
        }

        /// Median target toward one side, weighted 4 for a one-to-one chain
        /// link: keeping chains straight matters more than centering a node
        /// among several neighbors.
        func pull(
            _ id: String,
            toward neighbors: (String) -> [String],
            back: (String) -> [String]
        ) -> (target: CGFloat, weight: CGFloat)? {
            let ids = neighbors(id)
            let positions = ids.compactMap { center[$0] }.sorted()
            guard !positions.isEmpty else { return nil }
            let mid = positions.count / 2
            let target = positions.count.isMultiple(of: 2)
                ? (positions[mid - 1] + positions[mid]) / 2
                : positions[mid]
            let isChainLink = ids.count == 1 && back(ids[0]).count == 1
            return (target, isChainLink ? 4 : 1)
        }
        let preds: (String) -> [String] = { reverseAdj[$0] ?? [] }
        let succs: (String) -> [String] = { adjacency[$0] ?? [] }

        enum Pull { case up, down, both }
        func align(_ layerIndex: Int, _ mode: Pull) {
            let layer = layers[layerIndex]
            var desired: [CGFloat] = []
            var weights: [CGFloat] = []
            for id in layer {
                let pulls = [
                    mode == .down ? nil : pull(id, toward: preds, back: succs),
                    mode == .up ? nil : pull(id, toward: succs, back: preds),
                ].compactMap { $0 }
                let weight = pulls.reduce(0) { $0 + $1.weight }
                guard weight > 0 else {
                    // Free node: hold position, but yield to aligned peers.
                    desired.append(center[id] ?? 0)
                    weights.append(0.25)
                    continue
                }
                desired.append(pulls.reduce(0) { $0 + $1.target * $1.weight } / weight)
                weights.append(weight)
            }
            let placed = placeRank(
                desired: desired,
                weights: weights,
                sizes: layer.map(crossSize),
                gap: nodeSpacing
            )
            for (id, value) in zip(layer, placed) {
                center[id] = value
            }
        }

        // One-sided sweeps settle groups under parents and parents over
        // children; the final two-sided sweeps balance both.
        if layers.count > 1 {
            for iteration in 0 ..< 5 {
                let final = iteration >= 3
                for index in 1 ..< layers.count {
                    align(index, final ? .both : .up)
                }
                for index in stride(from: layers.count - 2, through: 0, by: -1) {
                    align(index, final ? .both : .down)
                }
            }
        }

        let minCross = layers.flatMap { $0 }
            .map { (center[$0] ?? 0) - crossSize($0) / 2 }
            .min() ?? 0

        let reversed = direction == .bottomToTop || direction == .rightToLeft
        let layerOrder: [Int] = reversed
            ? Array((0 ..< layers.count).reversed())
            : Array(0 ..< layers.count)

        var positions: [String: CGRect] = [:]
        var rankOffset: CGFloat = 0
        for layerIndex in layerOrder {
            let layer = layers[layerIndex]
            let thickness = layer.map(mainSize).max() ?? 0
            for id in layer {
                let nodeSize = size(id)
                let crossStart = (center[id] ?? 0) - crossSize(id) / 2 - minCross
                let mainStart = rankOffset + (thickness - mainSize(id)) / 2
                positions[id] = isHorizontal
                    ? CGRect(x: mainStart, y: crossStart, width: nodeSize.width, height: nodeSize.height)
                    : CGRect(x: crossStart, y: mainStart, width: nodeSize.width, height: nodeSize.height)
            }
            let gapIndex = reversed ? layerIndex - 1 : layerIndex
            rankOffset += thickness + (rankGaps.indices.contains(gapIndex) ? rankGaps[gapIndex] : 0)
        }

        return positions
    }

    /// Weighted least-squares placement of one rank: centers as close as
    /// possible to `desired` while keeping order and `gap` between neighbors.
    /// Exact via pool-adjacent-violators on gap-shifted coordinates.
    private static func placeRank(
        desired: [CGFloat],
        weights: [CGFloat],
        sizes: [CGFloat],
        gap: CGFloat
    ) -> [CGFloat] {
        guard !desired.isEmpty else { return [] }
        var offsets = [CGFloat](repeating: 0, count: desired.count)
        for index in 1 ..< max(desired.count, 1) {
            offsets[index] = offsets[index - 1] + (sizes[index - 1] + sizes[index]) / 2 + gap
        }
        var blocks: [(weightedSum: CGFloat, weight: CGFloat, count: Int)] = []
        for index in desired.indices {
            let weight = weights[index]
            var block = (weightedSum: (desired[index] - offsets[index]) * weight, weight: weight, count: 1)
            while let last = blocks.last,
                  last.weightedSum / last.weight > block.weightedSum / block.weight {
                block = (
                    last.weightedSum + block.weightedSum,
                    last.weight + block.weight,
                    last.count + block.count
                )
                blocks.removeLast()
            }
            blocks.append(block)
        }
        var result: [CGFloat] = []
        result.reserveCapacity(desired.count)
        for block in blocks {
            let mean = block.weightedSum / block.weight
            for _ in 0 ..< block.count {
                result.append(mean + offsets[result.count])
            }
        }
        return result
    }

    // MARK: - Phase 5: Edge routing

    /// Route edges as polylines. For same-layer or adjacent-layer edges, use direct lines.
    /// For multi-layer edges, add waypoints at each intermediate layer boundary.
    private static func routeEdges(
        originalEdges: [GraphLayoutEdge],
        positions: [String: CGRect],
        nodeMap: [String: GraphLayoutNode],
        direction: GraphLayoutDirection
    ) -> [GraphLayoutEdgePath] {
        let isHorizontal = direction == .leftToRight || direction == .rightToLeft

        return originalEdges.compactMap { edge in
            guard let fromRect = positions[edge.from],
                  let toRect = positions[edge.to] else { return nil }

            let fromCenter = CGPoint(x: fromRect.midX, y: fromRect.midY)
            let toCenter = CGPoint(x: toRect.midX, y: toRect.midY)

            // Compute connection points at node boundaries.
            let fromPoint: CGPoint
            let toPoint: CGPoint

            if isHorizontal {
                // Connect at left/right edges of nodes.
                if fromCenter.x < toCenter.x {
                    fromPoint = CGPoint(x: fromRect.maxX, y: fromRect.midY)
                    toPoint = CGPoint(x: toRect.minX, y: toRect.midY)
                } else {
                    fromPoint = CGPoint(x: fromRect.minX, y: fromRect.midY)
                    toPoint = CGPoint(x: toRect.maxX, y: toRect.midY)
                }
            } else {
                // Connect at top/bottom edges of nodes.
                if fromCenter.y < toCenter.y {
                    fromPoint = CGPoint(x: fromRect.midX, y: fromRect.maxY)
                    toPoint = CGPoint(x: toRect.midX, y: toRect.minY)
                } else {
                    fromPoint = CGPoint(x: fromRect.midX, y: fromRect.minY)
                    toPoint = CGPoint(x: toRect.midX, y: toRect.maxY)
                }
            }

            // For edges that need bends (different cross-axis position),
            // add a midpoint waypoint for an orthogonal route.
            var points = [fromPoint]

            let needsBend: Bool
            if isHorizontal {
                needsBend = abs(fromPoint.y - toPoint.y) > 1
            } else {
                needsBend = abs(fromPoint.x - toPoint.x) > 1
            }

            if needsBend {
                let midRank: CGFloat
                if isHorizontal {
                    midRank = (fromPoint.x + toPoint.x) / 2
                    points.append(CGPoint(x: midRank, y: fromPoint.y))
                    points.append(CGPoint(x: midRank, y: toPoint.y))
                } else {
                    midRank = (fromPoint.y + toPoint.y) / 2
                    points.append(CGPoint(x: fromPoint.x, y: midRank))
                    points.append(CGPoint(x: toPoint.x, y: midRank))
                }
            }

            points.append(toPoint)

            return GraphLayoutEdgePath(from: edge.from, to: edge.to, points: points)
        }
    }
}
