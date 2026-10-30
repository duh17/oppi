import Foundation

// MARK: - Inbox threads

/// One launch tree among the sessions a list has loaded.
struct SessionThreadRollup: Sendable, Equatable {
    let root: Session
    /// Root first, then descendants in launch order.
    let members: [Session]

    var descendants: ArraySlice<Session> { members.dropFirst() }

    /// What an open thread lists after its root, in two groups (`Member`: depth 1 is a first-level row).
    ///
    /// - `live`: members that are not stopped, in the order the list's own sections use: the
    ///   Your Turn ones (blocked, error, done, idle) first, sorted by
    ///   `SessionListPresentation.compareYourTurn` (blocked first, then the oldest activity),
    ///   then the Working ones, sorted by `compareWorking`. The section is the one the list
    ///   classifies by (`activeSectionKind`), without this device's seen state, so a glance
    ///   never reorders the rows, and a working member's activity ticking never moves it.
    /// - `stopped`: the stopped members, most recent activity first, as the list sorts stopped rows.
    ///
    /// A group is a forest. A member's parent is its nearest ancestor in the same group, skipping
    /// the root and members of the other group; with none it is first level (depth 1). A member
    /// therefore keeps its depth under a parent listed in its group, and a live grandchild whose
    /// parent is stopped hangs off the nearest live ancestor, or sits at depth 1. Children follow
    /// their parent directly, and a branch sorts where its most urgent member would, as a thread
    /// does in the list's sections. A parent cycle never reaches a first-level member: those
    /// members are listed last, at depth 1, so every descendant appears exactly once.
    typealias Member = (session: Session, depth: Int)

    func listing(
        attention: (Session) -> SessionListAttentionCounts
    ) -> (live: [Member], stopped: [Member]) {
        var live: [Session] = []
        var stopped: [Session] = []
        // Section and blocked state of each live member, as the list classifies a row.
        var sectionById: [String: SessionListActiveSectionKind] = [:]
        var blockedIds: Set<String> = []
        for member in descendants {
            let memberAttention = attention(member)
            guard let section = SessionListPresentation.activeSectionKind(for: member, attention: memberAttention) else {
                stopped.append(member)
                continue
            }
            live.append(member)
            sectionById[member.id] = section
            if SessionListPresentation.isBlocked(member, attention: memberAttention) { blockedIds.insert(member.id) }
        }
        return (
            forest(live) { lhs, rhs in
                let (lhsSection, rhsSection) = (sectionById[lhs.id] ?? .working, sectionById[rhs.id] ?? .working)
                if lhsSection != rhsSection { return lhsSection == .yourTurn }
                if lhsSection == .working { return SessionListPresentation.compareWorking(lhs, rhs) }
                return SessionListPresentation.compareYourTurn(
                    lhs, lhsBlocked: blockedIds.contains(lhs.id), rhs, rhsBlocked: blockedIds.contains(rhs.id)
                )
            },
            // The list's stopped sort: most recent activity first.
            forest(stopped) { lhs, rhs in
                if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
                return lhs.id < rhs.id
            }
        )
    }

    /// `group` as an outline ordered by `precedes` (a strict total order).
    private func forest(_ group: [Session], precedes: (Session, Session) -> Bool) -> [Member] {
        let groupIds = Set(group.map(\.id))
        let byId = Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var childrenByParent: [String: [Session]] = [:]
        var firstLevel: [Session] = []
        for session in group {
            // Nearest ancestor in this group. The walk passes over the root and members of the other
            // group, and ends at a missing parent or a cycle.
            var parentId = session.parentSessionId
            var seen: Set<String> = [session.id]
            var listedParent: String?
            while let id = parentId, seen.insert(id).inserted, let ancestor = byId[id] {
                if groupIds.contains(id) { listedParent = id; break }
                parentId = ancestor.parentSessionId
            }
            if let listedParent {
                childrenByParent[listedParent, default: []].append(session)
            } else {
                firstLevel.append(session)
            }
        }

        // The member of a branch that sorts first stands for the whole branch.
        var leaders: [String: Session] = [:]
        func leader(_ session: Session) -> Session {
            if let known = leaders[session.id] { return known }
            var winner = session
            for child in childrenByParent[session.id] ?? [] {
                let candidate = leader(child)
                if precedes(candidate, winner) { winner = candidate }
            }
            leaders[session.id] = winner
            return winner
        }
        func ordered(_ sessions: [Session]) -> [Session] {
            sessions.sorted { precedes(leader($0), leader($1)) }
        }

        var rows: [Member] = []
        var listed: Set<String> = []
        func visit(_ session: Session, depth: Int) {
            guard listed.insert(session.id).inserted else { return }
            rows.append((session, depth))
            for child in ordered(childrenByParent[session.id] ?? []) { visit(child, depth: depth + 1) }
        }
        for session in ordered(firstLevel) { visit(session, depth: 1) }
        for session in group.sorted(by: precedes) where !listed.contains(session.id) {
            rows.append((session, 1))
            listed.insert(session.id)
        }
        return rows
    }

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

    /// Root of the launch tree `sessionId` belongs to among the loaded `sessions`: the session
    /// itself when it has no loaded parent. Nil when `sessionId` is not among them.
    static func rootId(of sessionId: String, in sessions: [Session]) -> String? {
        // The rollup's own root, so a parent cycle resolves to the root the list shows for it.
        rollups(from: sessions).first { rollup in rollup.members.contains { $0.id == sessionId } }?.root.id
    }

    /// The first parent on `sessionId`'s chain that is not among `sessions`, so a caller can load
    /// it and find the whole chain. Nil when the chain is complete or `sessionId` is not among them.
    static func missingAncestorId(of sessionId: String, in sessions: [Session]) -> String? {
        let byId = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var current = byId[sessionId]
        var visited: Set<String> = [sessionId]
        while let parentId = current?.parentSessionId, visited.insert(parentId).inserted {
            guard let parent = byId[parentId] else { return parentId }
            current = parent
        }
        return nil
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
    /// Indent level of a child row listed under its expanded thread root; 0 for every list row.
    var depth = 0
    /// The thread this row roots is open, so its children are listed after it.
    var isExpanded = false
    /// Set on the row that folds an open thread's stopped members; `session` is the thread root.
    var stoppedFold: SessionThreadStoppedFold?

    var id: String { stoppedFold?.rowID ?? session.id }
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

/// The row at the end of an open thread that folds its stopped members.
struct SessionThreadStoppedFold: Sendable, Equatable {
    let rootId: String
    let count: Int
    /// The stopped members are listed after this row.
    let isOpen: Bool

    /// List item id; never a session id, so it cannot collide with a member's row.
    var rowID: String { "stopped-members:\(rootId)" }
}

enum SessionListEntries {
    /// One plain row per session: search results, which never fold into threads.
    static func flat(_ sessions: [Session]) -> [SessionListEntry] {
        sessions.map { SessionListEntry(session: $0, thread: nil, outsideRoot: nil) }
    }

    /// The rows of `entries` with each thread in `expandedRoots` open: its root row, its
    /// live members, then one fold row for its stopped members and, when the fold is open,
    /// those members. Each member is its own row, indented by `depth`; order and depth rules
    /// are `SessionThreadRollup.listing`. Members that run in another workspace are listed
    /// too: a thread is the whole launch tree, not the part this list's workspace shows.
    /// Other entries pass through.
    ///
    /// `stoppedFolds` holds what the person chose for a thread's fold (true: open), by root id.
    /// Without a choice the fold is closed, always: a thread whose members are all stopped lists
    /// its root and the fold row. `attention` supplies each member's pending asks, which make it
    /// blocked.
    /// A choice is kept per root until the owner clears it, so closing and reopening a thread
    /// finds its fold as it was left.
    ///
    /// The fold row is an entry whose `session` is the root and whose `stoppedFold` is set.
    /// A thread with no stopped member has no fold row.
    static func expanding(
        _ entries: [SessionListEntry],
        expandedRoots: Set<String>,
        stoppedFolds: [String: Bool],
        attention: (Session) -> SessionListAttentionCounts
    ) -> [SessionListEntry] {
        guard !expandedRoots.isEmpty else { return entries }
        var rows: [SessionListEntry] = []
        rows.reserveCapacity(entries.count)
        for entry in entries {
            guard let thread = entry.thread, expandedRoots.contains(entry.session.id) else {
                rows.append(entry)
                continue
            }
            var root = entry
            root.isExpanded = true
            rows.append(root)
            let listing = thread.listing(attention: attention)
            func member(_ listed: SessionThreadRollup.Member) -> SessionListEntry {
                SessionListEntry(session: listed.session, thread: nil, outsideRoot: nil, depth: listed.depth)
            }
            rows.append(contentsOf: listing.live.map(member))
            guard !listing.stopped.isEmpty else { continue }
            let isOpen = stoppedFolds[entry.session.id] ?? false
            rows.append(SessionListEntry(
                session: entry.session,
                thread: nil,
                outsideRoot: nil,
                depth: 1,
                stoppedFold: SessionThreadStoppedFold(
                    rootId: entry.session.id, count: listing.stopped.count, isOpen: isOpen
                )
            ))
            if isOpen { rows.append(contentsOf: listing.stopped.map(member)) }
        }
        return rows
    }

    /// Thread rows for the sessions a list shows (`listed`). Launch trees are
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
