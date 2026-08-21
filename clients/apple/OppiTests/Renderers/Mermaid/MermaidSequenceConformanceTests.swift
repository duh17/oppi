import Testing
@testable import Oppi

// SPEC: https://github.com/mermaid-js/mermaid/blob/develop/packages/mermaid/src/docs/syntax/sequenceDiagram.md
//
// Tests for sequence diagram features not yet covered.
// Each test references the spec section it validates.
//
// COVERAGE (new):
// [ ] Notes: right of, left of, over single, over two actors
// [ ] Loops: loop...end
// [ ] Alt/else/opt: alt...else...end, opt...end
// [ ] Parallel: par...and...end
// [ ] Critical: critical...option...end
// [ ] Break: break...end
// [ ] Activations: activate/deactivate keywords
// [ ] Activation shorthand: ->>+ and -->>-
// [ ] Async arrows: -) and --)
// [ ] Autonumber directive
// [ ] Boxes/grouping: box...end
// [ ] Rect background highlighting: rect...end
// [ ] Comments in sequence diagrams
// [x] Participant stereotype metadata: participant A@{ "type": "database" }
// [x] Participant aliases: external `as`, inline `alias`, external precedence
// [x] Actor creation/destruction directives
// [x] Entity codes in messages
// [x] Bidirectional arrows and v11.12.3 half-arrow syntax
// [x] Central connection `()` endpoints
// [x] Autonumber start/increment values
// [x] Actor menu link and JSON links syntax

@Suite("Sequence Diagram Conformance — Missing Features")
struct MermaidSequenceConformanceTests {
    let parser = MermaidParser()

    // MARK: - Participants and actors

    /// SPEC: ### Database / Boundary / Control — participant metadata config.
    @Test func participantMetadataTypeAndInlineAlias() {
        let result = parser.parse("""
        sequenceDiagram
            participant API@{ "type": "boundary", "alias": "Public API" }
            participant DB@{ "type": "database", "alias": "User Database" }
            API->>DB: Query user
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        let api = d.participants.first { $0.id == "API" }
        let db = d.participants.first { $0.id == "DB" }
        #expect(api?.label == "Public API")
        #expect(api?.kind == .boundary)
        #expect(db?.label == "User Database")
        #expect(db?.kind == .database)
    }

    /// SPEC: #### Alias Precedence — external alias wins over inline alias.
    @Test func participantExternalAliasOverridesInlineAlias() {
        let result = parser.parse("""
        sequenceDiagram
            participant API@{ "type": "control", "alias": "Internal Name" } as External Name
            API->>API: Ping
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        let api = d.participants.first { $0.id == "API" }
        #expect(api?.label == "External Name")
        #expect(api?.kind == .control)
    }

    /// SPEC: ### Actor Creation and Destruction — create supports actors, participants, and aliases.
    @Test func createAndDestroyActorParticipantDirectives() {
        let result = parser.parse("""
        sequenceDiagram
            Alice->>Bob: Hello Bob
            create participant Carl
            Alice->>Carl: Hi Carl!
            create actor D as Donald
            Carl->>D: Hi!
            destroy Carl
            Alice-xCarl: We are too many
            destroy Bob
            Bob->>Alice: I agree
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        #expect(d.participants.first { $0.id == "Carl" }?.label == "Carl")
        let donald = d.participants.first { $0.id == "D" }
        #expect(donald?.label == "Donald")
        #expect(donald?.isActor == true)
        #expect(donald?.kind == .actor)
        #expect(d.messages.count == 5)
    }

    // MARK: - Notes

    /// Event stream keeps notes in chronological order with messages.
    @Test func eventsPreserveNoteAndMessageOrder() {
        let result = parser.parse("""
        sequenceDiagram
            Alice->>Bob: Hello
            Note over Alice,Bob: in between
            Bob-->>Alice: Hi
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        guard d.events.count >= 3 else {
            Issue.record("Expected at least 3 events, got \(d.events.count)")
            return
        }
        guard case .message(let first) = d.events[0] else {
            Issue.record("Expected first event to be a message")
            return
        }
        guard case .note(let note) = d.events[1] else {
            Issue.record("Expected second event to be a note")
            return
        }
        guard case .message(let second) = d.events[2] else {
            Issue.record("Expected third event to be a message")
            return
        }
        #expect(first.text == "Hello")
        #expect(note.text == "in between")
        #expect(second.text == "Hi")
        #expect(d.messages.map(\.text) == ["Hello", "Hi"])
        #expect(d.notes.map(\.text) == ["in between"])
    }

    /// SPEC: ## Notes — `Note right of John: Text in note`
    @Test func noteRightOf() {
        let result = parser.parse("""
        sequenceDiagram
            participant John
            Note right of John: Text in note
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        #expect(d.participants.count == 1)
        // The note should be in the diagram's elements.
        // Notes are not messages — they should be a separate AST node.
        #expect(!d.notes.isEmpty, "Should have parsed the note")
        let note = d.notes.first
        #expect(note?.text == "Text in note")
        #expect(note?.position == .rightOf)
        #expect(note?.actors == ["John"])
    }

    /// SPEC: ## Notes — `Note left of Alice: text`
    @Test func noteLeftOf() {
        let result = parser.parse("""
        sequenceDiagram
            participant Alice
            Note left of Alice: This is a left note
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        let note = d.notes.first
        #expect(note?.text == "This is a left note")
        #expect(note?.position == .leftOf)
        #expect(note?.actors == ["Alice"])
    }

    /// SPEC: ## Notes — `Note over Alice,John: A typical interaction`
    @Test func noteOverTwoActors() {
        let result = parser.parse("""
        sequenceDiagram
            Alice->John: Hello John, how are you?
            Note over Alice,John: A typical interaction
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        let note = d.notes.first
        #expect(note?.text == "A typical interaction")
        #expect(note?.position == .over)
        #expect(note?.actors == ["Alice", "John"])
    }

    /// SPEC: ## Notes — Note over single actor
    @Test func noteOverSingleActor() {
        let result = parser.parse("""
        sequenceDiagram
            participant Alice
            Note over Alice: Self note
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        let note = d.notes.first
        #expect(note?.position == .over)
        #expect(note?.actors == ["Alice"])
    }

    // MARK: - Loops

    /// SPEC: ## Loops
    /// ```
    /// loop Loop text
    ///     ...statements...
    /// end
    /// ```
    @Test func loopBlock() {
        let result = parser.parse("""
        sequenceDiagram
            Alice->John: Hello John, how are you?
            loop Every minute
                John-->Alice: Great!
            end
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        // Should have 2 messages: the greeting + the loop body message.
        #expect(d.messages.count == 2)
        #expect(d.messages[1].text == "Great!")
        // Should have a loop block in the AST.
        #expect(!d.blocks.isEmpty, "Should have parsed the loop block")
        let block = d.blocks.first
        #expect(block?.kind == .loop)
        #expect(block?.label == "Every minute")
    }

    // MARK: - Alt / Else / Opt

    /// SPEC: ## Alt — alt...else...end
    @Test func altElseBlock() {
        let result = parser.parse("""
        sequenceDiagram
            Alice->>Bob: Hello Bob, how are you?
            alt is sick
                Bob->>Alice: Not so good :(
            else is well
                Bob->>Alice: Feeling fresh like a daisy
            end
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        #expect(d.messages.count == 3)
        let block = d.blocks.first { $0.kind == .alt }
        #expect(block != nil, "Should have an alt block")
        #expect(block?.label == "is sick")
        #expect(block?.elseBlocks?.first?.label == "is well")
    }

    /// SPEC: ## Alt — opt...end (optional block)
    @Test func optBlock() {
        let result = parser.parse("""
        sequenceDiagram
            Alice->>Bob: Hello
            opt Extra response
                Bob->>Alice: Thanks for asking
            end
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        let block = d.blocks.first { $0.kind == .opt }
        #expect(block != nil, "Should have an opt block")
        #expect(block?.label == "Extra response")
    }

    // MARK: - Parallel

    /// SPEC: ## Parallel — par...and...end
    @Test func parallelBlock() {
        let result = parser.parse("""
        sequenceDiagram
            par Alice to Bob
                Alice->>Bob: Hello guys!
            and Alice to John
                Alice->>John: Hello guys!
            end
            Bob-->>Alice: Hi Alice!
            John-->>Alice: Hi Alice!
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        #expect(d.messages.count == 4)
        let block = d.blocks.first { $0.kind == .par }
        #expect(block != nil, "Should have a par block")
        #expect(block?.label == "Alice to Bob")
    }

    // MARK: - Critical

    /// SPEC: ## Critical Region — critical...option...end
    @Test func criticalBlock() {
        let result = parser.parse("""
        sequenceDiagram
            critical Establish a connection to the DB
                Service-->DB: connect
            option Network timeout
                Service-->Service: Log error
            option Credentials rejected
                Service-->Service: Log different error
            end
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        let block = d.blocks.first { $0.kind == .critical }
        #expect(block != nil, "Should have a critical block")
        #expect(block?.label == "Establish a connection to the DB")
    }

    // MARK: - Break

    /// SPEC: ## Break — break...end
    @Test func breakBlock() {
        let result = parser.parse("""
        sequenceDiagram
            Consumer-->API: Book something
            API-->BookingService: Start booking process
            break when the booking process fails
                API-->Consumer: show failure
            end
            API-->BillingService: Start billing process
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        let block = d.blocks.first { $0.kind == .break }
        #expect(block != nil, "Should have a break block")
        #expect(block?.label == "when the booking process fails")
        // Messages inside and outside the break should all be parsed.
        #expect(d.messages.count == 4)
    }

    // MARK: - Activations

    /// SPEC: ## Activations — activate/deactivate keywords
    @Test func activationKeywords() {
        let result = parser.parse("""
        sequenceDiagram
            Alice->>John: Hello John, how are you?
            activate John
            John-->>Alice: Great!
            deactivate John
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        #expect(d.messages.count == 2)
        // Activations should be tracked — at minimum not cause parse errors.
        // The activation state is rendering metadata, but the keywords
        // must not be misinterpreted as participant names or messages.
        #expect(d.participants.count == 2)
        #expect(!d.participants.contains { $0.id == "activate" })
        #expect(!d.participants.contains { $0.id == "deactivate" })
    }

    /// SPEC: ## Activations — shorthand +/- suffix on arrows
    /// `Alice->>+John: Hello` / `John-->>-Alice: Great!`
    @Test func activationShorthand() {
        let result = parser.parse("""
        sequenceDiagram
            Alice->>+John: Hello John, how are you?
            John-->>-Alice: Great!
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        #expect(d.messages.count == 2)
        #expect(d.messages[0].from == "Alice")
        #expect(d.messages[0].to == "John")
        #expect(d.messages[0].activationModifier == .activate)
        #expect(d.messages[1].activationModifier == .deactivate)
    }

    // MARK: - Arrows

    /// SPEC: Supported Arrow Types — `<<->>` and `<<-->>` bidirectional arrows.
    @Test func bidirectionalArrows() {
        let result = parser.parse("""
        sequenceDiagram
            Alice<<->>Bob: Solid both ways
            Alice<<-->>Bob: Dashed both ways
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        #expect(d.messages.map(\.arrowStyle) == [.solidBidirectional, .dashedBidirectional])
    }

    /// SPEC: Supported Arrow Types — v11.12.3 half-arrow variants.
    @Test func halfArrowTypes() {
        let result = parser.parse(#"""
        sequenceDiagram
            A-\|\B: top half
            A--\|\B: dashed top half
            A-\|/B: bottom half
            A--\|/B: dashed bottom half
            A/\|-B: reverse top half
            A/\|--B: dashed reverse top half
            A\\-B: reverse bottom half
            A\\--B: dashed reverse bottom half
            A-\\B: top stick
            A--\\B: dashed top stick
            A-//B: bottom stick
            A--//B: dashed bottom stick
            A//-B: reverse top stick
            A//--B: dashed reverse top stick
        """#)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        #expect(d.messages.map(\.arrowStyle) == [
            .solidTopHalfArrow,
            .dashedTopHalfArrow,
            .solidBottomHalfArrow,
            .dashedBottomHalfArrow,
            .solidReverseTopHalfArrow,
            .dashedReverseTopHalfArrow,
            .solidReverseBottomHalfArrow,
            .dashedReverseBottomHalfArrow,
            .solidTopStickHalfArrow,
            .dashedTopStickHalfArrow,
            .solidBottomStickHalfArrow,
            .dashedBottomStickHalfArrow,
            .solidReverseTopStickHalfArrow,
            .dashedReverseTopStickHalfArrow,
        ])
    }

    /// SPEC: ## Central Connections — `()` is endpoint metadata, not part of actor IDs.
    @Test func centralConnections() {
        let result = parser.parse("""
        sequenceDiagram
            participant Alice
            participant John
            Alice->>()John: Hello John
            Alice()->>John: How are you?
            John()->>()Alice: Great!
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        #expect(d.participants.map(\.id) == ["Alice", "John"])
        #expect(d.messages[0].from == "Alice")
        #expect(d.messages[0].to == "John")
        #expect(d.messages[0].fromCentral == false)
        #expect(d.messages[0].toCentral == true)
        #expect(d.messages[1].fromCentral == true)
        #expect(d.messages[1].toCentral == false)
        #expect(d.messages[2].fromCentral == true)
        #expect(d.messages[2].toCentral == true)
    }

    /// SPEC: Supported Arrow Types — `-)` solid line with open arrow (async)
    @Test func asyncSolidArrow() {
        let result = parser.parse("""
        sequenceDiagram
            Alice-)John: Hello
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        #expect(d.messages.first?.arrowStyle == .solidAsync)
    }

    /// SPEC: Supported Arrow Types — `--)` dotted line with open arrow (async)
    @Test func asyncDashedArrow() {
        let result = parser.parse("""
        sequenceDiagram
            Alice--)John: Hello
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        #expect(d.messages.first?.arrowStyle == .dashedAsync)
    }

    // MARK: - Autonumber

    /// SPEC: ## sequenceNumbers — `autonumber` directive
    @Test func autonumberDirective() {
        let result = parser.parse("""
        sequenceDiagram
            autonumber
            Alice->>John: Hello John, how are you?
            John-->>Alice: Great!
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        #expect(d.autonumber == true)
        #expect(d.autonumberStart == 1)
        #expect(d.autonumberIncrement == 1)
        // Messages should still parse normally.
        #expect(d.messages.count == 2)
        // "autonumber" should not be treated as a participant.
        #expect(!d.participants.contains { $0.id == "autonumber" })
    }

    /// SPEC: ### Start and Increment values — `autonumber <start> <increment>`.
    @Test func autonumberStartAndIncrementValues() {
        let result = parser.parse("""
        sequenceDiagram
            autonumber 10.5 0.25
            Alice->>John: One
            John-->>Alice: Two
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        #expect(d.autonumber == true)
        #expect(d.autonumberStart == 10.5)
        #expect(d.autonumberIncrement == 0.25)
        #expect(d.messages.count == 2)
    }

    // MARK: - Boxes / Grouping

    /// SPEC: ### Grouping / Box — `box...end`
    @Test func boxGrouping() {
        let result = parser.parse("""
        sequenceDiagram
            box Purple Group Description
                participant Alice
                participant John
            end
            Alice->>John: Hello
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        #expect(d.participants.count == 2)
        #expect(d.messages.count == 1)
        #expect(d.boxes.count == 1)
        #expect(d.boxes.first?.color == "Purple")
        #expect(d.boxes.first?.label == "Group Description")
        #expect(d.boxes.first?.participantIds == ["Alice", "John"])
        // Box should not confuse participant parsing.
        #expect(!d.participants.contains { $0.id == "box" })
        #expect(!d.participants.contains { $0.id == "end" })
    }

    /// SPEC: ### Grouping / Box — boxes support labels, functional colors, and transparent color.
    @Test func boxGroupingColorAndLabelVariants() {
        let result = parser.parse("""
        sequenceDiagram
            box Group without description
                participant A
            end
            box rgb(33,66,99)
                participant B
            end
            box hsl(10, 40%, 90%) Warm
                participant H
            end
            box transparent Aqua
                participant C
            end
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        #expect(d.boxes.count == 4)
        #expect(d.boxes[0].label == "Group without description")
        #expect(d.boxes[0].color == nil)
        #expect(d.boxes[0].participantIds == ["A"])
        #expect(d.boxes[1].label == nil)
        #expect(d.boxes[1].color == "rgb(33,66,99)")
        #expect(d.boxes[1].participantIds == ["B"])
        #expect(d.boxes[2].label == "Warm")
        #expect(d.boxes[2].color == "hsl(10, 40%, 90%)")
        #expect(d.boxes[2].participantIds == ["H"])
        #expect(d.boxes[3].label == "Aqua")
        #expect(d.boxes[3].color == "transparent")
        #expect(d.boxes[3].participantIds == ["C"])
    }

    // MARK: - Rect (background highlighting)

    /// SPEC: ## Background Highlighting — `rect rgb(...)...end`
    @Test func rectBackgroundHighlighting() {
        let result = parser.parse("""
        sequenceDiagram
            participant Alice
            participant John
            rect rgb(191, 223, 255)
                Alice->>+John: Hello John
                John-->>-Alice: Great!
            end
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        // rect/end should not break message parsing.
        #expect(d.messages.count == 2)
        #expect(d.participants.count == 2)
        #expect(d.blocks.first?.kind == .rect)
        #expect(d.blocks.first?.label == "rgb(191, 223, 255)")
        #expect(d.blocks.first?.startMessageIndex == 0)
        #expect(d.blocks.first?.endMessageIndex == 1)
        // "rect" should not be misinterpreted as a participant.
        #expect(!d.participants.contains { $0.id == "rect" })
    }

    // MARK: - Actor menus

    /// SPEC: ## Actor Menus — `link Actor: Label @ URL` and `links Actor: {...}`.
    @Test func actorMenuLinks() {
        let result = parser.parse("""
        sequenceDiagram
            participant Alice
            participant John
            link Alice: Dashboard @ https://dashboard.contoso.com/alice
            link Alice: Wiki @ https://wiki.contoso.com/alice
            links John: {"Dashboard": "https://dashboard.contoso.com/john", "Wiki": "https://wiki.contoso.com/john"}
            Alice->>John: Hello John
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        #expect(d.links.contains(SequenceLink(
            actorId: "Alice",
            label: "Dashboard",
            url: "https://dashboard.contoso.com/alice"
        )))
        #expect(d.links.contains(SequenceLink(
            actorId: "Alice",
            label: "Wiki",
            url: "https://wiki.contoso.com/alice"
        )))
        #expect(d.links.contains(SequenceLink(
            actorId: "John",
            label: "Dashboard",
            url: "https://dashboard.contoso.com/john"
        )))
        #expect(d.links.contains(SequenceLink(
            actorId: "John",
            label: "Wiki",
            url: "https://wiki.contoso.com/john"
        )))
        #expect(d.links.count == 4)
        #expect(d.messages.count == 1)
        #expect(!d.participants.contains { $0.id == "link" || $0.id == "links" })
    }

    // MARK: - Entity codes

    /// SPEC: ## Entity codes to escape characters — messages decode decimal and named entities.
    @Test func entityCodesInMessages() {
        let result = parser.parse("""
        sequenceDiagram
            A->>B: I #9829; you #infin; times more#59;
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        #expect(d.messages.first?.text == "I ♥ you ∞ times more;")
    }

    // MARK: - Comments

    /// SPEC: ## Comments — `%% comment text`
    @Test func commentsInSequenceDiagram() {
        let result = parser.parse("""
        sequenceDiagram
            %% This is a comment
            Alice->>John: Hello
            %% Another comment
            John-->>Alice: Hi
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        #expect(d.messages.count == 2)
        // Comments should be stripped, not treated as messages or participants.
        #expect(!d.participants.contains { $0.id.contains("%%") })
    }

    // MARK: - Combined spec example

    /// Larger diagram from the autonumber spec example.
    @Test func fullSpecExample() {
        let result = parser.parse("""
        sequenceDiagram
            autonumber
            Alice->>John: Hello John, how are you?
            loop HealthCheck
                John->>John: Fight against hypochondria
            end
            Note right of John: Rational thoughts!
            John-->>Alice: Great!
            John->>Bob: How about you?
            Bob-->>John: Jolly good!
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        #expect(d.autonumber == true)
        #expect(d.participants.count == 3)
        #expect(d.messages.count == 5)
        #expect(!d.notes.isEmpty)
        #expect(!d.blocks.isEmpty)
    }
}
