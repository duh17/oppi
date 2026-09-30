import SwiftUI

// MARK: - Inbox thread strip

/// One-line summary under a thread root row: who is working, member dots, totals.
struct SessionThreadStrip: View {
    let rollup: SessionThreadRollup
    /// Member with a pending question, shown so the user knows where to answer.
    var attentionMember: Session?

    var body: some View {
        let working = rollup.workingDescendants
        VStack(alignment: .leading, spacing: 4) {
            if let attentionMember {
                Label("Question from \(attentionMember.displayTitle)", systemImage: "questionmark.bubble.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.themeOrange)
                    .lineLimit(1)
            } else if !working.isEmpty {
                Text(working.map(\.displayTitle).joined(separator: " · ") + " working")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.themeBlue)
                    .lineLimit(1)
            }
            SessionThreadLaneGraphView(members: rollup.members, rootId: rollup.root.id)
                .frame(maxWidth: 260, alignment: .leading)
            HStack(alignment: .center, spacing: 8) {
                SessionThreadAgentCluster(groups: SessionThreadAgentGroup.groups(Array(rollup.descendants)), maxGroups: 3)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var summary: String {
        var parts: [String] = []
        let working = rollup.workingDescendants.count
        if working > 0 { parts.append("\(working) working") }
        parts.append("\(rollup.finishedDescendantCount) done")
        parts.append(String(format: "$%.2f", rollup.totalCost))
        return parts.joined(separator: " · ")
    }

    private var accessibilitySummary: String {
        let question = attentionMember.map { "Question from \($0.displayTitle). " } ?? ""
        return question + "Thread with \(rollup.descendants.count) child sessions, \(summary)"
    }

}

// MARK: - Agent identity

/// Session's Agent icon (Pi avatar when none) with its status dot.
struct SessionThreadIdentityBadge: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let session: Session
    var hasQuestion = false
    var size: CGFloat = 22

    var body: some View {
        let status: SessionRowStatusKind = hasQuestion ? .question : SessionRowStatusKind.from(session: session)
        SessionIdentityIconView(sessionId: session.id, agentId: session.launch?.agentId, agentIcon: session.launch?.agentIcon)
            .frame(width: size, height: size)
            .opacity(session.status == .stopped ? 0.6 : 1)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(status.tint(theme))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(theme.bg.primary, lineWidth: 1.5))
                    .phaseAnimator(status == .working && !reduceMotion ? [1.0, 0.4] : [1.0]) { dot, phase in
                        dot.opacity(phase)
                    }
                    .offset(x: 2, y: 2)
            }
            .accessibilityHidden(true)
    }
}

/// Agents present in a group of sessions, largest first: 🛠️×15 🔬×12 +2.
struct SessionThreadAgentCluster: View {
    let groups: [SessionThreadAgentGroup]
    var maxGroups = 3

    var body: some View {
        HStack(spacing: 6) {
            ForEach(groups.prefix(maxGroups)) { group in
                HStack(spacing: 2) {
                    SessionIdentityIconView(sessionId: group.sampleSessionId, agentId: group.agentId, agentIcon: group.agentIcon)
                        .frame(width: 14, height: 14)
                    if group.count > 1 {
                        Text("×\(group.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.themeComment)
                    }
                }
            }
            if groups.count > maxGroups {
                Text("+\(groups.count - maxGroups)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.themeComment)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Waterfall

/// Trace-viewer layout: pinned label column (Agent icon, name, tree depth)
/// beside a horizontally scrolling clock-time Canvas of status bars and
/// message arrows. Pinch to zoom; tap a label or bar to open the session.
struct SessionThreadWaterfallView: View {
    @Environment(\.theme) private var theme

    let waterfall: SessionThreadWaterfall
    let agentNames: [String: String]
    let onOpen: (Session) -> Void

    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var viewportWidth: CGFloat = 220

    static let rowHeight: CGFloat = 28
    static let axisHeight: CGFloat = 20
    static let labelWidth: CGFloat = 132

    var body: some View {
        let rows = waterfall.rows
        let height = Self.axisHeight + CGFloat(rows.count) * Self.rowHeight
        let contentWidth = max(viewportWidth, viewportWidth * zoom * pinch)
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: Self.axisHeight)
                ForEach(rows) { row in
                    Button { onOpen(row.session) } label: {
                        HStack(spacing: 5) {
                            SessionIdentityIconView(
                                sessionId: row.session.id,
                                agentId: row.session.launch?.agentId,
                                agentIcon: row.session.launch?.agentIcon
                            )
                            .frame(width: 14, height: 14)
                            Text(row.session.displayTitle)
                                .font(.caption)
                                .foregroundStyle(row.session.status == .stopped ? theme.text.secondary : theme.text.primary)
                                .lineLimit(1)
                        }
                        .padding(.leading, CGFloat(min(row.depth, 4)) * 8)
                        .frame(width: Self.labelWidth, height: Self.rowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityLabel(row))
                    .accessibilityIdentifier("thread.waterfall.row.\(row.id)")
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Canvas { context, size in draw(in: &context, size: size) }
                    .frame(width: contentWidth, height: height)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        let index = Int((location.y - Self.axisHeight) / Self.rowHeight)
                        if rows.indices.contains(index) { onOpen(rows[index].session) }
                    }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = max($0, 1) }
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in zoom = min(12, max(1, zoom * value.magnification)) }
            )
        }
        .frame(height: height)
        // Contain first: an identifier on a plain container overrides its children's identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("thread.waterfall")
    }

    private func accessibilityLabel(_ row: SessionThreadWaterfall.Row) -> String {
        let agent = row.session.launch?.agentId.map { agentNames[$0] ?? "Agent" } ?? "Pi"
        return "\(row.session.displayTitle), \(agent), \(row.status.label)"
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let inset: CGFloat = 6
        let usable = max(size.width - inset * 2, 1)
        func x(_ value: Double) -> CGFloat { inset + CGFloat(value) * usable }
        func rowY(_ index: Int) -> CGFloat { Self.axisHeight + CGFloat(index) * Self.rowHeight + Self.rowHeight / 2 }

        // Axis: about one tick per 70 pt, labelled with clock time.
        let span = waterfall.endDate.timeIntervalSince(waterfall.startDate)
        let tickCount = max(2, Int(usable / 70))
        for tick in 0...tickCount {
            let fraction = Double(tick) / Double(tickCount)
            let tickX = x(fraction)
            context.stroke(
                Path { $0.move(to: CGPoint(x: tickX, y: Self.axisHeight - 4)); $0.addLine(to: CGPoint(x: tickX, y: size.height)) },
                with: .color(theme.text.tertiary.opacity(0.15)),
                lineWidth: 1
            )
            let date = waterfall.startDate.addingTimeInterval(span * fraction)
            context.draw(
                Text(date.formatted(date: .omitted, time: .shortened)).font(.system(size: 9)).foregroundStyle(theme.text.tertiary),
                at: CGPoint(x: tickX, y: 7),
                anchor: tick == 0 ? .leading : (tick == tickCount ? .trailing : .center)
            )
        }

        for (index, row) in waterfall.rows.enumerated() {
            let color = row.status.tint(theme)
            let y = rowY(index)
            let startX = x(row.start)
            let activeEnd = row.idleFrom.map { x($0) } ?? x(row.end)
            let bar = CGRect(x: startX, y: y - 5, width: max(activeEnd - startX, 3), height: 10)
            context.fill(Path(roundedRect: bar, cornerRadius: 3), with: .color(color.opacity(row.status == .stopped ? 0.55 : 0.9)))
            if row.idleFrom != nil {
                context.stroke(
                    Path { $0.move(to: CGPoint(x: bar.maxX, y: y)); $0.addLine(to: CGPoint(x: x(row.end), y: y)) },
                    with: .color(color),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 3])
                )
            }
        }

        for message in waterfall.messages {
            let messageX = x(message.at)
            switch (message.fromRow, message.toRow) {
            case let (from?, to?):
                let fromY = rowY(from), toY = rowY(to)
                context.stroke(
                    Path { $0.move(to: CGPoint(x: messageX, y: fromY)); $0.addLine(to: CGPoint(x: messageX, y: toY)) },
                    with: .color(theme.accent.cyan),
                    lineWidth: 1.2
                )
                let direction: CGFloat = toY > fromY ? -1 : 1
                context.fill(Path { path in
                    path.move(to: CGPoint(x: messageX, y: toY))
                    path.addLine(to: CGPoint(x: messageX - 3, y: toY + 5 * direction))
                    path.addLine(to: CGPoint(x: messageX + 3, y: toY + 5 * direction))
                    path.closeSubpath()
                }, with: .color(theme.accent.cyan))
            case let (from?, nil), let (nil, from?):
                let markY = rowY(from)
                context.fill(
                    Path { path in
                        path.move(to: CGPoint(x: messageX, y: markY - 5))
                        path.addLine(to: CGPoint(x: messageX + 4, y: markY))
                        path.addLine(to: CGPoint(x: messageX, y: markY + 5))
                        path.addLine(to: CGPoint(x: messageX - 4, y: markY))
                        path.closeSubpath()
                    },
                    with: .color(theme.accent.purple)
                )
            case (nil, nil):
                break
            }
        }
    }
}

// MARK: - Horizontal lane graph

/// Git-graph style thread overview: event order runs left to right, each
/// session has a lane from its launch to its last recorded activity, and
/// children branch from their parent's lane and merge back there. This
/// summarizes the thread; it is not an exact execution span. Working sessions
/// end in a pulsing dot at the right edge.
struct SessionThreadLaneGraphView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let members: [Session]
    let rootId: String
    var maxLanes = 4

    static let laneSpacing: CGFloat = 6
    static let inset: CGFloat = 4

    var body: some View {
        let graph = SessionThreadLaneGraph.layout(members: members, rootId: rootId, now: Date(), maxLanes: maxLanes)
        let height = CGFloat(max(graph.laneCount, 1) - 1) * Self.laneSpacing + Self.inset * 2
        HStack(spacing: 4) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in draw(graph, in: &context, size: size) }
                    ForEach(graph.segments.filter(\.isWorking)) { segment in
                        pulse(color: segment.status.tint(theme))
                            .position(
                                x: width - Self.inset,
                                y: Self.inset + CGFloat(segment.lane) * Self.laneSpacing
                            )
                    }
                }
            }
            .frame(height: height)
            if graph.hiddenLaneCount > 0 {
                Text("+\(graph.hiddenLaneCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.themeComment)
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ graph: SessionThreadLaneGraph, in context: inout GraphicsContext, size: CGSize) {
        let usable = max(size.width - Self.inset * 2, 1)
        func x(_ value: Double) -> CGFloat { Self.inset + CGFloat(value) * usable }
        func y(_ lane: Int) -> CGFloat { Self.inset + CGFloat(lane) * Self.laneSpacing }
        let bend: CGFloat = 5
        let solid = StrokeStyle(lineWidth: 1.6, lineCap: .round)
        let dashed = StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [1.5, 3])

        for segment in graph.segments {
            let color = segment.status.tint(theme)
            let startX = x(segment.start)
            let endX = max(x(segment.end), startX + 2)
            let laneY = y(segment.lane)

            guard let parentLane = segment.parentLane else {
                // Root lane: solid while it works, dashed while it waits on children.
                let idleX = segment.idleFrom.map { max(x($0), startX) } ?? endX
                context.stroke(Path { $0.move(to: CGPoint(x: startX, y: laneY)); $0.addLine(to: CGPoint(x: idleX, y: laneY)) },
                               with: .color(color), style: solid)
                if idleX < endX {
                    context.stroke(Path { $0.move(to: CGPoint(x: idleX, y: laneY)); $0.addLine(to: CGPoint(x: endX, y: laneY)) },
                                   with: .color(color), style: dashed)
                }
                continue
            }

            let parentY = y(parentLane)
            let opacity = segment.isStopped ? 0.55 : 1
            var path = Path()
            path.move(to: CGPoint(x: startX, y: parentY))
            if parentY != laneY {
                path.addQuadCurve(to: CGPoint(x: startX + bend, y: laneY), control: CGPoint(x: startX, y: laneY))
            }
            path.addLine(to: CGPoint(x: endX, y: laneY))
            if segment.isStopped, parentY != laneY {
                path.addQuadCurve(to: CGPoint(x: endX + bend, y: parentY), control: CGPoint(x: endX + bend, y: laneY))
            }
            context.stroke(path, with: .color(color.opacity(opacity)), style: solid)
        }
    }

    @ViewBuilder
    private func pulse(color: Color) -> some View {
        let dot = Circle().fill(color).frame(width: 5, height: 5)
        if reduceMotion {
            dot
        } else {
            dot.phaseAnimator([1.0, 0.35]) { view, phase in view.opacity(phase) }
        }
    }
}

// MARK: - Prompt cache badge

/// Warm/cold estimate. Ticks every 15 seconds only while the estimate can
/// change on its own (a warm countdown or a scheduled refresh).
struct SessionPromptCacheBadge: View {
    let session: Session
    let status: SessionPromptCacheStatus?

    var body: some View {
        let now = Date()
        let estimate = SessionPromptCacheEstimate.estimate(session: session, status: status, now: now)
        switch estimate {
        case .warm, .keptWarm:
            TimelineView(.periodic(from: now, by: 15)) { context in
                content(
                    SessionPromptCacheEstimate.estimate(session: session, status: status, now: context.date),
                    now: context.date
                )
            }
        case .inUse, .cold, .unknown:
            content(estimate, now: now)
        }
    }

    @ViewBuilder
    private func content(_ estimate: SessionPromptCacheEstimate, now: Date) -> some View {
        switch estimate {
        case .unknown:
            EmptyView()
        case .inUse:
            // Only a working session uses its cache, so it shares Working's color.
            label("in use", systemImage: "flame.fill", style: .themeBlue)
        case .keptWarm:
            label("kept warm", systemImage: "flame.fill", style: .themeYellow)
        case .warm(let until):
            let minutes = max(1, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
            label("warm \(minutes)m", systemImage: "flame", style: .themeYellow)
        case .cold:
            label("cold", systemImage: "snowflake", style: .themeCyan)
        }
    }

    private func label(_ text: String, systemImage: String, style: ThemeShapeStyle) -> some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(style)
            .accessibilityLabel("Prompt cache \(text)")
    }
}

// MARK: - Thread detail

struct SessionThreadDetailView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.theme) private var theme

    let target: SessionThreadNavTarget

    private enum Mode: String, CaseIterable, Identifiable {
        case outline
        case waterfall
        case timeline
        var id: String { rawValue }
        var label: String {
            switch self {
            case .outline: "Outline"
            case .waterfall: "Waterfall"
            case .timeline: "Timeline"
            }
        }
        var systemImage: String {
            switch self {
            case .outline: "list.bullet.indent"
            case .waterfall: "chart.bar.doc.horizontal"
            case .timeline: "chart.bar.xaxis"
            }
        }
    }

    /// Saved Agent names by id, fetched once per screen for row labels.
    @State private var agentNames: [String: String] = [:]

    @State private var snapshot: SessionThreadSnapshot?

    private var promptCache: [String: SessionPromptCacheStatus] { snapshot?.promptCache ?? [:] }
    @State private var loadError: String?
    @State private var refreshError: String?
    /// Member-change key the current snapshot reflects; avoids refetching for it.
    @State private var loadedMemberKey: String?
    @State private var mode: Mode = .outline
    @State private var filter: SessionThreadTimelineFilter = .all
    @State private var expandedFolds: Set<String> = []
    /// Only the newest load may replace the snapshot.
    @State private var loadGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var connection: ServerConnection? {
        coordinator.connection(for: target.serverId)
    }

    /// Server snapshot with live status from the session store, so the view
    /// follows settles and launches without polling.
    private var liveSnapshot: SessionThreadSnapshot? {
        guard let snapshot else { return nil }
        guard let store = connection?.sessionStore else { return snapshot }
        return SessionThreadSnapshot(
            rootSessionId: snapshot.rootSessionId,
            sessions: snapshot.sessions.map { stored in
                guard var live = store.session(id: stored.id) else { return stored }
                live.parentSessionId = live.parentSessionId ?? stored.parentSessionId
                return live
            },
            interactions: snapshot.interactions,
            counterparts: snapshot.counterparts,
            promptCache: snapshot.promptCache
        )
    }

    /// Changes when a member changes status or a new child of a member appears.
    private var memberKey: String {
        guard let snapshot, let store = connection?.sessionStore else { return "" }
        let memberIds = Set(snapshot.sessions.map(\.id))
        let statuses = snapshot.sessions.map { store.session(id: $0.id)?.status.rawValue ?? "?" }
        let newChildren = store.listProjectionSessions.filter {
            !memberIds.contains($0.id) && $0.parentSessionId.map(memberIds.contains) == true
        }
        return statuses.joined(separator: ",") + "|" + newChildren.map(\.id).sorted().joined(separator: ",")
    }

    var body: some View {
        List {
            if let thread = liveSnapshot {
                header(thread)
                Section {
                    SessionPillToggle(
                        options: Mode.allCases,
                        selection: $mode,
                        label: \.label,
                        systemImage: \.systemImage,
                        accessibilityPrefix: "thread.mode",
                        accessibilityID: \.rawValue
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                }
                switch mode {
                case .outline:
                    outline(thread)
                case .waterfall:
                    Section {
                        SessionThreadWaterfallView(
                            waterfall: SessionThreadWaterfall.build(snapshot: thread, now: Date()),
                            agentNames: agentNames,
                            onOpen: open
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    } footer: {
                        Text("Bars run from launch to last activity on clock time. Arrows are messages between sessions. Pinch to zoom.")
                    }
                case .timeline:
                    timeline(thread)
                }
            } else if let loadError {
                ContentUnavailableView(
                    "Thread Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                HStack {
                    Spacer()
                    ProgressView("Loading thread…")
                    Spacer()
                }
                .frame(minHeight: 120)
            }
        }
        .listStyle(.insetGrouped)
        .themedListSurface()
        .navigationTitle("Thread")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("thread.detail")
        .task { await load() }
        .onChange(of: memberKey) { _, newKey in
            guard snapshot != nil, newKey != loadedMemberKey else { return }
            Task { await load() }
        }
        .refreshable { await load() }
    }

    private func load() async {
        guard let api = connection?.apiClient else {
            loadError = "Server connection is unavailable."
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        if agentNames.isEmpty {
            // Names are labels only; icons come from each session's launch snapshot.
            if let agents = try? await api.listAgents(includeArchived: true) {
                agentNames = Dictionary(agents.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            }
        }
        do {
            let fetched = try await api.getSessionThread(sessionId: target.rootSessionId)
            guard generation == loadGeneration else { return }
            snapshot = fetched
            loadedMemberKey = memberKey
            loadError = nil
            refreshError = nil
        } catch {
            guard generation == loadGeneration else { return }
            if snapshot == nil {
                loadError = error.localizedDescription
            } else {
                refreshError = "Couldn't refresh: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ thread: SessionThreadSnapshot) -> some View {
        let root = thread.sessions.first { $0.id == thread.rootSessionId }
        let others = thread.sessions.filter { $0.id != thread.rootSessionId }
        let working = thread.sessions.filter(SessionThreadGrouping.isWorking).count
        let done = others.count { $0.status == .stopped }
        let cost = thread.sessions.reduce(0) { $0 + $1.cost }
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(root?.displayTitle ?? "Thread")
                    .font(.title2.bold())
                    .foregroundStyle(.themeFg)
                    .accessibilityIdentifier("thread.title")
                Text(headerMeta(root: root, count: thread.sessions.count, cost: cost, sessions: thread.sessions))
                    .font(.subheadline)
                    .foregroundStyle(.themeComment)
                HStack(spacing: 8) {
                    if working > 0 { chip("\(working) working", color: SessionRowStatusKind.working.tint(theme)) }
                    chip("\(done) finished", color: SessionRowStatusKind.stopped.tint(theme))
                    if let root, root.status != .stopped, !SessionThreadGrouping.isWorking(root) {
                        chip("root idle", color: SessionRowStatusKind.done.tint(theme))
                    }
                    if let root {
                        SessionPromptCacheBadge(session: root, status: thread.promptCache[root.id])
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("thread.summary")
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            if let refreshError {
                Label(refreshError, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.themeOrange)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                    .accessibilityIdentifier("thread.refreshError")
            }
        }
    }

    private func headerMeta(root: Session?, count: Int, cost: Double, sessions: [Session]) -> String {
        var parts: [String] = []
        if let workspace = root?.workspaceName, !workspace.isEmpty { parts.append(workspace) }
        parts.append("\(count) sessions")
        if let root {
            parts.append("since \(root.createdAt.formatted(date: .omitted, time: .shortened))")
        }
        parts.append(String(format: "$%.2f", cost))
        let total = sessions.reduce(TokenUsage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)) { sum, session in
            TokenUsage(
                input: sum.input + session.tokens.input,
                output: sum.output + session.tokens.output,
                cacheRead: (sum.cacheRead ?? 0) + (session.tokens.cacheRead ?? 0),
                cacheWrite: (sum.cacheWrite ?? 0) + (session.tokens.cacheWrite ?? 0)
            )
        }
        if let rate = total.cacheHitRate { parts.append("\(Int((rate * 100).rounded()))% cached") }
        return parts.joined(separator: " · ")
    }

    private func chip(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.footnote.weight(.semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.16), in: Capsule())
    }

    // MARK: Outline

    private enum OutlineEntry: Identifiable {
        case session(Session, depth: Int)
        case fold(parentId: String, children: [Session], depth: Int)

        var id: String {
            switch self {
            case .session(let session, _): "session:\(session.id)"
            case .fold(let parentId, _, _): "fold:\(parentId)"
            }
        }
    }

    /// Depth-first tree. A parent's stopped children with no live descendants
    /// fold into one "N finished" row; live work always stays visible.
    private func outlineEntries(_ thread: SessionThreadSnapshot) -> [OutlineEntry] {
        let childrenByParent = Dictionary(grouping: thread.sessions.filter { $0.id != thread.rootSessionId }) {
            $0.parentSessionId ?? thread.rootSessionId
        }
        func hasLiveWork(_ session: Session) -> Bool {
            session.status != .stopped || (childrenByParent[session.id] ?? []).contains(where: hasLiveWork)
        }
        var entries: [OutlineEntry] = []
        var visited: Set<String> = []
        func visit(_ session: Session, depth: Int) {
            guard visited.insert(session.id).inserted else { return }
            entries.append(.session(session, depth: depth))
            let children = (childrenByParent[session.id] ?? []).sorted { $0.createdAt < $1.createdAt }
            let finished = children.filter { !hasLiveWork($0) }
            if !finished.isEmpty {
                entries.append(.fold(parentId: session.id, children: finished, depth: depth + 1))
                if expandedFolds.contains(session.id) {
                    for child in finished { visit(child, depth: depth + 2) }
                }
            }
            for child in children where hasLiveWork(child) { visit(child, depth: depth + 1) }
        }
        if let root = thread.sessions.first(where: { $0.id == thread.rootSessionId }) {
            visit(root, depth: 0)
        }
        return entries
    }

    @ViewBuilder
    private func outline(_ thread: SessionThreadSnapshot) -> some View {
        Section {
            ForEach(outlineEntries(thread)) { entry in
                switch entry {
                case .session(let session, let depth):
                    outlineRow(session, depth: depth)
                case .fold(let parentId, let children, let depth):
                    foldRow(parentId: parentId, children: children, depth: depth)
                }
            }
        }
        if !thread.counterparts.isEmpty {
            Section("Cross-thread messages") {
                ForEach(thread.counterparts, id: \.id) { counterpart in
                    counterpartRow(counterpart, thread: thread)
                }
            }
        }
    }

    private func hasPendingQuestion(_ session: Session) -> Bool {
        guard let connection else { return false }
        return SessionListAttentionMerger.askCount(
            listCount: connection.sessionStore.listPendingAskCount(for: session.id),
            hasPendingAsk: connection.askRequestStore.hasPending(for: session.id),
            hasPendingExtensionDialog: connection.hasPendingExtensionDialog(for: session.id)
        ) > 0
    }

    private func outlineRow(_ session: Session, depth: Int) -> some View {
        let question = hasPendingQuestion(session)
        return Button {
            open(session)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                SessionThreadIdentityBadge(session: session, hasQuestion: question)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(session.displayTitle)
                            .font(.body.weight(depth == 0 ? .semibold : .regular))
                            .foregroundStyle(session.status == .stopped ? theme.text.secondary : theme.text.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        SessionPromptCacheBadge(session: session, status: promptCache[session.id])
                    }
                    HStack(spacing: 4) {
                        if let model = modelSummary(session) {
                            if !model.provider.isEmpty { ProviderIcon(provider: model.provider, size: 11) }
                            Text(model.label)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("·")
                        }
                        Text(outlineSubtitle(session))
                            .lineLimit(1)
                    }
                    .font(.footnote)
                    .foregroundStyle(SessionThreadGrouping.isWorking(session) ? SessionRowStatusKind.working.tint(theme) : theme.text.tertiary)
                }
            }
            .padding(.leading, CGFloat(depth) * 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(question ? "Question pending" : "")
        .accessibilityIdentifier("thread.row.\(session.id)")
        // Same actions and tints as the inbox row: Stop anything not stopped
        // (idle included), Resume a stopped session.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) { lifecycleButton(session) }
        .contextMenu {
            Button { open(session) } label: { Label("Open", systemImage: "bubble.left.and.text.bubble.right") }
            lifecycleButton(session)
        }
    }

    @ViewBuilder
    private func lifecycleButton(_ session: Session) -> some View {
        if session.status == .stopped {
            Button {
                Task { await setRunning(session, running: true) }
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .tint(.themeGreen)
            .accessibilityIdentifier("thread.resume.\(session.id)")
        } else {
            Button {
                Task { await setRunning(session, running: false) }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .tint(.themeOrange)
            .accessibilityIdentifier("thread.stop.\(session.id)")
        }
    }

    private func setRunning(_ session: Session, running: Bool) async {
        guard let connection, let api = connection.apiClient,
              let scope = SessionInboxSessionRouting.routeScope(for: session) else { return }
        do {
            let updated = running
                ? try await api.resumeSession(scope: scope, sessionId: session.id)
                : try await api.stopSession(scope: scope, sessionId: session.id)
            connection.sessionStore.upsert(updated)
            await load()
        } catch {
            refreshError = "\(running ? "Resume" : "Stop") failed: \(error.localizedDescription)"
        }
    }

    private func modelSummary(_ session: Session) -> SessionModelSummary? {
        SessionModelSummaryBuilder.summaries(
            primaryModel: session.model,
            catalogModels: connection?.chatState.cachedModels ?? []
        ).first
    }

    private func outlineSubtitle(_ session: Session) -> String {
        var parts: [String] = []
        parts.append(String(format: "$%.2f", session.cost))
        if let rate = session.tokens.cacheHitRate { parts.append("\(Int((rate * 100).rounded()))% cached") }
        if SessionThreadGrouping.isWorking(session) {
            parts.append("working")
        } else if session.status == .stopped {
            parts.append("stopped \(session.lastActivity.formatted(date: .omitted, time: .shortened))")
        } else {
            parts.append("idle since \(session.lastActivity.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    private func foldRow(parentId: String, children: [Session], depth: Int) -> some View {
        let expanded = expandedFolds.contains(parentId)
        let cost = children.reduce(0) { $0 + $1.cost }
        return Button {
            withAnimation(ThemeMotion.animation(.snappy, reduceMotion: reduceMotion)) {
                if expanded { expandedFolds.remove(parentId) } else { expandedFolds.insert(parentId) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeComment)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("\(children.count) finished")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.themeFg)
                        SessionThreadAgentCluster(groups: SessionThreadAgentGroup.groups(children), maxGroups: 4)
                    }
                    Text(agentSummary(children) + String(format: " · $%.2f", cost))
                        .font(.footnote)
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                }
            }
            .padding(.leading, CGFloat(depth) * 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("thread.fold.\(parentId)")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }

    /// "Worker ×3 · Reviewer ×2 · Pi ×1"
    private func agentSummary(_ sessions: [Session]) -> String {
        SessionThreadAgentGroup.groups(sessions).map { group in
            let name = group.agentId.map { agentNames[$0] ?? "Agent" } ?? "Pi"
            return group.count > 1 ? "\(name) ×\(group.count)" : name
        }.joined(separator: " · ")
    }

    private func counterpartRow(_ counterpart: SessionThreadCounterpart, thread: SessionThreadSnapshot) -> some View {
        let related = thread.interactions.filter {
            $0.fromSessionId == counterpart.id || $0.toSessionId == counterpart.id
        }
        let latest = related.last
        return Button {
            Task { await openCounterpart(counterpart) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.themePurple)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(counterpart.name ?? String(counterpart.id.prefix(8)))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)
                    Text(counterpartSubtitle(counterpart, latest: latest, count: related.count))
                        .font(.footnote)
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeComment)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("thread.counterpart.\(counterpart.id)")
    }

    private func counterpartSubtitle(
        _ counterpart: SessionThreadCounterpart,
        latest: SessionInteraction?,
        count: Int
    ) -> String {
        var parts: [String] = []
        if let latest {
            let verb = SessionThreadTimeline.verb(for: latest.kind)
            parts.append("\(verb) \(latest.at.formatted(date: .omitted, time: .shortened))")
        }
        if count > 1 { parts.append("\(count) messages") }
        if let rootName = counterpart.rootName { parts.append("in \(rootName)") }
        return parts.joined(separator: " · ")
    }

    // MARK: Timeline

    @ViewBuilder
    private func timeline(_ thread: SessionThreadSnapshot) -> some View {
        let layout = SessionThreadTimeline.build(snapshot: thread, now: Date(), filter: filter)
        Section {
            filterBar
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
        }
        Section {
            ForEach(layout.rows) { row in
                Button {
                    if case .crossThread(_, let counterpart, _) = row.kind {
                        Task { await openCounterpart(counterpart) }
                    } else if let session = thread.sessions.first(where: { $0.id == row.sessionId }) {
                        open(session)
                    }
                } label: {
                    SessionThreadTimelineRowView(row: row, laneCount: layout.laneCount)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("thread.timeline.\(row.id)")
            }
        } footer: {
            Text("Launch = created, stop = last activity. Messages and control come from the interaction log.")
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip("Launches", .launches, id: "launches")
                filterChip("Messages", .messages, id: "messages")
                filterChip("Control", .control, id: "control")
                filterChip("Ends", .ends, id: "ends")
                filterChip("Cross-thread", .crossThread, id: "crossThread")
            }
            .padding(.vertical, 2)
        }
    }

    private func filterChip(_ title: String, _ option: SessionThreadTimelineFilter, id: String) -> some View {
        let isOn = filter.contains(option)
        return Button {
            withAnimation(ThemeMotion.animation(.snappy, reduceMotion: reduceMotion)) {
                if isOn { filter.remove(option) } else { filter.insert(option) }
            }
        } label: {
            Text(title)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isOn ? theme.text.primary : theme.text.tertiary)
                .background(
                    Capsule().fill(isOn ? theme.accent.blue.opacity(0.28) : theme.text.tertiary.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("thread.filter.\(id)")
        .accessibilityValue(isOn ? "On" : "Off")
    }

    // MARK: Navigation

    private func open(_ session: Session) {
        guard let connection,
              let routeScope = SessionInboxSessionRouting.routeScope(for: session) else { return }
        connection.sessionStore.cacheSessionForNavigation(session)
        navigation.openReferencedSession(
            WorkspaceSessionNavTarget(serverId: target.serverId, sessionId: session.id, routeScope: routeScope)
        )
    }

    /// Open a session outside this thread: the live store first, then the
    /// authoritative server record. Chat needs the real session (its status) in
    /// the store before it opens, or a stopped session outside the recent list
    /// would look unknown and its stream would start it.
    private func openCounterpart(_ counterpart: SessionThreadCounterpart) async {
        guard let connection else { return }
        if let known = connection.sessionStore.session(id: counterpart.id) {
            open(known)
            return
        }
        let name = counterpart.name ?? "session"
        guard let api = connection.apiClient else {
            refreshError = "Couldn't open \(name): not connected to the server"
            return
        }
        do {
            open(try await api.getSessionRecord(sessionId: counterpart.id))
        } catch {
            refreshError = "Couldn't open \(name): \(error.localizedDescription)"
        }
    }
}

// MARK: - Timeline row

/// One git-graph row: lane segments, the event node, and its label.
struct SessionThreadTimelineRowView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let row: SessionThreadTimelineRow
    let laneCount: Int

    static let laneSpacing: CGFloat = 16
    static let rowHeight: CGFloat = 40

    /// A lane takes the status color of the session drawing it on this row.
    private func laneColor(_ lane: Int) -> Color {
        row.laneStatus[lane]?.tint(theme) ?? theme.text.tertiary
    }

    private var graphWidth: CGFloat {
        CGFloat(max(laneCount, 1)) * Self.laneSpacing + 12
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(row.at?.formatted(date: .omitted, time: .shortened) ?? "now")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.themeComment)
                .frame(width: 56, alignment: .leading)
            graph
                .frame(width: graphWidth, height: Self.rowHeight)
            VStack(alignment: .leading, spacing: 1) {
                Text(titleText)
                    .font(.subheadline)
                    .lineLimit(1)
                if let detail = row.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var titleText: AttributedString {
        let (verb, color): (String, Color) = switch row.kind {
        case .start: ("start ", theme.text.tertiary)
        case .launch: ("launch ", theme.text.tertiary)
        case .end: ("stop ", theme.text.tertiary)
        case .interaction(let kind, _): ("\(SessionThreadTimeline.verb(for: kind)) ", theme.accent.cyan)
        case .crossThread: ("↗ ", theme.accent.purple)
        case .working: ("", SessionRowStatusKind.working.tint(theme))
        }
        var prefix = AttributedString(verb)
        prefix.foregroundColor = color
        var title = AttributedString(row.title)
        switch row.kind {
        case .crossThread: title.foregroundColor = theme.accent.purple
        case .working: title.foregroundColor = SessionRowStatusKind.working.tint(theme)
        case .end: title.foregroundColor = theme.text.secondary
        default: title.foregroundColor = theme.text.primary
        }
        return prefix + title
    }

    @ViewBuilder
    private var graph: some View {
        if case .working = row.kind, !reduceMotion {
            TimelineView(.animation) { context in
                let phase = 0.55 + 0.45 * sin(context.date.timeIntervalSinceReferenceDate * 4)
                canvas(pulse: phase)
            }
        } else {
            canvas(pulse: 1)
        }
    }

    private func canvas(pulse: Double) -> some View {
        Canvas { context, size in
            let mid = size.height / 2
            func x(_ lane: Int) -> CGFloat { 8 + CGFloat(lane) * Self.laneSpacing }
            func stroke(_ path: Path, _ lane: Int, dashed: Bool = false, opacity: Double = 1) {
                context.stroke(
                    path,
                    with: .color(laneColor(lane).opacity(opacity)),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: dashed ? [2, 4] : [])
                )
            }
            for lane in row.lanesAbove {
                stroke(Path { $0.move(to: CGPoint(x: x(lane), y: 0)); $0.addLine(to: CGPoint(x: x(lane), y: mid)) },
                       lane, dashed: row.idleLanes.contains(lane))
            }
            for lane in row.lanesBelow {
                stroke(Path { $0.move(to: CGPoint(x: x(lane), y: mid)); $0.addLine(to: CGPoint(x: x(lane), y: size.height)) },
                       lane, dashed: row.idleLanes.contains(lane))
            }
            let node = CGPoint(x: x(row.lane), y: mid)
            func dot(_ point: CGPoint, color: Color, radius: CGFloat = 4.5, hollow: Bool = false) {
                let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                if hollow {
                    // Punch through the lane line so the row background shows in any theme.
                    var cutout = context
                    cutout.blendMode = .clear
                    cutout.fill(Path(ellipseIn: rect), with: .color(.black))
                    context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 2)
                } else {
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
            switch row.kind {
            case .start:
                dot(node, color: laneColor(row.lane), radius: 5)
            case .launch(let parentLane):
                if let parentLane {
                    stroke(Path {
                        $0.move(to: CGPoint(x: x(parentLane), y: 0))
                        $0.addCurve(to: node,
                                    control1: CGPoint(x: x(parentLane), y: mid * 0.7),
                                    control2: CGPoint(x: node.x, y: mid * 0.3))
                    }, row.lane)
                }
                dot(node, color: laneColor(row.lane))
            case .end(let parentLane):
                if let parentLane {
                    stroke(Path {
                        $0.move(to: node)
                        $0.addCurve(to: CGPoint(x: x(parentLane), y: size.height),
                                    control1: CGPoint(x: node.x, y: mid * 1.7),
                                    control2: CGPoint(x: x(parentLane), y: mid * 1.3))
                    }, row.lane, opacity: 0.55)
                }
                dot(node, color: laneColor(row.lane), hollow: true)
            case .interaction(_, let fromLane):
                let from = CGPoint(x: x(fromLane), y: mid)
                context.stroke(Path { $0.move(to: from); $0.addLine(to: node) },
                               with: .color(theme.accent.cyan),
                               style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                dot(from, color: theme.accent.cyan, radius: 3)
                dot(node, color: theme.accent.cyan, radius: 4)
            case .crossThread:
                context.stroke(Path { $0.move(to: node); $0.addLine(to: CGPoint(x: size.width, y: mid)) },
                               with: .color(theme.accent.purple),
                               style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                dot(node, color: theme.accent.purple, radius: 4)
            case .working(let lanes):
                for lane in lanes {
                    let working = SessionRowStatusKind.working.tint(theme)
                    dot(CGPoint(x: x(lane), y: mid), color: working.opacity(0.35), radius: 4 + 4 * pulse)
                    dot(CGPoint(x: x(lane), y: mid), color: working)
                }
            }
        }
    }
}

// MARK: - Pill toggle

/// Compact two-or-more option switch. The selected option slides inside one
/// capsule instead of a full-width tab bar. Used for the thread Outline /
/// Timeline switch.
struct SessionPillToggle<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String
    let systemImage: (Option) -> String
    let accessibilityPrefix: String
    let accessibilityID: (Option) -> String

    @Namespace private var highlight
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = option == selection
                Button {
                    withAnimation(ThemeMotion.animation(.snappy(duration: 0.25), reduceMotion: reduceMotion)) {
                        selection = option
                    }
                } label: {
                    Label(label(option), systemImage: systemImage(option))
                        .font(.footnote.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(isSelected ? theme.text.primary : theme.text.tertiary)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 38)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(theme.accent.blue.opacity(0.22))
                                    .matchedGeometryEffect(id: "selection", in: highlight)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(accessibilityPrefix).\(accessibilityID(option))")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(theme.text.tertiary.opacity(0.12)))
        .accessibilityElement(children: .contain)
    }
}
