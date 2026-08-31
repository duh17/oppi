import Foundation

struct MacSessionPaneID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init() {
        rawValue = UUID().uuidString
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct MacSessionPaneSplitID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init() {
        rawValue = UUID().uuidString
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The server route needed to restore a pane without retaining a full session.
enum MacSessionPaneRoute: Hashable, Sendable {
    case workspace(workspaceID: String, sessionID: String)
    case control(sessionID: String)

    var sessionID: String {
        switch self {
        case .workspace(_, let sessionID), .control(let sessionID): sessionID
        }
    }

    var routeScope: SessionRouteScope {
        switch self {
        case .workspace(let workspaceID, _): .workspace(workspaceID)
        case .control: .control
        }
    }
}

extension MacSessionPaneRoute: Codable {
    private enum Kind: String, Codable {
        case workspace
        case control
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case workspaceID
        case sessionID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let sessionID = try container.decode(String.self, forKey: .sessionID)
        switch kind {
        case .workspace:
            self = .workspace(
                workspaceID: try container.decode(String.self, forKey: .workspaceID),
                sessionID: sessionID
            )
        case .control:
            self = .control(sessionID: sessionID)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .workspace(let workspaceID, let sessionID):
            try container.encode(Kind.workspace, forKey: .kind)
            try container.encode(workspaceID, forKey: .workspaceID)
            try container.encode(sessionID, forKey: .sessionID)
        case .control(let sessionID):
            try container.encode(Kind.control, forKey: .kind)
            try container.encode(sessionID, forKey: .sessionID)
        }
    }
}

enum MacSessionPaneSplitAxis: String, Codable, Hashable, Sendable {
    /// Children are arranged side by side.
    case horizontal

    /// Children are arranged one above the other.
    case vertical
}

enum MacSessionPaneFocusDirection: String, Sendable {
    case left
    case right
    case up
    case down
}

struct MacSessionPane: Codable, Hashable, Sendable {
    let id: MacSessionPaneID
    /// `nil` is an empty Quick Session pane.
    let route: MacSessionPaneRoute?
}

struct MacSessionPaneSplit: Codable, Hashable, Sendable {
    let id: MacSessionPaneSplitID
    let axis: MacSessionPaneSplitAxis
    let fraction: Double
    let first: MacSessionPaneNode
    let second: MacSessionPaneNode
}

indirect enum MacSessionPaneNode: Hashable, Sendable {
    case pane(MacSessionPane)
    case split(MacSessionPaneSplit)
}

extension MacSessionPaneNode: Codable {
    private enum Kind: String, Codable {
        case pane
        case split
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case pane
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .pane:
            self = .pane(try container.decode(MacSessionPane.self, forKey: .pane))
        case .split:
            self = .split(try container.decode(MacSessionPaneSplit.self, forKey: .split))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let pane):
            try container.encode(Kind.pane, forKey: .kind)
            try container.encode(pane, forKey: .pane)
        case .split(let split):
            try container.encode(Kind.split, forKey: .kind)
            try container.encode(split, forKey: .split)
        }
    }
}

enum MacSessionPaneLayoutError: Error, Equatable, Sendable {
    case paneNotFound
    case splitNotFound
    case paneLimitReached
    case duplicatePaneID
    case duplicateSplitID
    case cannotCloseOnlyPane
    case invalidSplitFraction
    case focusedPaneNotFound
}

/// Restorable terminal-style tiling state for one Mac session window.
///
/// Replacing a closed split with its surviving child keeps the entire sibling
/// subtree intact, including its pane routes, identifiers, axes, and fractions.
struct MacSessionPaneLayout: Codable, Hashable, Sendable {
    static let maximumPaneCount = 4

    private(set) var root: MacSessionPaneNode
    private(set) var focusedPaneID: MacSessionPaneID

    init(initialRoute: MacSessionPaneRoute?, paneID: MacSessionPaneID = MacSessionPaneID()) {
        root = .pane(MacSessionPane(id: paneID, route: initialRoute))
        focusedPaneID = paneID
    }

    init(root: MacSessionPaneNode, focusedPaneID: MacSessionPaneID) throws {
        try Self.validate(root: root, focusedPaneID: focusedPaneID)
        self.root = root
        self.focusedPaneID = focusedPaneID
    }

    var panes: [MacSessionPane] {
        root.panes
    }

    var paneCount: Int {
        panes.count
    }

    var focusedPane: MacSessionPane? {
        pane(id: focusedPaneID)
    }

    func pane(id: MacSessionPaneID) -> MacSessionPane? {
        root.pane(id: id)
    }

    func split(id: MacSessionPaneSplitID) -> MacSessionPaneSplit? {
        root.split(id: id)
    }

    func node(containingSplit id: MacSessionPaneSplitID) -> MacSessionPaneNode? {
        root.node(containingSplit: id)
    }

    mutating func focus(_ paneID: MacSessionPaneID) throws {
        guard root.contains(paneID: paneID) else {
            throw MacSessionPaneLayoutError.paneNotFound
        }
        focusedPaneID = paneID
    }

    mutating func setRoute(_ route: MacSessionPaneRoute?, for paneID: MacSessionPaneID) throws {
        guard let nextRoot = root.replacingPane(id: paneID, route: route) else {
            throw MacSessionPaneLayoutError.paneNotFound
        }
        root = nextRoot
    }

    mutating func setFraction(_ fraction: Double, for splitID: MacSessionPaneSplitID) throws {
        guard Self.isValid(fraction: fraction) else {
            throw MacSessionPaneLayoutError.invalidSplitFraction
        }
        guard let nextRoot = root.replacingSplit(id: splitID, fraction: fraction) else {
            throw MacSessionPaneLayoutError.splitNotFound
        }
        root = nextRoot
    }

    mutating func split(
        paneID: MacSessionPaneID,
        axis: MacSessionPaneSplitAxis,
        newRoute: MacSessionPaneRoute? = nil,
        newPaneID: MacSessionPaneID = MacSessionPaneID(),
        splitID: MacSessionPaneSplitID = MacSessionPaneSplitID(),
        fraction: Double = 0.5
    ) throws {
        guard root.contains(paneID: paneID) else {
            throw MacSessionPaneLayoutError.paneNotFound
        }
        guard paneCount < Self.maximumPaneCount else {
            throw MacSessionPaneLayoutError.paneLimitReached
        }
        guard !root.contains(paneID: newPaneID) else {
            throw MacSessionPaneLayoutError.duplicatePaneID
        }
        guard root.split(id: splitID) == nil else {
            throw MacSessionPaneLayoutError.duplicateSplitID
        }
        guard Self.isValid(fraction: fraction) else {
            throw MacSessionPaneLayoutError.invalidSplitFraction
        }
        guard let nextRoot = root.splittingPane(
            id: paneID,
            with: MacSessionPane(id: newPaneID, route: newRoute),
            splitID: splitID,
            axis: axis,
            fraction: fraction
        ) else {
            throw MacSessionPaneLayoutError.paneNotFound
        }

        root = nextRoot
        focusedPaneID = newPaneID
    }

    mutating func close(paneID: MacSessionPaneID) throws {
        let orderedPaneIDs = panes.map(\.id)
        guard let closingIndex = orderedPaneIDs.firstIndex(of: paneID) else {
            throw MacSessionPaneLayoutError.paneNotFound
        }
        guard orderedPaneIDs.count > 1 else {
            throw MacSessionPaneLayoutError.cannotCloseOnlyPane
        }
        guard let nextRoot = root.removingPane(id: paneID) else {
            throw MacSessionPaneLayoutError.cannotCloseOnlyPane
        }

        if focusedPaneID == paneID {
            let remainingPaneIDs = orderedPaneIDs.filter { $0 != paneID }
            focusedPaneID = remainingPaneIDs[min(closingIndex, remainingPaneIDs.count - 1)]
        }
        root = nextRoot
    }

    func adjacentPaneID(direction: MacSessionPaneFocusDirection) -> MacSessionPaneID? {
        let frames = root.leafFrames(
            in: MacSessionPaneUnitFrame(x: 0, y: 0, width: 1, height: 1)
        )
        guard let focused = frames.first(where: { $0.id == focusedPaneID }) else {
            return nil
        }
        let candidates = frames.filter { $0.id != focused.id }
        let overlapping = candidates.filter { candidate in
            switch direction {
            case .left:
                candidate.frame.maxX <= focused.frame.minX + 0.001
                    && candidate.frame.overlapY(focused.frame) > 0
            case .right:
                candidate.frame.minX >= focused.frame.maxX - 0.001
                    && candidate.frame.overlapY(focused.frame) > 0
            case .up:
                candidate.frame.maxY <= focused.frame.minY + 0.001
                    && candidate.frame.overlapX(focused.frame) > 0
            case .down:
                candidate.frame.minY >= focused.frame.maxY - 0.001
                    && candidate.frame.overlapX(focused.frame) > 0
            }
        }
        let pool = overlapping.isEmpty
            ? candidates.filter { candidate in
                switch direction {
                case .left: candidate.frame.midX < focused.frame.midX
                case .right: candidate.frame.midX > focused.frame.midX
                case .up: candidate.frame.midY < focused.frame.midY
                case .down: candidate.frame.midY > focused.frame.midY
                }
            }
            : overlapping
        return pool.min { lhs, rhs in
            lhs.frame.distance(to: focused.frame) < rhs.frame.distance(to: focused.frame)
        }?.id
    }

    private static func isValid(fraction: Double) -> Bool {
        fraction.isFinite && fraction > 0 && fraction < 1
    }

    private static func validate(
        root: MacSessionPaneNode,
        focusedPaneID: MacSessionPaneID
    ) throws {
        let panes = root.panes
        guard panes.count <= maximumPaneCount else {
            throw MacSessionPaneLayoutError.paneLimitReached
        }
        guard Set(panes.map(\.id)).count == panes.count else {
            throw MacSessionPaneLayoutError.duplicatePaneID
        }
        guard panes.contains(where: { $0.id == focusedPaneID }) else {
            throw MacSessionPaneLayoutError.focusedPaneNotFound
        }

        let splits = root.splits
        guard Set(splits.map(\.id)).count == splits.count else {
            throw MacSessionPaneLayoutError.duplicateSplitID
        }
        guard splits.allSatisfy({ isValid(fraction: $0.fraction) }) else {
            throw MacSessionPaneLayoutError.invalidSplitFraction
        }
    }

    private enum CodingKeys: String, CodingKey {
        case root
        case focusedPaneID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let root = try container.decode(MacSessionPaneNode.self, forKey: .root)
        let focusedPaneID = try container.decode(MacSessionPaneID.self, forKey: .focusedPaneID)
        do {
            try self.init(root: root, focusedPaneID: focusedPaneID)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .root,
                in: container,
                debugDescription: "Invalid restored session pane layout: \(error)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(root, forKey: .root)
        try container.encode(focusedPaneID, forKey: .focusedPaneID)
    }
}

private extension MacSessionPaneNode {
    var panes: [MacSessionPane] {
        switch self {
        case .pane(let pane):
            [pane]
        case .split(let split):
            split.first.panes + split.second.panes
        }
    }

    var splits: [MacSessionPaneSplit] {
        switch self {
        case .pane:
            []
        case .split(let split):
            [split] + split.first.splits + split.second.splits
        }
    }

    func contains(paneID: MacSessionPaneID) -> Bool {
        pane(id: paneID) != nil
    }

    func pane(id: MacSessionPaneID) -> MacSessionPane? {
        switch self {
        case .pane(let pane):
            pane.id == id ? pane : nil
        case .split(let split):
            split.first.pane(id: id) ?? split.second.pane(id: id)
        }
    }

    func split(id: MacSessionPaneSplitID) -> MacSessionPaneSplit? {
        switch self {
        case .pane:
            return nil
        case .split(let split):
            if split.id == id {
                return split
            } else {
                return split.first.split(id: id) ?? split.second.split(id: id)
            }
        }
    }

    func node(containingSplit id: MacSessionPaneSplitID) -> MacSessionPaneNode? {
        switch self {
        case .pane:
            return nil
        case .split(let split):
            if split.id == id {
                return self
            } else {
                return split.first.node(containingSplit: id) ?? split.second.node(containingSplit: id)
            }
        }
    }

    func leafFrames(
        in frame: MacSessionPaneUnitFrame
    ) -> [(id: MacSessionPaneID, frame: MacSessionPaneUnitFrame)] {
        switch self {
        case .pane(let pane):
            return [(pane.id, frame)]
        case .split(let split):
            let (firstFrame, secondFrame) = split.childFrames(in: frame)
            return split.first.leafFrames(in: firstFrame) + split.second.leafFrames(in: secondFrame)
        }
    }

    func replacingPane(id: MacSessionPaneID, route: MacSessionPaneRoute?) -> MacSessionPaneNode? {
        switch self {
        case .pane(let pane):
            guard pane.id == id else { return nil }
            return .pane(MacSessionPane(id: id, route: route))
        case .split(let split):
            if let first = split.first.replacingPane(id: id, route: route) {
                return .split(split.replacing(first: first))
            }
            if let second = split.second.replacingPane(id: id, route: route) {
                return .split(split.replacing(second: second))
            }
            return nil
        }
    }

    func replacingSplit(id: MacSessionPaneSplitID, fraction: Double) -> MacSessionPaneNode? {
        switch self {
        case .pane:
            return nil
        case .split(let split):
            if split.id == id {
                return .split(split.replacing(fraction: fraction))
            }
            if let first = split.first.replacingSplit(id: id, fraction: fraction) {
                return .split(split.replacing(first: first))
            }
            if let second = split.second.replacingSplit(id: id, fraction: fraction) {
                return .split(split.replacing(second: second))
            }
            return nil
        }
    }

    func splittingPane(
        id: MacSessionPaneID,
        with newPane: MacSessionPane,
        splitID: MacSessionPaneSplitID,
        axis: MacSessionPaneSplitAxis,
        fraction: Double
    ) -> MacSessionPaneNode? {
        switch self {
        case .pane(let pane):
            guard pane.id == id else { return nil }
            return .split(MacSessionPaneSplit(
                id: splitID,
                axis: axis,
                fraction: fraction,
                first: .pane(pane),
                second: .pane(newPane)
            ))
        case .split(let split):
            if let first = split.first.splittingPane(
                id: id,
                with: newPane,
                splitID: splitID,
                axis: axis,
                fraction: fraction
            ) {
                return .split(split.replacing(first: first))
            }
            if let second = split.second.splittingPane(
                id: id,
                with: newPane,
                splitID: splitID,
                axis: axis,
                fraction: fraction
            ) {
                return .split(split.replacing(second: second))
            }
            return nil
        }
    }

    func removingPane(id: MacSessionPaneID) -> MacSessionPaneNode? {
        switch self {
        case .pane(let pane):
            return pane.id == id ? nil : self
        case .split(let split):
            if split.first.contains(paneID: id) {
                guard let first = split.first.removingPane(id: id) else {
                    return split.second
                }
                return .split(split.replacing(first: first))
            }
            if split.second.contains(paneID: id) {
                guard let second = split.second.removingPane(id: id) else {
                    return split.first
                }
                return .split(split.replacing(second: second))
            }
            return self
        }
    }
}

private extension MacSessionPaneSplit {
    func replacing(
        fraction: Double? = nil,
        first: MacSessionPaneNode? = nil,
        second: MacSessionPaneNode? = nil
    ) -> MacSessionPaneSplit {
        MacSessionPaneSplit(
            id: id,
            axis: axis,
            fraction: fraction ?? self.fraction,
            first: first ?? self.first,
            second: second ?? self.second
        )
    }

    func childFrames(
        in frame: MacSessionPaneUnitFrame
    ) -> (MacSessionPaneUnitFrame, MacSessionPaneUnitFrame) {
        switch axis {
        case .horizontal:
            let firstWidth = frame.width * fraction
            return (
                MacSessionPaneUnitFrame(x: frame.x, y: frame.y, width: firstWidth, height: frame.height),
                MacSessionPaneUnitFrame(
                    x: frame.x + firstWidth,
                    y: frame.y,
                    width: frame.width - firstWidth,
                    height: frame.height
                )
            )
        case .vertical:
            let firstHeight = frame.height * fraction
            return (
                MacSessionPaneUnitFrame(x: frame.x, y: frame.y, width: frame.width, height: firstHeight),
                MacSessionPaneUnitFrame(
                    x: frame.x,
                    y: frame.y + firstHeight,
                    width: frame.width,
                    height: frame.height - firstHeight
                )
            )
        }
    }
}

struct MacSessionPaneUnitFrame: Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var minX: Double { x }
    var maxX: Double { x + width }
    var minY: Double { y }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }

    func overlapX(_ other: Self) -> Double {
        max(0, min(maxX, other.maxX) - max(minX, other.minX))
    }

    func overlapY(_ other: Self) -> Double {
        max(0, min(maxY, other.maxY) - max(minY, other.minY))
    }

    func distance(to other: Self) -> Double {
        let dx = midX - other.midX
        let dy = midY - other.midY
        return (dx * dx + dy * dy).squareRoot()
    }
}
