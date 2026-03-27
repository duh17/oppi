import CoreGraphics
import Testing
@testable import Oppi

/// Tests for the Mermaid flowchart renderer.
///
/// Validates layout integration with Sugiyama and drawing correctness.
@Suite("Mermaid Renderer")
struct MermaidRendererTests {
    let parser = MermaidParser()
    let renderer = MermaidFlowchartRenderer()
    let config = RenderConfiguration.default(maxWidth: 600)

    // MARK: - Layout integration

    @Test func twoNodeGraph() {
        let diagram = parser.parse("flowchart TD\n    A --> B")
        let layout = renderer.layout(diagram, configuration: config)
        #expect(!layout.isPlaceholder)
        #expect(layout.graphResult.nodePositions.count == 2)

        let a = layout.graphResult.nodePositions["A"]!
        let b = layout.graphResult.nodePositions["B"]!
        #expect(a.midY < b.midY) // A above B
        #expect(!a.intersects(b)) // No overlap
    }

    @Test func threeNodeChainLayering() {
        let diagram = parser.parse("flowchart TD\n    A --> B\n    B --> C")
        let layout = renderer.layout(diagram, configuration: config)
        let positions = layout.graphResult.nodePositions
        #expect(positions.count == 3)

        let a = positions["A"]!
        let b = positions["B"]!
        let c = positions["C"]!
        #expect(a.midY < b.midY)
        #expect(b.midY < c.midY)
    }

    @Test func diamondPatternLayers() {
        let source = """
            flowchart TD
                A --> B
                A --> C
                B --> D
                C --> D
            """
        let diagram = parser.parse(source)
        let layout = renderer.layout(diagram, configuration: config)
        let positions = layout.graphResult.nodePositions
        #expect(positions.count == 4)

        let a = positions["A"]!
        let b = positions["B"]!
        let c = positions["C"]!
        let d = positions["D"]!

        #expect(a.midY < b.midY)
        #expect(abs(b.midY - c.midY) < 1) // Same layer
        #expect(b.midY < d.midY)
    }

    @Test func leftToRightDirection() {
        let diagram = parser.parse("flowchart LR\n    A --> B")
        let layout = renderer.layout(diagram, configuration: config)
        let positions = layout.graphResult.nodePositions

        let a = positions["A"]!
        let b = positions["B"]!
        #expect(a.midX < b.midX) // A left of B
    }

    @Test func edgePathsPresent() {
        let diagram = parser.parse("flowchart TD\n    A --> B")
        let layout = renderer.layout(diagram, configuration: config)
        #expect(layout.graphResult.edgePaths.count == 1)
        #expect(layout.graphResult.edgePaths[0].from == "A")
        #expect(layout.graphResult.edgePaths[0].to == "B")
        #expect(layout.graphResult.edgePaths[0].points.count >= 2)
    }

    @Test func cycleDoesNotCrash() {
        let diagram = parser.parse("flowchart TD\n    A --> B\n    B --> A")
        let layout = renderer.layout(diagram, configuration: config)
        #expect(layout.graphResult.nodePositions.count == 2)
    }

    @Test func emptyFlowchart() {
        let diagram = parser.parse("flowchart TD")
        let layout = renderer.layout(diagram, configuration: config)
        #expect(layout.graphResult.totalSize == .zero)
    }

    @Test func singleNode() {
        let diagram = parser.parse("flowchart TD\n    A[Hello]")
        let layout = renderer.layout(diagram, configuration: config)
        #expect(layout.graphResult.nodePositions.count == 1)
        let a = layout.graphResult.nodePositions["A"]!
        #expect(a.width > 0)
        #expect(a.height > 0)
    }

    // MARK: - Render output

    @Test func renderProducesNonZeroSize() {
        let diagram = parser.parse("flowchart TD\n    A --> B")
        let output = renderer.render(diagram, configuration: config)
        guard case .graphical(let result) = output else {
            Issue.record("Expected graphical output")
            return
        }
        #expect(result.boundingBox.width > 0)
        #expect(result.boundingBox.height > 0)
    }

    @Test func drawDoesNotCrash() {
        let diagram = parser.parse("""
            flowchart TD
                A[Rectangle] --> B(Rounded)
                B --> C([Stadium])
                C --> D{Diamond}
                D --> E{{Hexagon}}
                E --> F((Circle))
            """)
        let layout = renderer.layout(diagram, configuration: config)
        let box = renderer.boundingBox(layout)

        // Create a bitmap context and draw into it.
        let ctx = CGContext(
            data: nil,
            width: Int(box.width),
            height: Int(box.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        // Should not crash.
        renderer.draw(layout, in: ctx, at: .zero)
    }

    // MARK: - All node shapes

    @Test func allShapesRender() {
        let shapes: [(String, String)] = [
            ("A[Rectangle]", "rectangle"),
            ("B(Rounded)", "rounded"),
            ("C([Stadium])", "stadium"),
            ("D{Diamond}", "diamond"),
            ("E{{Hexagon}}", "hexagon"),
            ("F((Circle))", "circle"),
            ("G[(Cylindrical)]", "cylindrical"),
            ("H[[Subroutine]]", "subroutine"),
            ("I>Asymmetric]", "asymmetric"),
        ]

        for (node, shapeName) in shapes {
            let diagram = parser.parse("flowchart TD\n    \(node)")
            let layout = renderer.layout(diagram, configuration: config)
            #expect(!layout.isPlaceholder, "Shape \(shapeName) should not produce placeholder")
            #expect(layout.graphResult.nodePositions.count == 1,
                    "Shape \(shapeName) should have one positioned node")
        }
    }

    // MARK: - Edge styles

    @Test func allEdgeStylesRender() {
        let source = """
            flowchart TD
                A -->|arrow| B
                B --- C
                C -.-> D
                D ==> E
            """
        let diagram = parser.parse(source)
        let layout = renderer.layout(diagram, configuration: config)

        // All edges should be present.
        #expect(layout.graphResult.edgePaths.count == 4)

        // Arrow edge label should be captured.
        #expect(layout.edgeLabels["A->B"] == "arrow")
    }

    // MARK: - Style directives

    @Test func styleDirectivesCaptured() {
        let source = """
            flowchart TD
                A[Node] --> B[Other]
                style A fill:#f9f,stroke:#333
            """
        let diagram = parser.parse(source)
        let layout = renderer.layout(diagram, configuration: config)
        #expect(layout.styleDirectives["A"]?["fill"] == "#f9f")
        #expect(layout.styleDirectives["A"]?["stroke"] == "#333")
    }

    @Test func classDefCaptured() {
        let source = """
            flowchart TD
                A[Node]:::highlight --> B[Other]
                classDef highlight fill:#ff0,stroke:#000
            """
        let diagram = parser.parse(source)
        let layout = renderer.layout(diagram, configuration: config)
        #expect(layout.classDefs["highlight"]?["fill"] == "#ff0")
    }

    // MARK: - Sequence diagram placeholder

    @Test func sequenceDiagramRendersWithoutCrash() {
        let diagram = parser.parse("sequenceDiagram\n    A->>B: Hello")
        let layout = renderer.layout(diagram, configuration: config)
        let size = renderer.boundingBox(layout)
        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    @Test func unsupportedDiagramPlaceholder() {
        let diagram = parser.parse("journey\n    title Test")
        let layout = renderer.layout(diagram, configuration: config)
        #expect(layout.isPlaceholder)
        #expect(layout.placeholderText?.contains("journey") == true)
    }

    // MARK: - Render with complex diagram

    @Test func complexDiagramDoesNotCrash() {
        let source = """
            flowchart TD
                Start[Start] --> Decision{Is it?}
                Decision -->|Yes| Action1([Do thing])
                Decision -->|No| Action2([Do other])
                Action1 --> End((End))
                Action2 --> End
                style Start fill:#0f0,stroke:#000
                style End fill:#f00,stroke:#000
            """
        let diagram = parser.parse(source)
        let output = renderer.render(diagram, configuration: config)
        guard case .graphical(let result) = output else {
            Issue.record("Expected graphical output")
            return
        }
        #expect(result.boundingBox.width > 0)
        #expect(result.boundingBox.height > 0)

        // Draw it.
        let ctx = CGContext(
            data: nil,
            width: max(1, Int(result.boundingBox.width)),
            height: max(1, Int(result.boundingBox.height)),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        result.draw(ctx, .zero)
    }
}
