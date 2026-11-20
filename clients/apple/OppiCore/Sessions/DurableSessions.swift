import Foundation

/// Rules for Durable Sessions: with the server offering durable sessions (its Durable
/// Sessions setting, advertised as `capabilities.durableSessions`), the composer can start
/// a session durable. New sessions start Classic unless this device chose Durable by default.
enum DurableSessions {

    /// Engine a new session's composer launches with, and what the composer shows for it.
    struct LaunchDecision: Equatable, Sendable {
        let engine: SessionEngine
        /// Durable is available on this server, so the composer shows the engine pill.
        let showsPill: Bool
        /// Why this launch's engine is fixed although durable is available: a saved
        /// Agent still loading keeps it Classic, a durable-only Agent keeps it Durable.
        let fixedReason: String?
        /// The launch must not be sent yet: it may belong to a saved Agent that has not
        /// been resolved, and a plain durable session would lose that Agent's definition.
        let blocksLaunch: Bool

        /// The pill switches this launch between Classic and Durable.
        var canToggle: Bool { showsPill && fixedReason == nil && !blocksLaunch }
    }

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
    /// user's pill choice for this one launch and wins over the default. A selected Agent's
    /// `requiredEngine` (launch constraint) wins over both. Without durable on the server
    /// the launch goes out Classic, and the server refuses a durable-only Agent with its reason.
    static func launchDecision(
        serverOffersDurable: Bool,
        durableByDefault: Bool,
        incognito: Bool = false,
        chosenEngine: SessionEngine?,
        agentResolution: AgentResolution = .resolved,
        agentRequiredEngine: SessionEngine? = nil
    ) -> LaunchDecision {
        guard serverOffersDurable else {
            return LaunchDecision(engine: .classic, showsPill: false, fixedReason: nil, blocksLaunch: false)
        }
        if let reason = agentResolution.blockReason {
            return LaunchDecision(engine: .classic, showsPill: true, fixedReason: reason, blocksLaunch: true)
        }
        if let required = agentRequiredEngine {
            return LaunchDecision(engine: required, showsPill: true, fixedReason: "Required by Agent", blocksLaunch: false)
        }
        // The server refuses an incognito session on the durable engine
        // (`durableUnsupportedFeature`). The Incognito pill already says what
        // this launch is, so the engine pill steps aside instead of repeating it.
        if incognito {
            return LaunchDecision(engine: .classic, showsPill: false, fixedReason: nil, blocksLaunch: false)
        }
        return LaunchDecision(
            engine: chosenEngine ?? (durableByDefault ? .durable : .classic),
            showsPill: true,
            fixedReason: nil,
            blocksLaunch: false
        )
    }
}
