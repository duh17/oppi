import Foundation

enum DesiredSubscriptionLevel: Equatable, Sendable {
    case none
    case notifications
    case full

    var streamLevel: StreamSubscriptionLevel? {
        switch self {
        case .none: nil
        case .notifications: .notifications
        case .full: .full
        }
    }
}

enum SubscriptionAckState: Equatable, Sendable {
    case idle
    case inFlight(requestId: String, generation: Int, level: DesiredSubscriptionLevel)
    case acked(generation: Int, level: DesiredSubscriptionLevel)
    case failed(generation: Int, level: DesiredSubscriptionLevel, reason: String)
}

@MainActor
final class StreamSubscriptionRegistry {
    private struct Entry: Equatable {
        var desired: DesiredSubscriptionLevel = .none
        var ackState: SubscriptionAckState = .idle
        var generation: Int = 0
    }

    private var entries: [String: Entry] = [:]

    func setDesired(_ level: DesiredSubscriptionLevel, for sessionId: String) {
        var entry = entries[sessionId] ?? Entry()
        if entry.desired != level {
            entry.generation += 1
            entry.ackState = .idle
        }
        entry.desired = level
        if level == .none {
            entry.ackState = .idle
        }
        entries[sessionId] = entry
    }

    func desiredLevel(for sessionId: String) -> DesiredSubscriptionLevel {
        entries[sessionId]?.desired ?? .none
    }

    func desiredSessions() -> [String: DesiredSubscriptionLevel] {
        entries.compactMapValues { entry in
            entry.desired == .none ? nil : entry.desired
        }
    }

    func sessionIds(desired level: DesiredSubscriptionLevel) -> Set<String> {
        Set(entries.compactMap { sessionId, entry in
            entry.desired == level ? sessionId : nil
        })
    }

    func sessionIds(acked level: DesiredSubscriptionLevel) -> Set<String> {
        Set(entries.compactMap { sessionId, entry in
            if case .acked(_, let ackedLevel) = entry.ackState,
               ackedLevel == level {
                return sessionId
            }
            return nil
        })
    }

    func sessionIds(inFlight level: DesiredSubscriptionLevel) -> Set<String> {
        Set(entries.compactMap { sessionId, entry in
            if case .inFlight(_, _, let inFlightLevel) = entry.ackState,
               inFlightLevel == level {
                return sessionId
            }
            return nil
        })
    }

    func generation(for sessionId: String) -> Int {
        entries[sessionId]?.generation ?? 0
    }

    func markSubscribeSent(sessionId: String, requestId: String, level: DesiredSubscriptionLevel) {
        var entry = entries[sessionId] ?? Entry()
        if entry.desired == .none {
            entry.desired = level
        }
        entry.ackState = .inFlight(requestId: requestId, generation: entry.generation, level: level)
        entries[sessionId] = entry
    }

    func markSubscribeAck(sessionId: String, requestId: String) {
        guard var entry = entries[sessionId],
              case .inFlight(let inFlightRequestId, let generation, let level) = entry.ackState,
              inFlightRequestId == requestId,
              entry.desired == level else {
            return
        }
        entry.ackState = .acked(generation: generation, level: level)
        entries[sessionId] = entry
    }

    func markSubscribeFailed(sessionId: String, requestId: String, reason: String) {
        guard var entry = entries[sessionId],
              case .inFlight(let inFlightRequestId, let generation, let level) = entry.ackState,
              inFlightRequestId == requestId else {
            return
        }
        entry.ackState = .failed(generation: generation, level: level, reason: reason)
        entries[sessionId] = entry
    }

    func markUnsubscribeSent(sessionId: String, generation: Int) {
        guard var entry = entries[sessionId], entry.generation == generation else {
            return
        }
        entry.desired = .none
        entry.ackState = .idle
        entry.generation += 1
        entries[sessionId] = entry
    }

    func ackState(for sessionId: String) -> SubscriptionAckState {
        entries[sessionId]?.ackState ?? .idle
    }

    func routeLevel(for sessionId: String) -> DesiredSubscriptionLevel? {
        guard let entry = entries[sessionId] else { return nil }
        switch entry.ackState {
        case .acked(_, let level):
            return level
        case .inFlight(_, _, let level):
            return level
        case .failed, .idle:
            return entry.desired == .none ? nil : entry.desired
        }
    }

    func remove(sessionId: String) {
        entries.removeValue(forKey: sessionId)
    }

    func removeAll() {
        entries.removeAll()
    }
}
