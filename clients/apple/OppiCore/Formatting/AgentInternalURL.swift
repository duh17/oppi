/// The internal URLs an agent's `read` tool resolves (`server/src/internal-urls.ts`). An agent
/// writes them in chat, so Markdown keeps them as links, and no other app opens them, so a tap
/// stays in Oppi (`AppOpenRequest.agentInternalURL`).
enum AgentInternalURL {
    static let schemes: Set<String> = ["history", "agent", "proc", "mcp", "ssh"]
}
