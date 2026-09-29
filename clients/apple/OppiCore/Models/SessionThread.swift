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
    let rootSessionId: String
    let rootName: String?
}

/// `GET /sessions/:id/thread`: every session in one launch tree plus the
/// interactions touching it.
struct SessionThreadSnapshot: Sendable, Equatable {
    let rootSessionId: String
    let sessions: [Session]
    let interactions: [SessionInteraction]
    let counterparts: [SessionThreadCounterpart]
}

extension SessionThreadSnapshot: Decodable {
    private enum CodingKeys: String, CodingKey {
        case rootSessionId, sessions, interactions, counterparts
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
    }
}
