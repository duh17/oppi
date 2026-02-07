import Foundation

/// Transport-agnostic domain events from the agent.
///
/// Produced by translating `ServerMessage` into agent-level semantics.
/// Consumed by the `DeltaCoalescer` → `TimelineReducer` → `SurfaceCoordinator` pipeline.
enum AgentEvent: Sendable {
    case agentStart(sessionId: String)
    case agentEnd(sessionId: String)

    case textDelta(sessionId: String, delta: String)
    case thinkingDelta(sessionId: String, delta: String)

    /// Tool events carry a client-generated `toolEventId` (v1: sequential assumption).
    case toolStart(sessionId: String, toolEventId: String, tool: String, args: [String: JSONValue])
    case toolOutput(sessionId: String, toolEventId: String, output: String, isError: Bool)
    case toolEnd(sessionId: String, toolEventId: String)

    case permissionRequest(PermissionRequest)
    case permissionExpired(id: String)
    case sessionEnded(sessionId: String, reason: String)
    case error(sessionId: String, message: String)
}
