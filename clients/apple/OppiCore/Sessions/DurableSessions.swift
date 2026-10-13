import Foundation

/// Rules for the Durable Sessions experiment: with the device opted in and the
/// server offering durable sessions, new sessions start durable.
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

        /// The pill switches this launch between Durable and Classic.
        var canToggle: Bool { showsPill && classicReason == nil }
    }

    /// The server refuses a saved Agent launch with the durable engine
    /// (`routes/agents.ts`), so such a launch runs Classic instead of failing.
    /// Incognito sessions are not decided here: they never come from the composer.
    static let savedAgentClassicReason = "Saved Agents"

    static func launchDecision(
        experimentEnabled: Bool,
        serverOffersDurable: Bool,
        savedAgentSelected: Bool,
        userChoseClassic: Bool
    ) -> LaunchDecision {
        guard isAvailable(experimentEnabled: experimentEnabled, serverOffersDurable: serverOffersDurable) else {
            return LaunchDecision(engine: .classic, showsPill: false, classicReason: nil)
        }
        if savedAgentSelected {
            return LaunchDecision(engine: .classic, showsPill: true, classicReason: savedAgentClassicReason)
        }
        return LaunchDecision(engine: userChoseClassic ? .classic : .durable, showsPill: true, classicReason: nil)
    }
}
