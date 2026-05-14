import Foundation

// MARK: - Top-level diagram

/// Root AST node for any Mermaid diagram.
enum MermaidDiagram: Equatable, Sendable {
    case flowchart(FlowchartDiagram)
    case sequence(SequenceDiagram)
    case gantt(GanttDiagram)
    case mindmap(MindmapDiagram)
    case unsupported(type: String)
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

    static let empty = Self(root: MindmapNode(label: "", shape: .default, children: []))
}

struct MindmapNode: Equatable, Sendable {
    let label: String
    let shape: MindmapNodeShape
    let children: [MindmapNode]
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
    /// `))text((` — bang (cloud)
    case bang
    /// `)text(` — hexagon
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

    static let empty = Self(
        direction: .TD,
        nodes: [],
        edges: [],
        subgraphs: [],
        classDefs: [:],
        styleDirectives: []
    )
}

struct FlowNode: Equatable, Sendable {
    let id: String
    let label: String
    let shape: FlowNodeShape
}

struct FlowEdge: Equatable, Sendable {
    let from: String
    let to: String
    let label: String?
    let style: FlowEdgeStyle
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
    let subgraphs: [Self]
}

struct FlowStyleDirective: Equatable, Sendable {
    let nodeId: String
    let properties: [String: String]
}

// MARK: - Sequence diagram types (Phase 2)

struct SequenceDiagram: Equatable, Sendable {
    let participants: [SequenceParticipant]
    let messages: [SequenceMessage]
    let notes: [SequenceNote]
    let blocks: [SequenceBlock]
    let autonumber: Bool
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
}

struct SequenceMessage: Equatable, Sendable {
    let from: String
    let to: String
    let text: String
    let arrowStyle: SequenceArrowStyle
    let activationModifier: ActivationModifier?

    init(from: String, to: String, text: String, arrowStyle: SequenceArrowStyle, activationModifier: ActivationModifier? = nil) {
        self.from = from
        self.to = to
        self.text = text
        self.arrowStyle = arrowStyle
        self.activationModifier = activationModifier
    }
}
