import Foundation

// MARK: - Top-level diagram

/// Root AST node for any Mermaid diagram.
enum MermaidDiagram: Equatable, Sendable {
    case flowchart(FlowchartDiagram)
    case sequence(SequenceDiagram)
    case gantt(GanttDiagram)
    case mindmap(MindmapDiagram)
    case state(StateDiagram)
    case pie(PieDiagram)
    case timeline(TimelineDiagram)
    case classDiagram(ClassDiagram)
    case erDiagram(ERDiagram)
    case unsupported(type: String)
}

// MARK: - State diagram types

struct StateDiagram: Equatable, Sendable {
    let direction: FlowDirection
    let states: [StateNode]
    let transitions: [StateTransition]
    let notes: [StateDiagramNote]
    let composites: [StateComposite]
    let classDefs: [String: [String: String]]
    let accessibilityTitle: String?
    let accessibilityDescription: String?

    init(
        direction: FlowDirection,
        states: [StateNode],
        transitions: [StateTransition],
        notes: [StateDiagramNote],
        composites: [StateComposite],
        classDefs: [String: [String: String]],
        accessibilityTitle: String? = nil,
        accessibilityDescription: String? = nil
    ) {
        self.direction = direction
        self.states = states
        self.transitions = transitions
        self.notes = notes
        self.composites = composites
        self.classDefs = classDefs
        self.accessibilityTitle = accessibilityTitle
        self.accessibilityDescription = accessibilityDescription
    }

    static let empty = Self(
        direction: .TB,
        states: [],
        transitions: [],
        notes: [],
        composites: [],
        classDefs: [:]
    )
}

struct StateNode: Equatable, Sendable {
    let id: String
    let label: String
    let kind: StateNodeKind
    let classes: [String]
}

enum StateNodeKind: Equatable, Sendable {
    case normal
    case choice
    case fork
    case join
}

struct StateTransition: Equatable, Sendable {
    let from: StateEndpoint
    let to: StateEndpoint
    let label: String?
    let scopeId: String?

    init(from: StateEndpoint, to: StateEndpoint, label: String?, scopeId: String? = nil) {
        self.from = from
        self.to = to
        self.label = label
        self.scopeId = scopeId
    }
}

enum StateEndpoint: Equatable, Sendable {
    case terminal
    case state(String)
}

struct StateDiagramNote: Equatable, Sendable {
    let stateId: String
    let position: StateNotePosition
    let text: String
}

enum StateNotePosition: Equatable, Sendable {
    case leftOf
    case rightOf
}

struct StateComposite: Equatable, Sendable {
    let id: String
    let label: String?
    let direction: FlowDirection?
    let stateIds: [String]
    let regions: [Int]
    let children: [Self]
}

// MARK: - Gantt chart types

struct GanttDiagram: Equatable, Sendable {
    let title: String?
    let dateFormat: String
    let sections: [GanttSection]
    let axisFormat: String?
    let excludes: [String]
    let tickInterval: String?
    let weekend: String?
    let weekday: String?
    let todayMarker: String?
    let displayMode: GanttDisplayMode
    let topAxis: Bool
    let clicks: [GanttClick]

    init(
        title: String?,
        dateFormat: String,
        sections: [GanttSection],
        axisFormat: String?,
        excludes: [String],
        tickInterval: String?,
        weekend: String?,
        weekday: String? = nil,
        todayMarker: String? = nil,
        displayMode: GanttDisplayMode = .standard,
        topAxis: Bool = false,
        clicks: [GanttClick] = []
    ) {
        self.title = title
        self.dateFormat = dateFormat
        self.sections = sections
        self.axisFormat = axisFormat
        self.excludes = excludes
        self.tickInterval = tickInterval
        self.weekend = weekend
        self.weekday = weekday
        self.todayMarker = todayMarker
        self.displayMode = displayMode
        self.topAxis = topAxis
        self.clicks = clicks
    }
}

/// Mermaid Gantt `displayMode` frontmatter/config option.
enum GanttDisplayMode: Equatable, Sendable {
    case standard
    case compact
}

struct GanttClick: Equatable, Sendable {
    let taskId: String
    let action: GanttClickAction
}

enum GanttClickAction: Equatable, Sendable {
    case href(String)
    case call(String)
}

struct GanttSection: Equatable, Sendable {
    let name: String
    let tasks: [GanttTask]
}

struct GanttTask: Equatable, Sendable {
    let name: String
    let id: String?
    let status: GanttTaskStatus
    let startDate: String?
    let endDate: String?
    let duration: String?
    let afterId: String?
    let afterIds: [String]
    let untilIds: [String]

    init(
        name: String,
        id: String?,
        status: GanttTaskStatus,
        startDate: String?,
        endDate: String?,
        duration: String?,
        afterId: String?,
        afterIds: [String] = [],
        untilIds: [String] = []
    ) {
        self.name = name
        self.id = id
        self.status = status
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.afterId = afterId
        if !afterIds.isEmpty {
            self.afterIds = afterIds
        } else if let afterId {
            self.afterIds = [afterId]
        } else {
            self.afterIds = []
        }
        self.untilIds = untilIds
    }
}

enum GanttTaskStatus: Equatable, Sendable {
    case normal
    case active
    case done
    case critical
    case milestone
    case vert
}

// MARK: - Mindmap types

struct MindmapDiagram: Equatable, Sendable {
    let root: MindmapNode
    let layout: MindmapLayout

    init(root: MindmapNode, layout: MindmapLayout = .default) {
        self.root = root
        self.layout = layout
    }

    static let empty = Self(root: MindmapNode(label: "", shape: .default, children: []))
}

enum MindmapLayout: Equatable, Sendable {
    case `default`
    case tidyTree
}

struct MindmapNode: Equatable, Sendable {
    let label: String
    let shape: MindmapNodeShape
    let icon: String?
    let classes: [String]
    let children: [Self]

    init(
        label: String,
        shape: MindmapNodeShape,
        children: [Self],
        icon: String? = nil,
        classes: [String] = []
    ) {
        self.label = label
        self.shape = shape
        self.icon = icon
        self.classes = classes
        self.children = children
    }
}

enum MindmapNodeShape: Equatable, Sendable {
    /// Default (root gets rounded rect, children get plain)
    case `default`
    /// `[text]` — square
    case square
    /// `(text)` — rounded
    case rounded
    /// `((text))` — circle
    case circle
    /// `))text((` — bang
    case bang
    /// `)text(` — cloud
    case cloud
    /// `{{text}}` — hexagon
    case hexagon
}

// MARK: - Flowchart types

struct FlowchartDiagram: Equatable, Sendable {
    let direction: FlowDirection
    let nodes: [FlowNode]
    let edges: [FlowEdge]
    let subgraphs: [FlowSubgraph]
    let classDefs: [String: [String: String]]
    let styleDirectives: [FlowStyleDirective]
    let classApplications: [String: [String]]

    static let empty = Self(
        direction: .TD,
        nodes: [],
        edges: [],
        subgraphs: [],
        classDefs: [:],
        styleDirectives: [],
        classApplications: [:]
    )
}

struct FlowNode: Equatable, Sendable {
    let id: String
    let label: String
    let shape: FlowNodeShape
    let classes: [String]

    init(id: String, label: String, shape: FlowNodeShape, classes: [String] = []) {
        self.id = id
        self.label = label
        self.shape = shape
        self.classes = classes
    }
}

struct FlowEdge: Equatable, Sendable {
    let from: String
    let to: String
    let label: String?
    let style: FlowEdgeStyle
    let id: String?

    init(from: String, to: String, label: String?, style: FlowEdgeStyle, id: String? = nil) {
        self.from = from
        self.to = to
        self.label = label
        self.style = style
        self.id = id
    }
}

enum FlowDirection: String, Sendable, CaseIterable {
    case TB, TD, BT, LR, RL
}

enum FlowNodeShape: Equatable, Sendable {
    /// `A[text]`
    case rectangle
    /// `A(text)`
    case rounded
    /// `A([text])`
    case stadium
    /// `A{text}`
    case diamond
    /// `A{{text}}`
    case hexagon
    /// `A((text))`
    case circle
    /// `A[(text)]`
    case cylindrical
    /// `A[[text]]`
    case subroutine
    /// `A>text]`
    case asymmetric
    /// `A[/text/]`
    case parallelogram
    /// `A[\text\]`
    case parallelogramAlt
    /// `A[/text\]`
    case trapezoid
    /// `A[\text/]`
    case trapezoidAlt
    /// `A(((text)))`
    case doubleCircle
    /// v11.3+ `@{ shape: bang }`.
    case bang
    /// v11.3+ notched rectangle / card.
    case notchedRectangle
    /// v11.3+ cloud.
    case cloud
    /// v11.3+ hourglass / collate.
    case hourglass
    /// v11.3+ lightning bolt.
    case bolt
    /// v11.3+ left brace comment.
    case brace
    /// v11.3+ right brace comment.
    case braceRight
    /// v11.3+ braces on both sides.
    case braces
    /// v11.3+ datastore.
    case datastore
    /// v11.3+ horizontal cylinder.
    case horizontalCylinder
    /// v11.3+ lined cylinder.
    case linedCylinder
    /// v11.3+ curved trapezoid.
    case curvedTrapezoid
    /// v11.3+ divided rectangle.
    case dividedRectangle
    /// v11.3+ document.
    case document
    /// v11.3+ delay.
    case delay
    /// v11.3+ triangle.
    case triangle
    /// v11.3+ fork/join.
    case forkJoin
    /// v11.3+ window pane.
    case windowPane
    /// v11.3+ filled circle.
    case filledCircle
    /// v11.3+ lined document.
    case linedDocument
    /// v11.3+ notched pentagon.
    case notchedPentagon
    /// v11.3+ flipped triangle.
    case flippedTriangle
    /// v11.3+ sloped rectangle.
    case slopedRectangle
    /// v11.3+ stacked document.
    case stackedDocument
    /// v11.3+ stacked rectangle.
    case stackedRectangle
    /// v11.3+ flag / paper tape.
    case flag
    /// v11.3+ bow tie rectangle.
    case bowTieRectangle
    /// v11.3+ crossed circle.
    case crossedCircle
    /// v11.3+ tagged document.
    case taggedDocument
    /// v11.3+ tagged process.
    case taggedRectangle
    /// v11.3+ text block.
    case textBlock
    /// v11.3+ odd shape.
    case odd
    /// Bare ID with no shape delimiters — uses ID as label.
    case `default`
}

enum FlowEdgeStyle: Equatable, Sendable {
    /// `-->`
    case arrow
    /// `---`
    case open
    /// `-.->` or `-.->`
    case dotted
    /// `==>`
    case thick
    /// `~~~`
    case invisible
    /// `--o`
    case circle
    /// `--x`
    case cross
    /// `<-->`
    case biArrow
    /// `o--o`
    case biCircle
    /// `x--x`
    case biCross
}

struct FlowSubgraph: Equatable, Sendable {
    let id: String
    let title: String?
    let direction: FlowDirection?
    let nodeIds: [String]
    let regionCount: Int
    let subgraphs: [Self]
}

struct FlowStyleDirective: Equatable, Sendable {
    let nodeId: String
    let properties: [String: String]
}

// MARK: - Sequence diagram types (Phase 2)

/// Chronological sequence of parsed sequence-diagram events.
///
/// `participants` / `messages` / `notes` / `blocks` stay as derived views so
/// existing tests can keep reading those arrays. The renderer walks `events`
/// so notes, frames, activations, and create/destroy stay in source order.
enum SequenceEvent: Equatable, Sendable {
    case message(SequenceMessage)
    case note(SequenceNote)
    case activate(actorId: String)
    case deactivate(actorId: String)
    case create(SequenceParticipant)
    case destroy(actorId: String)
    case blockOpen(kind: SequenceBlockKind, label: String)
    case blockDivider(kind: SequenceBlockDividerKind, label: String)
    case blockClose
}

/// Branch divider inside `alt` / `par` / `critical`.
enum SequenceBlockDividerKind: Equatable, Sendable {
    /// `else` inside `alt`.
    case `else`
    /// `and` inside `par`.
    case and
    /// `option` inside `critical`.
    case option
}

struct SequenceDiagram: Equatable, Sendable {
    let events: [SequenceEvent]
    let participants: [SequenceParticipant]
    let boxes: [SequenceBox]
    let links: [SequenceLink]
    let autonumber: Bool
    let autonumberStart: Double
    let autonumberIncrement: Double

    init(
        events: [SequenceEvent] = [],
        participants: [SequenceParticipant],
        messages: [SequenceMessage]? = nil,
        notes: [SequenceNote]? = nil,
        blocks: [SequenceBlock]? = nil,
        boxes: [SequenceBox],
        links: [SequenceLink],
        autonumber: Bool,
        autonumberStart: Double,
        autonumberIncrement: Double
    ) {
        // Prefer an explicit event stream. Older call sites that only pass
        // parallel arrays still reconstruct a chronological approximation.
        if events.isEmpty, let messages, let notes {
            self.events = Self.events(
                fromMessages: messages,
                notes: notes,
                blocks: blocks ?? []
            )
        } else {
            self.events = events
        }
        self.participants = participants
        self.boxes = boxes
        self.links = links
        self.autonumber = autonumber
        self.autonumberStart = autonumberStart
        self.autonumberIncrement = autonumberIncrement
    }

    /// Messages in source order, derived from `events`.
    var messages: [SequenceMessage] {
        events.compactMap { event in
            if case .message(let message) = event { return message }
            return nil
        }
    }

    /// Notes in source order, derived from `events`.
    var notes: [SequenceNote] {
        events.compactMap { event in
            if case .note(let note) = event { return note }
            return nil
        }
    }

    /// Structural blocks derived from open/divider/close events.
    var blocks: [SequenceBlock] {
        struct OpenBlock {
            var kind: SequenceBlockKind
            var label: String
            var start: Int
            var elses: [SequenceElseBlock]
        }

        var result: [SequenceBlock] = []
        var stack: [OpenBlock] = []
        var messageCount = 0

        func closeTop() {
            guard let top = stack.popLast() else { return }
            guard top.kind != .rect || !top.label.isEmpty else { return }
            result.append(SequenceBlock(
                kind: top.kind,
                label: top.label,
                elseBlocks: top.elses.isEmpty ? nil : top.elses,
                startMessageIndex: top.start,
                endMessageIndex: max(top.start, messageCount - 1)
            ))
        }

        for event in events {
            switch event {
            case .message:
                messageCount += 1
            case .blockOpen(let kind, let label):
                stack.append(OpenBlock(kind: kind, label: label, start: messageCount, elses: []))
            case .blockDivider(_, let label):
                guard !stack.isEmpty else { continue }
                stack[stack.count - 1].elses.append(SequenceElseBlock(label: label))
            case .blockClose:
                closeTop()
            default:
                break
            }
        }
        while !stack.isEmpty {
            closeTop()
        }
        return result
    }

    private static func events(
        fromMessages messages: [SequenceMessage],
        notes: [SequenceNote],
        blocks: [SequenceBlock]
    ) -> [SequenceEvent] {
        var events: [SequenceEvent] = []
        for message in messages {
            events.append(.message(message))
        }
        for note in notes {
            events.append(.note(note))
        }
        // Block ranges are reconstructed from message indices when the caller
        // only supplied derived arrays. Nested/overlapping ranges stay nested.
        let sortedBlocks = blocks.enumerated().sorted { lhs, rhs in
            let leftStart = lhs.element.startMessageIndex ?? 0
            let rightStart = rhs.element.startMessageIndex ?? 0
            if leftStart != rightStart { return leftStart < rightStart }
            let leftEnd = lhs.element.endMessageIndex ?? leftStart
            let rightEnd = rhs.element.endMessageIndex ?? rightStart
            if leftEnd != rightEnd { return leftEnd > rightEnd }
            return lhs.offset < rhs.offset
        }
        if !sortedBlocks.isEmpty {
            var wrapped: [SequenceEvent] = []
            var openAt: [Int: [SequenceBlock]] = [:]
            var closeAt: [Int: [SequenceBlock]] = [:]
            for item in sortedBlocks {
                let start = item.element.startMessageIndex ?? 0
                let end = item.element.endMessageIndex ?? start
                openAt[start, default: []].append(item.element)
                closeAt[end, default: []].insert(item.element, at: 0)
            }
            var messageIndex = 0
            for event in events {
                if case .message = event {
                    for block in openAt[messageIndex] ?? [] {
                        wrapped.append(.blockOpen(kind: block.kind, label: block.label))
                    }
                    wrapped.append(event)
                    for block in closeAt[messageIndex] ?? [] {
                        for elseBlock in block.elseBlocks ?? [] {
                            wrapped.append(.blockDivider(kind: dividerKind(for: block.kind), label: elseBlock.label))
                        }
                        wrapped.append(.blockClose)
                    }
                    messageIndex += 1
                } else {
                    wrapped.append(event)
                }
            }
            return wrapped
        }
        return events
    }

    private static func dividerKind(for kind: SequenceBlockKind) -> SequenceBlockDividerKind {
        switch kind {
        case .par: return .and
        case .critical: return .option
        default: return .else
        }
    }
}

struct SequenceBox: Equatable, Sendable {
    let label: String?
    let color: String?
    let participantIds: [String]
}

struct SequenceLink: Equatable, Sendable {
    let actorId: String
    let label: String
    let url: String
}

/// A note annotation in a sequence diagram.
struct SequenceNote: Equatable, Sendable {
    let text: String
    let position: NotePosition
    let actors: [String]
}

enum NotePosition: Equatable, Sendable {
    case leftOf
    case rightOf
    case over
}

/// A structural block in a sequence diagram (loop, alt, par, critical, break, opt, rect).
struct SequenceBlock: Equatable, Sendable {
    let kind: SequenceBlockKind
    let label: String
    let elseBlocks: [SequenceElseBlock]?
    let startMessageIndex: Int?
    let endMessageIndex: Int?

    init(
        kind: SequenceBlockKind,
        label: String,
        elseBlocks: [SequenceElseBlock]?,
        startMessageIndex: Int? = nil,
        endMessageIndex: Int? = nil
    ) {
        self.kind = kind
        self.label = label
        self.elseBlocks = elseBlocks
        self.startMessageIndex = startMessageIndex
        self.endMessageIndex = endMessageIndex
    }
}

struct SequenceElseBlock: Equatable, Sendable {
    let label: String
}

enum SequenceBlockKind: Equatable, Sendable {
    case loop
    case alt
    case opt
    case par
    case critical
    case `break`
    case rect
}

/// Activation modifier on a sequence message arrow.
enum ActivationModifier: Equatable, Sendable {
    case activate
    case deactivate
}

struct SequenceParticipant: Equatable, Sendable {
    let id: String
    let label: String
    let isActor: Bool
    let kind: SequenceParticipantKind

    init(
        id: String,
        label: String,
        isActor: Bool,
        kind: SequenceParticipantKind? = nil
    ) {
        self.id = id
        self.label = label
        self.isActor = isActor
        self.kind = kind ?? (isActor ? .actor : .participant)
    }
}

/// Official sequence participant stereotype metadata from `participant A@{ "type": "..." }`.
enum SequenceParticipantKind: String, Equatable, Sendable {
    case participant
    case actor
    case boundary
    case control
    case entity
    case database
    case collections
    case queue
}

enum SequenceArrowStyle: Equatable, Sendable {
    /// `->>` solid with arrowhead
    case solid
    /// `-->>` dashed with arrowhead
    case dashed
    /// `->` solid without arrowhead
    case solidOpen
    /// `-->` dashed without arrowhead
    case dashedOpen
    /// `-x` solid with cross
    case solidCross
    /// `--x` dashed with cross
    case dashedCross
    /// `-)` solid with open async arrow
    case solidAsync
    /// `--)` dashed with open async arrow
    case dashedAsync
    /// `<<->>` solid with bidirectional arrowheads
    case solidBidirectional
    /// `<<-->>` dotted with bidirectional arrowheads
    case dashedBidirectional
    /// `-\|\` solid top half arrowhead
    case solidTopHalfArrow
    /// `--\|\` dashed top half arrowhead
    case dashedTopHalfArrow
    /// `-\|/` solid bottom half arrowhead
    case solidBottomHalfArrow
    /// `--\|/` dashed bottom half arrowhead
    case dashedBottomHalfArrow
    /// `/\|-` solid reverse top half arrowhead
    case solidReverseTopHalfArrow
    /// `/\|--` dashed reverse top half arrowhead
    case dashedReverseTopHalfArrow
    /// `\\-` solid reverse bottom half arrowhead
    case solidReverseBottomHalfArrow
    /// `\\--` dashed reverse bottom half arrowhead
    case dashedReverseBottomHalfArrow
    /// `-\\` solid top stick half arrowhead
    case solidTopStickHalfArrow
    /// `--\\` dashed top stick half arrowhead
    case dashedTopStickHalfArrow
    /// `-//` solid bottom stick half arrowhead
    case solidBottomStickHalfArrow
    /// `--//` dashed bottom stick half arrowhead
    case dashedBottomStickHalfArrow
    /// `//-` solid reverse top stick half arrowhead
    case solidReverseTopStickHalfArrow
    /// `//--` dashed reverse top stick half arrowhead
    case dashedReverseTopStickHalfArrow
}

struct SequenceMessage: Equatable, Sendable {
    let from: String
    let to: String
    let text: String
    let arrowStyle: SequenceArrowStyle
    let activationModifier: ActivationModifier?
    let fromCentral: Bool
    let toCentral: Bool

    init(
        from: String,
        to: String,
        text: String,
        arrowStyle: SequenceArrowStyle,
        activationModifier: ActivationModifier? = nil,
        fromCentral: Bool = false,
        toCentral: Bool = false
    ) {
        self.from = from
        self.to = to
        self.text = text
        self.arrowStyle = arrowStyle
        self.activationModifier = activationModifier
        self.fromCentral = fromCentral
        self.toCentral = toCentral
    }
}
