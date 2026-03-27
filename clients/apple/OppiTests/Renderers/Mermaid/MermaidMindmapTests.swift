import CoreGraphics
import Testing
@testable import Oppi

// MARK: - Parser Tests

@Suite("Mermaid Mindmap Parser")
struct MermaidMindmapParserTests {

    // MARK: - Root parsing

    @Test func singleRootNode() {
        let diagram = MermaidMindmapParser.parse(lines: ["  root"])
        #expect(diagram.root.label == "root")
        #expect(diagram.root.shape == .default)
        #expect(diagram.root.children.isEmpty)
    }

    @Test func rootWithCircleShape() {
        let diagram = MermaidMindmapParser.parse(lines: ["  ((Central Idea))"])
        #expect(diagram.root.label == "Central Idea")
        #expect(diagram.root.shape == .circle)
    }

    @Test func rootWithSquareShape() {
        let diagram = MermaidMindmapParser.parse(lines: ["  [Project]"])
        #expect(diagram.root.label == "Project")
        #expect(diagram.root.shape == .square)
    }

    @Test func emptyLinesProduceEmptyDiagram() {
        let diagram = MermaidMindmapParser.parse(lines: ["", "  ", ""])
        #expect(diagram.root.label == "")
        #expect(diagram == .empty)
    }

    // MARK: - Children by indent

    @Test func singleChild() {
        let diagram = MermaidMindmapParser.parse(lines: [
            "  root",
            "    Child A",
        ])
        #expect(diagram.root.children.count == 1)
        #expect(diagram.root.children[0].label == "Child A")
    }

    @Test func twoChildrenSameLevel() {
        let diagram = MermaidMindmapParser.parse(lines: [
            "  root",
            "    Branch A",
            "    Branch B",
        ])
        #expect(diagram.root.children.count == 2)
        #expect(diagram.root.children[0].label == "Branch A")
        #expect(diagram.root.children[1].label == "Branch B")
    }

    @Test func childrenDetermiedByRelativeIndent() {
        // 4-space indent for root, 8-space for children
        let diagram = MermaidMindmapParser.parse(lines: [
            "    root",
            "        Child 1",
            "        Child 2",
        ])
        #expect(diagram.root.children.count == 2)
    }

    // MARK: - Deep nesting

    @Test func threeDeepNesting() {
        let diagram = MermaidMindmapParser.parse(lines: [
            "  root",
            "    Branch",
            "      Leaf",
            "        Sub-leaf",
        ])
        #expect(diagram.root.children.count == 1)
        let branch = diagram.root.children[0]
        #expect(branch.label == "Branch")
        #expect(branch.children.count == 1)

        let leaf = branch.children[0]
        #expect(leaf.label == "Leaf")
        #expect(leaf.children.count == 1)

        let subLeaf = leaf.children[0]
        #expect(subLeaf.label == "Sub-leaf")
        #expect(subLeaf.children.isEmpty)
    }

    @Test func mixedDepthsWithSiblings() {
        let diagram = MermaidMindmapParser.parse(lines: [
            "  root",
            "    Branch A",
            "      Leaf 1",
            "      Leaf 2",
            "    Branch B",
            "      Leaf 3",
        ])
        #expect(diagram.root.children.count == 2)

        let branchA = diagram.root.children[0]
        #expect(branchA.children.count == 2)
        #expect(branchA.children[0].label == "Leaf 1")
        #expect(branchA.children[1].label == "Leaf 2")

        let branchB = diagram.root.children[1]
        #expect(branchB.children.count == 1)
        #expect(branchB.children[0].label == "Leaf 3")
    }

    // MARK: - Shape parsing

    @Test func allNodeShapes() {
        let lines = [
            "  root",
            "    plain text",
            "    [square node]",
            "    (rounded node)",
            "    ((circle node))",
            "    ))bang node((",
            "    )hexagon node(",
        ]
        let diagram = MermaidMindmapParser.parse(lines: lines)
        let children = diagram.root.children
        #expect(children.count == 6)

        #expect(children[0].label == "plain text")
        #expect(children[0].shape == .default)

        #expect(children[1].label == "square node")
        #expect(children[1].shape == .square)

        #expect(children[2].label == "rounded node")
        #expect(children[2].shape == .rounded)

        #expect(children[3].label == "circle node")
        #expect(children[3].shape == .circle)

        #expect(children[4].label == "bang node")
        #expect(children[4].shape == .bang)

        #expect(children[5].label == "hexagon node")
        #expect(children[5].shape == .hexagon)
    }

    @Test func rootShapePreserved() {
        let diagram = MermaidMindmapParser.parse(lines: ["  ))Cloud Root((" ])
        #expect(diagram.root.label == "Cloud Root")
        #expect(diagram.root.shape == .bang)
    }

    // MARK: - Empty lines and whitespace

    @Test func emptyLinesSkipped() {
        let diagram = MermaidMindmapParser.parse(lines: [
            "  root",
            "",
            "    Branch A",
            "  ",
            "    Branch B",
        ])
        #expect(diagram.root.children.count == 2)
    }

    @Test func tabIndentation() {
        let diagram = MermaidMindmapParser.parse(lines: [
            "\troot",
            "\t\tChild",
        ])
        #expect(diagram.root.label == "root")
        #expect(diagram.root.children.count == 1)
        #expect(diagram.root.children[0].label == "Child")
    }

    // MARK: - Edge cases

    @Test func singleLineIsRootOnly() {
        let diagram = MermaidMindmapParser.parse(lines: ["root"])
        #expect(diagram.root.label == "root")
        #expect(diagram.root.children.isEmpty)
    }

    @Test func complexTree() {
        let lines = [
            "  root((Central Idea))",
            "    Branch A",
            "      Leaf 1",
            "      Leaf 2",
            "        Sub-leaf",
            "    Branch B",
            "      [Square Node]",
            "      (Rounded Node)",
            "    Branch C",
        ]
        let diagram = MermaidMindmapParser.parse(lines: lines)
        #expect(diagram.root.label == "Central Idea")
        #expect(diagram.root.shape == .circle)
        #expect(diagram.root.children.count == 3)

        // Branch A
        let branchA = diagram.root.children[0]
        #expect(branchA.label == "Branch A")
        #expect(branchA.children.count == 2)
        #expect(branchA.children[1].children.count == 1)
        #expect(branchA.children[1].children[0].label == "Sub-leaf")

        // Branch B
        let branchB = diagram.root.children[1]
        #expect(branchB.children.count == 2)
        #expect(branchB.children[0].shape == .square)
        #expect(branchB.children[1].shape == .rounded)

        // Branch C (leaf)
        let branchC = diagram.root.children[2]
        #expect(branchC.label == "Branch C")
        #expect(branchC.children.isEmpty)
    }

    @Test func equatableConformance() {
        let a = MermaidMindmapParser.parse(lines: ["  root", "    child"])
        let b = MermaidMindmapParser.parse(lines: ["  root", "    child"])
        #expect(a == b)
    }
}

// MARK: - Renderer Tests

@Suite("Mermaid Mindmap Renderer")
struct MermaidMindmapRendererTests {
    let config = RenderConfiguration.default(maxWidth: 600)

    @Test func layoutProducesNonZeroSize() {
        let diagram = MindmapDiagram(root: MindmapNode(
            label: "Root",
            shape: .default,
            children: [
                MindmapNode(label: "A", shape: .default, children: []),
                MindmapNode(label: "B", shape: .default, children: []),
            ]
        ))
        let layout = MermaidMindmapRenderer.layout(diagram, configuration: config)
        #expect(layout.customSize != nil)
        #expect(layout.customSize!.width > 0)
        #expect(layout.customSize!.height > 0)
    }

    @Test func layoutIsNotPlaceholder() {
        let diagram = MindmapDiagram(root: MindmapNode(
            label: "Test",
            shape: .circle,
            children: []
        ))
        let layout = MermaidMindmapRenderer.layout(diagram, configuration: config)
        #expect(!layout.isPlaceholder)
    }

    @Test func customDrawBlockIsSet() {
        let diagram = MindmapDiagram(root: MindmapNode(
            label: "Root",
            shape: .default,
            children: [
                MindmapNode(label: "Child", shape: .square, children: []),
            ]
        ))
        let layout = MermaidMindmapRenderer.layout(diagram, configuration: config)
        #expect(layout.customDraw != nil)
    }

    @Test func multiBranchLayoutSizeGrowsWithChildren() {
        let small = MindmapDiagram(root: MindmapNode(
            label: "Root",
            shape: .default,
            children: [
                MindmapNode(label: "A", shape: .default, children: []),
            ]
        ))
        let large = MindmapDiagram(root: MindmapNode(
            label: "Root",
            shape: .default,
            children: [
                MindmapNode(label: "A", shape: .default, children: [
                    MindmapNode(label: "A1", shape: .default, children: []),
                    MindmapNode(label: "A2", shape: .default, children: []),
                    MindmapNode(label: "A3", shape: .default, children: []),
                ]),
                MindmapNode(label: "B", shape: .default, children: [
                    MindmapNode(label: "B1", shape: .default, children: []),
                ]),
                MindmapNode(label: "C", shape: .default, children: []),
            ]
        ))

        let smallLayout = MermaidMindmapRenderer.layout(small, configuration: config)
        let largeLayout = MermaidMindmapRenderer.layout(large, configuration: config)

        // More branches = wider and taller
        #expect(largeLayout.customSize!.width > smallLayout.customSize!.width)
        #expect(largeLayout.customSize!.height > smallLayout.customSize!.height)
    }

    @Test func singleNodeLayoutIsCompact() {
        let diagram = MindmapDiagram(root: MindmapNode(
            label: "Solo",
            shape: .default,
            children: []
        ))
        let layout = MermaidMindmapRenderer.layout(diagram, configuration: config)
        let size = layout.customSize!

        // Single node should be reasonably small
        #expect(size.width < 200)
        #expect(size.height < 100)
    }

    @Test func drawDoesNotCrash() {
        let diagram = MindmapDiagram(root: MindmapNode(
            label: "Root",
            shape: .circle,
            children: [
                MindmapNode(label: "Branch 1", shape: .rounded, children: [
                    MindmapNode(label: "Leaf", shape: .square, children: []),
                ]),
                MindmapNode(label: "Branch 2", shape: .hexagon, children: []),
                MindmapNode(label: "Branch 3", shape: .bang, children: []),
            ]
        ))

        let layout = MermaidMindmapRenderer.layout(diagram, configuration: config)
        let size = layout.customSize!

        // Create a bitmap context and draw into it.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            Issue.record("Failed to create CGContext")
            return
        }

        // Should not crash.
        layout.customDraw?(ctx, .zero)
    }

    @Test func endToEndParseThenLayout() {
        let lines = [
            "  root((Ideas))",
            "    Topic A",
            "      Detail 1",
            "      Detail 2",
            "    Topic B",
        ]
        let diagram = MermaidMindmapParser.parse(lines: lines)
        let layout = MermaidMindmapRenderer.layout(diagram, configuration: config)

        #expect(!layout.isPlaceholder)
        #expect(layout.customSize!.width > 0)
        #expect(layout.customSize!.height > 0)
        #expect(layout.customDraw != nil)
    }
}
