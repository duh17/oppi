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
    let renderer = MermaidRenderer()
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
        // Document canvases stay on content width (capped around a chat
        // bubble). More columns stay readable because each head keeps its
        // intrinsic width and the minimum gap.
        #expect(twoSize.width > 0)
        #expect(threeSize.width > 0)
        #expect(twoSize.width <= 600 + 0.5)
        #expect(threeSize.width >= twoSize.width - 0.5)
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

    // MARK: - Layout facts (Phase 1 fidelity)

    @Test func noteAppearsBeforeFollowingMessage() {
        let source = """
            sequenceDiagram
                Alice->>Bob: Hello
                Note over Alice,Bob: in between
                Bob-->>Alice: Hi
            """
        guard case .sequence(let diagram) = parser.parse(source) else {
            Issue.record("Expected sequence")
            return
        }
        let facts = MermaidSequenceRenderer.layoutFacts(diagram, configuration: config)
        let note = facts.notes.first { $0.text == "in between" }
        let hello = facts.messages.first { $0.text == "Hello" }
        let hi = facts.messages.first { $0.text == "Hi" }
        #expect(note != nil)
        #expect(hello != nil)
        #expect(hi != nil)
        guard let note, let hello, let hi else { return }
        #expect(hello.y < note.y, "Note must sit after the preceding message")
        #expect(note.rect.maxY <= hi.y, "Note must sit before the following message")
    }

    @Test func siblingFramesAreDisjoint() {
        let source = """
            sequenceDiagram
                Alice->>Bob: start
                alt first
                    Alice->>Bob: one
                end
                alt second
                    Alice->>Bob: two
                end
            """
        guard case .sequence(let diagram) = parser.parse(source) else {
            Issue.record("Expected sequence")
            return
        }
        let facts = MermaidSequenceRenderer.layoutFacts(diagram, configuration: config)
        let first = facts.frames.first { $0.label == "first" }
        let second = facts.frames.first { $0.label == "second" }
        #expect(first != nil)
        #expect(second != nil)
        guard let first, let second else { return }
        #expect(!first.rect.intersects(second.rect), "Sibling frames must not share a rect")
        #expect(first.rect.maxY <= second.rect.minY + 0.5 || second.rect.maxY <= first.rect.minY + 0.5)
    }

    @Test func nestedFramesAreInset() {
        let source = """
            sequenceDiagram
                alt outer
                    Alice->>Bob: one
                    alt inner
                        Alice->>Bob: two
                    end
                end
            """
        guard case .sequence(let diagram) = parser.parse(source) else {
            Issue.record("Expected sequence")
            return
        }
        let facts = MermaidSequenceRenderer.layoutFacts(diagram, configuration: config)
        let outer = facts.frames.first { $0.label == "outer" }
        let inner = facts.frames.first { $0.label == "inner" }
        #expect(outer != nil)
        #expect(inner != nil)
        guard let outer, let inner else { return }
        #expect(inner.rect.minX > outer.rect.minX, "Nested frames must inset")
        #expect(inner.rect.maxX < outer.rect.maxX)
        #expect(outer.rect.contains(inner.rect.insetBy(dx: 0.5, dy: 0.5)))
    }

    @Test func dividerYIsInsideParentFrame() {
        let source = """
            sequenceDiagram
                alt is sick
                    Bob->>Alice: Not so good
                else is well
                    Bob->>Alice: Feeling fresh
                end
            """
        guard case .sequence(let diagram) = parser.parse(source) else {
            Issue.record("Expected sequence")
            return
        }
        let facts = MermaidSequenceRenderer.layoutFacts(diagram, configuration: config)
        let parent = facts.frames.first { $0.label == "is sick" }
        let divider = facts.dividers.first { $0.label == "is well" }
        #expect(parent != nil)
        #expect(divider != nil)
        guard let parent, let divider else { return }
        #expect(divider.y > parent.rect.minY)
        #expect(divider.y < parent.rect.maxY)
    }

    @Test func activationRectExistsAndHasExtent() {
        let source = """
            sequenceDiagram
                Alice->>+John: Hello John, how are you?
                John-->>-Alice: Great!
            """
        guard case .sequence(let diagram) = parser.parse(source) else {
            Issue.record("Expected sequence")
            return
        }
        let facts = MermaidSequenceRenderer.layoutFacts(diagram, configuration: config)
        let bar = facts.activations.first { $0.participantId == "John" }
        #expect(bar != nil, "Activation shorthand must produce a bar")
        guard let bar else { return }
        #expect(bar.rect.height > 1, "Activation rect must have extent")
        #expect(bar.rect.width > 0)
    }

    @Test func keywordActivationRectExistsAndHasExtent() {
        let source = """
            sequenceDiagram
                Alice->>John: Hello John, how are you?
                activate John
                John-->>Alice: Great!
                deactivate John
            """
        guard case .sequence(let diagram) = parser.parse(source) else {
            Issue.record("Expected sequence")
            return
        }
        let facts = MermaidSequenceRenderer.layoutFacts(diagram, configuration: config)
        let bar = facts.activations.first { $0.participantId == "John" }
        #expect(bar != nil, "activate/deactivate keywords must produce a bar")
        guard let bar else { return }
        #expect(bar.rect.height > 1)
    }

    @Test func inlineModeOmitsBottomParticipantCopies() {
        let source = "sequenceDiagram\n    Alice->>Bob: Hello"
        guard case .sequence(let diagram) = parser.parse(source) else {
            Issue.record("Expected sequence")
            return
        }
        let inline = RenderConfiguration(
            fontSize: config.fontSize,
            maxWidth: config.maxWidth,
            theme: config.theme,
            displayMode: .inline
        )
        let facts = MermaidSequenceRenderer.layoutFacts(diagram, configuration: inline)
        #expect(facts.bottomParticipantCopyCount == 0)
    }

    @Test func documentModeDrawsBottomParticipantCopies() {
        let source = "sequenceDiagram\n    Alice->>Bob: Hello"
        guard case .sequence(let diagram) = parser.parse(source) else {
            Issue.record("Expected sequence")
            return
        }
        let facts = MermaidSequenceRenderer.layoutFacts(diagram, configuration: config)
        #expect(facts.bottomParticipantCopyCount == 2)
    }

    @Test func createDestroyAffectLayoutFacts() {
        let source = """
            sequenceDiagram
                Alice->>Bob: Hello Bob
                create participant Carl
                Alice->>Carl: Hi Carl!
                destroy Carl
                Alice-xCarl: We are too many
            """
        guard case .sequence(let diagram) = parser.parse(source) else {
            Issue.record("Expected sequence")
            return
        }
        let facts = MermaidSequenceRenderer.layoutFacts(diagram, configuration: config)
        #expect(facts.createdParticipantIds.contains("Carl"))
        #expect(facts.destroyedParticipantIds.contains("Carl"))
        let createY = facts.createYByParticipant["Carl"]
        let destroyY = facts.destroyYByParticipant["Carl"]
        #expect(createY != nil)
        #expect(destroyY != nil)
        if let createY, let destroyY {
            #expect(createY < destroyY)
        }
    }

    @Test func destroyMarkerSitsOnDestroyingMessageArrow() {
        let source = """
            sequenceDiagram
                Alice->>Bob: Hello Bob
                create participant Carl
                Alice->>Carl: Hi Carl!
                destroy Carl
                Alice-xCarl: We are too many
            """
        guard case .sequence(let diagram) = parser.parse(source) else {
            Issue.record("Expected sequence")
            return
        }
        let facts = MermaidSequenceRenderer.layoutFacts(diagram, configuration: config)
        let destroyY = facts.destroyYByParticipant["Carl"]
        let destroying = facts.messages.first { $0.text == "We are too many" }
        #expect(destroyY != nil)
        #expect(destroying != nil)
        guard let destroyY, let destroying else { return }
        #expect(
            abs(destroyY - destroying.y) < 0.5,
            "Destroy X must sit on Alice-xCarl arrow Y, not above it. destroyY=\(destroyY) arrowY=\(destroying.y)"
        )
    }

    static let sequenceStressCase = """
        sequenceDiagram
            Alice->>+John: Hello John, how are you?
            Note over Alice,John: A typical interaction
            alt is sick
                John->>Alice: Not so good
                Note right of John: Needs rest
            else is well
                John-->>-Alice: Feeling fresh like a daisy
                Note left of Alice: All good
            end
        """

    @Test(arguments: [5, 6])
    func narrowParticipantHeadsStayDisjointWithoutCompressingBelowGap(count: Int) {
        let names = ["Alice", "Bob", "Carol", "Dave", "Erin", "Frank"]
        let declared = names.prefix(count).map { "    participant \($0)" }.joined(separator: "\n")
        let source = """
            sequenceDiagram
            \(declared)
                Alice->>Bob: Hello
            """
        guard case .sequence(let diagram) = parser.parse(source) else {
            Issue.record("Expected sequence")
            return
        }
        let narrow = RenderConfiguration(
            fontSize: config.fontSize,
            maxWidth: 360,
            theme: config.theme,
            displayMode: .inline
        )
        let facts = MermaidSequenceRenderer.layoutFacts(diagram, configuration: narrow)
        let minGap = config.fontSize * 2.2
        #expect(facts.participants.count == count)
        assertParticipantsReadable(facts, minGap: minGap)
    }

    @Test func sequenceUsesAvailableWidthWithoutShrinkingBoxes() {
        guard case .sequence(let diagram) = parser.parse(Self.sequenceStressCase) else {
            Issue.record("Expected sequence")
            return
        }
        let minGap = config.fontSize * 2.2
        let narrow = RenderConfiguration(
            fontSize: config.fontSize,
            maxWidth: 360,
            theme: config.theme,
            displayMode: .inline
        )
        let wide = RenderConfiguration(
            fontSize: config.fontSize,
            maxWidth: 800,
            theme: config.theme,
            displayMode: .document
        )
        let narrowFacts = MermaidSequenceRenderer.layoutFacts(diagram, configuration: narrow)
        let wideFacts = MermaidSequenceRenderer.layoutFacts(diagram, configuration: wide)

        #expect(narrowFacts.participants.count == 2)
        #expect(wideFacts.participants.count == 2)
        assertParticipantsReadable(narrowFacts, minGap: minGap)
        assertParticipantsReadable(wideFacts, minGap: minGap)

        for (narrowHead, wideHead) in zip(narrowFacts.participants, wideFacts.participants) {
            #expect(
                abs(narrowHead.rect.width - wideHead.rect.width) < 0.5,
                "\(narrowHead.id) box width changed from \(narrowHead.rect.width) to \(wideHead.rect.width)"
            )
        }

        let narrowGap = narrowFacts.participants[1].rect.minX - narrowFacts.participants[0].rect.maxX
        let wideGap = wideFacts.participants[1].rect.minX - wideFacts.participants[0].rect.maxX
        #expect(
            wideFacts.size.width < 500,
            "Document 800pt must keep content width, not stretch to the canvas, got \(wideFacts.size.width)"
        )
        #expect(
            abs(wideFacts.size.width - narrowFacts.size.width) < 8,
            "360 vs 800 sequence widths should match, narrow=\(narrowFacts.size.width) wide=\(wideFacts.size.width)"
        )
        #expect(
            abs(wideGap - narrowGap) < 8,
            "Document layout must not stretch participant span past the chat bubble, narrowGap=\(narrowGap) wideGap=\(wideGap)"
        )
    }

    @Test func narrowSequenceMayExceedViewportInsteadOfOverlapping() {
        let source = """
            sequenceDiagram
                participant Alice
                participant Bob
                participant Carol
                participant Dave
                participant Erin
                participant Frank
                Alice->>Frank: Hello
            """
        guard case .sequence(let diagram) = parser.parse(source) else {
            Issue.record("Expected sequence")
            return
        }
        let minGap = config.fontSize * 2.2
        let narrow = RenderConfiguration(
            fontSize: config.fontSize,
            maxWidth: 200,
            theme: config.theme,
            displayMode: .inline
        )
        let facts = MermaidSequenceRenderer.layoutFacts(diagram, configuration: narrow)
        assertParticipantsReadable(facts, minGap: minGap)
        #expect(
            facts.size.width > 200 + 0.5,
            "Too-narrow viewport must keep a wider natural canvas, got \(facts.size.width)"
        )
    }

    @Test func keywordActivationAnchorsToAssociatedMessageRow() {
        let shorthand = """
            sequenceDiagram
                Alice->>+John: Hello John, how are you?
                John-->>-Alice: Great!
            """
        let keywords = """
            sequenceDiagram
                Alice->>John: Hello John, how are you?
                activate John
                John-->>Alice: Great!
                deactivate John
            """
        guard case .sequence(let shorthandDiagram) = parser.parse(shorthand),
              case .sequence(let keywordDiagram) = parser.parse(keywords)
        else {
            Issue.record("Expected sequence")
            return
        }
        let shorthandFacts = MermaidSequenceRenderer.layoutFacts(shorthandDiagram, configuration: config)
        let keywordFacts = MermaidSequenceRenderer.layoutFacts(keywordDiagram, configuration: config)
        let shorthandBar = shorthandFacts.activations.first { $0.participantId == "John" }
        let keywordBar = keywordFacts.activations.first { $0.participantId == "John" }
        let hello = keywordFacts.messages.first { $0.text == "Hello John, how are you?" }
        let great = keywordFacts.messages.first { $0.text == "Great!" }
        #expect(shorthandBar != nil)
        #expect(keywordBar != nil)
        #expect(hello != nil)
        #expect(great != nil)
        guard let shorthandBar, let keywordBar, let hello, let great else { return }
        #expect(
            abs(keywordBar.rect.minY - hello.y) < 0.5,
            "activate must start on the associated message arrow, not after message spacing"
        )
        #expect(
            abs(keywordBar.rect.maxY - great.y) < 0.5,
            "deactivate must end on the associated message arrow"
        )
        #expect(abs(keywordBar.rect.minY - shorthandBar.rect.minY) < 0.5)
        #expect(abs(keywordBar.rect.maxY - shorthandBar.rect.maxY) < 0.5)
    }

    @Test func destroyedParticipantsOmittedFromDocumentBottomCopies() {
        let source = """
            sequenceDiagram
                Alice->>Bob: Hello Bob
                create participant Carl
                Alice->>Carl: Hi Carl!
                destroy Carl
                Alice-xCarl: We are too many
            """
        guard case .sequence(let diagram) = parser.parse(source) else {
            Issue.record("Expected sequence")
            return
        }
        let facts = MermaidSequenceRenderer.layoutFacts(diagram, configuration: config)
        #expect(facts.destroyedParticipantIds.contains("Carl"))
        #expect(
            facts.bottomParticipantCopyCount == 2,
            "Destroyed Carl must not reappear in document-mode bottom copies"
        )
    }

    @Test func destroyClipsActivationBarAtKillingArrow() {
        let source = """
            sequenceDiagram
                Alice->>+Carl: Hi Carl!
                destroy Carl
                Alice-xCarl: We are too many
                Alice->>Bob: still here
            """
        guard case .sequence(let diagram) = parser.parse(source) else {
            Issue.record("Expected sequence")
            return
        }
        let facts = MermaidSequenceRenderer.layoutFacts(diagram, configuration: config)
        let bar = facts.activations.first { $0.participantId == "Carl" }
        let start = facts.messages.first { $0.text == "Hi Carl!" }
        let killing = facts.messages.first { $0.text == "We are too many" }
        let later = facts.messages.first { $0.text == "still here" }
        let destroyY = facts.destroyYByParticipant["Carl"]
        #expect(bar != nil, "Activation on Carl must produce a bar")
        #expect(start != nil)
        #expect(killing != nil)
        #expect(later != nil)
        #expect(destroyY != nil)
        guard let bar, let start, let killing, let later, let destroyY else { return }
        #expect(
            abs(bar.rect.minY - start.y) < 0.5,
            "Bar must start on Hi Carl!, not after message spacing"
        )
        #expect(
            abs(destroyY - killing.y) < 0.5,
            "Destroy X must sit on the killing arrow"
        )
        #expect(
            abs(bar.rect.maxY - destroyY) < 0.5,
            "Destroy must clip Carl's bar at the killing-arrow Y, not contentEndY. maxY=\(bar.rect.maxY) destroyY=\(destroyY)"
        )
        #expect(
            bar.rect.maxY < later.y - 0.5,
            "Bar must not continue past the truncated lifeline onto later messages"
        )
    }

    @Test func unmatchedActivationClosesAtLastArrow() {
        let shorthand = """
            sequenceDiagram
                Alice->>+Bob: Hello
                Bob->>Alice: Hi
            """
        let keywords = """
            sequenceDiagram
                Alice->>Bob: Hello
                activate Bob
                Bob->>Alice: Hi
            """
        guard case .sequence(let shorthandDiagram) = parser.parse(shorthand),
              case .sequence(let keywordDiagram) = parser.parse(keywords)
        else {
            Issue.record("Expected sequence")
            return
        }
        let shorthandFacts = MermaidSequenceRenderer.layoutFacts(shorthandDiagram, configuration: config)
        let keywordFacts = MermaidSequenceRenderer.layoutFacts(keywordDiagram, configuration: config)
        let shorthandBar = shorthandFacts.activations.first { $0.participantId == "Bob" }
        let keywordBar = keywordFacts.activations.first { $0.participantId == "Bob" }
        let last = shorthandFacts.messages.first { $0.text == "Hi" }
        #expect(shorthandBar != nil, "Unmatched +/- must still produce a bar")
        #expect(keywordBar != nil, "Unmatched activate must still produce a bar")
        #expect(last != nil)
        guard let shorthandBar, let keywordBar, let last else { return }
        #expect(
            abs(shorthandBar.rect.maxY - last.y) < 0.5,
            "Unmatched +/- must close at the last arrow, not after post-message spacing. maxY=\(shorthandBar.rect.maxY) lastY=\(last.y)"
        )
        #expect(
            abs(keywordBar.rect.maxY - last.y) < 0.5,
            "Unmatched activate must close at the last arrow, not after post-message spacing"
        )
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

    private func assertParticipantsReadable(_ facts: SequenceLayoutFacts, minGap: CGFloat) {
        for (index, participant) in facts.participants.enumerated() {
            #expect(
                abs(participant.centerX - participant.rect.midX) < 0.5,
                "Lifeline must stay centered under \(participant.id)"
            )
            #expect(participant.rect.minX >= -0.5, "\(participant.id) clips the left edge")
            #expect(
                participant.rect.maxX <= facts.size.width + 0.5,
                "\(participant.id) clips customSize (maxX=\(participant.rect.maxX) width=\(facts.size.width))"
            )
            if index > 0 {
                let previous = facts.participants[index - 1]
                let gap = participant.rect.minX - previous.rect.maxX
                #expect(
                    gap >= minGap - 0.5,
                    "Gap below minimum: \(previous.id) to \(participant.id) gap=\(gap) min=\(minGap)"
                )
            }
        }
    }
}
