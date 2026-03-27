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

    static let empty = Self(title: nil, dateFormat: "YYYY-MM-DD", sections: [], axisFormat: nil, excludes: [])
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

    static let empty = Self(participants: [], messages: [])
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
}

struct SequenceMessage: Equatable, Sendable {
    let from: String
    let to: String
    let text: String
    let arrowStyle: SequenceArrowStyle
}
