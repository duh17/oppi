import CoreGraphics
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

    @Test func yamlFrontmatterBeforeHeaderIsSkipped() {
        let result = parser.parse("""
        ---
        title: Simple sample
        ---
        stateDiagram-v2
            [*] --> Still
            Still --> [*]
        """)
        guard case .state(let diagram) = result else {
            Issue.record("Expected state diagram")
            return
        }
        #expect(diagram.transitions.count == 2)
        #expect(diagram.states.contains { $0.id == "Still" })
    }

    @Test func accessibilityTitleAndDescriptionDirectives() {
        let result = parser.parse("""
        stateDiagram
            accTitle: This is the accessible title
            accDescr: This is an accessible description
            [*] --> Still
        """)
        guard case .state(let diagram) = result else {
            Issue.record("Expected state diagram")
            return
        }
        #expect(diagram.accessibilityTitle == "This is the accessible title")
        #expect(diagram.accessibilityDescription == "This is an accessible description")
        #expect(!diagram.states.contains { $0.id == "accTitle" || $0.id == "accDescr" })
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

    @Test func stateLabelsTransitionLabelsAndNotesNormalizeMermaidText() {
        let result = parser.parse("""
        stateDiagram-v2
            state "Quoted<br/>State #9829;" as s1
            s2 : "`Markdown #infin; label`"
            s1 --> s2: "Cross #35; bridge"
            note right of s2 : "Note<br/>Line #9829;"
        """)
        guard case .state(let diagram) = result else {
            Issue.record("Expected state diagram")
            return
        }
        #expect(diagram.states.first { $0.id == "s1" }?.label == "Quoted\nState ♥")
        #expect(diagram.states.first { $0.id == "s2" }?.label == "Markdown ∞ label")
        #expect(diagram.transitions.first?.label == "Cross # bridge")
        #expect(diagram.notes.first?.text == "Note\nLine ♥")
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

    @Test func inlineClassOperatorOnTransitionEndpoints() {
        let result = parser.parse("""
        stateDiagram
            classDef notMoving fill:white
            classDef movement font-style:italic;
            [*] --> Still:::notMoving
            Still --> Moving:::movement: started moving
            Crash:::movement --> [*]
        """)
        guard case .state(let diagram) = result else {
            Issue.record("Expected state diagram")
            return
        }
        #expect(diagram.transitions[0].to == .state("Still"))
        #expect(diagram.transitions[1].to == .state("Moving"))
        #expect(diagram.transitions[1].label == "started moving")
        #expect(diagram.transitions[2].from == .state("Crash"))
        #expect(diagram.states.first { $0.id == "Still" }?.classes == ["notMoving"])
        #expect(diagram.states.first { $0.id == "Moving" }?.classes == ["movement"])
        #expect(diagram.states.first { $0.id == "Crash" }?.classes == ["movement"])
    }

    @Test func compositeStateRendersAsClusterWithoutDuplicateNode() {
        let result = parser.parse("""
        stateDiagram-v2
            [*] --> First
            state First {
                [*] --> second
                second --> [*]
            }
            First --> [*]
        """)
        guard case .state(let diagram) = result else {
            Issue.record("Expected state diagram")
            return
        }
        #expect(diagram.transitions.contains { $0.scopeId == "First" })

        let renderer = MermaidFlowchartRenderer()
        let layout = renderer.layout(result, configuration: .default())
        let first = layout.flowchart.subgraphs.first { $0.id == "First" }
        #expect(first != nil)
        #expect(layout.graphResult.nodePositions["First"] == nil)
        #expect(first?.nodeIds.contains("second") == true)
        #expect(first?.nodeIds.contains { $0.hasPrefix("__state_start_") } == true)
        #expect(first?.nodeIds.contains { $0.hasPrefix("__state_end_") } == true)
        #expect(layout.edgeEndpointSubgraphs.values.contains { $0.to == "First" })
        #expect(layout.edgeEndpointSubgraphs.values.contains { $0.from == "First" })

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
