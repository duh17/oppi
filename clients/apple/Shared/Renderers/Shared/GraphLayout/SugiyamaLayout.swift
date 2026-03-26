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
        let positions = assignCoordinates(
            layers: orderedLayers,
            nodeMap: nodeMap,
            direction: input.direction,
            nodeSpacing: input.nodeSpacing,
            rankSpacing: input.rankSpacing
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

        for id in nodeIds where color[id] == .white {
            dfs(id)
        }

        return edges.map { edge in
            if backEdges.contains("\(edge.from)->\(edge.to)") {
                return GraphLayoutEdge(from: edge.to, to: edge.from)
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
        // Find sources (no incoming edges in acyclic graph).
        let sources = nodeIds.filter { (reverseAdj[$0] ?? []).isEmpty }

        // BFS/topological longest path.
        var depth: [String: Int] = [:]
        for id in nodeIds { depth[id] = 0 }

        // If no sources (all nodes in a cycle that got fully reversed), pick arbitrary start.
        let startNodes = sources.isEmpty ? [nodeIds[0]] : sources

        var queue = startNodes
        for s in startNodes { depth[s] = 0 }

        var visited: Set<String> = Set(startNodes)
        var head = 0
        while head < queue.count {
            let u = queue[head]
            head += 1
            for v in adjacency[u] ?? [] {
                let newDepth = (depth[u] ?? 0) + 1
                if newDepth > (depth[v] ?? 0) {
                    depth[v] = newDepth
                }
                if !visited.contains(v) {
                    visited.insert(v)
                    queue.append(v)
                }
            }
        }

        // Assign unvisited disconnected nodes to layer 0.
        for id in nodeIds where !visited.contains(id) {
            depth[id] = 0
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

    /// Assign x/y positions to nodes. Centers each layer and spaces nodes evenly.
    private static func assignCoordinates(
        layers: [[String]],
        nodeMap: [String: GraphLayoutNode],
        direction: GraphLayoutDirection,
        nodeSpacing: CGFloat,
        rankSpacing: CGFloat
    ) -> [String: CGRect] {
        let isHorizontal = direction == .leftToRight || direction == .rightToLeft

        // Compute the width of each layer (max node size along the cross axis)
        // and total span along the cross axis for centering.
        struct NodeMetrics {
            let id: String
            let mainSize: CGFloat
            let crossSize: CGFloat
        }

        struct LayerMetrics {
            let rankThickness: CGFloat  // size along rank axis (height for TB, width for LR)
            let crossSpan: CGFloat      // total span along cross axis
            let nodeSizes: [NodeMetrics]
        }

        var metrics: [LayerMetrics] = []
        for layer in layers {
            var rankThickness: CGFloat = 0
            var crossSpan: CGFloat = 0
            var sizes: [NodeMetrics] = []
            for (i, id) in layer.enumerated() {
                let size = nodeMap[id]?.size ?? CGSize(width: 40, height: 30)
                let main = isHorizontal ? size.width : size.height
                let cross = isHorizontal ? size.height : size.width
                rankThickness = max(rankThickness, main)
                crossSpan += cross
                if i > 0 { crossSpan += nodeSpacing }
                sizes.append(NodeMetrics(id: id, mainSize: main, crossSize: cross))
            }
            metrics.append(LayerMetrics(rankThickness: rankThickness, crossSpan: crossSpan, nodeSizes: sizes))
        }

        // Find max cross span to center narrower layers.
        let maxCrossSpan = metrics.map(\.crossSpan).max() ?? 0

        // Lay out each layer.
        var positions: [String: CGRect] = [:]
        var rankOffset: CGFloat = 0

        let layerOrder: [Int]
        switch direction {
        case .bottomToTop:
            layerOrder = Array((0 ..< layers.count).reversed())
        case .rightToLeft:
            layerOrder = Array((0 ..< layers.count).reversed())
        default:
            layerOrder = Array(0 ..< layers.count)
        }

        for layerIdx in layerOrder {
            let m = metrics[layerIdx]
            // Center this layer within the max cross span.
            var crossOffset = (maxCrossSpan - m.crossSpan) / 2

            for nm in m.nodeSizes {
                let id = nm.id
                let crossSize = nm.crossSize
                let nodeSize = nodeMap[id]?.size ?? CGSize(width: 40, height: 30)
                let rect: CGRect
                if isHorizontal {
                    // rank axis = x, cross axis = y
                    rect = CGRect(x: rankOffset, y: crossOffset, width: nodeSize.width, height: nodeSize.height)
                } else {
                    // rank axis = y, cross axis = x
                    rect = CGRect(x: crossOffset, y: rankOffset, width: nodeSize.width, height: nodeSize.height)
                }
                positions[id] = rect
                crossOffset += crossSize + nodeSpacing
            }

            rankOffset += m.rankThickness + rankSpacing
        }

        return positions
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
