import Testing
@testable import Oppi

// SPEC: https://github.com/mermaid-js/mermaid/blob/develop/packages/mermaid/src/docs/syntax/stateDiagram.md
//
// Conformance tests for Mermaid state diagrams (`stateDiagram` and `stateDiagram-v2`).

@Suite("Mermaid State Diagram Conformance")
struct MermaidStateConformanceTests {
    let parser = MermaidParser()

    @Test func stateDiagramV2HeaderIsSupported() {
        let result = parser.parse("""
        stateDiagram-v2
            [*] --> Still
            Still --> [*]
        """)
        guard case .state(let diagram) = result else {
            Issue.record("Expected state diagram, got \(result)")
            return
        }
        #expect(diagram.transitions.count == 2)
        #expect(diagram.states.contains { $0.id == "Still" })
    }

    @Test func oldStateDiagramHeaderIsSupported() {
        let result = parser.parse("""
        stateDiagram
            [*] --> Still
            Still --> Moving
        """)
        guard case .state(let diagram) = result else {
            Issue.record("Expected state diagram")
            return
        }
        #expect(diagram.transitions.count == 2)
    }

    @Test func stateDeclarationsAndDescriptions() {
        let result = parser.parse("""
        stateDiagram-v2
            stateId
            state "This is a state description" as s2
            s3 : This is another description
        """)
        guard case .state(let diagram) = result else {
            Issue.record("Expected state diagram")
            return
        }
        #expect(diagram.states.first { $0.id == "stateId" }?.label == "stateId")
        #expect(diagram.states.first { $0.id == "s2" }?.label == "This is a state description")
        #expect(diagram.states.first { $0.id == "s3" }?.label == "This is another description")
    }

    @Test func transitionLabelsAndTerminalState() {
        let result = parser.parse("""
        stateDiagram-v2
            [*] --> s1
            s1 --> s2: A transition
            s2 --> [*]
        """)
        guard case .state(let diagram) = result else {
            Issue.record("Expected state diagram")
            return
        }
        #expect(diagram.transitions[0].from == .terminal)
        #expect(diagram.transitions[0].to == .state("s1"))
        #expect(diagram.transitions[1].label == "A transition")
        #expect(diagram.transitions[2].to == .terminal)
    }

    @Test func compositeStateAndNestedDirection() {
        let result = parser.parse("""
        stateDiagram-v2
            [*] --> First
            state First {
                direction LR
                [*] --> second
                second --> [*]
            }
        """)
        guard case .state(let diagram) = result else {
            Issue.record("Expected state diagram")
            return
        }
        #expect(diagram.composites.count == 1)
        #expect(diagram.composites[0].id == "First")
        #expect(diagram.composites[0].direction == .LR)
        #expect(diagram.composites[0].stateIds.contains("second"))
    }

    @Test func choiceForkJoinDeclarations() {
        let result = parser.parse("""
        stateDiagram-v2
            state if_state <<choice>>
            state fork_state <<fork>>
            state join_state <<join>>
        """)
        guard case .state(let diagram) = result else {
            Issue.record("Expected state diagram")
            return
        }
        #expect(diagram.states.first { $0.id == "if_state" }?.kind == .choice)
        #expect(diagram.states.first { $0.id == "fork_state" }?.kind == .fork)
        #expect(diagram.states.first { $0.id == "join_state" }?.kind == .join)
    }

    @Test func notesAndConcurrencyRegions() {
        let result = parser.parse("""
        stateDiagram-v2
            State1: The state with a note
            note right of State1
                Important information!
                You can write notes.
            end note
            note left of State2 : This is the note to the left.
            state Active {
                [*] --> NumLockOff
                --
                [*] --> CapsLockOff
            }
        """)
        guard case .state(let diagram) = result else {
            Issue.record("Expected state diagram")
            return
        }
        #expect(diagram.notes.count == 2)
        #expect(diagram.notes[0].position == .rightOf)
        #expect(diagram.notes[0].text.contains("Important information!"))
        #expect(diagram.notes[1].position == .leftOf)
        #expect(diagram.composites.first { $0.id == "Active" }?.regions.count == 1)
    }

    @Test func classDefsAndClassApplications() {
        let result = parser.parse("""
        stateDiagram
            classDef movement font-style:italic;
            Still --> Moving
            Moving --> Crash
            class Moving, Crash movement
        """)
        guard case .state(let diagram) = result else {
            Issue.record("Expected state diagram")
            return
        }
        #expect(diagram.classDefs["movement"]?["font-style"] == "italic")
        #expect(diagram.states.first { $0.id == "Moving" }?.classes == ["movement"])
        #expect(diagram.states.first { $0.id == "Crash" }?.classes == ["movement"])
    }

    @Test func stateDiagramRendersAsDiagramNotUnsupportedPlaceholder() {
        let result = parser.parse("""
        stateDiagram-v2
            classDef movement fill:#ff0,stroke:#000
            [*] --> Still
            Still --> Moving
            class Moving movement
            note right of Moving : In motion
            state Moving {
                [*] --> Rolling
                --
                [*] --> Gliding
            }
            Moving --> [*]
        """)
        let renderer = MermaidFlowchartRenderer()
        let layout = renderer.layout(result, configuration: .default())
        #expect(layout.isPlaceholder == false)
        #expect(renderer.boundingBox(layout).height > 40)
        #expect(layout.nodeLabels.values.contains("In motion"))
        #expect(layout.styleDirectives["Moving"]?["fill"] == "#ff0")
        #expect(layout.flowchart.subgraphs.contains { $0.id == "Moving" && $0.nodeIds.contains("Rolling") && $0.regionCount == 1 })
    }
}
