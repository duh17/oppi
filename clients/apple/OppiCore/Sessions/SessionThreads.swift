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
    /// Distinct workspaces the loaded members run in; above 1 marks a cross-workspace thread.
    var workspaceCount: Int { Set(members.compactMap(\.workspaceId)).count }
}

enum SessionThreadStatus {
    /// Status of a session when the caller has no per-device seen state: every done or
    /// error outcome counts as unseen.
    static func withoutSeenState(_ session: Session) -> SessionStatusKind {
        SessionStatusKind.resolve(session: session, seenAt: nil)
    }
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

    /// Thread section: a blocked member anywhere > any member working > any member
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
            if kind != nil, SessionListPresentation.isBlocked(member, attention: memberAttention) {
                return .yourTurn
            }
            sawWorking = sawWorking || kind == .working
            sawYourTurn = sawYourTurn || kind == .yourTurn
        }
        if sawWorking { return .working }
        return sawYourTurn ? .yourTurn : nil
    }

    /// Whether any live member waits on the person.
    static func isBlocked(
        _ rollup: SessionThreadRollup,
        attention: (Session) -> SessionListAttentionCounts
    ) -> Bool {
        rollup.members.contains {
            $0.status != .stopped && SessionListPresentation.isBlocked($0, attention: attention($0))
        }
    }
}

// MARK: - List entries

/// One row of a session list, the same in All Sessions and a workspace list.
/// In Threads layout a launch tree is listed once, at its root; a session whose
/// root belongs to another list links to that root instead of folding away.
struct SessionListEntry: Sendable, Equatable, Identifiable {
    let session: Session
    /// Loaded launch tree this session roots; nil when it has no loaded children or in Flat List.
    let thread: SessionThreadRollup?
    /// Root of this session's thread when that root is not in this list.
    let outsideRoot: Session?

    var id: String { session.id }
    /// `ForEach` id for stopped sections; see `SessionListPresentation.stoppedRowID`.
    var stoppedListID: String { SessionListPresentation.stoppedRowID(id) }

    /// Session that dates and orders the row: a thread sorts by its latest member.
    var representative: Session {
        guard let thread else { return session }
        var representative = session
        representative.lastActivity = thread.latestActivity
        return representative
    }

    /// Whether the row waits on the person: a thread when any live member does.
    func isBlocked(attention: (Session) -> SessionListAttentionCounts) -> Bool {
        if let thread { return SessionThreadGrouping.isBlocked(thread, attention: attention) }
        return session.status != .stopped && SessionListPresentation.isBlocked(session, attention: attention(session))
    }

    /// A thread sits where its most urgent member would; a plain row by its own state.
    func sectionKind(attention: (Session) -> SessionListAttentionCounts) -> SessionListActiveSectionKind? {
        if let thread {
            return SessionThreadGrouping.sectionKind(for: thread, attention: attention)
        }
        return SessionListPresentation.activeSectionKind(for: session, attention: attention(session))
    }
}

enum SessionListEntries {
    static func flat(_ sessions: [Session]) -> [SessionListEntry] {
        sessions.map { SessionListEntry(session: $0, thread: nil, outsideRoot: nil) }
    }

    /// Rows for a list: launch-tree threads when the experiment is on, otherwise
    /// one flat row per session.
    static func entries(threadsEnabled: Bool, listed: [Session], loaded: [Session]) -> [SessionListEntry] {
        threadsEnabled ? threads(listed: listed, loaded: loaded) : flat(listed)
    }

    /// Threads layout for the sessions a list shows (`listed`). Launch trees are
    /// built over every loaded session (`loaded`), so a thread keeps members
    /// that run in another workspace or worktree. A listed root carries its
    /// whole tree; a listed descendant of a listed root folds away; a listed
    /// session whose root is not listed stays a row linked to that root.
    /// Output keeps `listed` order.
    static func threads(listed: [Session], loaded: [Session]) -> [SessionListEntry] {
        let listedIds = Set(listed.map(\.id))
        var pool = listed
        var seen = listedIds
        for session in loaded where seen.insert(session.id).inserted {
            pool.append(session)
        }

        var rollupByMember: [String: SessionThreadRollup] = [:]
        for rollup in SessionThreadGrouping.rollups(from: pool) {
            for member in rollup.members {
                rollupByMember[member.id] = rollup
            }
        }

        return listed.compactMap { session in
            guard let rollup = rollupByMember[session.id] else {
                return SessionListEntry(session: session, thread: nil, outsideRoot: nil)
            }
            if rollup.root.id == session.id {
                return SessionListEntry(
                    session: session,
                    thread: rollup.descendants.isEmpty ? nil : rollup,
                    outsideRoot: nil
                )
            }
            if listedIds.contains(rollup.root.id) { return nil }
            return SessionListEntry(session: session, thread: nil, outsideRoot: rollup.root)
        }
    }
}

// MARK: - Lanes

/// Lane per session for thread graphs. The root owns lane 0; other sessions,
/// in launch order, take the lowest lane whose previous session has stopped.
enum SessionThreadLanes {
    struct Assignment: Sendable, Equatable {
        let laneBySessionId: [String: Int]
        let laneCount: Int
    }

    static func endDate(_ session: Session) -> Date? {
        session.status == .stopped ? session.lastActivity : nil
    }

    static func assign(root: Session, others: [Session]) -> Assignment {
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
        return Assignment(laneBySessionId: laneBySessionId, laneCount: laneFreeAfter.count)
    }
}

/// Horizontal lane graph for one thread, spaced like a git graph: x steps
/// by event order (each launch, stop, or idle moment is one step), not by
/// clock time, so a three-minute child in a two-hour thread still gets a
/// readable branch. y is the session's lane. Positions are 0...1; sessions
/// still running extend to the right edge.
struct SessionThreadLaneGraph: Sendable, Equatable {
    struct Segment: Sendable, Equatable, Identifiable {
        let id: String
        let lane: Int
        /// Lane it branches from and merges back into; nil for the root.
        let parentLane: Int?
        let start: Double
        let end: Double
        let isWorking: Bool
        let isStopped: Bool
        /// Where an idle root starts waiting (dashed from here); nil otherwise.
        let idleFrom: Double?
        let status: SessionStatusKind
    }

    let laneCount: Int
    /// Lanes folded into the last visible lane.
    let hiddenLaneCount: Int
    let segments: [Segment]

    static func layout(
        members: [Session],
        rootId: String,
        now: Date,
        maxLanes: Int = 4,
        status: (Session) -> SessionStatusKind = SessionThreadStatus.withoutSeenState
    ) -> SessionThreadLaneGraph {
        guard let root = members.first(where: { $0.id == rootId }) else {
            return SessionThreadLaneGraph(laneCount: 0, hiddenLaneCount: 0, segments: [])
        }
        let others = members
            .filter { $0.id != rootId }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        let lanes = SessionThreadLanes.assign(root: root, others: others)
        let visibleLanes = max(1, min(lanes.laneCount, maxLanes))

        // Ordinal axis: equal steps between distinct event times.
        let rootIdle = !SessionThreadGrouping.isWorking(root) && root.status != .stopped
        var eventTimes = Set(members.map(\.createdAt))
        for member in members where member.status == .stopped { eventTimes.insert(member.lastActivity) }
        if rootIdle { eventTimes.insert(root.lastActivity) }
        let steps = eventTimes.sorted()
        let stepCount = max(steps.count - 1, 1)
        let rankByTime = Dictionary(uniqueKeysWithValues: steps.enumerated().map { ($1, $0) })
        func x(_ date: Date) -> Double {
            Double(rankByTime[date] ?? 0) / Double(stepCount)
        }
        func visible(_ lane: Int) -> Int { min(lane, visibleLanes - 1) }

        let segments = ([root] + others).map { session -> Segment in
            let lane = lanes.laneBySessionId[session.id] ?? 0
            let parentLane = session.id == rootId
                ? nil
                : visible(session.parentSessionId.flatMap { lanes.laneBySessionId[$0] } ?? 0)
            let working = SessionThreadGrouping.isWorking(session)
            let stopped = session.status == .stopped
            let idle = session.id == rootId && rootIdle
            return Segment(
                id: session.id,
                lane: visible(lane),
                parentLane: parentLane,
                start: x(session.createdAt),
                end: stopped ? x(session.lastActivity) : 1,
                isWorking: working,
                isStopped: stopped,
                idleFrom: idle ? x(session.lastActivity) : nil,
                status: status(session)
            )
        }
        return SessionThreadLaneGraph(
            laneCount: visibleLanes,
            hiddenLaneCount: max(0, lanes.laneCount - visibleLanes),
            segments: segments
        )
    }
}

// MARK: - Agents

/// Sessions launched by the same saved Agent; `agentId == nil` is plain Pi.
struct SessionThreadAgentGroup: Sendable, Equatable, Identifiable {
    let agentId: String?
    let agentIcon: IconChoice?
    /// A member's id, for the Pi avatar's per-session rendering.
    let sampleSessionId: String
    let count: Int

    var id: String { agentId ?? "pi" }

    /// Largest group first; ties keep first-launch order.
    static func groups(_ sessions: [Session]) -> [SessionThreadAgentGroup] {
        var order: [String] = []
        var byKey: [String: (agentId: String?, icon: IconChoice?, sample: String, count: Int)] = [:]
        for session in sessions {
            let agentId = session.launch?.agentId
            let key = agentId ?? "pi"
            if var existing = byKey[key] {
                existing.count += 1
                byKey[key] = existing
            } else {
                order.append(key)
                byKey[key] = (agentId, session.launch?.agentIcon, session.id, 1)
            }
        }
        return order.enumerated()
            .compactMap { index, key in byKey[key].map { (index, $0) } }
            .sorted { $0.1.count != $1.1.count ? $0.1.count > $1.1.count : $0.0 < $1.0 }
            .map { SessionThreadAgentGroup(agentId: $0.1.agentId, agentIcon: $0.1.icon, sampleSessionId: $0.1.sample, count: $0.1.count) }
    }
}

// MARK: - Waterfall

/// Trace-viewer layout: one row per session in tree order (depth first,
/// children by launch), each a bar on a shared clock-time axis from launch
/// to last recorded activity. The bar summarizes; it is not an exact
/// execution span.
struct SessionThreadWaterfall: Sendable, Equatable {
    struct Row: Sendable, Equatable, Identifiable {
        let session: Session
        let depth: Int
        /// 0...1 on the time axis.
        let start: Double
        let end: Double
        /// Where an idle root starts waiting; nil otherwise.
        let idleFrom: Double?
        let status: SessionStatusKind

        var id: String { session.id }
    }

    let rows: [Row]
    let startDate: Date
    let endDate: Date

    static func build(
        snapshot: SessionThreadSnapshot,
        now: Date,
        status: (Session) -> SessionStatusKind = SessionThreadStatus.withoutSeenState
    ) -> SessionThreadWaterfall {
        let byId = Dictionary(snapshot.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let root = byId[snapshot.rootSessionId] else {
            return SessionThreadWaterfall(rows: [], startDate: now, endDate: now)
        }
        let children = Dictionary(grouping: snapshot.sessions.filter { $0.id != root.id }) {
            $0.parentSessionId ?? root.id
        }
        var ordered: [(Session, Int)] = []
        var visited: Set<String> = []
        func visit(_ session: Session, _ depth: Int) {
            guard visited.insert(session.id).inserted else { return }
            ordered.append((session, depth))
            for child in (children[session.id] ?? []).sorted(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }) {
                visit(child, depth + 1)
            }
        }
        visit(root, 0)

        // End at the latest activity, not `now`: a root idle for hours would
        // otherwise squeeze the real work into the left edge. Running bars
        // still reach the right edge.
        let latest = snapshot.sessions.map(\.lastActivity).max() ?? now
        let startDate = root.createdAt
        let endDate = max(latest, startDate.addingTimeInterval(1))
        let span = endDate.timeIntervalSince(startDate)
        func x(_ date: Date) -> Double { min(1, max(0, date.timeIntervalSince(startDate) / span)) }

        let rows = ordered.map { session, depth in
            let stopped = session.status == .stopped
            let idle = !stopped && !SessionThreadGrouping.isWorking(session)
            return Row(
                session: session,
                depth: depth,
                start: x(session.createdAt),
                end: stopped ? x(session.lastActivity) : 1,
                idleFrom: idle ? x(session.lastActivity) : nil,
                status: status(session)
            )
        }
        return SessionThreadWaterfall(rows: rows, startDate: startDate, endDate: endDate)
    }
}

// MARK: - Prompt cache

extension TokenUsage {
    /// Share of prompt tokens served from cache: reads over reads + writes + uncached input.
    var cacheHitRate: Double? {
        let read = Double(cacheRead ?? 0)
        let total = Double(input) + read + Double(cacheWrite ?? 0)
        return total > 0 ? read / total : nil
    }
}

enum SessionPromptCacheEstimate: Equatable, Sendable {
    /// The session is running a turn, so its cache is in use.
    case inUse
    /// Pi's warmer is refreshing the entry before it expires.
    case keptWarm(nextRefresh: Date?)
    case warm(until: Date)
    case cold
    case unknown

    /// Best effort: providers can evict early, so present `.warm` as likely.
    static func estimate(
        session: Session,
        status: SessionPromptCacheStatus?,
        now: Date
    ) -> SessionPromptCacheEstimate {
        if SessionThreadGrouping.isWorking(session) { return .inUse }
        guard let status else { return .unknown }
        // Kept warm only while Pi is refreshing now, or has a refresh it
        // decided to send that is still ahead. Pi arms a timer after every
        // request even when it has decided to let the cache expire.
        if let warmer = status.warmer, session.status != .stopped {
            switch warmer.state {
            case .refreshing:
                return .keptWarm(nextRefresh: nil)
            case .scheduled where warmer.action == .warm && (warmer.nextWarmAt.map { $0 >= now } ?? true):
                return .keptWarm(nextRefresh: warmer.nextWarmAt)
            case .scheduled, .inactive:
                break
            }
        }
        // The live store's reply time can be newer than the fetched snapshot.
        let lastRequestAt = [status.lastRequestAt, session.lastAgentReplyAt].compactMap { $0 }.max()
        guard let ttl = status.ttl, let lastRequestAt else { return .unknown }
        let until = lastRequestAt.addingTimeInterval(ttl)
        return until > now ? .warm(until: until) : .cold
    }
}
