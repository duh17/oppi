import Foundation
@testable import Oppi

let paneFixtureServer = "sha256:9f86d081884c7d65"

/// Builders for pane trees in tests: leaves are session leaves unless a
/// route is given, all on one server.
protocol PaneFixtureBuilding {}

extension PaneFixtureBuilding {
    /// The pairing of a chat's Git or Files panel, as the chat opens it.
    @MainActor static var gitPairing: String { PanePairing(.list, beside: .chat).key }

    func id(_ raw: String) -> PaneID {
        guard let id = PaneID(raw) else { preconditionFailure("bad test pane id \(raw)") }
        return id
    }

    func ids(_ raws: String...) -> [PaneID] { raws.map(id) }

    func leaf(_ raw: String, _ route: PaneRoute? = nil) -> PaneLeaf {
        PaneLeaf(
            id: id(raw), name: nil,
            stack: [PaneStackEntry(serverId: paneFixtureServer, route: route ?? .session(raw))],
            attachedTo: nil, origin: .split
        )
    }

    /// One row of leaves with these weights.
    func row(_ parts: (String, Double)..., focus: String? = nil, recency: [String]? = nil) -> PaneLayout {
        row(parts.map { (leaf($0.0), $0.1) }, focus: focus, recency: recency)
    }

    func row(_ parts: [(PaneLeaf, Double)], focus: String? = nil, recency: [String]? = nil) -> PaneLayout {
        PaneLayout(
            root: .split(axis: .row, children: parts.map { .leaf($0.0) }, weights: parts.map(\.1)),
            focus: focus.map(id) ?? parts[0].0.id,
            recency: recency.map { $0.map(id) } ?? parts.map(\.0.id)
        )
    }

    /// `row[a 0.5, column[b 0.5, c 0.5] 0.5]`, weights to three places.
    func shape(_ node: PaneNode) -> String {
        switch node {
        case .leaf(let leaf): return leaf.id.raw
        case .split(let axis, let children, let weights):
            let parts = zip(children, weights).map { child, weight in "\(shape(child)) \((weight * 1000).rounded() / 1000)" }
            return "\(axis)[\(parts.joined(separator: ", "))]"
        }
    }
}
