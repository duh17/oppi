#if DEBUG
import os
import SwiftUI
import UIKit

/// Debug-only harness for profiling the workspace-list → timeline toolbar handoff.
///
/// Launch with `--nav-chrome-profile` or `PI_NAV_CHROME_PROFILE=1` on Simulator.
/// Add `PI_NAV_CHROME_AUTORUN=1` to push into the heavy timeline automatically.
enum NavigationChromeProfileConfig {
    private static let environment = ProcessInfo.processInfo.environment
    private static let arguments = ProcessInfo.processInfo.arguments

    static var isEnabled: Bool {
#if targetEnvironment(simulator)
        arguments.contains("--nav-chrome-profile") || environment["PI_NAV_CHROME_PROFILE"] == "1"
#else
        false
#endif
    }

    static var autorun: Bool {
        arguments.contains("--nav-chrome-profile-autorun") || environment["PI_NAV_CHROME_AUTORUN"] == "1"
    }

    static var repeatCount: Int {
        guard let raw = environment["PI_NAV_CHROME_REPEAT"],
              let value = Int(raw) else { return 1 }
        return max(1, min(value, 10))
    }

    static var firstDelayMs: Int {
        guard let raw = environment["PI_NAV_CHROME_FIRST_DELAY_MS"],
              let value = Int(raw) else { return 1_200 }
        return max(0, value)
    }

    static var dwellMs: Int {
        guard let raw = environment["PI_NAV_CHROME_DWELL_MS"],
              let value = Int(raw) else { return 3_200 }
        return max(500, value)
    }

    static var lightDestination: Bool {
        arguments.contains("--nav-chrome-light") || environment["PI_NAV_CHROME_LIGHT"] == "1"
    }

    static var heavyList: Bool {
        arguments.contains("--nav-chrome-heavy-list") || environment["PI_NAV_CHROME_HEAVY_LIST"] == "1"
    }
}

@MainActor
enum NavigationChromeProfiler {
    private static let logger = Logger(
        subsystem: AppIdentifiers.subsystem,
        category: "NavChromeProfile"
    )
    private static let signposter = OSSignposter(
        subsystem: AppIdentifiers.subsystem,
        category: "NavChromeProfile"
    )
    private static var startNs: UInt64?

    static func reset(label: String) {
        startNs = nowNs()
        logger.notice("event=reset label=\(label, privacy: .public)")
        signposter.emitEvent("nav.mark")
    }

    static func mark(_ event: String, metadata: [String: String] = [:]) {
        let elapsedMs: Int
        if let startNs {
            elapsedMs = Int((nowNs() &- startNs) / 1_000_000)
        } else {
            elapsedMs = 0
            startNs = nowNs()
        }

        let metadataText = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")

        logger.notice(
            "event=\(event, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public) \(metadataText, privacy: .public)"
        )
        signposter.emitEvent("nav.mark")
    }

    private static func nowNs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

@MainActor
private final class NavigationChromeFrameProbe: NSObject {
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var sampleCount = 0
    private var over34MsCount = 0
    private var over50MsCount = 0
    private var maxGapMs: Double = 0
    private var label = ""

    func start(label: String) {
        stop(reason: "restart")
        self.label = label
        sampleCount = 0
        over34MsCount = 0
        over50MsCount = 0
        maxGapMs = 0
        lastTimestamp = nil

        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        NavigationChromeProfiler.mark("frame_probe_start", metadata: ["label": label])
    }

    func stop(reason: String) {
        guard let displayLink else { return }
        displayLink.invalidate()
        self.displayLink = nil
        NavigationChromeProfiler.mark(
            "frame_probe_stop",
            metadata: [
                "label": label,
                "reason": reason,
                "samples": String(sampleCount),
                "maxGapMs": String(format: "%.1f", maxGapMs),
                "over34Ms": String(over34MsCount),
                "over50Ms": String(over50MsCount),
            ]
        )
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard let lastTimestamp else { return }

        sampleCount += 1
        let gapMs = (link.timestamp - lastTimestamp) * 1_000
        maxGapMs = max(maxGapMs, gapMs)
        if gapMs > 34 { over34MsCount += 1 }
        if gapMs > 50 { over50MsCount += 1 }
    }
}

struct NavigationChromeProfileHarnessView: View {
    private static let heavyRows = NavigationChromeProfileListFixtures.makeRows(rootCount: 260, childrenPerRoot: 3)

    @State private var path = NavigationPath()
    @State private var frameProbe = NavigationChromeFrameProbe()
    @State private var hasStartedAutorun = false

    private var sourceRows: [NavigationChromeProfileListFixtures.RowSummary] {
        guard NavigationChromeProfileConfig.heavyList else {
            return [NavigationChromeProfileListFixtures.RowSummary(id: "timeline-manual", title: "Heavy timeline", detail: "Native NavigationLink path")]
        }

        let startNs = DispatchTime.now().uptimeNanoseconds
        let rows = Self.heavyRows
        var childrenByParent: [String: [NavigationChromeProfileListFixtures.Row]] = [:]
        childrenByParent.reserveCapacity(rows.count / 2)
        for row in rows {
            guard let parentId = row.parentId else { continue }
            childrenByParent[parentId, default: []].append(row)
        }

        let summaries = rows
            .filter { $0.parentId == nil }
            .sorted { lhs, rhs in
                if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
                return lhs.id < rhs.id
            }
            .map { row in
                let children = childrenByParent[row.id] ?? []
                let activeChildren = children.filter { $0.status != "stopped" }.count
                let detail = "\(children.count) children • \(activeChildren) active • $\(String(format: "%.2f", row.cost + children.reduce(0) { $0 + $1.cost }))"
                return NavigationChromeProfileListFixtures.RowSummary(
                    id: row.id,
                    title: row.title,
                    detail: detail
                )
            }

        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000)
        NavigationChromeProfiler.mark(
            "source_list_compute",
            metadata: ["durationMs": String(durationMs), "rows": String(rows.count), "roots": String(summaries.count)]
        )
        return summaries
    }

    var body: some View {
        NavigationStack(path: $path) {
            sessionList
                .navigationTitle("Profile Workspace")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarVisibility(.hidden, for: .tabBar)
                .toolbarVisibility(.automatic, for: .bottomBar)
                .toolbar { bottomToolbar }
                .navigationDestination(for: String.self) { route in
                    NavigationChromeProfileTimelineDestination(route: route)
                }
        }
        .onAppear {
            NavigationChromeProfiler.reset(label: "nav_chrome_profile")
            NavigationChromeProfiler.mark("harness_appear")
        }
        .task {
            await runAutorunIfNeeded()
        }
        .onDisappear {
            frameProbe.stop(reason: "harness_disappear")
        }
    }

    private var sessionList: some View {
        List {
            Section("Your Turn") {
                ForEach(sourceRows) { row in
                    NavigationLink(value: row.id) {
                        profileSessionRow(title: row.title, detail: row.detail)
                    }
                    .accessibilityIdentifier("navChrome.session.\(row.id)")
                    .listRowBackground(Color.themeBg)
                }
            }

            Section("Profiler") {
                Button("Run profile push") {
                    openTimeline(route: "timeline-button")
                }
                .accessibilityIdentifier("navChrome.run")
                .listRowBackground(Color.themeBg)

                Text("Autorun: \(NavigationChromeProfileConfig.autorun ? "on" : "off")")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .listRowBackground(Color.themeBg)
                Text("Heavy list: \(NavigationChromeProfileConfig.heavyList ? "on" : "off")")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .listRowBackground(Color.themeBg)
            }
        }
        .accessibilityIdentifier("navChrome.sessionList")
        .listStyle(.insetGrouped)
        .themedListSurface()
    }

    private var bottomToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Image(systemName: "folder")
                .accessibilityIdentifier("navChrome.bottom.folder")
            Text("3 skills")
                .font(.caption2)
                .accessibilityIdentifier("navChrome.bottom.skills")
            Spacer()
            Image(systemName: "lock.open.fill")
                .accessibilityIdentifier("navChrome.bottom.policy")
        }
    }

    private func profileSessionRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.themeFg)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.themeComment)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private func runAutorunIfNeeded() async {
        guard NavigationChromeProfileConfig.autorun, !hasStartedAutorun else { return }
        hasStartedAutorun = true

        try? await Task.sleep(for: .milliseconds(NavigationChromeProfileConfig.firstDelayMs))
        for index in 1...NavigationChromeProfileConfig.repeatCount {
            if Task.isCancelled { return }
            openTimeline(route: "timeline-autorun-\(index)")
            try? await Task.sleep(for: .milliseconds(NavigationChromeProfileConfig.dwellMs))
            frameProbe.stop(reason: "dwell_complete")
            if !path.isEmpty {
                NavigationChromeProfiler.mark("path_remove_start", metadata: ["run": String(index)])
                path.removeLast()
                NavigationChromeProfiler.mark("path_remove_end", metadata: ["run": String(index)])
            }
            try? await Task.sleep(for: .milliseconds(700))
        }
    }

    private func openTimeline(route: String) {
        frameProbe.start(label: route)
        NavigationChromeProfiler.mark("path_append_start", metadata: ["route": route])
        path.append(route)
        NavigationChromeProfiler.mark("path_append_end", metadata: ["route": route])
    }
}

private struct NavigationChromeProfileTimelineDestination: View {
    let route: String

    var body: some View {
        Group {
            if NavigationChromeProfileConfig.lightDestination {
                NavigationChromeProfileLightDestination(route: route)
            } else {
                NavigationChromeProfileHeavyTimelineDestination(route: route)
            }
        }
        .navigationTitle("Profile Timeline")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .bottomBar)
        .onAppear {
            NavigationChromeProfiler.mark(
                "timeline_appear",
                metadata: [
                    "route": route,
                    "mode": NavigationChromeProfileConfig.lightDestination ? "light" : "heavy",
                ]
            )
        }
        .onDisappear {
            NavigationChromeProfiler.mark("timeline_disappear", metadata: ["route": route])
        }
    }
}

private struct NavigationChromeProfileHeavyTimelineDestination: View {
    private static let initialRenderWindow = 80
    private static let renderWindowStep = 60
    private static let traceEvents = NavigationChromeProfileTimelineFixtures.makeTraceEvents(turnCount: 180)

    let route: String

    @State private var connection = ServerConnection()
    @State private var reducer = TimelineReducer()
    @State private var scrollController = ChatScrollController()
    @State private var renderWindow = initialRenderWindow
    @State private var scrollCommandNonce = 0
    @State private var pendingScrollCommand: ChatTimelineScrollCommand?

    private var visibleItems: [ChatItem] {
        Array(reducer.items.suffix(renderWindow))
    }

    private var hiddenCount: Int {
        max(0, reducer.items.count - visibleItems.count)
    }

    var body: some View {
        ChatTimelineCollectionHost(
            configuration: .init(
                items: visibleItems,
                hiddenCount: hiddenCount,
                renderWindowStep: Self.renderWindowStep,
                isBusy: false,
                streamingAssistantID: nil,
                sessionId: route,
                workspaceId: "nav-chrome-profile-workspace",
                onFork: { _ in },
                onShowEarlier: {
                    renderWindow = min(reducer.items.count, renderWindow + Self.renderWindowStep)
                },
                scrollCommand: pendingScrollCommand,
                scrollController: scrollController,
                reducer: reducer,
                toolOutputStore: reducer.toolOutputStore,
                toolArgsStore: reducer.toolArgsStore,
                toolSegmentStore: reducer.toolSegmentStore,
                toolDetailsStore: reducer.toolDetailsStore,
                connection: connection,
                currentModel: "profile/model",
                audioPlayer: connection.audioPlayer
            )
        )
        .background(Color.themeBg)
        .onAppear {
            NavigationChromeProfiler.mark(
                "heavy_timeline_host_appear",
                metadata: [
                    "route": route,
                    "events": String(Self.traceEvents.count),
                    "visible": String(visibleItems.count),
                ]
            )
            loadSyntheticTraceIfNeeded()
        }
    }

    private func loadSyntheticTraceIfNeeded() {
        guard reducer.items.isEmpty else { return }
        let startNs = DispatchTime.now().uptimeNanoseconds
        NavigationChromeProfiler.mark(
            "reducer_load_start",
            metadata: ["events": String(Self.traceEvents.count), "route": route]
        )
        reducer.loadSession(Self.traceEvents)
        renderWindow = TimelineRenderWindowPolicy.syncedWindow(
            currentWindow: renderWindow,
            totalItems: reducer.items.count
        )
        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000)
        NavigationChromeProfiler.mark(
            "reducer_load_end",
            metadata: [
                "durationMs": String(durationMs),
                "items": String(reducer.items.count),
                "route": route,
            ]
        )
        if let bottomID = visibleItems.last?.id {
            issueScrollCommand(id: bottomID, anchor: .bottom, animated: false)
        }
    }

    private func issueScrollCommand(id: String, anchor: ChatTimelineScrollCommand.Anchor, animated: Bool) {
        scrollCommandNonce &+= 1
        pendingScrollCommand = ChatTimelineScrollCommand(
            id: id,
            anchor: anchor,
            animated: animated,
            nonce: scrollCommandNonce
        )
    }
}

private enum NavigationChromeProfileListFixtures {
    struct Row: Identifiable {
        let id: String
        let parentId: String?
        let title: String
        let status: String
        let lastActivity: Date
        let cost: Double
    }

    struct RowSummary: Identifiable {
        let id: String
        let title: String
        let detail: String
    }

    static func makeRows(rootCount: Int, childrenPerRoot: Int) -> [Row] {
        var rows: [Row] = []
        rows.reserveCapacity(rootCount * (childrenPerRoot + 1))
        let now = Date(timeIntervalSince1970: 1_770_000_000)

        for root in 0..<rootCount {
            let rootId = "profile-root-\(root)"
            rows.append(Row(
                id: rootId,
                parentId: nil,
                title: "Profile session \(root)",
                status: root.isMultiple(of: 9) ? "ready" : "busy",
                lastActivity: now.addingTimeInterval(Double(-root * 37)),
                cost: Double((root % 13) + 1) / 10
            ))

            for child in 0..<childrenPerRoot {
                rows.append(Row(
                    id: "\(rootId)-child-\(child)",
                    parentId: rootId,
                    title: "Profile child \(root).\(child)",
                    status: child == 0 ? "busy" : "stopped",
                    lastActivity: now.addingTimeInterval(Double(-(root * 37 + child * 11))),
                    cost: Double(((root + child) % 7) + 1) / 20
                ))
            }
        }
        return rows
    }
}

private enum NavigationChromeProfileTimelineFixtures {
    static func makeTraceEvents(turnCount: Int) -> [TraceEvent] {
        var events: [TraceEvent] = []
        events.reserveCapacity(turnCount * 2 + 24)

        for turn in 1...turnCount {
            events.append(TraceEvent(
                id: "profile-u-\(turn)",
                type: .user,
                timestamp: timestamp(turn: turn, offset: 0),
                text: "Profile prompt \(turn): inspect navigation handoff and timeline startup latency.",
                tool: nil,
                args: nil,
                output: nil,
                toolCallId: nil,
                toolName: nil,
                isError: nil,
                thinking: nil
            ))

            events.append(TraceEvent(
                id: "profile-a-\(turn)",
                type: .assistant,
                timestamp: timestamp(turn: turn, offset: 1),
                text: assistantText(turn: turn),
                tool: nil,
                args: nil,
                output: nil,
                toolCallId: nil,
                toolName: nil,
                isError: nil,
                thinking: nil
            ))

            if turn.isMultiple(of: 18) {
                let toolCallId = "profile-tool-\(turn)"
                events.append(TraceEvent(
                    id: toolCallId,
                    type: .toolCall,
                    timestamp: timestamp(turn: turn, offset: 2),
                    text: nil,
                    tool: "bash",
                    args: ["command": .string("git status --short && xcrun xctrace record")],
                    output: nil,
                    toolCallId: nil,
                    toolName: nil,
                    isError: nil,
                    thinking: nil
                ))
                events.append(TraceEvent(
                    id: "profile-tool-result-\(turn)",
                    type: .toolResult,
                    timestamp: timestamp(turn: turn, offset: 3),
                    text: nil,
                    tool: nil,
                    args: nil,
                    output: String(repeating: "sample frame gap observed for route \(turn)\n", count: 24),
                    toolCallId: toolCallId,
                    toolName: "bash",
                    isError: false,
                    thinking: nil
                ))
            }
        }

        events.append(TraceEvent(
            id: "profile-system",
            type: .system,
            timestamp: timestamp(turn: turnCount + 1, offset: 0),
            text: "Profile fixture loaded \(turnCount) turns for navigation chrome timing",
            tool: nil,
            args: nil,
            output: nil,
            toolCallId: nil,
            toolName: nil,
            isError: nil,
            thinking: nil
        ))
        return events
    }

    private static func timestamp(turn: Int, offset: Int) -> String {
        let seconds = turn * 4 + offset
        return String(format: "2025-01-01T00:%02d:%02d.000Z", (seconds / 60) % 60, seconds % 60)
    }

    private static func assistantText(turn: Int) -> String {
        switch turn % 4 {
        case 0:
            return """
            ### Profile answer \(turn)

            This row intentionally mixes markdown, bullets, and code so the reducer and collection host have realistic first-render work.

            - transition: workspace list to timeline
            - turn: \(turn)
            - payload: \(String(repeating: "sample ", count: 16))

            ```swift
            struct ProfileSample\(turn) {
                let value = \(turn)
                func run() { print(value) }
            }
            ```
            """
        case 1:
            return "Short profile answer \(turn) with plain text and a few tokens."
        case 2:
            return """
            ```diff
            - old toolbar ownership waits for destination
            + active destination declares toolbar visibility
            + transition profiling measures frame gaps
            ```
            """
        default:
            return "Thinking through route \(turn): measure whether frame drops happen before timeline_appear, during reducer load, collection apply, or UIKit toolbar animation."
        }
    }
}

private struct NavigationChromeProfileLightDestination: View {
    let route: String

    var body: some View {
        VStack(spacing: 12) {
            Text("Light destination")
                .font(.headline)
            Text(route)
                .font(.caption.monospaced())
                .foregroundStyle(.themeComment)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.themeBg)
    }
}
#endif
