import Foundation

/// Rules for the Durable Sessions experiment: with the device opted in and the
/// server offering durable sessions, the composer can start a session durable.
/// New sessions start Classic unless the device also chose Durable by default.
enum DurableSessions {
    /// Durable applies only when this device opted in and the server advertises
    /// `capabilities.durableSessions`. Gates the Oppi Control entry, the composer's
    /// engine pill, and the durable default.
    static func isAvailable(experimentEnabled: Bool, serverOffersDurable: Bool) -> Bool {
        experimentEnabled && serverOffersDurable
    }

    /// Engine a new session's composer launches with, and what the composer shows for it.
    struct LaunchDecision: Equatable, Sendable {
        let engine: SessionEngine
        /// Durable is available on this server, so the composer shows the engine pill.
        let showsPill: Bool
        /// Why this launch cannot be durable although durable is available.
        let classicReason: String?
        /// The launch must not be sent yet: it may belong to a saved Agent that has not
        /// been resolved, and a plain durable session would lose that Agent's definition.
        let blocksLaunch: Bool

        /// The pill switches this launch between Classic and Durable.
        var canToggle: Bool { showsPill && classicReason == nil && !blocksLaunch }
    }

    /// The server refuses a saved Agent launch with the durable engine
    /// (`routes/agents.ts`), so such a launch runs Classic instead of failing.
    /// Incognito sessions are not decided here: they never come from the composer.
    static let savedAgentClassicReason = "Saved Agents"

    /// Whether the saved Agent a launch should use (a launch context's, or the remembered
    /// one) has been applied. Until it is, the composer cannot tell a plain launch from an
    /// Agent launch.
    enum AgentResolution: Equatable, Sendable {
        case resolved
        /// The Agent list is loading, or reloading after a server change.
        case pending
        /// The Agent list failed to load. Stays blocked until the user clears the Agent.
        case failed

        var blockReason: String? {
            switch self {
            case .resolved: nil
            case .pending: "Loading Agent"
            case .failed: "Agent not loaded"
            }
        }
    }

    /// `durableByDefault` picks the engine a launch starts with; `chosenEngine` is the
    /// user's pill choice for this one launch and wins over the default.
    static func launchDecision(
        experimentEnabled: Bool,
        serverOffersDurable: Bool,
        durableByDefault: Bool,
        savedAgentSelected: Bool,
        chosenEngine: SessionEngine?,
        agentResolution: AgentResolution = .resolved
    ) -> LaunchDecision {
        guard isAvailable(experimentEnabled: experimentEnabled, serverOffersDurable: serverOffersDurable) else {
            return LaunchDecision(engine: .classic, showsPill: false, classicReason: nil, blocksLaunch: false)
        }
        if let reason = agentResolution.blockReason {
            return LaunchDecision(engine: .classic, showsPill: true, classicReason: reason, blocksLaunch: true)
        }
        if savedAgentSelected {
            return LaunchDecision(
                engine: .classic, showsPill: true, classicReason: savedAgentClassicReason, blocksLaunch: false
            )
        }
        return LaunchDecision(
            engine: chosenEngine ?? (durableByDefault ? .durable : .classic),
            showsPill: true,
            classicReason: nil,
            blocksLaunch: false
        )
    }
}
