import CoreGraphics
import CoreText
import Testing
@testable import Oppi

// SPEC: https://github.com/mermaid-js/mermaid/blob/mermaid%4011.17.0/packages/mermaid/src/docs/syntax/classDiagram.md
//
// Tests call the dedicated parser/renderer directly. The shared dispatcher
// (MermaidParser / MermaidFlowchartRenderer.layout) is not wired to
// `classDiagram` until the one-line integrator lands, so this suite
// exercises MermaidClassParser and MermaidClassRenderer in isolation.
//
// COVERAGE:
// [x] class keyword + relationship-defined classes
// [x] class labels and backtick names
// [x] colon members and {} compartments
// [x] visibility + - # ~
// [x] relations <|-- *-- o-- --> ..> ..|> -- (and reverse / two-way)
// [x] labels and cardinalities
// [x] <<stereotype>> (inline, separate line, nested)
// [x] notes / click / css skipped without crashing
// [x] renderer customDraw/customSize, three-compartment height, wrap, disjoint boxes
// [x] abstract * italic and static $ underline via customDraw
// [x] unbroken long identifiers stay inside maxWidth boxes (painted bounds)
// [x] relationship labels reserve rank space (no box/cardinality overlap)
// [x] adjacent same-rank relationship labels use separate cross-axis lanes
// [x] stereotype measure/draw use the same wrapped text (painted bounds)

@Suite("Class Diagram Conformance — Mermaid v11.17.0")
struct MermaidClassConformanceTests {

    // MARK: - Spec examples: define a class

    /// SPEC: `class Animal` defines a class; `Vehicle <|-- Car` defines two more.
    @Test func defineClassKeywordAndRelation() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "    class Animal",
            "    Vehicle <|-- Car",
        ])
        #expect(ids(in: diagram) == ["Animal", "Vehicle", "Car"])
        #expect(diagram.relations.count == 1)
        #expect(diagram.relations[0].from == "Vehicle")
        #expect(diagram.relations[0].to == "Car")
        #expect(diagram.relations[0].fromEnd == .inheritance)
        #expect(diagram.relations[0].toEnd == .none)
        #expect(diagram.relations[0].line == .solid)
    }

    /// SPEC: `class Animal["Animal with a label"]`.
    @Test func classLabels() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "    class Animal[\"Animal with a label\"]",
            "    class Car[\"Car with *! symbols\"]",
            "    Animal --> Car",
        ])
        #expect(diagram.node("Animal")?.label == "Animal with a label")
        #expect(diagram.node("Car")?.label == "Car with *! symbols")
        #expect(diagram.node("Animal")?.displayName == "Animal with a label")
    }

    /// SPEC: backticks escape special characters in the class name.
    @Test func backtickClassNames() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "    class `Animal Class!`",
            "    class `Car Class`",
            "    `Animal Class!` --> `Car Class`",
        ])
        #expect(ids(in: diagram) == ["Animal Class!", "Car Class"])
        #expect(diagram.relations[0].from == "Animal Class!")
        #expect(diagram.relations[0].to == "Car Class")
    }

    // MARK: - Spec examples: members

    /// SPEC: Bank example — colon members, one at a time.
    @Test func bankAccountColonMembers() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "    class BankAccount",
            "    BankAccount : +String owner",
            "    BankAccount : +Bigdecimal balance",
            "    BankAccount : +deposit(amount)",
            "    BankAccount : +withdrawal(amount)",
        ])
        let bank = diagram.node("BankAccount")
        #expect(bank?.attributes.map(\.displayText) == ["+String owner", "+Bigdecimal balance"])
        #expect(bank?.methods.map(\.displayText) == ["+deposit(amount)", "+withdrawal(amount)"])
        #expect(bank?.attributes.allSatisfy { $0.visibility == .publicAccess } == true)
        #expect(bank?.methods.allSatisfy { $0.kind == .method } == true)
    }

    /// SPEC: `{}` compartments define multiple members at once.
    @Test func bankAccountBraceCompartment() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "class BankAccount{",
            "    +String owner",
            "    +BigDecimal balance",
            "    +deposit(amount)",
            "    +withdrawal(amount)",
            "}",
        ])
        let bank = diagram.node("BankAccount")
        #expect(bank?.attributes.map(\.displayText) == ["+String owner", "+BigDecimal balance"])
        #expect(bank?.methods.map(\.displayText) == ["+deposit(amount)", "+withdrawal(amount)"])
    }

    /// SPEC: return type after `)` with a space: `+deposit(amount) bool`.
    @Test func methodReturnTypes() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "class BankAccount{",
            "    +String owner",
            "    +BigDecimal balance",
            "    +deposit(amount) bool",
            "    +withdrawal(amount) int",
            "}",
        ])
        let methods = diagram.node("BankAccount")?.methods.map(\.displayText) ?? []
        #expect(methods.contains("+deposit(amount) bool"))
        #expect(methods.contains("+withdrawal(amount) int"))
    }

    /// SPEC: `class Square~Shape~` — generic is not part of the class name.
    @Test func genericClassNameIsStripped() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "class Square~Shape~{",
            "    int id",
            "    List~int~ position",
            "    setPoints(List~int~ points)",
            "    getPoints() List~int~",
            "}",
            "Square : -List~string~ messages",
            "Square : +setMessages(List~string~ messages)",
        ])
        let square = diagram.node("Square")
        #expect(square != nil)
        #expect(diagram.node("Square~Shape~") == nil)
        #expect(square?.generic == "Shape")
        #expect(square?.displayName == "Square<Shape>")
        #expect(square?.attributes.map(\.displayText).contains("List<int> position") == true)
        #expect(square?.attributes.map(\.displayText).contains("-List<string> messages") == true)
        #expect(square?.methods.map(\.displayText).contains("getPoints() List<int>") == true)
    }

    /// SPEC: visibility `+` public, `-` private, `#` protected, `~` package.
    @Test func visibilityMarkers() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "class V {",
            "    +pubAttr",
            "    -privAttr",
            "    #protAttr",
            "    ~pkgAttr",
            "    +pubMethod()",
            "    -privMethod()",
            "    #protMethod()",
            "    ~pkgMethod()",
            "}",
        ])
        let node = diagram.node("V")
        let attrs = node?.attributes ?? []
        #expect(attrs.map(\.visibility) == [
            .publicAccess, .privateAccess, .protected, .package,
        ])
        let methods = node?.methods ?? []
        #expect(methods.map(\.visibility) == [
            .publicAccess, .privateAccess, .protected, .package,
        ])
    }

    /// SPEC: `*` marks abstract (italic); `$` marks static (underline).
    @Test func abstractAndStaticClassifiers() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "class C {",
            "    +int count$",
            "    +someAbstractMethod() *",
            "    +someStaticMethod()$",
            "}",
        ])
        let node = diagram.node("C")
        let count = node?.attributes.first { $0.displayText == "+int count" }
        let abstractMethod = node?.methods.first { $0.displayText == "+someAbstractMethod()" }
        let staticMethod = node?.methods.first { $0.displayText == "+someStaticMethod()" }
        #expect(count?.isStatic == true)
        #expect(count?.isAbstract == false)
        #expect(abstractMethod?.isAbstract == true)
        #expect(abstractMethod?.isStatic == false)
        #expect(staticMethod?.isStatic == true)
        #expect(staticMethod?.isAbstract == false)
        #expect(abstractMethod?.displayText.contains("*") == false)
        #expect(staticMethod?.displayText.contains("$") == false)
    }

    // MARK: - Spec examples: relations

    /// SPEC table of the eight UML relations, first direction.
    @Test func eightRelationTypes() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "classA <|-- classB",
            "classC *-- classD",
            "classE o-- classF",
            "classG <-- classH",
            "classI -- classJ",
            "classK <.. classL",
            "classM <|.. classN",
            "classO .. classP",
        ])
        #expect(diagram.relations.count == 8)
        #expect(diagram.relations[0] == ClassRelation(
            from: "classA", to: "classB",
            fromEnd: .inheritance, toEnd: .none, line: .solid,
            label: nil, fromCardinality: nil, toCardinality: nil
        ))
        #expect(diagram.relations[1].fromEnd == .composition)
        #expect(diagram.relations[1].line == .solid)
        #expect(diagram.relations[2].fromEnd == .aggregation)
        #expect(diagram.relations[3].fromEnd == .association)
        #expect(diagram.relations[3].toEnd == .none)
        #expect(diagram.relations[4].fromEnd == .none)
        #expect(diagram.relations[4].toEnd == .none)
        #expect(diagram.relations[4].line == .solid)
        #expect(diagram.relations[5].fromEnd == .association)
        #expect(diagram.relations[5].line == .dashed)
        #expect(diagram.relations[6].fromEnd == .inheritance)
        #expect(diagram.relations[6].line == .dashed)
        #expect(diagram.relations[7].line == .dashed)
        #expect(diagram.relations[7].fromEnd == .none)
    }

    /// SPEC: arrowheads in the opposite direction, with labels.
    @Test func reverseRelationsAndLabels() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "classA --|> classB : Inheritance",
            "classC --* classD : Composition",
            "classE --o classF : Aggregation",
            "classG --> classH : Association",
            "classI -- classJ : Link(Solid)",
            "classK ..> classL : Dependency",
            "classM ..|> classN : Realization",
            "classO .. classP : Link(Dashed)",
        ])
        #expect(diagram.relations.count == 8)
        #expect(diagram.relations[0].toEnd == .inheritance)
        #expect(diagram.relations[0].label == "Inheritance")
        #expect(diagram.relations[1].toEnd == .composition)
        #expect(diagram.relations[1].label == "Composition")
        #expect(diagram.relations[2].toEnd == .aggregation)
        #expect(diagram.relations[3].toEnd == .association)
        #expect(diagram.relations[5].toEnd == .association)
        #expect(diagram.relations[5].line == .dashed)
        #expect(diagram.relations[5].label == "Dependency")
        #expect(diagram.relations[6].toEnd == .inheritance)
        #expect(diagram.relations[6].line == .dashed)
        #expect(diagram.relations[6].label == "Realization")
        #expect(diagram.relations[7].label == "Link(Dashed)")
    }

    /// SPEC: two-way relation `Animal <|--|> Zebra`.
    @Test func twoWayInheritance() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "    Animal <|--|> Zebra",
        ])
        #expect(diagram.relations.count == 1)
        #expect(diagram.relations[0].from == "Animal")
        #expect(diagram.relations[0].to == "Zebra")
        #expect(diagram.relations[0].fromEnd == .inheritance)
        #expect(diagram.relations[0].toEnd == .inheritance)
        #expect(diagram.relations[0].line == .solid)
    }

    /// SPEC: `Customer "1" --> "*" Ticket` and friends.
    @Test func cardinalities() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "    Customer \"1\" --> \"*\" Ticket",
            "    Student \"1\" --> \"1..*\" Course",
            "    Galaxy --> \"many\" Star : Contains",
        ])
        #expect(diagram.relations.count == 3)
        #expect(diagram.relations[0].fromCardinality == "1")
        #expect(diagram.relations[0].toCardinality == "*")
        #expect(diagram.relations[1].fromCardinality == "1")
        #expect(diagram.relations[1].toCardinality == "1..*")
        #expect(diagram.relations[2].fromCardinality == nil)
        #expect(diagram.relations[2].toCardinality == "many")
        #expect(diagram.relations[2].label == "Contains")
    }

    // MARK: - Spec examples: stereotypes

    /// SPEC: inline `class Shape <<interface>>`.
    @Test func stereotypeInline() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "  class Shape <<interface>>",
        ])
        #expect(diagram.node("Shape")?.stereotype == "interface")
    }

    /// SPEC: separate line `<<interface>> Shape`.
    @Test func stereotypeSeparateLine() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "class Shape",
            "<<interface>> Shape",
            "Shape : noOfVertices",
            "Shape : draw()",
        ])
        let shape = diagram.node("Shape")
        #expect(shape?.stereotype == "interface")
        #expect(shape?.attributes.map(\.displayText) == ["noOfVertices"])
        #expect(shape?.methods.map(\.displayText) == ["draw()"])
    }

    /// SPEC: nested `<<interface>>` / `<<enumeration>>` inside `{}`.
    @Test func stereotypeNested() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "class Shape{",
            "    <<interface>>",
            "    noOfVertices",
            "    draw()",
            "}",
            "class Color{",
            "    <<enumeration>>",
            "    RED",
            "    BLUE",
            "    GREEN",
            "    WHITE",
            "    BLACK",
            "}",
        ])
        #expect(diagram.node("Shape")?.stereotype == "interface")
        #expect(diagram.node("Color")?.stereotype == "enumeration")
        #expect(diagram.node("Color")?.attributes.map(\.displayText) == [
            "RED", "BLUE", "GREEN", "WHITE", "BLACK",
        ])
    }

    // MARK: - Spec example: Animal

    /// SPEC opening example — inheritance tree + mixed member syntax.
    @Test func animalExample() {
        let diagram = MermaidClassParser.parse(lines: Self.animalLines)
        #expect(ids(in: diagram) == ["Animal", "Duck", "Fish", "Zebra"])
        #expect(diagram.relations.count == 3)
        #expect(diagram.relations.allSatisfy { $0.from == "Animal" && $0.fromEnd == .inheritance })

        let animal = diagram.node("Animal")
        #expect(animal?.attributes.map(\.displayText) == ["+int age", "+String gender"])
        #expect(animal?.methods.map(\.displayText) == ["+isMammal()", "+mate()"])

        #expect(diagram.node("Duck")?.attributes.map(\.displayText) == ["+String beakColor"])
        #expect(diagram.node("Duck")?.methods.map(\.displayText) == ["+swim()", "+quack()"])
        #expect(diagram.node("Fish")?.attributes.map(\.visibility) == [.privateAccess])
        #expect(diagram.node("Zebra")?.attributes.map(\.displayText) == ["+bool is_wild"])
    }

    /// SPEC: `direction RL` plus cardinalities on aggregation.
    @Test func directionAndStudentExample() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "  direction RL",
            "  class Student {",
            "    -idCard : IdCard",
            "  }",
            "  class IdCard{",
            "    -id : int",
            "    -name : string",
            "  }",
            "  class Bike{",
            "    -id : int",
            "    -name : string",
            "  }",
            "  Student \"1\" --o \"1\" IdCard : carries",
            "  Student \"1\" --o \"1\" Bike : rides",
        ])
        #expect(diagram.direction == .RL)
        #expect(diagram.relations.count == 2)
        #expect(diagram.relations[0].toEnd == .aggregation)
        #expect(diagram.relations[0].fromCardinality == "1")
        #expect(diagram.relations[0].toCardinality == "1")
        #expect(diagram.relations[0].label == "carries")
        #expect(diagram.relations[1].label == "rides")
        #expect(diagram.node("Student")?.attributes.map(\.displayText) == ["-idCard : IdCard"])
    }

    // MARK: - Skip without crashing

    /// SPEC: `%%` comments are ignored, including syntax on the comment line.
    @Test func commentsIgnored() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "%% This whole line is a comment classDiagram class Shape <<interface>>",
            "class Shape{",
            "    <<interface>>",
            "    noOfVertices",
            "    draw()",
            "}",
        ])
        #expect(ids(in: diagram) == ["Shape"])
        #expect(diagram.node("Shape")?.stereotype == "interface")
    }

    /// Notes, click/link/callback, and CSS must not crash or invent classes.
    @Test func notesClickAndCssSkipped() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "    note \"This is a general note\"",
            "    note for MyClass \"This is a note for a class\"",
            "    class MyClass{",
            "    }",
            "    class Animal:::someclass",
            "    classDef someclass fill:#f96",
            "    style Animal fill:#f9f,stroke:#333,stroke-width:4px",
            "    cssClass \"MyClass\" someclass",
            "    click MyClass href \"https://www.github.com\" \"tooltip\"",
            "    link Animal \"https://www.github.com\" \"tooltip\"",
            "    callback MyClass \"callbackFunction\" \"tooltip\"",
        ])
        #expect(Set(ids(in: diagram)) == Set(["MyClass", "Animal"]))
        #expect(diagram.relations.isEmpty)
        #expect(diagram.node("MyClass")?.attributes.isEmpty == true)
    }

    /// Lollipop interfaces and unknown lines are skipped without crashing.
    @Test func lollipopAndUnknownSkipped() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "  class Class01 {",
            "    int amount",
            "    draw()",
            "  }",
            "  Class01 --() bar",
            "  foo ()-- Class01",
            "  this is not a statement",
        ])
        #expect(ids(in: diagram) == ["Class01"])
        #expect(diagram.relations.isEmpty)
        #expect(diagram.node("Class01")?.attributes.map(\.displayText) == ["int amount"])
    }

    /// Empty body yields an empty diagram, not a crash.
    @Test func emptyBody() {
        let diagram = MermaidClassParser.parse(lines: ["classDiagram"])
        #expect(diagram.classes.isEmpty)
        #expect(diagram.relations.isEmpty)
        #expect(diagram.direction == .TB)
    }

    /// Namespace wrapper is ignored; classes inside still parse.
    @Test func namespaceDoesNotDropInnerClasses() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "namespace BaseShapes {",
            "    class Triangle",
            "    class Rectangle {",
            "      double width",
            "      double height",
            "    }",
            "}",
        ])
        #expect(ids(in: diagram) == ["Triangle", "Rectangle"])
        #expect(diagram.node("Rectangle")?.attributes.map(\.displayText) == [
            "double width", "double height",
        ])
    }

    // MARK: - Renderer / layout facts

    /// Renderer produces a non-placeholder layout with customDraw/customSize.
    @Test func rendererProducesNonPlaceholderLayout() {
        let diagram = MermaidClassParser.parse(lines: Self.animalLines)
        let layout = MermaidClassRenderer.layout(
            diagram,
            configuration: .default(maxWidth: 360)
        )
        #expect(layout.isPlaceholder == false)
        #expect(layout.customDraw != nil)
        guard let size = layout.customSize else {
            Issue.record("Expected non-nil customSize")
            return
        }
        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    /// Empty diagram yields a placeholder layout, not a crash.
    @Test func emptyDiagramYieldsPlaceholder() {
        let layout = MermaidClassRenderer.layout(
            .empty,
            configuration: .default(maxWidth: 360)
        )
        #expect(layout.isPlaceholder == true)
        #expect(layout.customDraw == nil)
    }

    /// SPEC Animal example: four boxes, three edges, parent above children.
    @Test func animalLayoutParentAboveChildren() {
        let diagram = MermaidClassParser.parse(lines: Self.animalLines)
        let layout = MermaidClassRenderer.layout(
            diagram,
            configuration: .default(maxWidth: 360)
        )
        let positions = layout.graphResult.nodePositions
        #expect(positions["Animal"] != nil)
        #expect(positions["Duck"] != nil)
        #expect(positions["Fish"] != nil)
        #expect(positions["Zebra"] != nil)
        #expect(layout.graphResult.edgePaths.count == 3)

        guard let animal = positions["Animal"],
              let duck = positions["Duck"],
              let fish = positions["Fish"],
              let zebra = positions["Zebra"]
        else { return }

        #expect(animal.maxY < duck.minY)
        #expect(animal.maxY < fish.minY)
        #expect(animal.maxY < zebra.minY)
        #expect(!boxesOverlap(animal, duck))
        #expect(!boxesOverlap(animal, fish))
        #expect(!boxesOverlap(animal, zebra))
        #expect(!boxesOverlap(duck, fish))
        #expect(!boxesOverlap(duck, zebra))
        #expect(!boxesOverlap(fish, zebra))
    }

    /// Three-compartment boxes grow with members.
    @Test func membersIncreaseBoxHeight() {
        let empty = MermaidClassParser.parse(lines: [
            "classDiagram",
            "class Empty",
        ])
        let bank = MermaidClassParser.parse(lines: [
            "classDiagram",
            "class BankAccount{",
            "    +String owner",
            "    +BigDecimal balance",
            "    +deposit(amount)",
            "    +withdrawal(amount)",
            "}",
        ])
        let emptyLayout = MermaidClassRenderer.layout(empty, configuration: .default(maxWidth: 360))
        let bankLayout = MermaidClassRenderer.layout(bank, configuration: .default(maxWidth: 360))
        guard let emptyRect = emptyLayout.graphResult.nodePositions["Empty"],
              let bankRect = bankLayout.graphResult.nodePositions["BankAccount"]
        else {
            Issue.record("Expected laid-out class boxes")
            return
        }
        #expect(bankRect.height > emptyRect.height)
        // Empty still has three compartments (name / attributes / methods).
        #expect(emptyRect.height > 20)
    }

    /// Long members wrap instead of emitting one giant unwrapped canvas.
    @Test func membersWrapToMaxWidth() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "class Wide {",
            "    +String this is a very long attribute that should wrap inside the class box",
            "    +computeSomethingQuiteExpensive(input value) Result",
            "}",
        ])
        let config = RenderConfiguration.default(maxWidth: 200)
        let layout = MermaidClassRenderer.layout(diagram, configuration: config)
        guard let rect = layout.graphResult.nodePositions["Wide"] else {
            Issue.record("Expected Wide box")
            return
        }
        #expect(rect.width <= 200)
        #expect(rect.height > 40)
    }

    /// `direction RL`: Student (source) sits to the right of IdCard.
    @Test func directionRLPlacesSourceOnTheRight() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "  direction RL",
            "  Student \"1\" --o \"1\" IdCard : carries",
        ])
        let layout = MermaidClassRenderer.layout(
            diagram,
            configuration: .default(maxWidth: 360)
        )
        guard let student = layout.graphResult.nodePositions["Student"],
              let idCard = layout.graphResult.nodePositions["IdCard"]
        else {
            Issue.record("Expected Student and IdCard boxes")
            return
        }
        #expect(student.minX > idCard.maxX)
        #expect(!boxesOverlap(student, idCard))
        #expect(layout.graphResult.edgePaths.count == 1)
    }

    /// Stereotype + members still produce a usable custom-drawn layout.
    @Test func rendererWithStereotypeAndRelations() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "class Shape{",
            "    <<interface>>",
            "    noOfVertices",
            "    draw()",
            "}",
            "class Circle",
            "Shape <|-- Circle",
        ])
        let layout = MermaidClassRenderer.layout(
            diagram,
            configuration: .default(maxWidth: 360)
        )
        #expect(layout.isPlaceholder == false)
        #expect(layout.graphResult.nodePositions["Shape"] != nil)
        #expect(layout.graphResult.nodePositions["Circle"] != nil)
        #expect(layout.graphResult.edgePaths.count == 1)
        guard let size = layout.customSize else {
            Issue.record("Expected non-nil customSize")
            return
        }
        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    /// customDraw must run and paint abstract/static members differently from ordinary ones.
    @Test func customDrawMarksAbstractAndStaticMembers() {
        let abstract = MermaidClassParser.parse(lines: [
            "classDiagram",
            "class Shape {",
            "    +draw() *",
            "}",
        ])
        let ordinary = MermaidClassParser.parse(lines: [
            "classDiagram",
            "class Shape {",
            "    +draw()",
            "}",
        ])
        let staticMember = MermaidClassParser.parse(lines: [
            "classDiagram",
            "class Shape {",
            "    +draw()$",
            "}",
        ])

        #expect(abstract.node("Shape")?.methods.first?.isAbstract == true)
        #expect(staticMember.node("Shape")?.methods.first?.isStatic == true)

        let abstractShot = renderBitmap(abstract)
        let ordinaryShot = renderBitmap(ordinary)
        let staticShot = renderBitmap(staticMember)
        guard let abstractShot, let ordinaryShot, let staticShot else {
            Issue.record("Expected customDraw bitmaps for abstract/static/ordinary members")
            return
        }
        #expect(abstractShot.image != nil)
        #expect(ordinaryShot.image != nil)
        #expect(staticShot.image != nil)
        // Italic abstract and underlined static must not match the ordinary member.
        #expect(abstractShot.pixels != ordinaryShot.pixels)
        #expect(staticShot.pixels != ordinaryShot.pixels)
        #expect(abstractShot.pixels != staticShot.pixels)
    }

    /// Unbroken identifiers wrap/ellipsize so painted text stays inside the maxWidth box.
    @Test func unbrokenIdentifiersStayInsideBox() {
        let longName = "VeryLongUnbrokenClassIdentifierWithoutSpaces"
        let longMethod = "computeSomethingQuiteExpensiveWithoutAnySpaces(inputValue)Result"
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "class \(longName) {",
            "    +\(longMethod)",
            "}",
        ])
        let config = RenderConfiguration.default(maxWidth: 200)
        let layout = MermaidClassRenderer.layout(diagram, configuration: config)
        guard let rect = layout.graphResult.nodePositions[longName] else {
            Issue.record("Expected long-id box")
            return
        }
        #expect(rect.width <= 200)
        #expect(rect.height > 40)

        guard let shot = renderBitmap(diagram, configuration: config) else {
            Issue.record("Expected customDraw for long-id class")
            return
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, config.fontSize, nil)
        let rawNameWidth = MermaidTextUtils.measureText(longName, font: font, fontSize: config.fontSize).width
        let rawMethodWidth = MermaidTextUtils.measureText("+" + longMethod, font: font, fontSize: config.fontSize).width
        #expect(rawNameWidth > rect.width - 8 || rawMethodWidth > rect.width - 8)

        guard let painted = paintedNodeRect(longName, layout: layout, shot: shot),
              let ink = shot.inkBounds()
        else {
            Issue.record("Expected painted bounds for long-id class")
            return
        }
        // Overflowing glyphs land on the white canvas outside the box.
        #expect(ink.minX + 0.5 >= painted.minX - 3)
        #expect(ink.maxX <= painted.maxX + 3)
        #expect(ink.minY + 0.5 >= painted.minY - 3)
        #expect(ink.maxY <= painted.maxY + 3)
    }

    /// Relationship labels reserve rank space so they clear boxes and cardinalities.
    @Test func relationshipLabelsReserveClearance() {
        let unlabeled = MermaidClassParser.parse(lines: [
            "classDiagram",
            "    Parent \"1\" --> \"*\" Child",
        ])
        let labeled = MermaidClassParser.parse(lines: [
            "classDiagram",
            "    Parent \"1\" --> \"*\" Child : this is a very long relationship label that must wrap",
        ])
        let config = RenderConfiguration.default(maxWidth: 280)
        let unlabeledLayout = MermaidClassRenderer.layout(unlabeled, configuration: config)
        let labeledLayout = MermaidClassRenderer.layout(labeled, configuration: config)

        guard let unlabeledParent = unlabeledLayout.graphResult.nodePositions["Parent"],
              let unlabeledChild = unlabeledLayout.graphResult.nodePositions["Child"],
              let parent = labeledLayout.graphResult.nodePositions["Parent"],
              let child = labeledLayout.graphResult.nodePositions["Child"],
              let path = labeledLayout.graphResult.edgePaths.first,
              path.points.count >= 2
        else {
            Issue.record("Expected Parent/Child boxes and an edge path")
            return
        }

        let unlabeledGap = unlabeledChild.minY - unlabeledParent.maxY
        let labeledGap = child.minY - parent.maxY
        #expect(labeledGap > unlabeledGap)

        let font = CTFontCreateWithName("Helvetica" as CFString, config.fontSize, nil)
        let label = labeled.relations[0].label ?? ""
        let labelSize = MermaidTextUtils.measureText(label, font: font, fontSize: config.fontSize)
        // Rank gap must fit the wrapped/unwrapped label plus cardinality breathing room.
        #expect(labeledGap + 0.5 >= min(labelSize.height, config.fontSize * 2) + config.fontSize)

        let mid = arcMidpoint(path.points)
        let padding = config.fontSize * 0.25
        let labelRect = CGRect(
            x: mid.x - labelSize.width / 2 - padding,
            y: mid.y - labelSize.height / 2 - padding,
            width: labelSize.width + padding * 2,
            height: labelSize.height + padding * 2
        )
        // Even the unwrapped label estimate should sit in the reserved corridor, not on a box.
        // After wrapping, height grows and width shrinks; the reserved gap is what keeps it clear.
        #expect(mid.y > parent.maxY)
        #expect(mid.y < child.minY)
        #expect(!labelRect.intersects(parent.insetBy(dx: 1, dy: 1)) || labeledGap >= labelSize.height)
        #expect(!boxesOverlap(parent, child))

        let fromEnd = path.points[0]
        let toEnd = path.points[path.points.count - 1]
        let cardOffset = config.fontSize * 1.6
        let fromCard = CGPoint(
            x: fromEnd.x + (path.points[1].x - fromEnd.x) * 0.15,
            y: fromEnd.y + cardOffset
        )
        let toCard = CGPoint(
            x: toEnd.x + (path.points[path.points.count - 2].x - toEnd.x) * 0.15,
            y: toEnd.y - cardOffset
        )
        let cardSize = CGSize(width: config.fontSize, height: config.fontSize)
        let fromCardRect = CGRect(
            x: fromCard.x - cardSize.width / 2,
            y: fromCard.y - cardSize.height / 2,
            width: cardSize.width,
            height: cardSize.height
        )
        let toCardRect = CGRect(
            x: toCard.x - cardSize.width / 2,
            y: toCard.y - cardSize.height / 2,
            width: cardSize.width,
            height: cardSize.height
        )
        #expect(!labelRect.intersects(fromCardRect) || labeledGap >= labelSize.height + cardOffset)
        #expect(!labelRect.intersects(toCardRect) || labeledGap >= labelSize.height + cardOffset)

        guard let shot = renderBitmap(labeled, configuration: config) else {
            Issue.record("Expected customDraw for labeled relation")
            return
        }
        #expect(shot.image != nil)
    }

    /// Two long relations in the same rank corridor must not share one label midpoint.
    @Test func adjacentSameRankRelationshipLabelsDoNotOverlap() {
        let diagram = MermaidClassParser.parse(lines: [
            "classDiagram",
            "    Parent --> ChildA : this is a very long relationship label for the first child",
            "    Parent --> ChildB : this is a very long relationship label for the second child",
        ])
        let config = RenderConfiguration.default(maxWidth: 280)
        let layout = MermaidClassRenderer.layout(diagram, configuration: config)
        guard let parent = layout.graphResult.nodePositions["Parent"],
              let childA = layout.graphResult.nodePositions["ChildA"],
              let childB = layout.graphResult.nodePositions["ChildB"],
              layout.graphResult.edgePaths.count == 2
        else {
            Issue.record("Expected Parent/ChildA/ChildB boxes and two edge paths")
            return
        }
        #expect(abs(childA.minY - childB.minY) < 1)
        #expect(parent.maxY < childA.minY)
        #expect(parent.maxY < childB.minY)
        #expect(!boxesOverlap(parent, childA))
        #expect(!boxesOverlap(parent, childB))
        #expect(!boxesOverlap(childA, childB))

        guard let shot = renderBitmap(diagram, configuration: config) else {
            Issue.record("Expected customDraw for adjacent labeled relations")
            return
        }
        guard let paintedParent = paintedNodeRect("Parent", layout: layout, shot: shot),
              let paintedA = paintedNodeRect("ChildA", layout: layout, shot: shot),
              let paintedB = paintedNodeRect("ChildB", layout: layout, shot: shot)
        else {
            Issue.record("Expected painted class boxes")
            return
        }
        let corridorTop = paintedParent.maxY + 1
        let corridorBottom = min(paintedA.minY, paintedB.minY) - 1
        #expect(corridorBottom > corridorTop)
        let corridor = CGRect(
            x: 0,
            y: corridorTop,
            width: shot.size.width,
            height: corridorBottom - corridorTop
        )
        // Label chips are filled with the dark theme background. One shared
        // midpoint produces a single dark run; separate lanes produce two.
        #expect(shot.darkColumnRuns(in: corridor) >= 2)
    }

    /// Long stereotypes wrap for both measurement and drawing.
    @Test func longStereotypeWrapsConsistently() {
        let short = MermaidClassParser.parse(lines: [
            "classDiagram",
            "class Shape <<interface>>",
        ])
        let long = MermaidClassParser.parse(lines: [
            "classDiagram",
            "class Shape <<this is a very long stereotype annotation that should wrap>>",
        ])
        let config = RenderConfiguration.default(maxWidth: 200)
        let shortLayout = MermaidClassRenderer.layout(short, configuration: config)
        let longLayout = MermaidClassRenderer.layout(long, configuration: config)
        guard let shortRect = shortLayout.graphResult.nodePositions["Shape"],
              let longRect = longLayout.graphResult.nodePositions["Shape"]
        else {
            Issue.record("Expected Shape boxes")
            return
        }
        #expect(longRect.width <= 200)
        #expect(longRect.height > shortRect.height)
        guard let shot = renderBitmap(long, configuration: config) else {
            Issue.record("Expected customDraw for wrapped stereotype")
            return
        }
        guard let painted = paintedNodeRect("Shape", layout: longLayout, shot: shot),
              let ink = shot.inkBounds()
        else {
            Issue.record("Expected painted bounds for wrapped stereotype")
            return
        }
        // Drawing the unwrapped stereotype would spill ink past the measured box.
        #expect(ink.minX + 0.5 >= painted.minX - 3)
        #expect(ink.maxX <= painted.maxX + 3)
        #expect(ink.minY + 0.5 >= painted.minY - 3)
        #expect(ink.maxY <= painted.maxY + 3)
    }

    // MARK: - Helpers

    private static let animalLines = [
        "classDiagram",
        "    Animal <|-- Duck",
        "    Animal <|-- Fish",
        "    Animal <|-- Zebra",
        "    Animal : +int age",
        "    Animal : +String gender",
        "    Animal: +isMammal()",
        "    Animal: +mate()",
        "    class Duck{",
        "      +String beakColor",
        "      +swim()",
        "      +quack()",
        "    }",
        "    class Fish{",
        "      -int sizeInFeet",
        "      -canEat()",
        "    }",
        "    class Zebra{",
        "      +bool is_wild",
        "      +run()",
        "    }",
    ]

    private func ids(in diagram: ClassDiagram) -> [String] {
        diagram.classes.map(\.id)
    }

    private func boxesOverlap(_ a: CGRect, _ b: CGRect) -> Bool {
        a.insetBy(dx: 0.5, dy: 0.5).intersects(b.insetBy(dx: 0.5, dy: 0.5))
    }

    private struct BitmapShot {
        let image: CGImage?
        let pixels: [UInt8]
        let size: CGSize
        let width: Int
        let height: Int

        func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
            guard x >= 0, y >= 0, x < width, y < height else { return nil }
            let offset = (y * width + x) * 4
            return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
        }

        /// Bounding box of pixels that are not the white test canvas.
        func inkBounds(whiteThreshold: UInt8 = 250) -> CGRect? {
            var minX = width
            var minY = height
            var maxX = 0
            var maxY = 0
            var found = false
            for y in 0..<height {
                for x in 0..<width {
                    guard let px = pixel(x, y) else { continue }
                    // Skip leftover zeroed buffer pixels; the canvas fill is white.
                    if px.r == 0, px.g == 0, px.b == 0 { continue }
                    if px.r < whiteThreshold || px.g < whiteThreshold || px.b < whiteThreshold {
                        found = true
                        minX = min(minX, x)
                        minY = min(minY, y)
                        maxX = max(maxX, x)
                        maxY = max(maxY, y)
                    }
                }
            }
            guard found else { return nil }
            return CGRect(
                x: minX,
                y: minY,
                width: maxX - minX + 1,
                height: maxY - minY + 1
            )
        }

        /// Count separated columns of dark fill, used for relationship-label chips.
        func darkColumnRuns(
            in rect: CGRect,
            maxChannel: UInt8 = 80,
            minPixelsInColumn: Int = 2,
            minRunWidth: Int = 4
        ) -> Int {
            let minX = max(Int(floor(rect.minX)), 0)
            let maxX = min(Int(ceil(rect.maxX)), width)
            let minY = max(Int(floor(rect.minY)), 0)
            let maxY = min(Int(ceil(rect.maxY)), height)
            guard maxX > minX, maxY > minY else { return 0 }

            var darkColumns: [Bool] = []
            darkColumns.reserveCapacity(max(maxX - minX, 0))
            for x in minX..<maxX {
                var dark = 0
                for y in minY..<maxY {
                    guard let px = pixel(x, y) else { continue }
                    if px.r <= maxChannel, px.g <= maxChannel, px.b <= maxChannel {
                        dark += 1
                    }
                }
                darkColumns.append(dark >= minPixelsInColumn)
            }

            var runs = 0
            var index = 0
            while index < darkColumns.count {
                guard darkColumns[index] else {
                    index += 1
                    continue
                }
                let start = index
                while index < darkColumns.count, darkColumns[index] {
                    index += 1
                }
                if index - start >= minRunWidth {
                    runs += 1
                }
            }
            return runs
        }
    }

    private func paintedNodeRect(
        _ id: String,
        layout: MermaidFlowchartRenderer.FlowchartLayout,
        shot: BitmapShot
    ) -> CGRect? {
        guard let rect = layout.graphResult.nodePositions[id] else { return nil }
        let marginX = (shot.size.width - layout.graphResult.totalSize.width) / 2
        let marginY = (shot.size.height - layout.graphResult.totalSize.height) / 2
        return rect.offsetBy(dx: marginX, dy: marginY)
    }

    private func renderBitmap(
        _ diagram: ClassDiagram,
        configuration: RenderConfiguration = .default(maxWidth: 360)
    ) -> BitmapShot? {
        let layout = MermaidClassRenderer.layout(diagram, configuration: configuration)
        guard let draw = layout.customDraw, let size = layout.customSize else { return nil }
        let width = max(Int(size.width.rounded(.up)), 1)
        let height = max(Int(size.height.rounded(.up)), 1)
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let image: CGImage? = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            // Fill the raw buffer in identity coords so ceil(size) padding is not black ink.
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            draw(ctx, .zero)
            return ctx.makeImage()
        }
        return BitmapShot(image: image, pixels: pixels, size: size, width: width, height: height)
    }

    private func arcMidpoint(_ points: [CGPoint]) -> CGPoint {
        guard points.count >= 2 else { return points.first ?? .zero }
        var total: CGFloat = 0
        for index in 0..<(points.count - 1) {
            total += hypot(
                points[index + 1].x - points[index].x,
                points[index + 1].y - points[index].y
            )
        }
        guard total > 0 else { return points[0] }
        var remaining = total / 2
        for index in 0..<(points.count - 1) {
            let dx = points[index + 1].x - points[index].x
            let dy = points[index + 1].y - points[index].y
            let length = hypot(dx, dy)
            if length >= remaining {
                let t = length > 0 ? remaining / length : 0
                return CGPoint(
                    x: points[index].x + dx * t,
                    y: points[index].y + dy * t
                )
            }
            remaining -= length
        }
        return points[points.count - 1]
    }
}

private extension ClassDiagram {
    func node(_ id: String) -> ClassNode? {
        classes.first { $0.id == id }
    }
}
