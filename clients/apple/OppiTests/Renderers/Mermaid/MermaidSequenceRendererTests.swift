import CoreGraphics
import Testing
@testable import Oppi

/// Tests for the Mermaid sequence diagram renderer.
///
/// Validates layout sizing, participant positioning, message rendering,
/// and arrow style coverage. Drawing tests use a bitmap CGContext to
/// verify no crashes during actual Core Graphics calls.
@Suite("Mermaid Sequence Renderer")
struct MermaidSequenceRendererTests {
    let parser = MermaidParser()
    let renderer = MermaidFlowchartRenderer()
    let config = RenderConfiguration.default(maxWidth: 600)

    // MARK: - Helpers

    /// Parse a sequence diagram and return its layout.
    private func layoutFor(_ source: String) -> MermaidFlowchartRenderer.FlowchartLayout {
        let diagram = parser.parse(source)
        return renderer.layout(diagram, configuration: config)
    }

    /// Create a bitmap context and draw the layout into it. Returns true if no crash.
    @discardableResult
    private func drawLayout(_ layout: MermaidFlowchartRenderer.FlowchartLayout) -> Bool {
        let size = renderer.boundingBox(layout)
        guard size.width > 0, size.height > 0 else { return false }
        let ctx = CGContext(
            data: nil,
            width: max(1, Int(size.width)),
            height: max(1, Int(size.height)),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        renderer.draw(layout, in: ctx, at: .zero)
        return true
    }

    // MARK: - Layout sizing

    @Test func nonZeroSizeForBasicDiagram() {
        let layout = layoutFor("sequenceDiagram\n    Alice->>Bob: Hello")
        let size = renderer.boundingBox(layout)
        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    @Test func emptyDiagramDoesNotCrash() {
        let layout = layoutFor("sequenceDiagram")
        let size = renderer.boundingBox(layout)
        // Should produce some size (even if small) and not crash.
        #expect(size.width > 0)
        #expect(size.height > 0)
        drawLayout(layout)
    }

    @Test func customDrawIsSet() {
        let layout = layoutFor("sequenceDiagram\n    Alice->>Bob: Hello")
        #expect(layout.customDraw != nil)
        #expect(layout.customSize != nil)
    }

    // MARK: - Participants

    @Test func multipleParticipantsProduceWiderLayout() {
        let twoParticipants = layoutFor("""
            sequenceDiagram
                Alice->>Bob: Hello
            """)
        let threeParticipants = layoutFor("""
            sequenceDiagram
                participant Alice
                participant Bob
                participant Carol
                Alice->>Bob: Hello
            """)

        let twoSize = renderer.boundingBox(twoParticipants)
        let threeSize = renderer.boundingBox(threeParticipants)
        #expect(threeSize.width > twoSize.width)
    }

    @Test func moreMessagesProduceTallerLayout() {
        let oneMessage = layoutFor("""
            sequenceDiagram
                Alice->>Bob: Hello
            """)
        let threeMessages = layoutFor("""
            sequenceDiagram
                Alice->>Bob: Hello
                Bob->>Alice: Hi
                Alice->>Bob: How are you?
            """)

        let oneSize = renderer.boundingBox(oneMessage)
        let threeSize = renderer.boundingBox(threeMessages)
        #expect(threeSize.height > oneSize.height)
    }

    @Test func participantsWithActorFlag() {
        // Actors should still produce a valid layout.
        let layout = layoutFor("""
            sequenceDiagram
                actor Alice
                participant Bob
                Alice->>Bob: Hello
            """)
        let size = renderer.boundingBox(layout)
        #expect(size.width > 0)
        #expect(size.height > 0)
        drawLayout(layout)
    }

    @Test func participantStereotypeMetadataRenders() {
        let layout = layoutFor("""
            sequenceDiagram
                participant API@{ "type": "boundary", "alias": "Public API" }
                participant Auth@{ "type": "control", "alias": "Auth Service" }
                participant User@{ "type": "entity", "alias": "User Entity" }
                participant DB@{ "type": "database", "alias": "User Database" }
                participant Cache@{ "type": "collections", "alias": "Cache Cluster" }
                participant Queue@{ "type": "queue", "alias": "Job Queue" }
                API->>Auth: Login
                Auth->>User: Load
                Auth->>DB: Query
                Auth->>Cache: Store
                Auth->>Queue: Enqueue
            """)
        let size = renderer.boundingBox(layout)
        #expect(size.width > 0)
        #expect(size.height > 0)
        #expect(drawLayout(layout))
    }

    // MARK: - Messages between participants

    @Test func messagesBetweenParticipantsRender() {
        let layout = layoutFor("""
            sequenceDiagram
                Alice->>Bob: Request
                Bob-->>Alice: Response
            """)
        #expect(drawLayout(layout))
    }

    @Test func messageToNonAdjacentParticipant() {
        let layout = layoutFor("""
            sequenceDiagram
                participant Alice
                participant Bob
                participant Carol
                Alice->>Carol: Skip Bob
            """)
        let size = renderer.boundingBox(layout)
        #expect(size.width > 0)
        #expect(size.height > 0)
        #expect(drawLayout(layout))
    }

    // MARK: - Blocks and notes

    @Test func sequenceBlocksAndRectsRender() {
        let layout = layoutFor("""
            sequenceDiagram
                participant Alice
                participant Bob
                rect rgb(191, 223, 255)
                    Alice->>Bob: Hello
                    loop Every minute
                        Bob-->>Alice: Ping
                    end
                end
                alt ok
                    Alice->>Bob: Done
                else retry
                    Bob-->>Alice: Again
                end
        """)
        let size = renderer.boundingBox(layout)
        #expect(size.width > 0)
        #expect(size.height > 0)
        #expect(drawLayout(layout))
    }

    @Test func sequenceBoxesRender() {
        let layout = layoutFor("""
            sequenceDiagram
                box Purple Alice and Bob
                    participant Alice
                    participant Bob
                end
                box transparent Carol
                    participant Carol
                end
                box hsl(10, 40%, 90%) Service
                    participant Service
                end
                Alice->>Bob: Hello
                Bob->>Carol: Forward
                Carol->>Service: Render color
        """)
        let size = renderer.boundingBox(layout)
        #expect(size.width > 0)
        #expect(size.height > 0)
        #expect(drawLayout(layout))
    }

    @Test func sequenceNotesRenderAndAffectHeight() {
        let withoutNote = layoutFor("""
            sequenceDiagram
                Alice->>Bob: Hello
            """)
        let withNote = layoutFor("""
            sequenceDiagram
                Alice->>Bob: Hello
                Note right of Bob: A rendered note
                Note over Alice,Bob: A spanning note
                Note left of Alice: A left note
            """)
        let withoutSize = renderer.boundingBox(withoutNote)
        let withSize = renderer.boundingBox(withNote)
        #expect(withSize.height > withoutSize.height)
        #expect(drawLayout(withNote))
    }

    // MARK: - Self-messages

    @Test func selfMessageRenders() {
        let layout = layoutFor("""
            sequenceDiagram
                Alice->>Alice: Think
            """)
        let size = renderer.boundingBox(layout)
        #expect(size.width > 0)
        #expect(size.height > 0)
        #expect(drawLayout(layout))
    }

    @Test func selfMessageRendersWithNonZeroSize() {
        let withSelf = layoutFor("""
            sequenceDiagram
                Alice->>Alice: Self
            """)
        let selfSize = renderer.boundingBox(withSelf)
        #expect(selfSize.width > 0)
        #expect(selfSize.height > 0)
    }

    // MARK: - Arrow styles

    @Test func solidArrowRenders() {
        let layout = layoutFor("sequenceDiagram\n    Alice->>Bob: Solid arrow")
        #expect(drawLayout(layout))
    }

    @Test func dashedArrowRenders() {
        let layout = layoutFor("sequenceDiagram\n    Alice-->>Bob: Dashed arrow")
        #expect(drawLayout(layout))
    }

    @Test func solidOpenRenders() {
        let layout = layoutFor("sequenceDiagram\n    Alice->Bob: Solid open")
        #expect(drawLayout(layout))
    }

    @Test func dashedOpenRenders() {
        let layout = layoutFor("sequenceDiagram\n    Alice-->Bob: Dashed open")
        #expect(drawLayout(layout))
    }

    @Test func solidCrossRenders() {
        let layout = layoutFor("sequenceDiagram\n    Alice-xBob: Solid cross")
        #expect(drawLayout(layout))
    }

    @Test func dashedCrossRenders() {
        let layout = layoutFor("sequenceDiagram\n    Alice--xBob: Dashed cross")
        #expect(drawLayout(layout))
    }

    @Test func allArrowStylesInOneDiagram() {
        let layout = layoutFor("""
            sequenceDiagram
                Alice->>Bob: solid
                Bob-->>Alice: dashed
                Alice->Bob: solidOpen
                Bob-->Alice: dashedOpen
                Alice-xBob: solidCross
                Bob--xAlice: dashedCross
            """)
        let size = renderer.boundingBox(layout)
        #expect(size.width > 0)
        #expect(size.height > 0)
        #expect(drawLayout(layout))
    }

    @Test func v11ArrowStylesRender() {
        let layout = layoutFor(#"""
            sequenceDiagram
                Alice<<->>Bob: bidirectional
                Alice<<-->>Bob: dashed bidirectional
                Alice-\|\Bob: top half
                Alice--\|/Bob: dashed bottom half
                Alice/\|-Bob: reverse top half
                Alice\\--Bob: dashed reverse bottom half
                Alice-\\Bob: top stick
                Alice--//Bob: dashed bottom stick
                Alice//--Bob: dashed reverse top stick
                Alice->>()Bob: central end
                Alice()->>Bob: central start
            """#)
        let size = renderer.boundingBox(layout)
        #expect(size.width > 0)
        #expect(size.height > 0)
        #expect(drawLayout(layout))
    }

    @Test func autonumberStartAndIncrementRender() {
        let layout = layoutFor("""
            sequenceDiagram
                autonumber 10.5 0.25
                Alice->>Bob: One
                Bob-->>Alice: Two
            """)
        let size = renderer.boundingBox(layout)
        #expect(size.width > 0)
        #expect(size.height > 0)
        #expect(drawLayout(layout))
    }

    // MARK: - Complex diagrams

    @Test func complexDiagramDoesNotCrash() {
        let layout = layoutFor("""
            sequenceDiagram
                participant Browser
                participant Server
                participant Database
                Browser->>Server: GET /api/data
                Server->>Database: SELECT * FROM items
                Database-->>Server: rows
                Server-->>Browser: 200 OK
                Browser->>Browser: Render UI
            """)
        let size = renderer.boundingBox(layout)
        #expect(size.width > 0)
        #expect(size.height > 0)
        #expect(drawLayout(layout))
    }

    @Test func renderOutputIsGraphical() {
        let diagram = parser.parse("sequenceDiagram\n    Alice->>Bob: Hello")
        let output = renderer.render(diagram, configuration: config)
        guard case .graphical(let result) = output else {
            Issue.record("Expected graphical output for sequence diagram")
            return
        }
        #expect(result.boundingBox.width > 0)
        #expect(result.boundingBox.height > 0)
    }

    @Test func renderDrawDoesNotCrash() {
        let diagram = parser.parse("""
            sequenceDiagram
                participant A
                participant B
                A->>B: msg1
                B-->>A: msg2
                A->>A: self
            """)
        let output = renderer.render(diagram, configuration: config)
        guard case .graphical(let result) = output else {
            Issue.record("Expected graphical output")
            return
        }
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
