import Foundation

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

/// `GET /sessions/:id/thread`: every session in one launch tree.
struct SessionThreadSnapshot: Sendable, Equatable {
    let rootSessionId: String
    let sessions: [Session]
    var promptCache: [String: SessionPromptCacheStatus] = [:]
}

extension SessionThreadSnapshot: Decodable {
    private enum CodingKeys: String, CodingKey {
        case rootSessionId, sessions, promptCache
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rootSessionId = try container.decode(String.self, forKey: .rootSessionId)
        sessions = try container.decode([SessionSummary].self, forKey: .sessions).map(\.session)
        promptCache = try container.decodeIfPresent([String: SessionPromptCacheStatus].self, forKey: .promptCache) ?? [:]
    }
}
