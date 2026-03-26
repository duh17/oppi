import Testing
@testable import Oppi

/// Error recovery tests — parser must not crash on malformed input.
///
/// Every test here verifies that the parser produces *some* result
/// without trapping, even when the input violates the spec.
@Suite("Mermaid Parser Error Recovery")
struct MermaidParserErrorRecoveryTests {
    let parser = MermaidParser()

    // MARK: - Completely invalid input

    @Test func emptyString() {
        let result = parser.parse("")
        guard case .unsupported = result else {
            Issue.record("Expected unsupported for empty input")
            return
        }
    }

    @Test func whitespaceOnly() {
        let result = parser.parse("   \n  \n   ")
        guard case .unsupported = result else {
            Issue.record("Expected unsupported for whitespace")
            return
        }
    }

    @Test func randomGarbage() {
        // Must not crash.
        _ = parser.parse("asdlkfjasd;flkja;sdlfkj")
    }

    @Test func binaryContent() {
        // Must not crash.
        let binary = String(bytes: [0x00, 0x01, 0xFF, 0xFE, 0x80, 0x7F], encoding: .utf8) ?? ""
        _ = parser.parse(binary)
    }

    // MARK: - Malformed flowcharts

    @Test func flowchartNoDirection() {
        let result = parser.parse("flowchart\n    A --> B")
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart even without direction")
            return
        }
        #expect(d.direction == .TD) // Default fallback
        #expect(d.edges.count == 1)
    }

    @Test func flowchartInvalidDirection() {
        let result = parser.parse("flowchart XY\n    A --> B")
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        // Invalid direction falls back to TD.
        #expect(d.direction == .TD)
    }

    @Test func unclosedSubgraph() {
        let input = """
        flowchart TD
            subgraph sg1
                A --> B
        """
        // Must not crash. Should recover by closing subgraph at EOF.
        let result = parser.parse(input)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.subgraphs.count == 1)
        #expect(d.nodes.count == 2)
    }

    @Test func extraEndKeyword() {
        let input = """
        flowchart TD
            A --> B
            end
            end
        """
        // Extra `end` should be harmlessly ignored.
        let result = parser.parse(input)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.edges.count == 1)
    }

    @Test func unclosedNodeBracket() {
        let input = "flowchart TD\n    A[unclosed text"
        // Parser should handle gracefully.
        let result = parser.parse(input)
        guard case .flowchart = result else {
            Issue.record("Expected flowchart")
            return
        }
    }

    @Test func emptyNodeBrackets() {
        let input = "flowchart TD\n    A[] --> B"
        let result = parser.parse(input)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        let nodeA = d.nodes.first { $0.id == "A" }
        let label = nodeA?.label ?? "non-empty"
        #expect(label.isEmpty)
    }

    @Test func edgeWithNoTarget() {
        let input = "flowchart TD\n    A -->"
        // Should not crash. Might produce node A with no edges.
        let result = parser.parse(input)
        guard case .flowchart = result else {
            Issue.record("Expected flowchart")
            return
        }
    }

    @Test func onlyComments() {
        let input = """
        flowchart TD
            %% just comments
            %% nothing else
        """
        let result = parser.parse(input)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.nodes.isEmpty)
        #expect(d.edges.isEmpty)
    }

    @Test func duplicateClassDef() {
        let input = """
        flowchart TD
            classDef blue fill:#00f
            classDef blue fill:#0ff
            A --> B
        """
        // Second definition should overwrite.
        let result = parser.parse(input)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.classDefs["blue"]?["fill"] == "#0ff")
    }

    @Test func incompleteStyleDirective() {
        let input = "flowchart TD\n    style"
        _ = parser.parse(input)
        // Must not crash.
    }

    @Test func incompleteClassDef() {
        let input = "flowchart TD\n    classDef"
        _ = parser.parse(input)
        // Must not crash.
    }

    // MARK: - Batch no-crash test

    @Test func batchNoCrash() {
        let inputs = [
            "",
            "flowchart",
            "flowchart TD",
            "flowchart TD\n",
            "graph",
            "graph LR\n-->",
            "flowchart TD\n    -->",
            "flowchart TD\n    A -->",
            "flowchart TD\n    --> B",
            "flowchart TD\n    A[",
            "flowchart TD\n    A(",
            "flowchart TD\n    A{",
            "flowchart TD\n    A(((",
            "flowchart TD\n    A[[",
            "flowchart TD\n    subgraph\n    subgraph\n    end",
            "flowchart TD\n    A & & B",
            "flowchart TD\n    A -.-.-> B",
            "flowchart TD\n    A ==== B",
            "sequenceDiagram",
            "sequenceDiagram\n    participant",
            "sequenceDiagram\n    ->>",
            "\n\n\n",
            "%%%",
            "flowchart TD\n    A[text with [brackets] inside]",
        ]
        RendererTestSupport.assertNoParseFailure(parser: parser, inputs: inputs)
    }

    // MARK: - Edge cases

    @Test func veryLongNodeId() {
        let longId = String(repeating: "a", count: 10000)
        let input = "flowchart TD\n    \(longId) --> B"
        let result = parser.parse(input)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.nodes.contains { $0.id == longId })
    }

    @Test func veryLongLabel() {
        let longLabel = String(repeating: "x", count: 10000)
        let input = "flowchart TD\n    A[\(longLabel)]"
        let result = parser.parse(input)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.nodes.first?.label == longLabel)
    }

    @Test func manyNodes() {
        var lines = ["flowchart TD"]
        for i in 0 ..< 1000 {
            lines.append("    N\(i) --> N\(i + 1)")
        }
        let result = parser.parse(lines.joined(separator: "\n"))
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.edges.count == 1000)
    }

    @Test func deeplyNestedSubgraphs() {
        var input = "flowchart TD\n"
        for i in 0 ..< 50 {
            input += String(repeating: "    ", count: i + 1) + "subgraph sg\(i)\n"
        }
        input += String(repeating: "    ", count: 51) + "A --> B\n"
        for i in (0 ..< 50).reversed() {
            input += String(repeating: "    ", count: i + 1) + "end\n"
        }
        let result = parser.parse(input)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.edges.count == 1)
    }
}
