import CoreGraphics
import Testing
@testable import Oppi

// SPEC: https://github.com/mermaid-js/mermaid/blob/develop/packages/mermaid/src/docs/syntax/flowchart.md
//
// Tests for flowchart features not yet covered by MermaidParserConformanceTests.
// Each test references the spec section it validates.
//
// COVERAGE (new):
// [ ] Parallelogram shape: [/text/]
// [ ] Parallelogram alt shape: [\text\]
// [ ] Trapezoid shape: [/text\]
// [ ] Trapezoid alt shape: [\text/]
// [ ] Double circle shape: (((text)))
// [ ] Circle edge: --o
// [ ] Cross edge: --x
// [ ] Bidirectional arrow: <-->
// [ ] Bidirectional circle: o--o
// [ ] Bidirectional cross: x--x
// [x] Quoted node labels: A["text with (special) chars"]
// [x] Markdown string labels: A["`text with **markdown**`"]
// [x] Entity codes in labels: A["A double quote:#quot;"]
// [x] Class applications via `class A name` and `A:::name`
// [x] Multiple class names in one classDef statement
// [x] v11.3.0+ general shape syntax: A@{ shape: rect, label: "Process" }
// [x] Edge IDs and edge metadata/classes: A e1@--> B

@Suite("Flowchart Conformance — Missing Shapes and Edges")
struct MermaidFlowchartConformanceTests {
    let parser = MermaidParser()

    // MARK: - Missing node shapes

    /// SPEC: ### Parallelogram
    /// `id1[/This is the text in the box/]`
    @Test func parallelogramShape() {
        let result = parser.parse("""
        flowchart TD
            id1[/This is the text in the box/]
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        let node = d.nodes.first { $0.id == "id1" }
        #expect(node != nil, "Node id1 should exist")
        #expect(node?.label == "This is the text in the box")
        #expect(node?.shape == .parallelogram)
    }

    /// SPEC: ### Parallelogram alt
    /// `id1[\This is the text in the box\]`
    @Test func parallelogramAltShape() {
        let result = parser.parse("""
        flowchart TD
            id1[\\This is the text in the box\\]
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        let node = d.nodes.first { $0.id == "id1" }
        #expect(node != nil, "Node id1 should exist")
        #expect(node?.label == "This is the text in the box")
        #expect(node?.shape == .parallelogramAlt)
    }

    /// SPEC: ### Trapezoid
    /// `A[/Christmas\]`
    @Test func trapezoidShape() {
        let result = parser.parse("""
        flowchart TD
            A[/Christmas\\]
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        let node = d.nodes.first { $0.id == "A" }
        #expect(node != nil, "Node A should exist")
        #expect(node?.label == "Christmas")
        #expect(node?.shape == .trapezoid)
    }

    /// SPEC: ### Trapezoid alt
    /// `B[\Go shopping/]`
    @Test func trapezoidAltShape() {
        let result = parser.parse("""
        flowchart TD
            B[\\Go shopping/]
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        let node = d.nodes.first { $0.id == "B" }
        #expect(node != nil, "Node B should exist")
        #expect(node?.label == "Go shopping")
        #expect(node?.shape == .trapezoidAlt)
    }

    /// SPEC: ### Double circle
    /// `id1(((This is the text in the circle)))`
    @Test func doubleCircleShape() {
        let result = parser.parse("""
        flowchart TD
            id1(((This is the text in the circle)))
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        let node = d.nodes.first { $0.id == "id1" }
        #expect(node != nil, "Node id1 should exist")
        #expect(node?.label == "This is the text in the circle")
        #expect(node?.shape == .doubleCircle)
    }

    // MARK: - Quoted and escaped labels

    /// SPEC: #### Unicode text — `id["This ❤ Unicode"]`
    @Test func quotedUnicodeNodeLabel() {
        let result = parser.parse("""
        flowchart LR
            id["This ❤ Unicode"]
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.nodes.first { $0.id == "id" }?.label == "This ❤ Unicode")
    }

    /// SPEC: ## Special characters that break syntax — quoted node labels.
    @Test func quotedSpecialCharacterNodeLabel() {
        let result = parser.parse("""
        flowchart LR
            id1["This is the (text) in the box"]
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.nodes.first { $0.id == "id1" }?.label == "This is the (text) in the box")
    }

    /// SPEC: ## Markdown Strings — double quotes plus backticks delimit markdown labels.
    @Test func markdownStringNodeAndEdgeLabels() {
        let result = parser.parse("""
        flowchart LR
            A["`This **is** _Markdown_`"] -- "`Bold **edge label**`" --> B
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.nodes.first { $0.id == "A" }?.label == "This **is** _Markdown_")
        #expect(d.edges.first?.label == "Bold **edge label**")
    }

    /// SPEC: ### Entity codes to escape characters — `#quot;`, decimal `#9829;`, and `#35;`.
    @Test func entityCodesInNodeLabels() {
        let result = parser.parse("""
        flowchart LR
            A["A double quote:#quot;"] --> B["A dec char:#9829;"] --> C["A hash:#35;"]
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.nodes.first { $0.id == "A" }?.label == "A double quote:\"")
        #expect(d.nodes.first { $0.id == "B" }?.label == "A dec char:♥")
        #expect(d.nodes.first { $0.id == "C" }?.label == "A hash:#")
    }

    // MARK: - v11.3.0+ general shape syntax

    /// SPEC: ## Expanded Node Shapes — `A@{ shape: rect }` renders like a normal process node.
    @Test func generalShapeSyntaxDefaultsLabelToNodeId() {
        let result = parser.parse("""
        flowchart TD
            A@{ shape: rect }
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        let node = d.nodes.first { $0.id == "A" }
        #expect(node?.label == "A")
        #expect(node?.shape == .rectangle)
    }

    /// SPEC: ## Expanded Node Shapes — label metadata sets display text.
    @Test func generalShapeSyntaxWithLabel() {
        let result = parser.parse("""
        flowchart TD
            A@{ shape: cyl, label: "Database" }
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        let node = d.nodes.first { $0.id == "A" }
        #expect(node?.label == "Database")
        #expect(node?.shape == .cylindrical)
    }

    /// SPEC: ## Expanded Node Shapes — aliases map to their classic Mermaid shapes.
    @Test func generalShapeSyntaxAliases() {
        let result = parser.parse("""
        flowchart TD
            A@{ shape: rounded, label: "Event" }
            B@{ shape: diamond, label: "Decision" }
            C@{ shape: hex, label: "Prepare" }
            D@{ shape: subproc, label: "Subprocess" }
            E@{ shape: dbl-circ, label: "Stop" }
            F@{ shape: trap-b, label: "Priority" }
            G@{ shape: trap-t, label: "Manual" }
            H@{ shape: lean-r, label: "Input" }
            I@{ shape: lean-l, label: "Output" }
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        let expected: [String: FlowNodeShape] = [
            "A": .rounded,
            "B": .diamond,
            "C": .hexagon,
            "D": .subroutine,
            "E": .doubleCircle,
            "F": .trapezoid,
            "G": .trapezoidAlt,
            "H": .parallelogram,
            "I": .parallelogramAlt,
        ]
        for (id, shape) in expected {
            #expect(d.nodes.first { $0.id == id }?.shape == shape)
        }
    }

    /// SPEC: ## Expanded Node Shapes — v11-only shapes parse to dedicated shapes and render.
    @Test func generalShapeSyntaxNewV11ShapesRender() {
        let result = parser.parse("""
        flowchart TD
            A@{ shape: bang, label: "Bang" }
            B@{ shape: notch-rect, label: "Card" }
            C@{ shape: cloud, label: "Cloud" }
            D@{ shape: hourglass, label: "Collate" }
            E@{ shape: bolt, label: "Link" }
            F@{ shape: braces, label: "Comment" }
            G@{ shape: datastore, label: "Store" }
            H@{ shape: h-cyl, label: "DAS" }
            I@{ shape: lin-cyl, label: "Disk" }
            J@{ shape: curv-trap, label: "Display" }
            K@{ shape: div-rect, label: "Divided" }
            L@{ shape: doc, label: "Document" }
            M@{ shape: delay, label: "Delay" }
            N@{ shape: tri, label: "Extract" }
            O@{ shape: fork, label: "Fork" }
            P@{ shape: win-pane, label: "Pane" }
            Q@{ shape: f-circ, label: "Junction" }
            R@{ shape: lin-doc, label: "Lined Doc" }
            S@{ shape: notch-pent, label: "Loop" }
            T@{ shape: flip-tri, label: "File" }
            U@{ shape: sl-rect, label: "Input" }
            V@{ shape: docs, label: "Docs" }
            W@{ shape: st-rect, label: "Processes" }
            X@{ shape: flag, label: "Tape" }
            Y@{ shape: bow-rect, label: "Stored" }
            Z@{ shape: cross-circ, label: "Summary" }
            AA@{ shape: tag-doc, label: "Tagged Doc" }
            AB@{ shape: tag-rect, label: "Tagged Proc" }
            AC@{ shape: text, label: "Text" }
            AD@{ shape: odd, label: "Odd" }
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        let expected: [String: FlowNodeShape] = [
            "A": .bang, "B": .notchedRectangle, "C": .cloud, "D": .hourglass,
            "E": .bolt, "F": .braces, "G": .datastore, "H": .horizontalCylinder,
            "I": .linedCylinder, "J": .curvedTrapezoid, "K": .dividedRectangle,
            "L": .document, "M": .delay, "N": .triangle, "O": .forkJoin,
            "P": .windowPane, "Q": .filledCircle, "R": .linedDocument,
            "S": .notchedPentagon, "T": .flippedTriangle, "U": .slopedRectangle,
            "V": .stackedDocument, "W": .stackedRectangle, "X": .flag,
            "Y": .bowTieRectangle, "Z": .crossedCircle, "AA": .taggedDocument,
            "AB": .taggedRectangle, "AC": .textBlock, "AD": .odd,
        ]
        for (id, shape) in expected {
            #expect(d.nodes.first { $0.id == id }?.shape == shape)
        }

        let renderer = MermaidFlowchartRenderer()
        let layout = renderer.layout(result, configuration: .default(maxWidth: 900))
        let box = renderer.boundingBox(layout)
        let ctx = CGContext(
            data: nil,
            width: max(1, Int(box.width)),
            height: max(1, Int(box.height)),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        renderer.draw(layout, in: ctx, at: .zero)
    }

    // MARK: - Missing edge types

    /// SPEC: ### Circle edge example
    /// `A --o B`
    @Test func circleEdge() {
        let result = parser.parse("""
        flowchart LR
            A --o B
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.edges.count == 1)
        #expect(d.edges.first?.from == "A")
        #expect(d.edges.first?.to == "B")
        #expect(d.edges.first?.style == .circle)
    }

    /// SPEC: ### Cross edge example
    /// `A --x B`
    @Test func crossEdge() {
        let result = parser.parse("""
        flowchart LR
            A --x B
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.edges.count == 1)
        #expect(d.edges.first?.from == "A")
        #expect(d.edges.first?.to == "B")
        #expect(d.edges.first?.style == .cross)
    }

    /// SPEC: ## Multi directional arrows — `B <--> C`
    @Test func bidirectionalArrow() {
        let result = parser.parse("""
        flowchart LR
            B <--> C
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.edges.count == 1)
        #expect(d.edges.first?.from == "B")
        #expect(d.edges.first?.to == "C")
        #expect(d.edges.first?.style == .biArrow)
    }

    /// SPEC: ## Multi directional arrows — `A o--o B`
    @Test func bidirectionalCircle() {
        let result = parser.parse("""
        flowchart LR
            A o--o B
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.edges.count == 1)
        #expect(d.edges.first?.from == "A")
        #expect(d.edges.first?.to == "B")
        #expect(d.edges.first?.style == .biCircle)
    }

    /// SPEC: ## Multi directional arrows — `C x--x D`
    @Test func bidirectionalCross() {
        let result = parser.parse("""
        flowchart LR
            C x--x D
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.edges.count == 1)
        #expect(d.edges.first?.from == "C")
        #expect(d.edges.first?.to == "D")
        #expect(d.edges.first?.style == .biCross)
    }

    // MARK: - Circle/cross edges with labels

    /// Circle edge with pipe label: `A --o|text| B`
    @Test func circleEdgeWithLabel() {
        let result = parser.parse("""
        flowchart LR
            A --o|label text| B
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.edges.first?.style == .circle)
        #expect(d.edges.first?.label == "label text")
    }

    /// Cross edge with pipe label: `A --x|text| B`
    @Test func crossEdgeWithLabel() {
        let result = parser.parse("""
        flowchart LR
            A --x|label text| B
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.edges.first?.style == .cross)
        #expect(d.edges.first?.label == "label text")
    }

    // MARK: - Class definitions and application

    /// SPEC: #### Classes — `class nodeId1 className` applies a classDef to a node.
    @Test func classStatementAppliesClassDefToNode() {
        let result = parser.parse("""
        flowchart LR
            A[Start] --> B[Stop]
            classDef highlight fill:#ff0,stroke:#000,color:#111
            class A highlight
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        let renderer = MermaidFlowchartRenderer()
        let layout = renderer.layout(result, configuration: .default())
        #expect(d.classApplications["A"] == ["highlight"])
        #expect(layout.styleDirectives["A"]?["fill"] == "#ff0")
        #expect(layout.styleDirectives["A"]?["stroke"] == "#000")
        #expect(layout.styleDirectives["A"]?["color"] == "#111")
        #expect(layout.styleDirectives["B"]?["fill"] == nil)
    }

    /// SPEC: #### Classes — shorthand `A:::someclass` applies a classDef.
    @Test func tripleColonClassSyntaxAppliesClassDefToNode() {
        let result = parser.parse("""
        flowchart LR
            A:::highlight --> B
            classDef highlight fill:#ff0,stroke:#000
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        let renderer = MermaidFlowchartRenderer()
        let layout = renderer.layout(result, configuration: .default())
        #expect(d.classApplications["A"] == ["highlight"])
        #expect(layout.styleDirectives["A"]?["fill"] == "#ff0")
        #expect(layout.styleDirectives["A"]?["stroke"] == "#000")
    }

    /// SPEC: #### Classes — one classDef can define multiple class names.
    @Test func classDefWithMultipleNamesAppliesToEachName() {
        let result = parser.parse("""
        flowchart LR
            A[One] --> B[Two]
            classDef first,second fill:#bbf,stroke:#f66
            class A first
            class B second
        """)
        guard case .flowchart = result else {
            Issue.record("Expected flowchart")
            return
        }
        let renderer = MermaidFlowchartRenderer()
        let layout = renderer.layout(result, configuration: .default())
        #expect(layout.styleDirectives["A"]?["fill"] == "#bbf")
        #expect(layout.styleDirectives["B"]?["stroke"] == "#f66")
    }

    /// SPEC: ### Styling a node — explicit `style` overrides classDef properties.
    @Test func explicitStyleOverridesClassDefProperties() {
        let result = parser.parse("""
        flowchart LR
            A:::highlight
            classDef highlight fill:#ff0,stroke:#000
            style A fill:#f00
        """)
        guard case .flowchart = result else {
            Issue.record("Expected flowchart")
            return
        }
        let renderer = MermaidFlowchartRenderer()
        let layout = renderer.layout(result, configuration: .default())
        #expect(layout.styleDirectives["A"]?["fill"] == "#f00")
        #expect(layout.styleDirectives["A"]?["stroke"] == "#000")
    }

    // MARK: - Edge IDs and edge classes

    /// SPEC: ### Attaching an ID to Edges — `A e1@--> B`.
    @Test func edgeIdSyntaxIsParsed() {
        let result = parser.parse("""
        flowchart LR
            A e1@--> B
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.edges.count == 1)
        #expect(d.edges.first?.id == "e1")
        #expect(d.edges.first?.from == "A")
        #expect(d.edges.first?.to == "B")
        let renderer = MermaidFlowchartRenderer()
        let layout = renderer.layout(result, configuration: .default())
        #expect(layout.edgeIds["A->B"] == "e1")
    }

    /// SPEC: ### Turning an Animation On — edge metadata attaches to edge ID.
    @Test func edgeMetadataDirectiveIsCaptured() {
        let result = parser.parse("""
        flowchart LR
            A e1@==> B
            e1@{ animate: true, animation: fast, curve: linear }
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.edges.first?.id == "e1")
        let renderer = MermaidFlowchartRenderer()
        let layout = renderer.layout(result, configuration: .default())
        #expect(layout.edgeStyleDirectives["A->B"]?["animate"] == "true")
        #expect(layout.edgeStyleDirectives["A->B"]?["animation"] == "fast")
        #expect(layout.edgeStyleDirectives["A->B"]?["curve"] == "linear")
    }

    /// SPEC: ### Using classDef Statements for Animations — edge IDs can receive class styles.
    @Test func edgeClassDefStylesApplyToEdgeId() {
        let result = parser.parse("""
        flowchart LR
            A e1@--> B
            classDef animate stroke:#f00,stroke-width:4px,stroke-dasharray:9\\,5
            class e1 animate
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.classApplications["e1"] == ["animate"])
        let renderer = MermaidFlowchartRenderer()
        let layout = renderer.layout(result, configuration: .default())
        #expect(layout.edgeStyleDirectives["A->B"]?["stroke"] == "#f00")
        #expect(layout.edgeStyleDirectives["A->B"]?["stroke-width"] == "4px")
        #expect(layout.edgeStyleDirectives["A->B"]?["stroke-dasharray"] == "9,5")
    }

    /// Parallel edges between the same nodes keep distinct edge IDs, labels, styles, and class styles.
    @Test func parallelEdgeIdsDoNotOverwriteEachOther() {
        let result = parser.parse("""
        flowchart LR
            A e1@-->|one| B
            A e2@==>|two| B
            classDef red stroke:#f00
            classDef blue stroke:#00f
            class e1 red
            class e2 blue
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.edges.map(\.id) == ["e1", "e2"])

        let renderer = MermaidFlowchartRenderer()
        let layout = renderer.layout(result, configuration: .default())
        #expect(layout.edgeKeys == ["A->B#0", "A->B#1"])
        #expect(layout.edgeIds["A->B#0"] == "e1")
        #expect(layout.edgeIds["A->B#1"] == "e2")
        #expect(layout.edgeLabels["A->B#0"] == "one")
        #expect(layout.edgeLabels["A->B#1"] == "two")
        #expect(layout.edgeStyles["A->B#0"] == .arrow)
        #expect(layout.edgeStyles["A->B#1"] == .thick)
        #expect(layout.edgeStyleDirectives["A->B#0"]?["stroke"] == "#f00")
        #expect(layout.edgeStyleDirectives["A->B#1"]?["stroke"] == "#00f")
    }

    // MARK: - Subgraphs

    /// SPEC: ### Direction in subgraphs — local direction applies when member nodes have no outside links.
    @Test func subgraphDirectionAppliesWithoutOutsideMemberLinks() {
        let result = parser.parse("""
        flowchart LR
            outside --> cluster
            subgraph cluster
                direction TB
                top --> bottom
            end
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.subgraphs.first?.direction == .TB)

        let renderer = MermaidFlowchartRenderer()
        let layout = renderer.layout(result, configuration: .default(maxWidth: 700))
        guard let top = layout.graphResult.nodePositions["top"],
              let bottom = layout.graphResult.nodePositions["bottom"]
        else {
            Issue.record("Expected top and bottom positions")
            return
        }
        #expect(top.midY < bottom.midY)
        #expect(abs(top.midX - bottom.midX) < 1)
        #expect(layout.edgeEndpointSubgraphs.values.contains { $0.to == "cluster" })
    }

    @Test func subgraphDirectionRelayoutKeepsNodePositionsNonNegative() {
        let result = parser.parse("""
        flowchart TD
            subgraph cluster
                direction LR
                A --> B --> C
            end
        """)
        let renderer = MermaidFlowchartRenderer()
        let layout = renderer.layout(result, configuration: .default(maxWidth: 700))
        let positions = layout.graphResult.nodePositions.values
        #expect(!positions.isEmpty)
        #expect(positions.allSatisfy { $0.minX >= 0 && $0.minY >= 0 })
        #expect(layout.graphResult.totalSize.width >= (positions.map(\.maxX).max() ?? 0))
        #expect(layout.graphResult.totalSize.height >= (positions.map(\.maxY).max() ?? 0))
    }

    /// SPEC: ### Direction in subgraphs — if a member node is linked outside, local direction is ignored.
    @Test func subgraphDirectionIgnoredWhenMemberLinksOutside() {
        let result = parser.parse("""
        flowchart LR
            outside --> top2
            subgraph subgraph2
                direction TB
                top2 --> bottom2
            end
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.subgraphs.first?.direction == .TB)

        let renderer = MermaidFlowchartRenderer()
        let layout = renderer.layout(result, configuration: .default(maxWidth: 700))
        guard let top = layout.graphResult.nodePositions["top2"],
              let bottom = layout.graphResult.nodePositions["bottom2"]
        else {
            Issue.record("Expected top2 and bottom2 positions")
            return
        }
        #expect(top.midX < bottom.midX)
    }

    /// SPEC: ### flowcharts — edges can connect to and from subgraph IDs.
    @Test func subgraphIdsCanBeUsedAsEdgeEndpoints() {
        let result = parser.parse("""
        flowchart TB
            c1-->a2
            subgraph one
                a1-->a2
            end
            subgraph two
                b1-->b2
            end
            one --> two
            two --> c2
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.subgraphs.map(\.id).sorted() == ["one", "two"])
        #expect(!d.nodes.contains { $0.id == "one" })
        #expect(!d.nodes.contains { $0.id == "two" })
        #expect(d.edges.contains { $0.from == "one" && $0.to == "two" })

        let renderer = MermaidFlowchartRenderer()
        let layout = renderer.layout(result, configuration: .default(maxWidth: 700))
        #expect(layout.graphResult.nodePositions["one"] == nil)
        #expect(layout.graphResult.nodePositions["two"] == nil)
        #expect(!layout.edgeEndpointSubgraphs.isEmpty, "endpoint map: \(layout.edgeEndpointSubgraphs)")
        #expect(layout.edgeEndpointSubgraphs.keys.contains("a2->b1"), "endpoint map: \(layout.edgeEndpointSubgraphs)")
        #expect(layout.edgeEndpointSubgraphs["a2->b1"]?.from == "one")
        #expect(layout.edgeEndpointSubgraphs["a2->b1"]?.to == "two")
        #expect(layout.edgeEndpointSubgraphs["b2->c2"]?.from == "two")

        let box = renderer.boundingBox(layout)
        let ctx = CGContext(
            data: nil,
            width: max(1, Int(box.width)),
            height: max(1, Int(box.height)),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        renderer.draw(layout, in: ctx, at: .zero)
    }

    // MARK: - Combined spec example

    /// SPEC: Multi directional arrows example
    /// ```
    /// flowchart LR
    ///     A o--o B
    ///     B <--> C
    ///     C x--x D
    /// ```
    @Test func multiDirectionalArrowsExample() {
        let result = parser.parse("""
        flowchart LR
            A o--o B
            B <--> C
            C x--x D
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.edges.count == 3)
        #expect(d.edges[0].style == .biCircle)
        #expect(d.edges[1].style == .biArrow)
        #expect(d.edges[2].style == .biCross)
    }

    // MARK: - All shapes in one diagram

    /// Verify all original + new shapes parse in a single diagram.
    @Test func allShapesInOneDiagram() {
        let result = parser.parse("""
        flowchart TD
            A[rectangle]
            B(rounded)
            C([stadium])
            D{diamond}
            E{{hexagon}}
            F((circle))
            G[(cylindrical)]
            H[[subroutine]]
            I>asymmetric]
            J(((double circle)))
            K[/parallelogram/]
            L[\\parallelogram alt\\]
            M[/trapezoid\\]
            N[\\trapezoid alt/]
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.nodes.count == 14)

        let shapes: [String: FlowNodeShape] = [
            "A": .rectangle, "B": .rounded, "C": .stadium,
            "D": .diamond, "E": .hexagon, "F": .circle,
            "G": .cylindrical, "H": .subroutine, "I": .asymmetric,
            "J": .doubleCircle, "K": .parallelogram,
            "L": .parallelogramAlt, "M": .trapezoid, "N": .trapezoidAlt,
        ]

        for (id, expectedShape) in shapes {
            let node = d.nodes.first { $0.id == id }
            #expect(node?.shape == expectedShape, "Node \(id) should be \(expectedShape), got \(String(describing: node?.shape))")
        }
    }
}
