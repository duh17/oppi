import Foundation

enum SessionContextCompositionKind: String, Sendable, Equatable {
    case piBasePrompt
    case agentsFiles
    case skillsIndex
    case messagesAndRuntime
}

struct SessionContextCompositionSegment: Identifiable, Equatable, Sendable {
    let kind: SessionContextCompositionKind
    let label: String
    let detail: String
    let tokens: Int

    var id: String { kind.rawValue }
}

/// Split total context into Pi prompt, AGENTS files, skills index, and messages.
enum SessionContextCompositionProjection {
    static func segments(
        totalContextTokens: Int,
        composition: SessionContextCompositionSnapshot
    ) -> [SessionContextCompositionSegment] {
        guard totalContextTokens > 0 else { return [] }

        let systemTotal = min(max(composition.piSystemPromptTokens, 0), totalContextTokens)
        let agents = min(max(composition.agentsTokens, 0), systemTotal)
        let skills = min(max(composition.skillsListingTokens, 0), systemTotal)
        let basePrompt = max(systemTotal - agents - skills, 0)
        let messages = max(totalContextTokens - systemTotal, 0)

        var segments: [SessionContextCompositionSegment] = []

        if basePrompt > 0 {
            segments.append(SessionContextCompositionSegment(
                kind: .piBasePrompt,
                label: "Pi Base Prompt",
                detail: "Pi system prompt, tools, and baseline instructions.",
                tokens: basePrompt
            ))
        }

        if agents > 0 {
            let fileCount = composition.agentsFiles.count
            segments.append(SessionContextCompositionSegment(
                kind: .agentsFiles,
                label: "AGENTS files (\(fileCount))",
                detail: "Workspace instructions from AGENTS.md files.",
                tokens: agents
            ))
        }

        if skills > 0 {
            segments.append(SessionContextCompositionSegment(
                kind: .skillsIndex,
                label: "Skills Index",
                detail: "Available skill names and descriptions included in context.",
                tokens: skills
            ))
        }

        if messages > 0 {
            segments.append(SessionContextCompositionSegment(
                kind: .messagesAndRuntime,
                label: "Messages and Runtime",
                detail: "Conversation history, tool calls, and results.",
                tokens: messages
            ))
        }

        return segments
    }
}
