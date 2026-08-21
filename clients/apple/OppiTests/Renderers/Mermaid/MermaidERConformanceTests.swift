import CoreGraphics
import Testing
@testable import Oppi

// SPEC: https://github.com/mermaid-js/mermaid/blob/mermaid%4011.17.0/packages/mermaid/src/docs/syntax/entityRelationshipDiagram.md
//
// Tests call the dedicated parser/renderer directly. The shared
// dispatcher (MermaidParser / MermaidFlowchartRenderer.layout) is not
// wired to `erDiagram` until the one-line integrator lands, so the
// conformance suite exercises MermaidERParser and MermaidERRenderer
// in isolation.
//
// COVERAGE:
// [x] official order-example relationships (`||--o{`, `||--|{`, `}|..|{`)
// [x] standalone entity (only first-entity is mandatory)
// [x] quoted / unicode / markdown entity names
// [x] entity aliases `p[Person]` and `a["Customer Account"]`
// [x] `:::class` suffixes accepted and stripped
// [x] crow's-foot symbol cardinalities (both sides)
// [x] word-alias cardinalities from the spec table
// [x] identifying `--` / `to` vs non-identifying `..` / `optionally to`
// [x] attribute blocks: type/name, `*PK`, PK/FK/UK, comments
// [x] optional `type?`, `type[]`, `type(n)` attribute types
// [x] `direction` TB/BT/LR/RL (default TB); case-insensitive, not an entity
// [x] `%%` comments; subgraph/style/class/title ignored
// [x] first-appearance entity order; source-order relationships
// [x] renderer: non-placeholder layout, positions, edges, draw
// [x] wrapped header/attribute/comment heights enlarge the table
// [x] self-relationship routes outside the entity
// [x] parallel relationships use distinct lanes

@Suite("ER Conformance — Mermaid v11.17.0")
struct MermaidERConformanceTests {

    // MARK: - Official examples

    /// SPEC: first example — three relationships, crow's-foot markers, labels.
    @Test func officialOrderExampleRelationships() {
        let diagram = parseER("""
        erDiagram
            CUSTOMER ||--o{ ORDER : places
            ORDER ||--|{ LINE-ITEM : contains
            CUSTOMER }|..|{ DELIVERY-ADDRESS : uses
        """)

        #expect(diagram.direction == .TB)
        #expect(diagram.entities.map(\.name) == [
            "CUSTOMER", "ORDER", "LINE-ITEM", "DELIVERY-ADDRESS",
        ])
        #expect(diagram.relationships.count == 3)

        let places = diagram.relationships[0]
        #expect(places.from == "CUSTOMER")
        #expect(places.to == "ORDER")
        #expect(places.fromCardinality == .exactlyOne)
        #expect(places.toCardinality == .zeroOrMore)
        #expect(places.identifying == true)
        #expect(places.label == "places")

        let contains = diagram.relationships[1]
        #expect(contains.from == "ORDER")
        #expect(contains.to == "LINE-ITEM")
        #expect(contains.fromCardinality == .exactlyOne)
        #expect(contains.toCardinality == .oneOrMore)
        #expect(contains.identifying == true)
        #expect(contains.label == "contains")

        let uses = diagram.relationships[2]
        #expect(uses.from == "CUSTOMER")
        #expect(uses.to == "DELIVERY-ADDRESS")
        #expect(uses.fromCardinality == .oneOrMore)
        #expect(uses.toCardinality == .oneOrMore)
        #expect(uses.identifying == false)
        #expect(uses.label == "uses")
    }

    /// SPEC: attributes are `type name` rows inside an entity `{` block.
    @Test func officialAttributeExample() {
        let diagram = parseER("""
        erDiagram
            CUSTOMER ||--o{ ORDER : places
            CUSTOMER {
                string name
                string custNumber
                string sector
            }
            ORDER ||--|{ LINE-ITEM : contains
            ORDER {
                int orderNumber
                string deliveryAddress
            }
            LINE-ITEM {
                string productCode
                int quantity
                float pricePerUnit
            }
        """)

        #expect(diagram.entity("CUSTOMER")?.attributes.map(\.name) == [
            "name", "custNumber", "sector",
        ])
        #expect(diagram.entity("CUSTOMER")?.attributes.map(\.type) == [
            "string", "string", "string",
        ])
        #expect(diagram.entity("ORDER")?.attributes.map(\.name) == [
            "orderNumber", "deliveryAddress",
        ])
        #expect(diagram.entity("LINE-ITEM")?.attributes.map(\.name) == [
            "productCode", "quantity", "pricePerUnit",
        ])
        #expect(diagram.entity("LINE-ITEM")?.attributes.map(\.type) == [
            "string", "int", "float",
        ])
    }

    /// SPEC: `PROPERTY ||--|{ ROOM : contains` reads as one-or-more rooms.
    @Test func propertyContainsRooms() {
        let diagram = parseER("""
        PROPERTY ||--|{ ROOM : contains
        """)
        #expect(diagram.relationships.count == 1)
        #expect(diagram.relationships[0].from == "PROPERTY")
        #expect(diagram.relationships[0].to == "ROOM")
        #expect(diagram.relationships[0].fromCardinality == .exactlyOne)
        #expect(diagram.relationships[0].toCardinality == .oneOrMore)
        #expect(diagram.relationships[0].label == "contains")
    }

    // MARK: - Entities

    /// SPEC: only `first-entity` is mandatory — an entity may have no relationships.
    @Test func standaloneEntity() {
        let diagram = parseER("FACTORY")
        #expect(diagram.entities.map(\.name) == ["FACTORY"])
        #expect(diagram.relationships.isEmpty)
    }

    /// SPEC: quoted names support spaces; unicode is allowed.
    @Test func quotedUnicodeEntityName() {
        let diagram = parseER(#""This ❤ Unicode""#)
        #expect(diagram.entities.map(\.name) == ["This ❤ Unicode"])
    }

    /// SPEC: markdown formatting in entity names is accepted.
    @Test func markdownEntityName() {
        let diagram = parseER(#""This **is** _Markdown_""#)
        #expect(diagram.entities.map(\.name) == ["This **is** _Markdown_"])
    }

    /// SPEC: `p[Person]` / `a["Customer Account"]` show the alias instead of the id.
    @Test func entityNameAliases() {
        let diagram = parseER("""
        erDiagram
            p[Person] {
                string firstName
                string lastName
            }
            a["Customer Account"] {
                string email
            }
            p ||--o| a : has
        """)

        let person = diagram.entity("p")
        #expect(person?.alias == "Person")
        #expect(person?.displayName == "Person")
        #expect(person?.attributes.map(\.name) == ["firstName", "lastName"])

        let account = diagram.entity("a")
        #expect(account?.alias == "Customer Account")
        #expect(account?.displayName == "Customer Account")
        #expect(account?.attributes.map(\.name) == ["email"])

        #expect(diagram.relationships.count == 1)
        #expect(diagram.relationships[0].from == "p")
        #expect(diagram.relationships[0].to == "a")
        #expect(diagram.relationships[0].fromCardinality == .exactlyOne)
        #expect(diagram.relationships[0].toCardinality == .zeroOrOne)
        #expect(diagram.relationships[0].label == "has")
    }

    /// SPEC: `:::class` can be attached to a declaration or a relationship endpoint.
    @Test func classSuffixesAreStripped() {
        let diagram = parseER("""
        erDiagram
            CAR:::someclass {
                string make
            }
            PERSON:::foo ||--|| CAR : owns
            PERSON o{--|| HOUSE:::bar : has
        """)

        #expect(Set(diagram.entities.map(\.name)) == ["CAR", "PERSON", "HOUSE"])
        #expect(diagram.entities.allSatisfy { !$0.name.contains(":") })
        #expect(diagram.relationships.map { "\($0.from)->\($0.to)" } == [
            "PERSON->CAR",
            "PERSON->HOUSE",
        ])
        #expect(diagram.relationships.map(\.label) == ["owns", "has"])
        #expect(diagram.relationships.last?.fromCardinality == .zeroOrMore)
        #expect(diagram.relationships.last?.toCardinality == .exactlyOne)
    }

    /// First appearance wins for entity order, including attribute-only entities.
    @Test func firstAppearanceEntityOrder() {
        let diagram = parseER("""
        ORDER ||--|{ LINE-ITEM : contains
        CUSTOMER ||--o{ ORDER : places
        WAREHOUSE {
            string code
        }
        """)
        #expect(diagram.entities.map(\.name) == [
            "ORDER", "LINE-ITEM", "CUSTOMER", "WAREHOUSE",
        ])
    }

    // MARK: - Cardinality symbols

    /// SPEC table: left/right crow's-foot markers.
    @Test(arguments: [
        ("|o", "o|", ERCardinality.zeroOrOne, ERCardinality.zeroOrOne),
        ("||", "||", .exactlyOne, .exactlyOne),
        ("}o", "o{", .zeroOrMore, .zeroOrMore),
        ("}|", "|{", .oneOrMore, .oneOrMore),
        ("||", "o{", .exactlyOne, .zeroOrMore),
        ("||", "|{", .exactlyOne, .oneOrMore),
        ("}|", "|{", .oneOrMore, .oneOrMore),
        ("}o", "o{", .zeroOrMore, .zeroOrMore),
        ("|o", "||", .zeroOrOne, .exactlyOne),
    ])
    func symbolCardinalities(
        left: String,
        right: String,
        from: ERCardinality,
        to: ERCardinality
    ) {
        let diagram = parseER("A \(left)--\(right) B : rel")
        #expect(diagram.relationships.count == 1)
        #expect(diagram.relationships[0].fromCardinality == from)
        #expect(diagram.relationships[0].toCardinality == to)
        #expect(diagram.relationships[0].identifying == true)
    }

    /// No-space form `A||--||B` is still a valid statement.
    @Test func symbolRelationshipWithoutSpaces() {
        let diagram = parseER("A||--o{B : rel")
        #expect(diagram.relationships.count == 1)
        #expect(diagram.relationships[0].from == "A")
        #expect(diagram.relationships[0].to == "B")
        #expect(diagram.relationships[0].toCardinality == .zeroOrMore)
    }

    // MARK: - Word aliases

    /// SPEC alias table, used on both sides with identifying `to`.
    @Test(arguments: [
        ("zero or one", ERCardinality.zeroOrOne),
        ("one or zero", .zeroOrOne),
        ("one or more", .oneOrMore),
        ("one or many", .oneOrMore),
        ("many(1)", .oneOrMore),
        ("1+", .oneOrMore),
        ("zero or more", .zeroOrMore),
        ("zero or many", .zeroOrMore),
        ("many(0)", .zeroOrMore),
        ("0+", .zeroOrMore),
        ("only one", .exactlyOne),
        ("1", .exactlyOne),
    ])
    func wordAliasCardinalities(phrase: String, expected: ERCardinality) {
        let diagram = parseER("A \(phrase) to \(phrase) B : rel")
        #expect(diagram.relationships.count == 1)
        #expect(diagram.relationships[0].fromCardinality == expected)
        #expect(diagram.relationships[0].toCardinality == expected)
        #expect(diagram.relationships[0].identifying == true)
        #expect(diagram.relationships[0].from == "A")
        #expect(diagram.relationships[0].to == "B")
    }

    /// SPEC: word-form identifying vs non-identifying aliases.
    @Test func officialWordAliasExample() {
        let diagram = parseER("""
        erDiagram
            CAR 1 to zero or more NAMED-DRIVER : allows
            PERSON many(0) optionally to 0+ NAMED-DRIVER : is
        """)

        #expect(diagram.relationships.count == 2)

        let allows = diagram.relationships[0]
        #expect(allows.from == "CAR")
        #expect(allows.to == "NAMED-DRIVER")
        #expect(allows.fromCardinality == .exactlyOne)
        #expect(allows.toCardinality == .zeroOrMore)
        #expect(allows.identifying == true)
        #expect(allows.label == "allows")

        let isRel = diagram.relationships[1]
        #expect(isRel.from == "PERSON")
        #expect(isRel.to == "NAMED-DRIVER")
        #expect(isRel.fromCardinality == .zeroOrMore)
        #expect(isRel.toCardinality == .zeroOrMore)
        #expect(isRel.identifying == false)
        #expect(isRel.label == "is")
    }

    /// SPEC: `--` is identifying (solid); `..` is non-identifying (dashed).
    @Test func identificationMarkers() {
        let identifying = parseER("PERSON }|..|{ CAR : driver")
        #expect(identifying.relationships[0].identifying == false)

        let nonIdentifying = parseER("CAR ||--o{ NAMED-DRIVER : allows")
        #expect(nonIdentifying.relationships[0].identifying == true)
    }

    /// Quoted labels keep inner spaces and drop wrapping quotes.
    @Test func quotedRelationshipLabel() {
        let diagram = parseER(#"PERSON }|..|{ CAR : "driver""#)
        #expect(diagram.relationships[0].label == "driver")
    }

    // MARK: - Attributes

    /// SPEC: keys `PK` / `FK` / `UK`, comma-separated multi-keys, trailing comments,
    /// `string[]`, `string(99)`, and `*` as a primary-key prefix.
    @Test func attributeKeysCommentsAndTypes() {
        let diagram = parseER("""
        erDiagram
            CAR {
                string registrationNumber PK
                string make
                string model
                string[] parts
            }
            PERSON {
                string driversLicense PK "The license #"
                string(99) firstName "Only 99 characters are allowed"
                string lastName
                string phone UK
                int age
            }
            NAMED-DRIVER {
                string carRegistrationNumber PK, FK
                string driverLicence PK, FK
                string *legacyId
            }
        """)

        let car = diagram.entity("CAR")
        #expect(car?.attributes[0] == ERAttribute(
            type: "string", name: "registrationNumber", keys: [.PK], comment: nil
        ))
        #expect(car?.attributes[3] == ERAttribute(
            type: "string[]", name: "parts", keys: [], comment: nil
        ))

        let person = diagram.entity("PERSON")
        #expect(person?.attributes[0] == ERAttribute(
            type: "string",
            name: "driversLicense",
            keys: [.PK],
            comment: "The license #"
        ))
        #expect(person?.attributes[1] == ERAttribute(
            type: "string(99)",
            name: "firstName",
            keys: [],
            comment: "Only 99 characters are allowed"
        ))
        #expect(person?.attributes[3] == ERAttribute(
            type: "string", name: "phone", keys: [.UK], comment: nil
        ))

        let driver = diagram.entity("NAMED-DRIVER")
        #expect(driver?.attributes[0].keys == [.PK, .FK])
        #expect(driver?.attributes[1].keys == [.PK, .FK])
        #expect(driver?.attributes[2] == ERAttribute(
            type: "string", name: "legacyId", keys: [.PK], comment: nil
        ))
    }

    /// SPEC (v11.16.0+): attribute types may end with `?` for optional/nullable.
    @Test func optionalAttributeTypes() {
        let diagram = parseER("""
        erDiagram
            PERSON {
                string firstName
                string? middleName
                string lastName
            }
        """)
        #expect(diagram.entity("PERSON")?.attributes.map(\.type) == [
            "string", "string?", "string",
        ])
        #expect(diagram.entity("PERSON")?.attributes.map(\.name) == [
            "firstName", "middleName", "lastName",
        ])
    }

    /// A later attribute block appends to the entity created by a relationship.
    @Test func attributeBlockMergesIntoExistingEntity() {
        let diagram = parseER("""
        CAR ||--o{ NAMED-DRIVER : allows
        CAR {
            string make
            string model
        }
        """)
        #expect(diagram.entities.map(\.name) == ["CAR", "NAMED-DRIVER"])
        #expect(diagram.entity("CAR")?.attributes.map(\.name) == ["make", "model"])
    }

    // MARK: - Direction

    /// SPEC: `direction TB|BT|LR|RL`. Default is TB.
    @Test(arguments: [
        ("TB", FlowDirection.TB),
        ("BT", .BT),
        ("LR", .LR),
        ("RL", .RL),
    ])
    func directionStatement(value: String, expected: FlowDirection) {
        let diagram = parseER("""
        direction \(value)
        CUSTOMER ||--o{ ORDER : places
        """)
        #expect(diagram.direction == expected)
    }

    @Test func defaultDirectionIsTB() {
        let diagram = parseER("CUSTOMER ||--o{ ORDER : places")
        #expect(diagram.direction == .TB)
    }

    /// SPEC: direction keywords are case-insensitive. `direction lr` must not
    /// become an entity named `direction`.
    @Test(arguments: [
        ("lr", FlowDirection.LR),
        ("Lr", .LR),
        ("td", .TD),
        ("bt", .BT),
        ("rl", .RL),
    ])
    func directionStatementIsCaseInsensitive(value: String, expected: FlowDirection) {
        let diagram = parseER("""
        direction \(value)
        CUSTOMER ||--o{ ORDER : places
        """)
        #expect(diagram.direction == expected)
        #expect(diagram.entities.map(\.name) == ["CUSTOMER", "ORDER"])
    }

    /// Lowercase `direction lr` must actually switch layout off the TB default.
    @Test func lowercaseDirectionChangesPlacement() {
        let source = """
        CUSTOMER ||--o{ ORDER : places
        ORDER ||--|{ LINE-ITEM : contains
        """
        let tbLayout = layoutER(parseER(source))
        let lr = parseER("direction lr\n" + source)
        #expect(lr.direction == .LR)
        #expect(lr.entities.map(\.name) == ["CUSTOMER", "ORDER", "LINE-ITEM"])
        let lrLayout = layoutER(lr)
        #expect(tbLayout.graphResult.nodePositions != lrLayout.graphResult.nodePositions)
    }

    // MARK: - Recovery / ignored statements

    /// `%%` comments (including trailing) are stripped; blanks are ignored.
    @Test func commentsAndBlanksIgnored() {
        let diagram = parseER("""
        %% a file-level comment

        CUSTOMER ||--o{ ORDER : places %% trailing
        %% another
        ORDER ||--|{ LINE-ITEM : contains
        """)
        #expect(diagram.relationships.count == 2)
        #expect(diagram.entities.map(\.name) == ["CUSTOMER", "ORDER", "LINE-ITEM"])
    }

    /// `%%` inside a quoted name is data, not a comment.
    @Test func percentPercentInsideQuotedNameIsPreserved() {
        let diagram = parseER(#""100%% done""#)
        #expect(diagram.entities.map(\.name) == ["100%% done"])
    }

    /// SPEC (v11.17.0+): subgraphs group entities. v1 accepts and ignores the
    /// wrapper so inner entities and relationships still parse.
    @Test func subgraphWrappersAreIgnored() {
        let diagram = parseER("""
        erDiagram
            subgraph title1
                CUSTOMER
                CUSTOMER {
                    string name
                }
            end
            subgraph title2
                CAR ||--o{ NAMED-DRIVER : allows
            end
        """)
        #expect(Set(diagram.entities.map(\.name)) == [
            "CUSTOMER", "CAR", "NAMED-DRIVER",
        ])
        #expect(diagram.entity("CUSTOMER")?.attributes.map(\.name) == ["name"])
        #expect(diagram.relationships.count == 1)
        #expect(diagram.entities.contains { $0.name == "title1" } == false)
        #expect(diagram.entities.contains { $0.name == "end" } == false)
    }

    /// style / classDef / class / title do not become entities.
    @Test func styleAndClassStatementsAreIgnored() {
        let diagram = parseER("""
        erDiagram
            CUSTOMER ||--o{ ORDER : places
            style CUSTOMER fill:#f9f,stroke:#333,stroke-width:4px
            classDef someclass fill:#f96
            class CUSTOMER someclass
            title Order example
        """)
        #expect(diagram.entities.map(\.name) == ["CUSTOMER", "ORDER"])
        #expect(diagram.relationships.count == 1)
    }

    /// Leading `erDiagram` is the diagram header, not an entity.
    @Test func headerLineIsNotAnEntity() {
        let diagram = parseER("""
        erDiagram
            CUSTOMER
        """)
        #expect(diagram.entities.map(\.name) == ["CUSTOMER"])
    }

    /// Empty / comment-only input yields an empty diagram, not a crash.
    @Test func emptyBody() {
        let diagram = parseER("""
        erDiagram
        %% nothing here
        """)
        #expect(diagram.entities.isEmpty)
        #expect(diagram.relationships.isEmpty)
        #expect(diagram.direction == .TB)
    }

    /// Junk relationship text is skipped without crashing.
    @Test func malformedRelationshipDoesNotCrash() {
        let diagram = parseER("""
        CUSTOMER ||-- ORDER : places
        FACTORY
        """)
        #expect(diagram.entity("FACTORY") != nil)
        #expect(diagram.relationships.isEmpty)
    }

    // MARK: - Renderer

    /// Renderer produces a non-placeholder layout with positions and edges.
    @Test func rendererProducesNonPlaceholderLayout() {
        let diagram = parseER("""
        erDiagram
            CUSTOMER ||--o{ ORDER : places
            ORDER ||--|{ LINE-ITEM : contains
            CUSTOMER }|..|{ DELIVERY-ADDRESS : uses
        """)
        let layout = layoutER(diagram)

        #expect(layout.isPlaceholder == false)
        #expect(layout.customDraw != nil)
        guard let size = layout.customSize else {
            Issue.record("Expected non-nil customSize")
            return
        }
        #expect(size.width > 1)
        #expect(size.height > 1)

        for name in ["CUSTOMER", "ORDER", "LINE-ITEM", "DELIVERY-ADDRESS"] {
            guard let rect = layout.graphResult.nodePositions[name] else {
                Issue.record("Missing position for \(name)")
                continue
            }
            #expect(rect.width > 0)
            #expect(rect.height > 0)
        }
        #expect(layout.graphResult.edgePaths.count == 3)
        #expect(layout.graphResult.edgePaths.allSatisfy { $0.points.count >= 2 })
    }

    /// Attribute tables are taller than header-only entities.
    @Test func attributeRowsIncreaseTableHeight() {
        let bare = layoutER(parseER("CUSTOMER"))
        let withRows = layoutER(parseER("""
        CUSTOMER {
            string name
            string custNumber
            string sector
        }
        """))

        let bareHeight = bare.graphResult.nodePositions["CUSTOMER"]?.height ?? 0
        let rowHeight = withRows.graphResult.nodePositions["CUSTOMER"]?.height ?? 0
        #expect(rowHeight > bareHeight)
    }

    /// Two related entities get distinct origins (Sugiyama assigned both).
    @Test func relatedEntitiesAreNotStackedOnTheSameOrigin() {
        let layout = layoutER(parseER("CUSTOMER ||--o{ ORDER : places"))
        let customer = layout.graphResult.nodePositions["CUSTOMER"]
        let order = layout.graphResult.nodePositions["ORDER"]
        #expect(customer != nil)
        #expect(order != nil)
        #expect(customer?.origin != order?.origin)
    }

    /// `direction LR` changes placement versus the default TB.
    @Test func directionChangesPlacement() {
        let source = """
        CUSTOMER ||--o{ ORDER : places
        ORDER ||--|{ LINE-ITEM : contains
        """
        let tb = parseER(source)
        #expect(tb.direction == .TB)
        let lr = parseER("direction LR\n" + source)
        #expect(lr.direction == .LR)

        let tbLayout = layoutER(tb)
        let lrLayout = layoutER(lr)
        #expect(tbLayout.graphResult.nodePositions != lrLayout.graphResult.nodePositions)
    }

    /// Long names clamp to the mobile table-width budget instead of one giant line.
    @Test func longEntityNameIsWidthClamped() {
        let name = "This is an extremely long entity name that would overflow a phone bubble if the renderer never wrapped or clamped it"
        let layout = layoutER(parseER("\"\(name)\""), maxWidth: 360)
        guard let rect = layout.graphResult.nodePositions[name] else {
            Issue.record("Expected a positioned entity")
            return
        }
        // maxTableWidth = max(maxWidth - fontSize*3, fontSize*12) ≈ 318 at 14pt.
        #expect(rect.width <= 360)
        #expect(rect.height > 0)
    }

    /// Wrapped header text must enlarge the Sugiyama rectangle, not spill out.
    @Test func wrappedHeaderIncreasesTableHeight() {
        let short = layoutER(parseER("SHORT"), maxWidth: 220)
        let longName = "This is an extremely long entity alias that must wrap across several lines inside a narrow phone bubble"
        let long = layoutER(parseER("""
        s[\"\(longName)\"]
        """), maxWidth: 220)

        let shortHeight = short.graphResult.nodePositions["SHORT"]?.height ?? 0
        guard let longRect = long.graphResult.nodePositions["s"] else {
            Issue.record("Expected a positioned long-alias entity")
            return
        }
        #expect(longRect.width <= 220)
        #expect(longRect.height > shortHeight + 8)
    }

    /// Wrapped attribute names must enlarge the row, not overflow the box.
    @Test func wrappedAttributeNameIncreasesTableHeight() {
        let short = layoutER(
            ERDiagram(
                direction: .TB,
                entities: [
                    EREntity(
                        name: "CUSTOMER",
                        alias: nil,
                        attributes: [
                            ERAttribute(type: "string", name: "name", keys: [], comment: nil),
                        ]
                    ),
                ],
                relationships: []
            ),
            maxWidth: 220
        )
        let long = layoutER(
            ERDiagram(
                direction: .TB,
                entities: [
                    EREntity(
                        name: "CUSTOMER",
                        alias: nil,
                        attributes: [
                            ERAttribute(
                                type: "string",
                                name: "preferred delivery window for the customer billing cycle and contact hours",
                                keys: [],
                                comment: nil
                            ),
                        ]
                    ),
                ],
                relationships: []
            ),
            maxWidth: 220
        )

        let shortHeight = short.graphResult.nodePositions["CUSTOMER"]?.height ?? 0
        let longHeight = long.graphResult.nodePositions["CUSTOMER"]?.height ?? 0
        #expect(longHeight > shortHeight + 8)
    }

    /// Wrapped attribute comments must enlarge the table, not draw past the box.
    @Test func wrappedCommentIncreasesTableHeight() {
        let short = layoutER(parseER("""
        CUSTOMER {
            string name "id"
        }
        """), maxWidth: 220)
        let long = layoutER(parseER("""
        CUSTOMER {
            string name "This is an extremely long attribute comment that must wrap across several lines inside the entity table instead of overflowing the box"
        }
        """), maxWidth: 220)

        let shortHeight = short.graphResult.nodePositions["CUSTOMER"]?.height ?? 0
        let longHeight = long.graphResult.nodePositions["CUSTOMER"]?.height ?? 0
        #expect(longHeight > shortHeight + 8)
    }

    /// `EMPLOYEE ||--o{ EMPLOYEE` must loop outside the table, not through it.
    @Test func selfRelationshipRoutesOutsideEntity() {
        let layout = layoutER(parseER("EMPLOYEE ||--o{ EMPLOYEE : manages"))
        guard let rect = layout.graphResult.nodePositions["EMPLOYEE"] else {
            Issue.record("Expected EMPLOYEE table")
            return
        }
        #expect(layout.graphResult.edgePaths.count == 1)
        guard let path = layout.graphResult.edgePaths.first else {
            Issue.record("Expected a self-relationship path")
            return
        }
        #expect(path.from == "EMPLOYEE")
        #expect(path.to == "EMPLOYEE")
        #expect(path.points.count >= 3)
        #expect(!polylineCrossesInterior(path.points, rect: rect))
        if let start = path.points.first, let end = path.points.last {
            #expect(pointOnRectBoundary(start, rect: rect))
            #expect(pointOnRectBoundary(end, rect: rect))
        }
    }

    /// Two relationships between the same pair must not share one polyline.
    @Test func parallelRelationshipsUseDistinctLanes() {
        let layout = layoutER(parseER("""
        CUSTOMER ||--o{ ORDER : places
        CUSTOMER }|..|{ ORDER : uses
        """))
        #expect(layout.graphResult.edgePaths.count == 2)
        let first = layout.graphResult.edgePaths[0].points
        let second = layout.graphResult.edgePaths[1].points
        #expect(first != second)

        let midFirst = polylineMidpoint(first)
        let midSecond = polylineMidpoint(second)
        let separation = hypot(midFirst.x - midSecond.x, midFirst.y - midSecond.y)
        #expect(separation > 8)
    }

    /// Empty diagram does not crash and reports a size.
    @Test func emptyDiagramDoesNotCrash() {
        let layout = layoutER(.empty)
        #expect(layout.customSize != nil)
        #expect((layout.customSize?.width ?? 0) > 0)
        #expect((layout.customSize?.height ?? 0) > 0)
    }

    /// customDraw can paint into a bitmap without trapping.
    @Test func customDrawRunsWithoutTrapping() {
        let diagram = parseER("""
        erDiagram
            CAR ||--o{ NAMED-DRIVER : allows
            PERSON }o..o{ NAMED-DRIVER : is
            CAR {
                string registrationNumber PK
                string make
            }
        """)
        let layout = layoutER(diagram)
        guard let draw = layout.customDraw, let size = layout.customSize else {
            Issue.record("Expected customDraw and customSize")
            return
        }
        let width = max(Int(size.width.rounded(.up)), 1)
        let height = max(Int(size.height.rounded(.up)), 1)
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            Issue.record("Failed to create bitmap context")
            return
        }
        draw(ctx, .zero)
        #expect(ctx.makeImage() != nil)
    }
}

// MARK: - Helpers

private func parseER(_ source: String) -> ERDiagram {
    MermaidERParser.parse(
        lines: source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
    )
}

private func layoutER(
    _ diagram: ERDiagram,
    maxWidth: CGFloat = 360
) -> MermaidFlowchartRenderer.FlowchartLayout {
    MermaidERRenderer.layout(diagram, configuration: .default(maxWidth: maxWidth))
}

private extension ERDiagram {
    func entity(_ name: String) -> EREntity? {
        entities.first { $0.name == name }
    }
}

/// Midpoint of each segment must stay out of the table interior.
private func polylineCrossesInterior(_ points: [CGPoint], rect: CGRect) -> Bool {
    let interior = rect.insetBy(dx: 1, dy: 1)
    guard interior.width > 0, interior.height > 0 else { return false }
    for (start, end) in zip(points, points.dropFirst()) {
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        if interior.contains(mid) { return true }
    }
    return false
}

private func pointOnRectBoundary(_ point: CGPoint, rect: CGRect, tolerance: CGFloat = 1.5) -> Bool {
    let alongVertical =
        (abs(point.x - rect.minX) <= tolerance || abs(point.x - rect.maxX) <= tolerance)
        && point.y >= rect.minY - tolerance
        && point.y <= rect.maxY + tolerance
    let alongHorizontal =
        (abs(point.y - rect.minY) <= tolerance || abs(point.y - rect.maxY) <= tolerance)
        && point.x >= rect.minX - tolerance
        && point.x <= rect.maxX + tolerance
    return alongVertical || alongHorizontal
}

private func polylineMidpoint(_ points: [CGPoint]) -> CGPoint {
    guard points.count >= 2 else { return points.first ?? .zero }
    var total: CGFloat = 0
    for index in 0..<(points.count - 1) {
        total += hypot(points[index + 1].x - points[index].x, points[index + 1].y - points[index].y)
    }
    guard total > 0 else { return points[0] }
    var remaining = total / 2
    for index in 0..<(points.count - 1) {
        let dx = points[index + 1].x - points[index].x
        let dy = points[index + 1].y - points[index].y
        let length = hypot(dx, dy)
        if length >= remaining {
            let t = length > 0 ? remaining / length : 0
            return CGPoint(x: points[index].x + dx * t, y: points[index].y + dy * t)
        }
        remaining -= length
    }
    return points[points.count - 1]
}
