import Foundation

// MARK: - Inbox threads

/// One launch tree among the sessions a list has loaded.
struct SessionThreadRollup: Sendable, Equatable {
    let root: Session
    /// Root first, then descendants in launch order.
    let members: [Session]

    var descendants: ArraySlice<Session> { members.dropFirst() }
    var latestActivity: Date { members.lazy.map(\.lastActivity).max() ?? root.lastActivity }
    var totalCost: Double { members.reduce(0) { $0 + $1.cost } }
    var workingDescendants: [Session] { descendants.filter(SessionThreadGrouping.isWorking) }
    var finishedDescendantCount: Int { descendants.count { $0.status == .stopped } }
}

enum SessionThreadGrouping {
    static func isWorking(_ session: Session) -> Bool {
        SessionListPresentation.activeSectionKind(for: session) == .working
    }

    /// Group sessions by launch root. A session whose parent is not loaded is a
    /// root, so a partial list never hides sessions. Roots keep input order.
    static func rollups(from sessions: [Session]) -> [SessionThreadRollup] {
        let byId = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rootIdBySession: [String: String] = [:]

        func rootId(of session: Session) -> String {
            if let known = rootIdBySession[session.id] { return known }
            var path = [session.id]
            var visited: Set<String> = [session.id]
            var current = session
            var root: String?
            while let parentId = current.parentSessionId,
                  let parent = byId[parentId],
                  visited.insert(parent.id).inserted {
                if let known = rootIdBySession[parent.id] {
                    root = known
                    break
                }
                path.append(parent.id)
                current = parent
            }
            // Every session on the walk shares one root, so a parent cycle still
            // resolves to a single thread.
            let resolved = root ?? current.id
            for id in path { rootIdBySession[id] = resolved }
            return resolved
        }

        var membersByRoot: [String: [Session]] = [:]
        var rootOrder: [String] = []
        for session in sessions {
            let root = rootId(of: session)
            if membersByRoot[root] == nil { rootOrder.append(root) }
            membersByRoot[root, default: []].append(session)
        }

        return rootOrder.compactMap { rootId in
            guard let root = byId[rootId], let members = membersByRoot[rootId] else { return nil }
            let descendants = members
                .filter { $0.id != rootId }
                .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
            return SessionThreadRollup(root: root, members: [root] + descendants)
        }
    }

    /// Thread section: attention anywhere > any member working > any member
    /// idle > stopped. A root that is idle or stopped while a child works still
    /// lists the thread as Working, so detached hand-offs stay visible.
    static func sectionKind(
        for rollup: SessionThreadRollup,
        attention: (Session) -> SessionListAttentionCounts
    ) -> SessionListActiveSectionKind? {
        var sawWorking = false
        var sawYourTurn = false
        for member in rollup.members {
            let memberAttention = attention(member)
            let kind = SessionListPresentation.activeSectionKind(for: member, attention: memberAttention)
            if kind != nil, memberAttention.hasAttention { return .yourTurn }
            sawWorking = sawWorking || kind == .working
            sawYourTurn = sawYourTurn || kind == .yourTurn
        }
        if sawWorking { return .working }
        return sawYourTurn ? .yourTurn : nil
    }
}

// MARK: - Thread timeline

/// Interaction primitives the timeline can show or hide.
struct SessionThreadTimelineFilter: OptionSet, Sendable, Hashable {
    let rawValue: Int

    static let launches = SessionThreadTimelineFilter(rawValue: 1 << 0)
    static let messages = SessionThreadTimelineFilter(rawValue: 1 << 1)
    static let control = SessionThreadTimelineFilter(rawValue: 1 << 2)
    static let ends = SessionThreadTimelineFilter(rawValue: 1 << 3)
    static let crossThread = SessionThreadTimelineFilter(rawValue: 1 << 4)
    static let all: SessionThreadTimelineFilter = [.launches, .messages, .control, .ends, .crossThread]

    static func category(for kind: SessionInteractionKind) -> SessionThreadTimelineFilter {
        switch kind {
        case .prompt, .steer, .followUp: .messages
        case .abort, .stop, .resume: .control
        }
    }
}

struct SessionThreadTimelineRow: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable {
        case start
        /// Session launched from the session on `parentLane`.
        case launch(parentLane: Int?)
        /// Session stopped; its lane merges back into `parentLane`.
        case end(parentLane: Int?)
        /// Both ends are in the thread.
        case interaction(SessionInteractionKind, fromLane: Int)
        /// One end is outside the thread.
        case crossThread(SessionInteractionKind, counterpart: SessionThreadCounterpart, outgoing: Bool)
        /// Sessions still working at `now`.
        case working(lanes: [Int])
    }

    let id: String
    /// Nil for the trailing "now" row.
    let at: Date?
    let lane: Int
    let kind: Kind
    /// Session this row opens.
    let sessionId: String
    let title: String
    let detail: String?
    /// Lanes drawn through the top half of the row.
    let lanesAbove: Set<Int>
    /// Lanes drawn through the bottom half of the row.
    let lanesBelow: Set<Int>
    /// Lanes drawn dashed: the root waiting idle on its children.
    let idleLanes: Set<Int>
}

struct SessionThreadTimeline: Sendable, Equatable {
    let laneCount: Int
    let laneBySessionId: [String: Int]
    let rows: [SessionThreadTimelineRow]

    /// Lay out a git-graph style timeline. Launch = `createdAt`, end =
    /// `lastActivity` of a stopped session, plus recorded interactions. Lanes
    /// and their continuity come from session lifetimes, so hiding a primitive
    /// with `filter` removes its rows without breaking the lanes.
    static func build(
        snapshot: SessionThreadSnapshot,
        now: Date,
        filter: SessionThreadTimelineFilter = .all
    ) -> SessionThreadTimeline {
        let byId = Dictionary(snapshot.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let root = byId[snapshot.rootSessionId] else {
            return SessionThreadTimeline(laneCount: 0, laneBySessionId: [:], rows: [])
        }
        let others = snapshot.sessions
            .filter { $0.id != root.id }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }

        func endDate(_ session: Session) -> Date? {
            session.status == .stopped ? session.lastActivity : nil
        }

        // Greedy lane reuse: a lane frees once its previous session has ended.
        var laneBySessionId: [String: Int] = [root.id: 0]
        var laneFreeAfter: [Date?] = [endDate(root)]
        for session in others {
            let lane = laneFreeAfter.indices.dropFirst().first { index in
                laneFreeAfter[index].map { $0 < session.createdAt } ?? false
            } ?? laneFreeAfter.count
            if lane == laneFreeAfter.count { laneFreeAfter.append(nil) }
            laneFreeAfter[lane] = endDate(session)
            laneBySessionId[session.id] = lane
        }
        let counterpartsById = Dictionary(
            snapshot.counterparts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        struct Event {
            let at: Date
            let order: Int
            let category: SessionThreadTimelineFilter
            let row: (_ above: Set<Int>, _ below: Set<Int>, _ idle: Set<Int>) -> SessionThreadTimelineRow
            let lane: Int
            let sessionId: String
        }
        var events: [Event] = []

        func parentLane(of session: Session) -> Int? {
            session.parentSessionId.flatMap { laneBySessionId[$0] }
        }

        events.append(Event(at: root.createdAt, order: 0, category: .launches, row: { above, below, idle in
            SessionThreadTimelineRow(
                id: "start:\(root.id)", at: root.createdAt, lane: 0, kind: .start,
                sessionId: root.id, title: root.displayTitle, detail: "started",
                lanesAbove: above, lanesBelow: below, idleLanes: idle
            )
        }, lane: 0, sessionId: root.id))

        for session in others {
            let lane = laneBySessionId[session.id] ?? 0
            let parent = parentLane(of: session)
            let parentName = session.parentSessionId.flatMap { byId[$0]?.displayTitle }
            events.append(Event(at: session.createdAt, order: 1, category: .launches, row: { above, below, idle in
                SessionThreadTimelineRow(
                    id: "launch:\(session.id)", at: session.createdAt, lane: lane,
                    kind: .launch(parentLane: parent), sessionId: session.id,
                    title: session.displayTitle,
                    detail: parentName.map { "launched by \($0)" },
                    lanesAbove: above, lanesBelow: below, idleLanes: idle
                )
            }, lane: lane, sessionId: session.id))
        }

        for session in snapshot.sessions where session.status == .stopped {
            let lane = laneBySessionId[session.id] ?? 0
            let parent = session.id == root.id ? nil : parentLane(of: session)
            events.append(Event(at: session.lastActivity, order: 3, category: .ends, row: { above, below, idle in
                SessionThreadTimelineRow(
                    id: "end:\(session.id)", at: session.lastActivity, lane: lane,
                    kind: .end(parentLane: parent), sessionId: session.id,
                    title: session.displayTitle,
                    detail: String(format: "stopped · $%.2f", session.cost),
                    lanesAbove: above, lanesBelow: below, idleLanes: idle
                )
            }, lane: lane, sessionId: session.id))
        }

        for interaction in snapshot.interactions {
            let fromLane = laneBySessionId[interaction.fromSessionId]
            let toLane = laneBySessionId[interaction.toSessionId]
            let verb = Self.verb(for: interaction.kind)
            if let fromLane, let toLane {
                let fromName = byId[interaction.fromSessionId]?.displayTitle ?? interaction.fromSessionId
                let toName = byId[interaction.toSessionId]?.displayTitle ?? interaction.toSessionId
                events.append(Event(
                    at: interaction.at, order: 2,
                    category: SessionThreadTimelineFilter.category(for: interaction.kind),
                    row: { above, below, idle in
                        SessionThreadTimelineRow(
                            id: "interaction:\(interaction.id)", at: interaction.at, lane: toLane,
                            kind: .interaction(interaction.kind, fromLane: fromLane),
                            sessionId: interaction.toSessionId, title: toName,
                            detail: "\(verb) by \(fromName)",
                            lanesAbove: above, lanesBelow: below, idleLanes: idle
                        )
                    },
                    lane: toLane, sessionId: interaction.toSessionId
                ))
            } else if let lane = fromLane ?? toLane {
                let outgoing = fromLane != nil
                let otherId = outgoing ? interaction.toSessionId : interaction.fromSessionId
                let insideId = outgoing ? interaction.fromSessionId : interaction.toSessionId
                let counterpart = counterpartsById[otherId]
                    ?? SessionThreadCounterpart(id: otherId, name: nil, status: nil, rootSessionId: otherId, rootName: nil)
                let otherName = counterpart.name ?? String(otherId.prefix(8))
                let insideName = byId[insideId]?.displayTitle ?? insideId
                let rootNote = counterpart.rootName.map { " · in \($0)" } ?? ""
                events.append(Event(
                    at: interaction.at, order: 2, category: .crossThread,
                    row: { above, below, idle in
                        SessionThreadTimelineRow(
                            id: "interaction:\(interaction.id)", at: interaction.at, lane: lane,
                            kind: .crossThread(interaction.kind, counterpart: counterpart, outgoing: outgoing),
                            sessionId: insideId,
                            title: outgoing ? "\(verb) \(otherName)" : "\(verb) by \(otherName)",
                            detail: (outgoing ? "from \(insideName)" : "to \(insideName)") + rootNote,
                            lanesAbove: above, lanesBelow: below, idleLanes: idle
                        )
                    },
                    lane: lane, sessionId: insideId
                ))
            }
        }

        events.sort { ($0.at, $0.order, $0.lane) < ($1.at, $1.order, $1.lane) }

        // Lifetimes in event positions; a session without an end runs to `now`.
        var startIndex: [String: Int] = [:]
        var endIndex: [String: Int] = [:]
        for (index, event) in events.enumerated() {
            switch event.order {
            case 0, 1: startIndex[event.sessionId] = startIndex[event.sessionId] ?? index
            case 3: endIndex[event.sessionId] = index
            default: break
            }
        }
        let nowIndex = events.count
        let rootIdleSince = root.status == .stopped || isWorkingLike(root) ? nil : root.lastActivity

        func lanes(at index: Int, above: Bool) -> Set<Int> {
            var result: Set<Int> = []
            for session in snapshot.sessions {
                guard let start = startIndex[session.id], let lane = laneBySessionId[session.id] else { continue }
                let end = endIndex[session.id] ?? Int.max
                let alive = above ? (start < index && index <= end) : (start <= index && index < end)
                if alive { result.insert(lane) }
            }
            return result
        }

        func idleLanes(at date: Date) -> Set<Int> {
            guard let rootIdleSince, date > rootIdleSince else { return [] }
            return [0]
        }

        var rows: [SessionThreadTimelineRow] = []
        for (index, event) in events.enumerated() where filter.contains(event.category) {
            rows.append(event.row(lanes(at: index, above: true), lanes(at: index, above: false), idleLanes(at: event.at)))
        }

        let working = snapshot.sessions.filter(isWorkingLike)
        if !working.isEmpty {
            let workingLanes = working.compactMap { laneBySessionId[$0.id] }.sorted()
            rows.append(SessionThreadTimelineRow(
                id: "now", at: nil, lane: workingLanes.first ?? 0,
                kind: .working(lanes: workingLanes),
                sessionId: working[0].id,
                title: working.map(\.displayTitle).joined(separator: ", "),
                detail: "working",
                lanesAbove: lanes(at: nowIndex, above: true),
                lanesBelow: [],
                idleLanes: idleLanes(at: now)
            ))
        }

        return SessionThreadTimeline(
            laneCount: laneFreeAfter.count,
            laneBySessionId: laneBySessionId,
            rows: rows
        )
    }

    private static func isWorkingLike(_ session: Session) -> Bool {
        SessionThreadGrouping.isWorking(session)
    }

    static func verb(for kind: SessionInteractionKind) -> String {
        switch kind {
        case .prompt: "prompted"
        case .steer: "steered"
        case .followUp: "followed up"
        case .abort: "aborted"
        case .stop: "stopped"
        case .resume: "resumed"
        }
    }
}
