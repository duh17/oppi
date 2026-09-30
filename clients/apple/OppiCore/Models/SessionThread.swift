import Foundation

/// Cross-session primitive the server recorded when one session drove another.
/// Launch edges are not interactions: they come from `Session.parentSessionId`.
enum SessionInteractionKind: String, Sendable, Equatable, CaseIterable {
    case prompt
    case steer
    case followUp = "follow_up"
    case abort
    case stop
    case resume
}

struct SessionInteraction: Sendable, Equatable, Identifiable {
    let id: Int
    let at: Date
    let fromSessionId: String
    let toSessionId: String
    let kind: SessionInteractionKind
}

/// Session outside a thread that exchanged interactions with it.
struct SessionThreadCounterpart: Decodable, Sendable, Equatable {
    let id: String
    let name: String?
    let status: SessionStatus?
    /// Workspace route for opening the counterpart; absent for control sessions.
    var workspaceId: String? = nil
    var model: String? = nil
    let rootSessionId: String
    let rootName: String?
}

/// Pi's prompt-cache warmer for a live session.
struct SessionPromptCacheWarmer: Decodable, Sendable, Equatable {
    enum State: String, Decodable, Sendable {
        case inactive, scheduled, refreshing
    }

    enum Action: String, Decodable, Sendable {
        case warm, stop
    }

    let state: State
    /// Pi's pending decision for the scheduled refresh; "stop" lets the cache expire.
    let action: Action?
    let nextWarmAt: Date?

    private enum CodingKeys: String, CodingKey { case state, action, nextWarmAt }

    init(state: State, action: Action? = nil, nextWarmAt: Date? = nil) {
        self.state = state
        self.action = action
        self.nextWarmAt = nextWarmAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Newer Pi states read as inactive rather than failing the thread.
        state = (try? container.decode(State.self, forKey: .state)) ?? .inactive
        action = try? container.decodeIfPresent(Action.self, forKey: .action)
        nextWarmAt = try container.decodeIfPresent(Double.self, forKey: .nextWarmAt)
            .map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

/// Server's best-effort view of one session's prompt cache.
struct SessionPromptCacheStatus: Decodable, Sendable, Equatable {
    let ttl: TimeInterval?
    let lastRequestAt: Date?
    let warmer: SessionPromptCacheWarmer?

    private enum CodingKeys: String, CodingKey { case ttlMs, lastRequestAt, warmer }

    init(ttl: TimeInterval?, lastRequestAt: Date?, warmer: SessionPromptCacheWarmer? = nil) {
        self.ttl = ttl
        self.lastRequestAt = lastRequestAt
        self.warmer = warmer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ttl = try container.decodeIfPresent(Double.self, forKey: .ttlMs).map { $0 / 1000 }
        lastRequestAt = try container.decodeIfPresent(Double.self, forKey: .lastRequestAt)
            .map { Date(timeIntervalSince1970: $0 / 1000) }
        warmer = try container.decodeIfPresent(SessionPromptCacheWarmer.self, forKey: .warmer)
    }
}

/// `GET /sessions/:id/thread`: every session in one launch tree plus the
/// interactions touching it.
struct SessionThreadSnapshot: Sendable, Equatable {
    let rootSessionId: String
    let sessions: [Session]
    let interactions: [SessionInteraction]
    let counterparts: [SessionThreadCounterpart]
    var promptCache: [String: SessionPromptCacheStatus] = [:]
}

extension SessionThreadSnapshot: Decodable {
    private enum CodingKeys: String, CodingKey {
        case rootSessionId, sessions, interactions, counterparts, promptCache
    }

    private struct WireInteraction: Decodable {
        let id: Int
        let at: Double
        let fromSessionId: String
        let toSessionId: String
        let kind: String
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rootSessionId = try container.decode(String.self, forKey: .rootSessionId)
        sessions = try container.decode([SessionSummary].self, forKey: .sessions).map(\.session)
        // Newer servers may record primitives this client cannot draw; skip them.
        interactions = try container.decode([WireInteraction].self, forKey: .interactions).compactMap { wire in
            SessionInteractionKind(rawValue: wire.kind).map {
                SessionInteraction(
                    id: wire.id,
                    at: Date(timeIntervalSince1970: wire.at / 1000),
                    fromSessionId: wire.fromSessionId,
                    toSessionId: wire.toSessionId,
                    kind: $0
                )
            }
        }
        counterparts = try container.decodeIfPresent([SessionThreadCounterpart].self, forKey: .counterparts) ?? []
        promptCache = try container.decodeIfPresent([String: SessionPromptCacheStatus].self, forKey: .promptCache) ?? [:]
    }
}
