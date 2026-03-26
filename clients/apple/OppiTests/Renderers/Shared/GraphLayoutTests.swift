import CoreGraphics
import Testing
@testable import Oppi

/// Tests for the generic Sugiyama graph layout engine.
///
/// Validates all five phases: cycle removal, layer assignment,
/// crossing minimization, coordinate assignment, edge routing.
@Suite("Graph Layout")
struct GraphLayoutTests {

    // MARK: - Empty and trivial graphs

    @Test func emptyGraph() {
        let input = GraphLayoutInput(
            nodes: [], edges: [], direction: .topToBottom,
            nodeSpacing: 20, rankSpacing: 40
        )
        let result = SugiyamaLayout.layout(input)
        #expect(result.nodePositions.isEmpty)
        #expect(result.edgePaths.isEmpty)
        #expect(result.totalSize == .zero)
    }

    @Test func singleNode() {
        let input = GraphLayoutInput(
            nodes: [GraphLayoutNode(id: "A", size: CGSize(width: 80, height: 40))],
            edges: [],
            direction: .topToBottom,
            nodeSpacing: 20,
            rankSpacing: 40
        )
        let result = SugiyamaLayout.layout(input)
        #expect(result.nodePositions.count == 1)
        let rect = result.nodePositions["A"]!
        #expect(rect.width == 80)
        #expect(rect.height == 40)
        #expect(result.totalSize.width > 0)
        #expect(result.totalSize.height > 0)
    }

    // MARK: - Linear chains

    @Test func twoNodeChain() {
        let input = GraphLayoutInput(
            nodes: [
                GraphLayoutNode(id: "A", size: CGSize(width: 60, height: 30)),
                GraphLayoutNode(id: "B", size: CGSize(width: 60, height: 30)),
            ],
            edges: [GraphLayoutEdge(from: "A", to: "B")],
            direction: .topToBottom,
            nodeSpacing: 20,
            rankSpacing: 40
        )
        let result = SugiyamaLayout.layout(input)
        #expect(result.nodePositions.count == 2)

        let a = result.nodePositions["A"]!
        let b = result.nodePositions["B"]!
        // A should be above B (lower Y).
        #expect(a.midY < b.midY)
        // No overlap.
        #expect(a.maxY <= b.minY)
    }

    @Test func threeNodeChain() {
        let input = GraphLayoutInput(
            nodes: [
                GraphLayoutNode(id: "A", size: CGSize(width: 60, height: 30)),
                GraphLayoutNode(id: "B", size: CGSize(width: 60, height: 30)),
                GraphLayoutNode(id: "C", size: CGSize(width: 60, height: 30)),
            ],
            edges: [
                GraphLayoutEdge(from: "A", to: "B"),
                GraphLayoutEdge(from: "B", to: "C"),
            ],
            direction: .topToBottom,
            nodeSpacing: 20,
            rankSpacing: 40
        )
        let result = SugiyamaLayout.layout(input)
        let a = result.nodePositions["A"]!
        let b = result.nodePositions["B"]!
        let c = result.nodePositions["C"]!

        // Layer ordering: A < B < C vertically.
        #expect(a.midY < b.midY)
        #expect(b.midY < c.midY)
    }

    // MARK: - Diamond pattern

    @Test func diamondPattern() {
        // A -> B, A -> C, B -> D, C -> D
        let input = GraphLayoutInput(
            nodes: [
                GraphLayoutNode(id: "A", size: CGSize(width: 60, height: 30)),
                GraphLayoutNode(id: "B", size: CGSize(width: 60, height: 30)),
                GraphLayoutNode(id: "C", size: CGSize(width: 60, height: 30)),
                GraphLayoutNode(id: "D", size: CGSize(width: 60, height: 30)),
            ],
            edges: [
                GraphLayoutEdge(from: "A", to: "B"),
                GraphLayoutEdge(from: "A", to: "C"),
                GraphLayoutEdge(from: "B", to: "D"),
                GraphLayoutEdge(from: "C", to: "D"),
            ],
            direction: .topToBottom,
            nodeSpacing: 20,
            rankSpacing: 40
        )
        let result = SugiyamaLayout.layout(input)

        let a = result.nodePositions["A"]!
        let b = result.nodePositions["B"]!
        let c = result.nodePositions["C"]!
        let d = result.nodePositions["D"]!

        // A is top layer, B and C are middle, D is bottom.
        #expect(a.midY < b.midY)
        #expect(a.midY < c.midY)
        #expect(b.midY < d.midY)
        #expect(c.midY < d.midY)

        // B and C should be on the same layer (same Y).
        #expect(abs(b.midY - c.midY) < 1)

        // B and C should not overlap horizontally.
        let leftNode = b.minX < c.minX ? b : c
        let rightNode = b.minX < c.minX ? c : b
        #expect(leftNode.maxX <= rightNode.minX)
    }

    // MARK: - Direction

    @Test func leftToRightDirection() {
        let input = GraphLayoutInput(
            nodes: [
                GraphLayoutNode(id: "A", size: CGSize(width: 60, height: 30)),
                GraphLayoutNode(id: "B", size: CGSize(width: 60, height: 30)),
            ],
            edges: [GraphLayoutEdge(from: "A", to: "B")],
            direction: .leftToRight,
            nodeSpacing: 20,
            rankSpacing: 40
        )
        let result = SugiyamaLayout.layout(input)
        let a = result.nodePositions["A"]!
        let b = result.nodePositions["B"]!

        // A should be to the left of B.
        #expect(a.midX < b.midX)
        // No horizontal overlap.
        #expect(a.maxX <= b.minX)
    }

    @Test func directionAffectsCoordinateAxes() {
        let nodesTB = [
            GraphLayoutNode(id: "A", size: CGSize(width: 60, height: 30)),
            GraphLayoutNode(id: "B", size: CGSize(width: 60, height: 30)),
        ]
        let edge = [GraphLayoutEdge(from: "A", to: "B")]

        let tbResult = SugiyamaLayout.layout(GraphLayoutInput(
            nodes: nodesTB, edges: edge, direction: .topToBottom,
            nodeSpacing: 20, rankSpacing: 40
        ))
        let lrResult = SugiyamaLayout.layout(GraphLayoutInput(
            nodes: nodesTB, edges: edge, direction: .leftToRight,
            nodeSpacing: 20, rankSpacing: 40
        ))

        let tbA = tbResult.nodePositions["A"]!
        let tbB = tbResult.nodePositions["B"]!
        let lrA = lrResult.nodePositions["A"]!
        let lrB = lrResult.nodePositions["B"]!

        // TB: same X, different Y.
        #expect(abs(tbA.midX - tbB.midX) < 1)
        #expect(tbA.midY < tbB.midY)

        // LR: same Y, different X.
        #expect(abs(lrA.midY - lrB.midY) < 1)
        #expect(lrA.midX < lrB.midX)
    }

    // MARK: - Node sizes respected

    @Test func nodeSizesRespected() {
        let input = GraphLayoutInput(
            nodes: [
                GraphLayoutNode(id: "A", size: CGSize(width: 100, height: 50)),
                GraphLayoutNode(id: "B", size: CGSize(width: 200, height: 80)),
            ],
            edges: [GraphLayoutEdge(from: "A", to: "B")],
            direction: .topToBottom,
            nodeSpacing: 20,
            rankSpacing: 40
        )
        let result = SugiyamaLayout.layout(input)
        let a = result.nodePositions["A"]!
        let b = result.nodePositions["B"]!

        #expect(a.width == 100)
        #expect(a.height == 50)
        #expect(b.width == 200)
        #expect(b.height == 80)
    }

    // MARK: - Edge paths

    @Test func edgePathsHaveCorrectEndpoints() {
        let input = GraphLayoutInput(
            nodes: [
                GraphLayoutNode(id: "A", size: CGSize(width: 60, height: 30)),
                GraphLayoutNode(id: "B", size: CGSize(width: 60, height: 30)),
            ],
            edges: [GraphLayoutEdge(from: "A", to: "B")],
            direction: .topToBottom,
            nodeSpacing: 20,
            rankSpacing: 40
        )
        let result = SugiyamaLayout.layout(input)
        #expect(result.edgePaths.count == 1)

        let path = result.edgePaths[0]
        #expect(path.from == "A")
        #expect(path.to == "B")
        #expect(path.points.count >= 2)

        let a = result.nodePositions["A"]!
        let b = result.nodePositions["B"]!

        // First point should be near A's boundary.
        let firstPoint = path.points.first!
        #expect(abs(firstPoint.x - a.midX) < a.width)
        #expect(abs(firstPoint.y - a.midY) < a.height)

        // Last point should be near B's boundary.
        let lastPoint = path.points.last!
        #expect(abs(lastPoint.x - b.midX) < b.width)
        #expect(abs(lastPoint.y - b.midY) < b.height)
    }

    // MARK: - Cycles

    @Test func cycleDoesNotCrash() {
        let input = GraphLayoutInput(
            nodes: [
                GraphLayoutNode(id: "A", size: CGSize(width: 60, height: 30)),
                GraphLayoutNode(id: "B", size: CGSize(width: 60, height: 30)),
            ],
            edges: [
                GraphLayoutEdge(from: "A", to: "B"),
                GraphLayoutEdge(from: "B", to: "A"),
            ],
            direction: .topToBottom,
            nodeSpacing: 20,
            rankSpacing: 40
        )
        let result = SugiyamaLayout.layout(input)
        // Both nodes should be positioned without crashing.
        #expect(result.nodePositions.count == 2)
        #expect(result.nodePositions["A"] != nil)
        #expect(result.nodePositions["B"] != nil)
    }

    @Test func threeNodeCycle() {
        let input = GraphLayoutInput(
            nodes: [
                GraphLayoutNode(id: "A", size: CGSize(width: 60, height: 30)),
                GraphLayoutNode(id: "B", size: CGSize(width: 60, height: 30)),
                GraphLayoutNode(id: "C", size: CGSize(width: 60, height: 30)),
            ],
            edges: [
                GraphLayoutEdge(from: "A", to: "B"),
                GraphLayoutEdge(from: "B", to: "C"),
                GraphLayoutEdge(from: "C", to: "A"),
            ],
            direction: .topToBottom,
            nodeSpacing: 20,
            rankSpacing: 40
        )
        let result = SugiyamaLayout.layout(input)
        #expect(result.nodePositions.count == 3)
    }

    // MARK: - Disconnected nodes

    @Test func disconnectedNodesAllPositioned() {
        let input = GraphLayoutInput(
            nodes: [
                GraphLayoutNode(id: "A", size: CGSize(width: 60, height: 30)),
                GraphLayoutNode(id: "B", size: CGSize(width: 60, height: 30)),
                GraphLayoutNode(id: "C", size: CGSize(width: 60, height: 30)),
            ],
            edges: [], // No edges — all disconnected.
            direction: .topToBottom,
            nodeSpacing: 20,
            rankSpacing: 40
        )
        let result = SugiyamaLayout.layout(input)
        #expect(result.nodePositions.count == 3)
        #expect(result.nodePositions["A"] != nil)
        #expect(result.nodePositions["B"] != nil)
        #expect(result.nodePositions["C"] != nil)

        // All should be on the same layer (same Y).
        let yValues = result.nodePositions.values.map { $0.midY }
        #expect(abs(yValues[0] - yValues[1]) < 1)
        #expect(abs(yValues[1] - yValues[2]) < 1)
    }

    @Test func disconnectedNodesNoOverlap() {
        let input = GraphLayoutInput(
            nodes: [
                GraphLayoutNode(id: "A", size: CGSize(width: 80, height: 40)),
                GraphLayoutNode(id: "B", size: CGSize(width: 80, height: 40)),
            ],
            edges: [],
            direction: .topToBottom,
            nodeSpacing: 20,
            rankSpacing: 40
        )
        let result = SugiyamaLayout.layout(input)
        let a = result.nodePositions["A"]!
        let b = result.nodePositions["B"]!

        // Should not overlap.
        let overlaps = a.intersects(b)
        #expect(!overlaps)
    }
}
