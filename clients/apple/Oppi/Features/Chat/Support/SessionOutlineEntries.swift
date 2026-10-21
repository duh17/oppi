import Foundation

// Session Outline data: timeline entries, their filtering and search, and the
// session tree's filtering, collapse, and connector layout. The UIKit screen
// (`SessionOutlineViewController`) only renders what these return.

enum OutlineEntryKind: String {
    case user
    case assistant
    case thinking
    case tool
    case system
    case compaction
    case custom
    case error
}

/// One timeline row: summary, search text, and classification, built once
/// when the outline opens so filtering and search are cheap.
struct OutlineEntry: Identifiable {
    let id: String
    let kind: OutlineEntryKind
    let tool: String?
    let timestamp: Date?
    let summary: String
    let diffStats: ToolCallFormatting.DiffStats?
    let glyph: String?
    let isAudioClip: Bool
    let isCompaction: Bool
    let isForkable: Bool

    // Filter category flags
    let passesAllFilter: Bool
    let isMessage: Bool
    let isTool: Bool
    let isError: Bool

    /// Unicode scalar positions of the current query's matches in `summary`.
    var matchPositions: [Int] = []
}

enum OutlineFilter: String, CaseIterable {
    case all = "All"
    case messages = "Messages"
    case tools = "Tools"
}

/// A tree switch the outline asks the chat to perform.
struct SessionTreeNavigationRequest: Sendable, Equatable {
    let targetId: String
    let summarize: Bool
    let customInstructions: String?
    let replaceInstructions: Bool?
    let label: String?
}

@MainActor
enum SessionOutlineIndex {
    /// Entries for the chat's loaded timeline items.
    static func entries(
        items: [ChatItem],
        toolArgsStore: ToolArgsStore,
        toolDetails: (String) -> JSONValue?
    ) -> [OutlineEntry] {
        items.map { item in
            let isCompaction = isCompactionEvent(item)
            let inspection = inspection(for: item, toolArgsStore: toolArgsStore, toolDetails: toolDetails)
            let diffStats = inspection?.file?.stats

            let passesAllFilter: Bool
            switch item {
            case .systemEvent, .cacheMiss, .notice:
                passesAllFilter = isCompaction
            default:
                passesAllFilter = true
            }

            let isMessage: Bool
            switch item {
            case .userMessage, .agentMessage, .assistantMessage, .audioClip:
                isMessage = true
            default:
                isMessage = false
            }

            let isTool: Bool
            if case .toolCall = item {
                isTool = true
            } else {
                isTool = false
            }

            let isForkable: Bool
            // Agent messages are user-role turns too; the server lists them as fork points.
            if case .userMessage = item, UUID(uuidString: item.id) == nil {
                isForkable = true
            } else if case .agentMessage = item, UUID(uuidString: item.id) == nil {
                isForkable = true
            } else {
                isForkable = false
            }

            let isAudioClip: Bool
            if case .audioClip = item {
                isAudioClip = true
            } else {
                isAudioClip = false
            }

            return OutlineEntry(
                id: item.id,
                kind: outlineKind(for: item, isCompaction: isCompaction),
                tool: outlineTool(for: item),
                timestamp: item.timestamp,
                summary: outlineSummary(for: item, inspection: inspection),
                diffStats: diffStats,
                glyph: inspection?.glyph,
                isAudioClip: isAudioClip,
                isCompaction: isCompaction,
                isForkable: isForkable,
                passesAllFilter: passesAllFilter,
                isMessage: isMessage,
                isTool: isTool,
                isError: outlineIsError(for: item)
            )
        }
    }

    /// An entry from the server's full-session outline.
    static func entry(from snapshot: SessionOutlineEntrySnapshot) -> OutlineEntry {
        let inspection = snapshot.isTool ? ToolContentDescriptorBuilder.inspect(tool: snapshot.tool ?? "tool",
            isError: snapshot.isError == true, isDone: true,
            context: .init(args: snapshot.args, details: snapshot.details, inputPresentation: snapshot.inputPresentation,
                display: snapshot.display, outputPresentation: snapshot.outputPresentation),
            includeOutput: false, includeFileContent: false) : nil
        return OutlineEntry(
            id: snapshot.id,
            kind: OutlineEntryKind(rawValue: snapshot.kind) ?? .system,
            tool: snapshot.tool,
            timestamp: outlineTimestamp(snapshot.timestamp),
            summary: inspection?.outlineSummary(argsSummary: "", fallback: snapshot.summary,
                displayPath: inspection?.file?.path?.shortenedPath) ?? snapshot.summary,
            diffStats: inspection?.file?.stats,
            glyph: inspection?.glyph,
            isAudioClip: false,
            isCompaction: snapshot.kind == OutlineEntryKind.compaction.rawValue,
            isForkable: snapshot.isForkable == true,
            passesAllFilter: snapshot.passesAllFilter,
            isMessage: snapshot.isMessage,
            isTool: snapshot.isTool,
            isError: snapshot.isError == true
        )
    }

    /// The rows to show for `filter` and `query`. A blank query keeps
    /// timeline order; otherwise best matches come first, equal matches stay
    /// in timeline order, and every row carries the current query's match
    /// positions (empty when only the tool name matched).
    static func filtered(_ entries: [OutlineEntry], filter: OutlineFilter, query: String) -> [OutlineEntry] {
        var filtered = entries.filter { entry in
            switch filter {
            case .all: entry.passesAllFilter
            case .messages: entry.isMessage
            case .tools: entry.isTool
            }
        }

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            for index in filtered.indices {
                filtered[index].matchPositions = []
            }
            return filtered
        }
        // The tool name counts too: shell rows summarize as "$ <command>".
        let matches = FuzzyMatch.rank(query: query, fields: filtered.map { [$0.summary, $0.tool] })
        return matches.map { match in
            var entry = filtered[match.index]
            entry.matchPositions = match.positions
            return entry
        }
    }

    private static func outlineTimestamp(_ timestamp: String) -> Date? {
        guard !timestamp.isEmpty else { return nil }
        return FastISO8601Parser.parse(timestamp, fallback: outlineDateFormatter)
    }

    nonisolated(unsafe) private static let outlineDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func outlineKind(for item: ChatItem, isCompaction: Bool) -> OutlineEntryKind {
        if isCompaction { return .compaction }
        switch item {
        case .userMessage, .agentMessage: return .user
        case .assistantMessage: return .assistant
        case .audioClip: return .assistant
        case .thinking: return .thinking
        case .toolCall: return .tool
        case .systemEvent, .cacheMiss, .notice: return .system
        case .customEvent: return .custom
        case .error: return .error
        }
    }

    private static func outlineTool(for item: ChatItem) -> String? {
        if case .toolCall(_, let tool, _, _, _, _, _) = item {
            return tool
        }
        return nil
    }

    private static func outlineIsError(for item: ChatItem) -> Bool {
        if case .toolCall(_, _, _, _, _, let isError, _) = item {
            return isError
        }
        if case .error = item {
            return true
        }
        return false
    }

    private static func outlineSummary(for item: ChatItem, inspection: ToolInspection?) -> String {
        switch item {
        case .userMessage(_, let text, _, _):
            return String(text.prefix(120))

        case .agentMessage(_, let text, let origin, _):
            let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return String("\(origin.caption): \(clean)".prefix(120))

        case .assistantMessage(_, let text, _):
            let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return String(clean.prefix(120))

        case .audioClip(_, let title, let fileURL, _):
            return "\(title): \(fileURL.lastPathComponent)"

        case .thinking(_, let preview, _, _):
            let clean = preview.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return String(clean.prefix(80))

        case .toolCall(_, _, let argsSummary, _, _, _, _):
            return inspection?.outlineSummary(argsSummary: argsSummary,
                displayPath: inspection?.file?.path?.shortenedPath) ?? argsSummary

        case .systemEvent(_, let msg), .cacheMiss(_, let msg), .notice(_, let msg):
            return msg

        case .customEvent(_, let msg, let presentation):
            return msg.isEmpty ? presentation.title : msg

        case .error(_, let msg):
            return msg
        }
    }

    private static func inspection(
        for item: ChatItem,
        toolArgsStore: ToolArgsStore,
        toolDetails: (String) -> JSONValue?
    ) -> ToolInspection? {
        guard case .toolCall(let id, let tool, let summary, let output, _, let isError, let isDone) = item else { return nil }
        return ToolContentDescriptorBuilder.inspect(tool: tool, argsSummary: summary, outputPreview: output,
            isError: isError, isDone: isDone,
            context: .init(args: toolArgsStore.args(for: id), details: toolDetails(id),
                inputPresentation: toolArgsStore.inputPresentation(for: id), display: toolArgsStore.display(for: id),
                outputPresentation: toolArgsStore.outputPresentation(for: id), outputAvailability: toolArgsStore.outputAvailability(for: id)),
            includeOutput: false, includeFileContent: false)
    }

    private static func isCompactionEvent(_ item: ChatItem) -> Bool {
        guard case .systemEvent(_, let message) = item else { return false }
        let normalized = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return !normalized.isEmpty && normalized.contains("compact")
    }
}

// MARK: - Search highlights

enum OutlineHighlight {
    /// UTF-16 ranges in `text` for unicode scalar `positions` (what
    /// `FuzzyMatch` reports), adjacent positions merged into one range.
    static func ranges(in text: String, scalarPositions positions: [Int]) -> [NSRange] {
        guard !positions.isEmpty else { return [] }
        let matched = Set(positions)
        var ranges: [NSRange] = []
        var utf16Offset = 0
        for (index, scalar) in text.unicodeScalars.enumerated() {
            let length = scalar.utf16.count
            if matched.contains(index) {
                if let last = ranges.last, last.location + last.length == utf16Offset {
                    ranges[ranges.count - 1].length += length
                } else {
                    ranges.append(NSRange(location: utf16Offset, length: length))
                }
            }
            utf16Offset += length
        }
        return ranges
    }
}

// MARK: - Session tree

enum SessionOutlineTree {
    /// Nodes the server's filter keeps that match `query` (all of them for a
    /// blank query).
    static func filteredNodes(_ snapshot: SessionTreeSnapshot?, query: String) -> [SessionTreeNodeSnapshot] {
        guard let snapshot else { return [] }
        let baseNodes = snapshot.nodes.filter(\.matchesFilter)
        guard let prepared = FuzzyMatch.Query(query.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return baseNodes
        }
        return baseNodes.filter { node in
            let candidate = [node.textPreview, node.label, node.id, node.type, node.role]
                .compactMap { $0 }
                .joined(separator: " ")
            return FuzzyMatch.score(prepared, candidate: candidate) != nil
        }
    }

    /// `nodes` (depth-first order) without the descendants of collapsed nodes.
    static func visibleNodes(
        _ nodes: [SessionTreeNodeSnapshot],
        collapsed collapsedIds: Set<String>
    ) -> [SessionTreeNodeSnapshot] {
        guard !collapsedIds.isEmpty else { return nodes }

        var visible: [SessionTreeNodeSnapshot] = []
        var collapsedDepthStack: [Int] = []

        for node in nodes {
            while let last = collapsedDepthStack.last, node.depth <= last {
                _ = collapsedDepthStack.popLast()
            }
            if !collapsedDepthStack.isEmpty {
                continue
            }
            visible.append(node)
            if collapsedIds.contains(node.id) {
                collapsedDepthStack.append(node.depth)
            }
        }
        return visible
    }

    /// Node ids in `nodes` whose next node is deeper: they can collapse.
    static func collapsibleNodeIds(in nodes: [SessionTreeNodeSnapshot]) -> Set<String> {
        var ids: Set<String> = []
        for index in nodes.indices.dropLast() where nodes[index + 1].depth > nodes[index].depth {
            ids.insert(nodes[index].id)
        }
        return ids
    }

    /// User turns with server ids can fork; local placeholders cannot.
    static func isForkable(_ node: SessionTreeNodeSnapshot) -> Bool {
        node.role == "user" && UUID(uuidString: node.id) == nil
    }

    static func shouldRetryLoad(_ error: Error) -> Bool {
        if let wsError = error as? WebSocketError {
            switch wsError {
            case .notConnected, .sendTimeout:
                return true
            default:
                return false
            }
        }

        if let commandError = error as? CommandRequestError {
            switch commandError {
            case .timeout:
                return true
            case .rejected(_, let reason):
                guard let reason else { return false }
                return reason.contains("Session not active")
            }
        }

        let description = error.localizedDescription.lowercased()
        return description.contains("session not active")
            || description.contains("timed out")
    }

    static func displayLabel(for node: SessionTreeNodeSnapshot) -> String? {
        guard let label = node.label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else {
            return nil
        }
        return label
    }

    static func primaryText(for node: SessionTreeNodeSnapshot) -> String {
        let preview = node.textPreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !preview.isEmpty {
            return preview
        }
        return node.type == "message" ? "(no content)" : ""
    }

    static func rolePrefix(for node: SessionTreeNodeSnapshot) -> String {
        if node.type == "message" {
            switch node.role {
            case "user": return "user:"
            case "assistant": return "assistant:"
            case "toolResult": return ""
            case "bashExecution": return "bash:"
            case let role? where !role.isEmpty:
                return "\(role):"
            default:
                return "message:"
            }
        }

        switch node.type {
        case "compaction":
            return "[compaction]"
        case "branch_summary":
            return "[branch summary]"
        case "model_change":
            return "[model]"
        case "thinking_level_change":
            return "[thinking]"
        default:
            let normalized = node.type.replacingOccurrences(of: "_", with: " ")
            return "[\(normalized)]"
        }
    }
}

struct SessionTreeDisplayGutter: Equatable {
    let position: Int
    let show: Bool
}

private struct SessionTreeLayoutFrame {
    let id: String
    let indent: Int
    let justBranched: Bool
    let showConnector: Bool
    let isLast: Bool
    let gutters: [SessionTreeDisplayGutter]
    let isVirtualRootChild: Bool
}

enum SessionTreeDisplayLayout {
    static func displayNodes(
        visibleNodes: [SessionTreeNodeSnapshot],
        allNodes: [SessionTreeNodeSnapshot]
    ) -> [SessionTreeDisplayNode] {
        guard !visibleNodes.isEmpty else { return [] }

        let visibleIds = Set(visibleNodes.map(\.id))

        var allNodesById: [String: SessionTreeNodeSnapshot] = [:]
        allNodesById.reserveCapacity(max(allNodes.count, visibleNodes.count))

        for node in allNodes {
            allNodesById[node.id] = node
        }

        for node in visibleNodes where allNodesById[node.id] == nil {
            allNodesById[node.id] = node
        }

        func nearestVisibleAncestorId(for node: SessionTreeNodeSnapshot) -> String? {
            var currentParentId = node.parentId

            while let parentId = currentParentId {
                if visibleIds.contains(parentId) {
                    return parentId
                }
                currentParentId = allNodesById[parentId]?.parentId
            }

            return nil
        }

        var visibleChildren: [String?: [String]] = [nil: []]
        visibleChildren.reserveCapacity(visibleNodes.count)

        for node in visibleNodes {
            let parentId = nearestVisibleAncestorId(for: node)
            visibleChildren[parentId, default: []].append(node.id)
        }

        let rootIds = visibleChildren[nil] ?? []
        let multipleRoots = rootIds.count > 1

        var displayNodes: [SessionTreeDisplayNode] = []
        displayNodes.reserveCapacity(visibleNodes.count)

        var stack: [SessionTreeLayoutFrame] = []

        for (index, rootId) in rootIds.enumerated().reversed() {
            stack.append(SessionTreeLayoutFrame(
                id: rootId,
                indent: multipleRoots ? 1 : 0,
                justBranched: multipleRoots,
                showConnector: multipleRoots,
                isLast: index == rootIds.count - 1,
                gutters: [],
                isVirtualRootChild: multipleRoots
            ))
        }

        while let current = stack.popLast() {
            guard let node = allNodesById[current.id] else { continue }

            let displayDepth = multipleRoots
                ? max(0, current.indent - 1)
                : max(0, current.indent)

            displayNodes.append(SessionTreeDisplayNode(
                node: node,
                displayDepth: displayDepth,
                showConnector: current.showConnector,
                isLast: current.isLast,
                gutters: current.gutters,
                isVirtualRootChild: current.isVirtualRootChild
            ))

            let children = visibleChildren[current.id] ?? []
            let multipleChildren = children.count > 1

            let childIndent: Int
            if multipleChildren {
                childIndent = current.indent + 1
            } else if current.justBranched, current.indent > 0 {
                childIndent = current.indent + 1
            } else {
                childIndent = current.indent
            }

            let connectorDisplayed = current.showConnector && !current.isVirtualRootChild
            let connectorPosition = max(0, displayDepth - 1)
            let childGutters = connectorDisplayed
                ? current.gutters + [SessionTreeDisplayGutter(
                    position: connectorPosition,
                    show: !current.isLast
                )]
                : current.gutters

            for (index, childId) in children.enumerated().reversed() {
                stack.append(SessionTreeLayoutFrame(
                    id: childId,
                    indent: childIndent,
                    justBranched: multipleChildren,
                    showConnector: multipleChildren,
                    isLast: index == children.count - 1,
                    gutters: childGutters,
                    isVirtualRootChild: false
                ))
            }
        }

        return displayNodes
    }
}

struct SessionTreeDisplayNode: Identifiable, Equatable {
    let node: SessionTreeNodeSnapshot
    let displayDepth: Int
    let showConnector: Bool
    let isLast: Bool
    let gutters: [SessionTreeDisplayGutter]
    let isVirtualRootChild: Bool

    var id: String { node.id }

    /// Whether the row draws its own branch elbow (a virtual root's children
    /// do not).
    var connectorDisplayed: Bool {
        showConnector && !isVirtualRootChild
    }
}
