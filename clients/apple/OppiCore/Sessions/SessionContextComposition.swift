import Foundation

enum SessionContextCompositionKind: String, Sendable, Equatable, CaseIterable {
    case systemPrompt
    case agentsFiles
    case skills
    case messages
    case tools
    case mcpTools
    case compactionReserve
}

struct SessionContextCompositionSegment: Identifiable, Equatable, Sendable {
    let kind: SessionContextCompositionKind
    let label: String
    let detail: String
    let tokens: Int

    var id: String { kind.rawValue }
}

/// Splits the context window the way a request fills it, top to bottom: the system
/// prompt (with its AGENTS files and Skills list), the messages, the tool
/// declarations, and the space auto-compaction keeps free.
///
/// The provider-reported total anchors the split. The server estimates the prompt and
/// tool sizes from their text; messages are what remains, so the parts never add up to
/// more than the total.
enum SessionContextCompositionProjection {
    static func segments(
        totalContextTokens: Int,
        contextWindow: Int?,
        composition: SessionContextCompositionSnapshot
    ) -> [SessionContextCompositionSegment] {
        guard totalContextTokens > 0 else { return [] }

        let systemTotal = min(max(composition.piSystemPromptTokens, 0), totalContextTokens)
        let agents = min(max(composition.agentsTokens, 0), systemTotal)
        let skills = min(max(composition.skillsListingTokens, 0), systemTotal - agents)
        let basePrompt = systemTotal - agents - skills

        let declared = composition.tools.filter(\.inContext)
        let declaredMcp = declared.filter { $0.sourceKind == .mcp }
        let declaredOther = declared.filter { $0.sourceKind != .mcp }
        let afterPrompt = totalContextTokens - systemTotal
        let tools = min(declaredOther.reduce(0) { $0 + max($1.tokens, 0) }, afterPrompt)
        let mcpTools = min(declaredMcp.reduce(0) { $0 + max($1.tokens, 0) }, afterPrompt - tools)
        let messages = afterPrompt - tools - mcpTools

        let reserve: Int
        if let reserveTokens = composition.compactionReserveTokens, let contextWindow, contextWindow > 0 {
            reserve = min(max(reserveTokens, 0), max(contextWindow - totalContextTokens, 0))
        } else {
            reserve = 0
        }

        let candidates: [SessionContextCompositionSegment] = [
            SessionContextCompositionSegment(
                kind: .systemPrompt,
                label: "System prompt",
                detail: "Pi and Oppi instructions, tool guidelines, and the MCP server list.",
                tokens: basePrompt
            ),
            SessionContextCompositionSegment(
                kind: .agentsFiles,
                label: "AGENTS files (\(composition.agentsFiles.count))",
                detail: "Instructions from AGENTS.md files.",
                tokens: agents
            ),
            SessionContextCompositionSegment(
                kind: .skills,
                label: "Skills",
                detail: "Skill names and descriptions the model can load.",
                tokens: skills
            ),
            SessionContextCompositionSegment(
                kind: .messages,
                label: "Messages",
                detail: "Conversation, tool calls and results, and summaries.",
                tokens: messages
            ),
            SessionContextCompositionSegment(
                kind: .tools,
                label: "Tools (\(declaredOther.count))",
                detail: "Tool declarations sent with every request.",
                tokens: tools
            ),
            SessionContextCompositionSegment(
                kind: .mcpTools,
                label: "MCP tools (\(declaredMcp.count))",
                detail: "MCP tool declarations sent with every request.",
                tokens: mcpTools
            ),
            SessionContextCompositionSegment(
                kind: .compactionReserve,
                label: "Compaction reserve",
                detail: "Kept free. Auto-compaction runs when messages reach it.",
                tokens: reserve
            ),
        ]
        return candidates.filter { $0.tokens > 0 }
    }
}

/// The tools of one source: Pi's built-ins, one extension, or one MCP server.
struct ContextToolGroup: Identifiable, Equatable, Sendable {
    let kind: ContextToolSnapshot.SourceKind
    let name: String
    let path: String?
    /// In-context tools first, then on-demand ones; each by size, largest first.
    let tools: [ContextToolSnapshot]

    var id: String { "\(kind.rawValue)\u{0}\(path ?? name)" }
    var inContextCount: Int { tools.count(where: \.inContext) }
    var onDemandCount: Int { tools.count(where: { !$0.inContext }) }
    var inContextTokens: Int { tools.reduce(0) { $0 + ($1.inContext ? $1.tokens : 0) } }
    var onDemandTokens: Int { tools.reduce(0) { $0 + ($1.inContext ? 0 : $1.tokens) } }

    /// Groups by source: built-ins first, then extensions, then MCP servers, each by name.
    static func groups(_ tools: [ContextToolSnapshot]) -> [ContextToolGroup] {
        let bySource = Dictionary(grouping: tools) { tool in
            SourceKey(kind: tool.sourceKind, name: tool.sourceName, path: tool.sourcePath)
        }
        return bySource.map { key, tools in
            ContextToolGroup(
                kind: key.kind,
                name: key.name,
                path: key.path,
                tools: tools.sorted { lhs, rhs in
                    if lhs.inContext != rhs.inContext { return lhs.inContext }
                    if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
                    return lhs.name < rhs.name
                }
            )
        }
        .sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return order(lhs.kind) < order(rhs.kind) }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private struct SourceKey: Hashable {
        let kind: ContextToolSnapshot.SourceKind
        let name: String
        let path: String?
    }

    private static func order(_ kind: ContextToolSnapshot.SourceKind) -> Int {
        switch kind {
        case .builtIn: 0
        case .piExtension: 1
        case .mcp: 2
        }
    }
}
