import Testing
@testable import Oppi

// SPEC: https://mermaid.js.org/syntax/flowchart.html
// COVERAGE:
// [x] Diagram type detection (flowchart, graph, sequence, unknown)
// [x] Direction (TB, TD, BT, LR, RL)
// [x] Implicit nodes (bare ID)
// [x] Node shapes (rectangle, rounded, stadium, diamond, hexagon, circle, cylindrical, subroutine, asymmetric)
// [x] Edge types (arrow, open, dotted, thick, invisible)
// [x] Edge labels (pipe syntax, inline syntax)
// [x] Chain syntax (A --> B --> C)
// [x] Ampersand multi-target (A --> B & C)
// [x] Subgraphs (basic, nested)
// [x] Subgraph direction
// [x] Style directives
// [x] Class definitions (classDef)
// [x] Class application (class keyword)
// [x] Class application (:::syntax)
// [x] Comments (%%)
// [x] Semicolons as statement separators
// [x] Node ID reuse
// [x] graph keyword alias
// [x] Mixed implicit and explicit nodes
// [x] Empty flowchart
// [x] Unicode labels
// [x] Special characters in labels
// [x] Sequence diagram (basic)

@Suite("Mermaid Parser Conformance")
struct MermaidParserConformanceTests {
    let parser = MermaidParser()

    // MARK: - Diagram type detection

    @Test func detectsFlowchartType() {
        let result = parser.parse("flowchart TD\n    A --> B")
        guard case .flowchart = result else {
            Issue.record("Expected flowchart, got \(result)")
            return
        }
    }

    @Test func detectsGraphAlias() {
        let result = parser.parse("graph LR\n    A --> B")
        guard case .flowchart(let diagram) = result else {
            Issue.record("Expected flowchart for 'graph' keyword")
            return
        }
        #expect(diagram.direction == .LR)
    }

    @Test func detectsSequenceType() {
        let result = parser.parse("sequenceDiagram\n    A->>B: Hello")
        guard case .sequence = result else {
            Issue.record("Expected sequence diagram")
            return
        }
    }

    @Test func detectsUnsupportedType() {
        let result = parser.parse("gantt\n    title A Gantt")
        guard case .unsupported(let type) = result else {
            Issue.record("Expected unsupported diagram type")
            return
        }
        #expect(type == "gantt")
    }

    @Test func emptyInputReturnsUnsupported() {
        let result = parser.parse("")
        guard case .unsupported = result else {
            Issue.record("Expected unsupported for empty input")
            return
        }
    }

    // MARK: - Direction

    @Test func allDirections() {
        for dir in FlowDirection.allCases {
            let result = parser.parse("flowchart \(dir.rawValue)\n    A --> B")
            guard case .flowchart(let diagram) = result else {
                Issue.record("Expected flowchart for direction \(dir.rawValue)")
                continue
            }
            #expect(diagram.direction == dir, "Direction mismatch for \(dir.rawValue)")
        }
    }

    @Test func defaultDirectionIsTD() {
        let result = parser.parse("flowchart\n    A --> B")
        guard case .flowchart(let diagram) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(diagram.direction == .TD)
    }

    // MARK: - Minimal flowchart

    @Test func minimalFlowchart() {
        let result = parser.parse("flowchart TD\n    A --> B")
        guard case .flowchart(let diagram) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(diagram.direction == .TD)
        #expect(diagram.nodes.count == 2)
        #expect(diagram.edges.count == 1)
        #expect(diagram.edges[0].from == "A")
        #expect(diagram.edges[0].to == "B")
        #expect(diagram.edges[0].style == .arrow)
    }

    // MARK: - Node shapes

    @Test func rectangleNode() {
        let result = parser.parse("flowchart TD\n    A[Hello World]")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        let node = d.nodes.first { $0.id == "A" }
        #expect(node?.shape == .rectangle)
        #expect(node?.label == "Hello World")
    }

    @Test func roundedNode() {
        let result = parser.parse("flowchart TD\n    A(Hello)")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        let node = d.nodes.first { $0.id == "A" }
        #expect(node?.shape == .rounded)
        #expect(node?.label == "Hello")
    }

    @Test func stadiumNode() {
        let result = parser.parse("flowchart TD\n    A([Stadium])")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        let node = d.nodes.first { $0.id == "A" }
        #expect(node?.shape == .stadium)
        #expect(node?.label == "Stadium")
    }

    @Test func diamondNode() {
        let result = parser.parse("flowchart TD\n    A{Decision}")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        let node = d.nodes.first { $0.id == "A" }
        #expect(node?.shape == .diamond)
        #expect(node?.label == "Decision")
    }

    @Test func hexagonNode() {
        let result = parser.parse("flowchart TD\n    A{{Hexagon}}")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        let node = d.nodes.first { $0.id == "A" }
        #expect(node?.shape == .hexagon)
        #expect(node?.label == "Hexagon")
    }

    @Test func circleNode() {
        let result = parser.parse("flowchart TD\n    A((Circle))")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        let node = d.nodes.first { $0.id == "A" }
        #expect(node?.shape == .circle)
        #expect(node?.label == "Circle")
    }

    @Test func cylindricalNode() {
        let result = parser.parse("flowchart TD\n    A[(Database)]")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        let node = d.nodes.first { $0.id == "A" }
        #expect(node?.shape == .cylindrical)
        #expect(node?.label == "Database")
    }

    @Test func subroutineNode() {
        let result = parser.parse("flowchart TD\n    A[[Subroutine]]")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        let node = d.nodes.first { $0.id == "A" }
        #expect(node?.shape == .subroutine)
        #expect(node?.label == "Subroutine")
    }

    @Test func asymmetricNode() {
        let result = parser.parse("flowchart TD\n    A>Flag]")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        let node = d.nodes.first { $0.id == "A" }
        #expect(node?.shape == .asymmetric)
        #expect(node?.label == "Flag")
    }

    @Test func implicitNode() {
        let result = parser.parse("flowchart TD\n    A --> B")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        let nodeA = d.nodes.first { $0.id == "A" }
        #expect(nodeA?.shape == .default)
        #expect(nodeA?.label == "A")
    }

    // MARK: - Edge types

    @Test func arrowEdge() {
        let result = parser.parse("flowchart TD\n    A --> B")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.edges.first?.style == .arrow)
    }

    @Test func openEdge() {
        let result = parser.parse("flowchart TD\n    A --- B")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.edges.first?.style == .open)
        #expect(d.edges.first?.label == nil)
    }

    @Test func dottedEdge() {
        let result = parser.parse("flowchart TD\n    A -.-> B")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.edges.first?.style == .dotted)
    }

    @Test func thickEdge() {
        let result = parser.parse("flowchart TD\n    A ==> B")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.edges.first?.style == .thick)
    }

    @Test func invisibleEdge() {
        let result = parser.parse("flowchart TD\n    A ~~~ B")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.edges.first?.style == .invisible)
    }

    // MARK: - Edge labels

    @Test func arrowWithPipeLabel() {
        let result = parser.parse("flowchart TD\n    A -->|Yes| B")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.edges.first?.label == "Yes")
        #expect(d.edges.first?.style == .arrow)
    }

    @Test func arrowWithInlineLabel() {
        let result = parser.parse("flowchart TD\n    A -- text --> B")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.edges.first?.label == "text")
        #expect(d.edges.first?.style == .arrow)
    }

    @Test func openWithInlineLabel() {
        let result = parser.parse("flowchart TD\n    A -- text --- B")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.edges.first?.label == "text")
        #expect(d.edges.first?.style == .open)
    }

    @Test func dottedWithLabel() {
        let result = parser.parse("flowchart TD\n    A -. text .-> B")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.edges.first?.label == "text")
        #expect(d.edges.first?.style == .dotted)
    }

    @Test func thickWithInlineLabel() {
        let result = parser.parse("flowchart TD\n    A == text ==> B")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.edges.first?.label == "text")
        #expect(d.edges.first?.style == .thick)
    }

    @Test func thickWithPipeLabel() {
        let result = parser.parse("flowchart TD\n    A ==>|heavy| B")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.edges.first?.label == "heavy")
        #expect(d.edges.first?.style == .thick)
    }

    // MARK: - Chain syntax

    @Test func chainThreeNodes() {
        let result = parser.parse("flowchart TD\n    A --> B --> C")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.nodes.count == 3)
        #expect(d.edges.count == 2)
        #expect(d.edges[0].from == "A")
        #expect(d.edges[0].to == "B")
        #expect(d.edges[1].from == "B")
        #expect(d.edges[1].to == "C")
    }

    @Test func ampersandMultiTarget() {
        let result = parser.parse("flowchart TD\n    A --> B & C --> D")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        // A -> B, A -> C, B -> D, C -> D
        #expect(d.edges.count == 4)
        let fromA = d.edges.filter { $0.from == "A" }
        #expect(fromA.count == 2)
        let toD = d.edges.filter { $0.to == "D" }
        #expect(toD.count == 2)
    }

    @Test func multipleEdgesFromOneNode() {
        let input = """
        flowchart TD
            A --> B
            A --> C
            A --> D
        """
        let result = parser.parse(input)
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        let fromA = d.edges.filter { $0.from == "A" }
        #expect(fromA.count == 3)
    }

    // MARK: - Subgraphs

    @Test func basicSubgraph() {
        let input = """
        flowchart TD
            subgraph sg1 [My Subgraph]
                A --> B
            end
        """
        let result = parser.parse(input)
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.subgraphs.count == 1)
        #expect(d.subgraphs[0].id == "sg1")
        #expect(d.subgraphs[0].title == "My Subgraph")
        #expect(d.subgraphs[0].nodeIds.contains("A"))
        #expect(d.subgraphs[0].nodeIds.contains("B"))
    }

    @Test func nestedSubgraphs() {
        let input = """
        flowchart TD
            subgraph outer [Outer]
                subgraph inner [Inner]
                    A --> B
                end
                C --> D
            end
        """
        let result = parser.parse(input)
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.subgraphs.count == 1)
        let outer = d.subgraphs[0]
        #expect(outer.id == "outer")
        #expect(outer.subgraphs.count == 1)
        let inner = outer.subgraphs[0]
        #expect(inner.id == "inner")
        #expect(inner.nodeIds.contains("A"))
        #expect(inner.nodeIds.contains("B"))
    }

    @Test func subgraphWithDirection() {
        let input = """
        flowchart TD
            subgraph sg1
                direction LR
                A --> B
            end
        """
        let result = parser.parse(input)
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.subgraphs[0].direction == .LR)
    }

    // MARK: - Style directives

    @Test func styleDirective() {
        let input = """
        flowchart TD
            A --> B
            style A fill:#f9f,stroke:#333
        """
        let result = parser.parse(input)
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.styleDirectives.count == 1)
        #expect(d.styleDirectives[0].nodeId == "A")
        #expect(d.styleDirectives[0].properties["fill"] == "#f9f")
        #expect(d.styleDirectives[0].properties["stroke"] == "#333")
    }

    // MARK: - Class definitions and application

    @Test func classDefAndApplication() {
        let input = """
        flowchart TD
            A --> B
            classDef highlight fill:#ff0,stroke:#000
            class A highlight
        """
        let result = parser.parse(input)
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.classDefs["highlight"]?["fill"] == "#ff0")
        #expect(d.classDefs["highlight"]?["stroke"] == "#000")
    }

    @Test func classApplicationMultipleNodes() {
        let input = """
        flowchart TD
            A --> B --> C
            classDef blue fill:#00f
            class A,B blue
        """
        let result = parser.parse(input)
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.classDefs["blue"] != nil)
    }

    @Test func tripleColonClassSyntax() {
        let input = "flowchart TD\n    A:::highlight --> B"
        let result = parser.parse(input)
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        // Node A should still be parsed correctly, class is stripped.
        let nodeA = d.nodes.first { $0.id == "A" }
        #expect(nodeA != nil)
        #expect(d.edges.count == 1)
    }

    // MARK: - Comments

    @Test func commentsIgnored() {
        let input = """
        flowchart TD
            %% This is a comment
            A --> B
            %% Another comment
        """
        let result = parser.parse(input)
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.nodes.count == 2)
        #expect(d.edges.count == 1)
    }

    @Test func inlineCommentStripped() {
        let input = "flowchart TD\n    A --> B %% inline"
        let result = parser.parse(input)
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.edges.count == 1)
    }

    // MARK: - Semicolons

    @Test func semicolonSeparators() {
        let input = "flowchart TD\n    A --> B; B --> C"
        let result = parser.parse(input)
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.edges.count == 2)
        #expect(d.edges[0].from == "A")
        #expect(d.edges[0].to == "B")
        #expect(d.edges[1].from == "B")
        #expect(d.edges[1].to == "C")
    }

    // MARK: - Node ID reuse

    @Test func nodeIdReuse() {
        let input = """
        flowchart TD
            A[Start] --> B
            B --> A
        """
        let result = parser.parse(input)
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        // A is referenced twice but should only appear once with its first declaration.
        let nodesA = d.nodes.filter { $0.id == "A" }
        #expect(nodesA.count == 1)
        #expect(d.edges.count == 2)
    }

    // MARK: - Mixed implicit and explicit

    @Test func mixedImplicitExplicit() {
        let input = """
        flowchart TD
            A[Explicit] --> B
            B --> C[Also Explicit]
        """
        let result = parser.parse(input)
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        let nodeA = d.nodes.first { $0.id == "A" }
        let nodeB = d.nodes.first { $0.id == "B" }
        let nodeC = d.nodes.first { $0.id == "C" }
        #expect(nodeA?.label == "Explicit")
        #expect(nodeA?.shape == .rectangle)
        #expect(nodeB?.label == "B")
        #expect(nodeB?.shape == .default)
        #expect(nodeC?.label == "Also Explicit")
        #expect(nodeC?.shape == .rectangle)
    }

    // MARK: - Empty flowchart

    @Test func emptyFlowchart() {
        let result = parser.parse("flowchart TD")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.nodes.isEmpty)
        #expect(d.edges.isEmpty)
    }

    // MARK: - Unicode and special characters

    @Test func unicodeLabels() {
        let result = parser.parse("flowchart TD\n    A[日本語テスト] --> B[Ünïcödé]")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        let nodeA = d.nodes.first { $0.id == "A" }
        let nodeB = d.nodes.first { $0.id == "B" }
        #expect(nodeA?.label == "日本語テスト")
        #expect(nodeB?.label == "Ünïcödé")
    }

    @Test func specialCharactersInLabels() {
        let result = parser.parse("flowchart TD\n    A[Hello & World!] --> B[x = 42]")
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        let nodeA = d.nodes.first { $0.id == "A" }
        #expect(nodeA?.label == "Hello & World!")
    }

    // MARK: - Complex real-world examples

    @Test func gitFlowDiagram() {
        let input = """
        flowchart LR
            A[Feature Branch] --> B{Code Review}
            B -->|Approved| C[Merge to Main]
            B -->|Changes Requested| A
            C --> D((Deploy))
        """
        let result = parser.parse(input)
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.direction == .LR)
        #expect(d.nodes.count == 4)
        #expect(d.edges.count == 4)

        let nodeB = d.nodes.first { $0.id == "B" }
        #expect(nodeB?.shape == .diamond)

        let nodeD = d.nodes.first { $0.id == "D" }
        #expect(nodeD?.shape == .circle)

        let approvedEdge = d.edges.first { $0.label == "Approved" }
        #expect(approvedEdge?.from == "B")
        #expect(approvedEdge?.to == "C")
    }

    @Test func multipleSubgraphsDiagram() {
        let input = """
        flowchart TB
            subgraph frontend [Frontend]
                A[React App] --> B[API Client]
            end
            subgraph backend [Backend]
                C[REST API] --> D[(Database)]
            end
            B --> C
        """
        let result = parser.parse(input)
        guard case .flowchart(let d) = result else { Issue.record("Expected flowchart"); return }
        #expect(d.subgraphs.count == 2)
        #expect(d.edges.count == 3)

        let nodeD = d.nodes.first { $0.id == "D" }
        #expect(nodeD?.shape == .cylindrical)
    }

    // MARK: - Sequence diagram basics (Phase 2)

    @Test func basicSequenceDiagram() {
        let input = """
        sequenceDiagram
            participant A
            participant B
            A->>B: Hello
            B-->>A: Reply
        """
        let result = parser.parse(input)
        guard case .sequence(let d) = result else { Issue.record("Expected sequence"); return }
        #expect(d.participants.count == 2)
        #expect(d.messages.count == 2)
        #expect(d.messages[0].from == "A")
        #expect(d.messages[0].to == "B")
        #expect(d.messages[0].text == "Hello")
        #expect(d.messages[0].arrowStyle == .solid)
        #expect(d.messages[1].arrowStyle == .dashed)
    }

    @Test func sequenceWithActors() {
        let input = """
        sequenceDiagram
            actor U as User
            participant S as Server
            U->>S: Request
        """
        let result = parser.parse(input)
        guard case .sequence(let d) = result else { Issue.record("Expected sequence"); return }
        #expect(d.participants.count == 2)
        let user = d.participants.first { $0.id == "U" }
        #expect(user?.label == "User")
        #expect(user?.isActor == true)
        let server = d.participants.first { $0.id == "S" }
        #expect(server?.label == "Server")
        #expect(server?.isActor == false)
    }

    @Test func sequenceAutoParticipants() {
        let input = """
        sequenceDiagram
            Alice->>Bob: Hi
        """
        let result = parser.parse(input)
        guard case .sequence(let d) = result else { Issue.record("Expected sequence"); return }
        // Participants auto-created from message.
        #expect(d.participants.count == 2)
        #expect(d.participants[0].id == "Alice")
        #expect(d.participants[1].id == "Bob")
    }
}
