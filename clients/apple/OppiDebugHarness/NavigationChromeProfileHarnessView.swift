#if DEBUG
import SwiftUI
import UIKit

/// Debug-only harness for the chat Files control and Back handoff from a
/// workspace list: a fixture workspace list, workspace page, and the
/// production chat pushed through the router, as the app opens them.
///
/// Launch with `--nav-chrome-profile` on Simulator.
/// `--nav-chrome-chat-back-local-repro` stops at the workspace page, whose
/// local chat pushes above it.
enum NavigationChromeProfileConfig {
    private static let arguments = ProcessInfo.processInfo.arguments

    static var isEnabled: Bool {
#if targetEnvironment(simulator)
        arguments.contains("--nav-chrome-profile")
#else
        false
#endif
    }

    static var chatBackLocalRepro: Bool {
        arguments.contains("--nav-chrome-chat-back-local-repro")
    }
}

/// What the harness's pages share: each pushed page is its own SwiftUI graph,
/// so the state they edit lives in one observable model.
@MainActor @Observable
private final class NavigationChromeReproState {
    /// Pages the harness opened from the root list: the workspace page (and a
    /// session above it), not the local chat a workspace page pushes.
    var pathCount = 0
}

struct NavigationChromeProfileHarnessView: View {
    private static let workspace = Workspace(
        id: "nav-chrome-repro-workspace",
        name: "e2e-workspace",
        description: nil,
        icon: .symbol("square.grid.2x2"),
        systemPrompt: nil,
        hostMount: "/tmp/oppi-repro",
        tools: nil,
        gitStatusEnabled: false,
        runtime: .host,
        sandboxConfig: nil,
        createdAt: Date(timeIntervalSince1970: 1_770_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_770_000_000)
    )
    private static let serverId = "nav-chrome-repro-server"
    private static let sessionId = "nav-chrome-repro-session"

    @State private var navigation = AppNavigation()
    @State private var connection = Self.makeConnection()
    @State private var state = NavigationChromeReproState()

    var body: some View {
        RouterPreviewNavigation {
            NavigationChromeReproRoot(
                state: state,
                connection: connection,
                navigation: navigation
            )
        }
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            diagnosticsOverlay
        }
        .onAppear {
            navigation.launchPhase = .ready
            navigation.showOnboarding = false
            navigation.workspaceNavigationPresentation = .stack
        }
    }

    private var diagnosticsOverlay: some View {
        Text(String(state.pathCount))
            .accessibilityIdentifier("navChrome.repro.pathCount")
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
    }

    private static func makeConnection() -> ServerConnection {
        let connection = ServerConnection()
        connection.setPreviewServerId(serverId)
        connection.workspaceStore.workspacesByServer[serverId] = [workspace]
        connection.sessionStore.switchServer(to: serverId)
        connection.sessionStore.upsert(Session(
            id: sessionId,
            workspaceId: workspace.id,
            workspaceName: workspace.name,
            name: "Session Repro",
            status: .ready,
            createdAt: Date(timeIntervalSince1970: 1_770_000_010),
            lastActivity: Date(timeIntervalSince1970: 1_770_000_020),
            model: "profile/model",
            messageCount: 0,
            tokens: TokenUsage(input: 0, output: 0, cacheRead: nil, cacheWrite: nil),
            cost: 0,
            changeStats: SessionChangeStats(
                mutatingToolCalls: 1,
                filesChanged: 1,
                changedFiles: ["clients/apple/Oppi/App/NavigationChromeProfileHarnessView.swift"],
                changedFilesOverflow: nil
            ),
            contextTokens: 0,
            contextWindow: 128_000,
            firstMessage: nil,
            lastMessage: nil,
            thinkingLevel: "medium"
        ))
        return connection
    }
}

/// The workspace list, with the harness's pushes. It opens the workspace page
/// (local chat repro) or the chat straight away.
private struct NavigationChromeReproRoot: View {
    let state: NavigationChromeReproState
    let connection: ServerConnection
    let navigation: AppNavigation
    @Environment(\.screenNavigator) private var navigator
    @State private var didAutoOpen = false

    var body: some View {
        List {
            Section("Workspace") {
                Button("Open e2e-workspace") {
                    openFromRoot()
                }
                .accessibilityIdentifier("navChrome.repro.openWorkspace")
            }
        }
        .accessibilityIdentifier("navChrome.repro.root")
        .listStyle(.insetGrouped)
        .themedListSurface()
        .navigationTitle("Workspaces")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !didAutoOpen else { return }
            didAutoOpen = true
            try? await Task.sleep(for: .milliseconds(250))
            openFromRoot()
        }
    }

    private func openFromRoot() {
        state.pathCount += 1
        if NavigationChromeProfileConfig.chatBackLocalRepro {
            let state = state
            let connection = connection
            let navigation = navigation
            navigator.push {
                NavigationChromeReproWorkspace(state: state, connection: connection, navigation: navigation)
            }
        } else {
            state.pathCount += 1
            navigator.push(makeNavigationChromeReproChat(connection: connection, navigation: navigation))
        }
    }
}

private struct NavigationChromeReproWorkspace: View {
    let state: NavigationChromeReproState
    let connection: ServerConnection
    let navigation: AppNavigation
    @Environment(\.screenNavigator) private var navigator

    var body: some View {
        List {
            Section("Sessions") {
                Button("Open Session") {
                    state.pathCount += 1
                    navigator.push(makeNavigationChromeReproChat(connection: connection, navigation: navigation))
                }
                .accessibilityIdentifier("navChrome.repro.openSession")

                if NavigationChromeProfileConfig.chatBackLocalRepro {
                    Button("Open Local Chat") {
                        // Router push, not an AppNavigation path hop. Chat back
                        // must finish this push.
                        navigator.push(makeNavigationChromeReproChat(connection: connection, navigation: navigation))
                    }
                    .accessibilityIdentifier("navChrome.repro.openLocalChat")
                }
            }
        }
        .accessibilityIdentifier("navChrome.repro.workspace")
        .listStyle(.insetGrouped)
        .themedListSurface()
        .navigationTitle("e2e-workspace")
        .navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
private func makeNavigationChromeReproChat(
    connection: ServerConnection,
    navigation: AppNavigation
) -> UIViewController {
    ChatViewController(
        sessionId: "nav-chrome-repro-session",
        connection: connection,
        navigation: navigation,
        workspaceIdHint: "nav-chrome-repro-workspace"
    )
}
#endif
