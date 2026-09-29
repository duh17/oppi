import SwiftUI

// MARK: - Status glyph

/// Compact status mark shared by thread strips, outline rows, and timeline nodes.
struct SessionThreadStatusGlyph: View {
    let session: Session

    var body: some View {
        Group {
            if SessionThreadGrouping.isWorking(session) {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.themeGreen)
                    .symbolEffect(.pulse, options: .repeating)
            } else {
                switch session.status {
                case .stopped:
                    Image(systemName: "checkmark").foregroundStyle(.themeComment)
                case .error:
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.themeRed)
                default:
                    Image(systemName: "circle.fill").foregroundStyle(.themeOrange)
                }
            }
        }
        .font(.system(size: 9, weight: .bold))
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

// MARK: - Inbox thread strip

/// One-line summary under a thread root row: who is working, member dots, totals.
struct SessionThreadStrip: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let rollup: SessionThreadRollup
    /// Member with a pending question, shown so the user knows where to answer.
    var attentionMember: Session?

    private static let maxDots = 24

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
                    .foregroundStyle(.themeGreen)
                    .lineLimit(1)
            }
            HStack(spacing: 5) {
                HStack(spacing: 3) {
                    dot(for: rollup.root)
                    Rectangle().fill(theme.text.tertiary.opacity(0.5)).frame(width: 5, height: 1.5)
                    ForEach(Array(rollup.descendants.prefix(Self.maxDots)), id: \.id) { dot(for: $0) }
                }
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var summary: String {
        let extra = rollup.descendants.count - Self.maxDots
        var parts: [String] = []
        if extra > 0 { parts.append("+\(extra)") }
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

    @ViewBuilder
    private func dot(for session: Session) -> some View {
        let circle = Circle().fill(dotColor(session)).frame(width: 7, height: 7)
        if SessionThreadGrouping.isWorking(session), !reduceMotion {
            circle.phaseAnimator([1.0, 0.35]) { view, phase in view.opacity(phase) }
        } else {
            circle
        }
    }

    private func dotColor(_ session: Session) -> Color {
        if SessionThreadGrouping.isWorking(session) { return theme.accent.green }
        switch session.status {
        case .stopped: return theme.text.tertiary.opacity(0.55)
        case .error: return theme.accent.red
        default: return theme.accent.orange
        }
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
        case timeline
        var id: String { rawValue }
        var label: String { self == .outline ? "Outline" : "Timeline" }
        var systemImage: String { self == .outline ? "list.bullet.indent" : "chart.bar.xaxis" }
    }

    @State private var snapshot: SessionThreadSnapshot?
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
            counterparts: snapshot.counterparts
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
                Text(headerMeta(root: root, count: thread.sessions.count, cost: cost))
                    .font(.subheadline)
                    .foregroundStyle(.themeComment)
                HStack(spacing: 8) {
                    if working > 0 { chip("\(working) working", color: theme.accent.green) }
                    chip("\(done) done", color: theme.text.tertiary)
                    if let root, root.status != .stopped, !SessionThreadGrouping.isWorking(root) {
                        chip("root idle", color: theme.accent.orange)
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

    private func headerMeta(root: Session?, count: Int, cost: Double) -> String {
        var parts: [String] = []
        if let workspace = root?.workspaceName, !workspace.isEmpty { parts.append(workspace) }
        parts.append("\(count) sessions")
        if let root {
            parts.append("since \(root.createdAt.formatted(date: .omitted, time: .shortened))")
        }
        parts.append(String(format: "$%.2f", cost))
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if question {
                    Image(systemName: "questionmark.bubble.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.themeOrange)
                        .frame(width: 14, height: 14)
                } else {
                    SessionThreadStatusGlyph(session: session)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.body.weight(depth == 0 ? .semibold : .regular))
                        .foregroundStyle(session.status == .stopped ? theme.text.secondary : theme.text.primary)
                        .lineLimit(1)
                    Text(outlineSubtitle(session))
                        .font(.footnote)
                        .foregroundStyle(SessionThreadGrouping.isWorking(session) ? theme.accent.green : theme.text.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, CGFloat(depth) * 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(question ? "Question pending" : "")
        .accessibilityIdentifier("thread.row.\(session.id)")
    }

    private func outlineSubtitle(_ session: Session) -> String {
        var parts: [String] = []
        if let model = session.model { parts.append(SessionThreadDetailView.shortModel(model)) }
        parts.append("\(session.messageCount) msgs")
        parts.append(String(format: "$%.2f", session.cost))
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
                    Text("\(children.count) finished")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.themeFg)
                    Text(children.map(\.displayTitle).joined(separator: " · ") + String(format: " · $%.2f", cost))
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

    private func counterpartRow(_ counterpart: SessionThreadCounterpart, thread: SessionThreadSnapshot) -> some View {
        let related = thread.interactions.filter {
            $0.fromSessionId == counterpart.id || $0.toSessionId == counterpart.id
        }
        let latest = related.last
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.up.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.themeBlue)
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
        }
        .accessibilityElement(children: .combine)
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
                    if let session = thread.sessions.first(where: { $0.id == row.sessionId }) {
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

    static func shortModel(_ model: String) -> String {
        let last = model.split(separator: "/").last.map(String.init) ?? model
        return last.replacingOccurrences(of: "claude-", with: "")
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

    private func laneColor(_ lane: Int) -> Color {
        let palette = [
            theme.accent.orange, theme.accent.cyan, theme.accent.purple,
            theme.accent.red, theme.accent.blue, theme.accent.yellow,
        ]
        return palette[lane % palette.count]
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
        case .crossThread: ("↗ ", theme.accent.blue)
        case .working: ("", theme.accent.green)
        }
        var prefix = AttributedString(verb)
        prefix.foregroundColor = color
        var title = AttributedString(row.title)
        switch row.kind {
        case .crossThread: title.foregroundColor = theme.accent.blue
        case .working: title.foregroundColor = theme.accent.green
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
                               with: .color(theme.accent.blue),
                               style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                dot(node, color: theme.accent.blue, radius: 4)
            case .working(let lanes):
                for lane in lanes {
                    dot(CGPoint(x: x(lane), y: mid), color: theme.accent.green.opacity(0.35), radius: 4 + 4 * pulse)
                    dot(CGPoint(x: x(lane), y: mid), color: theme.accent.green)
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
