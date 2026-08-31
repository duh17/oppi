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
    var loadsSessionsOnMount = true

    var body: some View {
        if let root = deck.root {
            MacSessionPaneNodeView(
                node: root,
                deck: deck,
                workspaces: workspaces,
                isStoppingSession: isStoppingSession,
                stopTarget: stopTarget,
                loadWorktrees: loadWorktrees,
                launchQuickSession: launchQuickSession,
                loadsSessionsOnMount: loadsSessionsOnMount
            )
        } else {
            ContentUnavailableView(
                "Quick Session unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("Close and reopen this window to restore its start pane.")
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
    let loadsSessionsOnMount: Bool

    @ViewBuilder
    var body: some View {
        switch node {
        case .pane(let pane):
            paneView(pane)
        case .split(let split):
            switch split.axis {
            case .horizontal:
                HSplitView {
                    child(split.first)
                    child(split.second)
                }
            case .vertical:
                VSplitView {
                    child(split.first)
                    child(split.second)
                }
            }
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
                centersQuickSession: deck.paneCount == 1,
                loadsSessionOnMount: loadsSessionsOnMount
            )
            .id(pane.id)
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
        if runtime.isEmpty {
            MacQuickSessionPaneComposer(
                workspaces: workspaces,
                agents: catalogStore.agents,
                state: runtime.quickSession,
                composerState: runtime.composerState,
                sessionFocus: $sessionFocus,
                centersInPane: centersQuickSession,
                activate: activate,
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
                isActivePane: isActive,
                activatePane: activate,
                loadsSessionOnMount: loadsSessionOnMount
            )
        }
    }

    private var paneHeader: some View {
        HStack(spacing: 8) {
            Button(action: activate) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Focus \(title)")
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
}
