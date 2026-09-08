import SwiftUI

/// Terminal-style presentation for the window-local session pane tree.
/// Runtime and composer ownership stay in `MacSessionPaneDeck`; this view only
/// paints the current tree so a split or rebalance cannot move input state.
struct MacSessionPaneDeckView: View {
    let deck: MacSessionPaneDeck
    let workspaces: [Workspace]
    let isStoppingSession: (String) -> Bool
    let stopTarget: (MacSelectedSessionTarget) async -> Void
    let loadWorktrees: (String) async -> [WorkspaceWorktree]
    let launchQuickSession: (MacSessionPaneRuntime, MacQuickSessionLaunchAttempt) async -> Void
    var retryRestoration: ((MacSessionPaneRuntime) async -> Void)? = nil
    var loadsSessionsOnMount = true

    var body: some View {
        Group {
            if let root = deck.root {
                ZStack(alignment: .top) {
                    MacSessionPaneNodeView(
                        node: root,
                        deck: deck,
                        workspaces: workspaces,
                        isStoppingSession: isStoppingSession,
                        stopTarget: stopTarget,
                        loadWorktrees: loadWorktrees,
                        launchQuickSession: launchQuickSession,
                        retryRestoration: retryRestoration,
                        loadsSessionsOnMount: loadsSessionsOnMount
                    )
                    if let message = deck.splitRejectionMessage {
                        Text(message)
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.themeBgHighlight, in: Capsule())
                            .padding(.top, 8)
                            .accessibilityIdentifier("mac.session.pane.splitRejected")
                    }
                }
            } else {
                ContentUnavailableView(
                    "Quick Session unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Close and reopen this window to restore its start pane.")
                )
            }
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            deck.noteWindowSize(
                MacSessionPaneMeasuredSize(width: size.width, height: size.height)
            )
        }
    }
}

enum MacSessionPaneFocusChrome {
    static let usesFullPaneDimmingOverlay = false
    static let focusStrokeAllowsHitTesting = false
}

private struct MacSessionPaneNodeView: View {
    let node: MacSessionPaneNode
    let deck: MacSessionPaneDeck
    let workspaces: [Workspace]
    let isStoppingSession: (String) -> Bool
    let stopTarget: (MacSelectedSessionTarget) async -> Void
    let loadWorktrees: (String) async -> [WorkspaceWorktree]
    let launchQuickSession: (MacSessionPaneRuntime, MacQuickSessionLaunchAttempt) async -> Void
    let retryRestoration: ((MacSessionPaneRuntime) async -> Void)?
    let loadsSessionsOnMount: Bool

    @ViewBuilder
    var body: some View {
        switch node {
        case .pane(let pane):
            paneView(pane)
        case .split(let split):
            MacSessionPaneDividerSplit(
                axis: split.axis,
                fraction: split.fraction,
                firstMinimum: MacSessionPaneSplitAdmission.subtreeMinimumSize(of: split.first),
                secondMinimum: MacSessionPaneSplitAdmission.subtreeMinimumSize(of: split.second),
                onFractionChange: { deck.setFraction($0, for: split.id) },
                first: { child(split.first) },
                second: { child(split.second) }
            )
        }
    }

    private func child(_ node: MacSessionPaneNode) -> some View {
        MacSessionPaneNodeView(
            node: node,
            deck: deck,
            workspaces: workspaces,
            isStoppingSession: isStoppingSession,
            stopTarget: stopTarget,
            loadWorktrees: loadWorktrees,
            launchQuickSession: launchQuickSession,
            retryRestoration: retryRestoration,
            loadsSessionsOnMount: loadsSessionsOnMount
        )
    }

    @ViewBuilder
    private func paneView(_ pane: MacSessionPane) -> some View {
        if let runtime = deck.runtime(for: pane.id) {
            MacSessionPaneSurface(
                runtime: runtime,
                isActive: deck.layout?.focusedPaneID == pane.id,
                workspace: workspaces.first(where: { $0.id == runtime.target?.workspaceId }),
                workspaces: workspaces,
                isStoppingSession: runtime.target.map { isStoppingSession($0.sessionId) } ?? false,
                activate: { _ = deck.focus(paneID: pane.id) },
                close: { _ = deck.close(paneID: pane.id) },
                stopSession: {
                    if let target = runtime.target {
                        await stopTarget(target)
                    }
                },
                loadWorktrees: loadWorktrees,
                launchQuickSession: { request in
                    await launchQuickSession(runtime, request)
                },
                retryRestoration: retryRestoration,
                centersQuickSession: deck.paneCount == 1,
                loadsSessionOnMount: loadsSessionsOnMount
            )
            .id(pane.id)
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                deck.notePaneSize(
                    MacSessionPaneMeasuredSize(width: size.width, height: size.height),
                    for: pane.id
                )
            }
        } else {
            ContentUnavailableView(
                "Pane unavailable",
                systemImage: "rectangle.split.2x1",
                description: Text("Close this pane and reopen the session.")
            )
            .frame(minWidth: MacSessionShellLayoutPolicy.timelineMinimumWidth)
        }
    }
}

private struct MacSessionPaneSurface: View {
    let runtime: MacSessionPaneRuntime
    let isActive: Bool
    let workspace: Workspace?
    let workspaces: [Workspace]
    let isStoppingSession: Bool
    let activate: () -> Void
    let close: () -> Void
    let stopSession: () async -> Void
    let loadWorktrees: (String) async -> [WorkspaceWorktree]
    let launchQuickSession: (MacQuickSessionLaunchAttempt) async -> Void
    var retryRestoration: ((MacSessionPaneRuntime) async -> Void)? = nil
    let centersQuickSession: Bool
    let loadsSessionOnMount: Bool

    private let catalogStore = MacCatalogStore.shared
    @FocusState private var sessionFocus: KeybindingFocus?

    var body: some View {
        VStack(spacing: 0) {
            paneHeader
            Divider()
            paneBody
        }
        .frame(
            minWidth: MacSessionShellLayoutPolicy.timelineMinimumWidth,
            maxWidth: .infinity,
            minHeight: 240,
            maxHeight: .infinity
        )
        .background(.themeBg)
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(
                    isActive ? Color.accentColor.opacity(0.72) : .clear,
                    lineWidth: 2
                )
                .allowsHitTesting(MacSessionPaneFocusChrome.focusStrokeAllowsHitTesting)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac.session.pane.\(runtime.id.rawValue)")
        .task {
            if runtime.isEmpty {
                await catalogStore.load(.agents)
            }
        }
        .onChange(of: sessionFocus) { _, new in
            runtime.traceStore.keybindingFocus = new ?? .composer
        }
        .onChange(of: isActive) { _, active in
            if !active {
                sessionFocus = nil
            }
        }
        .onChange(of: isActive) { _, active in
            guard !active else { return }
            sessionFocus = nil
            runtime.composerState.isComposerFirstResponder = false
        }
    }

    @ViewBuilder
    private var paneBody: some View {
        if let restorationError = runtime.restorationError {
            restorationChrome(restorationError)
        } else if runtime.isEmpty {
            MacQuickSessionPaneComposer(
                workspaces: workspaces,
                agents: catalogStore.agents,
                state: runtime.quickSession,
                composerState: runtime.composerState,
                sessionFocus: $sessionFocus,
                centersInPane: centersQuickSession,
                activate: activate,
                isActivePane: isActive,
                loadWorktrees: loadWorktrees,
                launch: launchQuickSession
            )
        } else {
            SessionTraceShellDetail(
                store: runtime.traceStore,
                workspace: workspace,
                isStoppingSession: isStoppingSession,
                stopSession: stopSession,
                composerState: runtime.composerState,
                presentation: runtime.presentation,
                isActivePane: isActive,
                activatePane: activate,
                loadsSessionOnMount: loadsSessionOnMount
            )
        }
    }

    @ViewBuilder
    private func restorationChrome(_ message: String) -> some View {
        let kind = Self.restorationKind(for: message)
        ContentUnavailableView {
            Label(kind.title, systemImage: kind.systemImage)
        } description: {
            Text(message)
        } actions: {
            if kind.showsRetry {
                Button("Retry") {
                    Task { await retryRestoration?(runtime) }
                }
                .accessibilityIdentifier("mac.session.pane.restoration.retry")
            }
        }
        .accessibilityIdentifier(kind.identifier)
    }

    private struct RestorationKind {
        let title: String
        let systemImage: String
        let identifier: String
        let showsRetry: Bool
    }

    private static func restorationKind(for message: String) -> RestorationKind {
        switch message {
        case MacSessionPaneRuntime.pendingRestorationMessage:
            RestorationKind(
                title: "Opening this session…",
                systemImage: "arrow.clockwise",
                identifier: "mac.session.pane.restoration.pending",
                showsRetry: false
            )
        case MacSessionPaneRuntime.disconnectedRestorationMessage:
            RestorationKind(
                title: "Can't open this session",
                systemImage: "wifi.slash",
                identifier: "mac.session.pane.restoration.disconnected",
                showsRetry: true
            )
        default:
            RestorationKind(
                title: "Session unavailable",
                systemImage: "exclamationmark.triangle",
                identifier: "mac.session.pane.restoration.unavailable",
                showsRetry: false
            )
        }
    }

    private var paneHeader: some View {
        HStack(spacing: 8) {
            Button(action: activate) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)
                    if hasLiveAsk {
                        Label("Needs input", systemImage: "questionmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.themeOrange)
                            .labelStyle(.titleAndIcon)
                            .accessibilityIdentifier("mac.session.pane.ask")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(hasLiveAsk ? "Focus \(title), needs input" : "Focus \(title)")
            .accessibilityIdentifier("mac.session.pane.header")

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help("Close Pane")
            .accessibilityLabel("Close \(title) pane")
            .accessibilityIdentifier("mac.session.pane.close")
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background {
            if isActive {
                Rectangle().fill(.themeBgHighlight.opacity(0.72))
            } else {
                Rectangle().fill(.themeBgDark)
            }
        }
    }

    private var title: String {
        if runtime.isEmpty {
            return "New Session"
        }
        return runtime.traceStore.session?.displayTitle
            ?? runtime.target?.summary.session.displayTitle
            ?? "Session"
    }

    private var hasLiveAsk: Bool {
        runtime.traceStore.currentExtensionRequest != nil
            || (runtime.target?.summary.pendingAskCount ?? 0) > 0
    }
}

private struct MacSessionPaneDividerSplit<First: View, Second: View>: View {
    let axis: MacSessionPaneSplitAxis
    let fraction: Double
    let firstMinimum: MacSessionPaneMeasuredSize
    let secondMinimum: MacSessionPaneMeasuredSize
    let onFractionChange: (Double) -> Void
    let first: First
    let second: Second
    @State private var dragOrigin: Double?

    init(
        axis: MacSessionPaneSplitAxis,
        fraction: Double,
        firstMinimum: MacSessionPaneMeasuredSize,
        secondMinimum: MacSessionPaneMeasuredSize,
        onFractionChange: @escaping (Double) -> Void,
        @ViewBuilder first: () -> First,
        @ViewBuilder second: () -> Second
    ) {
        self.axis = axis
        self.fraction = fraction
        self.firstMinimum = firstMinimum
        self.secondMinimum = secondMinimum
        self.onFractionChange = onFractionChange
        self.first = first()
        self.second = second()
    }

    var body: some View {
        GeometryReader { proxy in
            let along = axis == .horizontal ? proxy.size.width : proxy.size.height
            let firstMin = axis == .horizontal ? firstMinimum.width : firstMinimum.height
            let secondMin = axis == .horizontal ? secondMinimum.width : secondMinimum.height
            let paint = MacSessionPaneSplitAdmission.paintedSplitLengths(
                along: along,
                fraction: fraction,
                firstMinimum: firstMin,
                secondMinimum: secondMin
            )
            let firstLength = paint.first
            let contentAlong = paint.first + MacSessionPaneSplitAdmission.dividerThickness + paint.second
            let usable = max(along - MacSessionPaneSplitAdmission.dividerThickness, 1)

            let painted = Group {
                if axis == .horizontal {
                    HStack(spacing: 0) {
                        first.frame(width: firstLength)
                        dividerHandle(usable: usable, firstMin: firstMin, secondMin: secondMin)
                        second.frame(width: paint.second)
                    }
                    .frame(
                        width: paint.overflows ? contentAlong : proxy.size.width,
                        height: proxy.size.height,
                        alignment: .topLeading
                    )
                } else {
                    VStack(spacing: 0) {
                        first.frame(height: firstLength)
                        dividerHandle(usable: usable, firstMin: firstMin, secondMin: secondMin)
                        second.frame(height: paint.second)
                    }
                    .frame(
                        width: proxy.size.width,
                        height: paint.overflows ? contentAlong : proxy.size.height,
                        alignment: .topLeading
                    )
                }
            }

            if paint.overflows {
                ScrollView(axis == .horizontal ? .horizontal : .vertical) {
                    painted
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                painted
            }
        }
    }

    private func dividerHandle(
        usable: Double,
        firstMin: Double,
        secondMin: Double
    ) -> some View {
        Rectangle()
            .fill(.themeComment.opacity(0.35))
            .frame(
                width: axis == .horizontal ? MacSessionPaneSplitAdmission.dividerThickness : nil,
                height: axis == .vertical ? MacSessionPaneSplitAdmission.dividerThickness : nil
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragOrigin == nil {
                            dragOrigin = fraction
                        }
                        let delta = axis == .horizontal ? value.translation.width : value.translation.height
                        let origin = dragOrigin ?? fraction
                        let next = ((origin * usable) + delta) / usable
                        let paint = MacSessionPaneSplitAdmission.paintedSplitLengths(
                            along: usable + MacSessionPaneSplitAdmission.dividerThickness,
                            fraction: next,
                            firstMinimum: firstMin,
                            secondMinimum: secondMin
                        )
                        let nextUsable = max(paint.first + paint.second, 1)
                        let clamped = paint.first / nextUsable
                        if clamped.isFinite {
                            onFractionChange(clamped)
                        }
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                    }
            )
            .accessibilityIdentifier("mac.session.pane.divider")
    }
}
