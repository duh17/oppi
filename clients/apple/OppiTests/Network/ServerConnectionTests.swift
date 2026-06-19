import Testing
import Foundation
@testable import Oppi

// swiftlint:disable force_unwrapping large_tuple

@Suite("ServerConnection")
@MainActor
struct ServerConnectionTests {

    // MARK: - Message routing (via TestEventPipeline)

    @Test func routeConnected() {
        let (conn, pipe) = makeTestConnection()
        let session = makeTestSession(status: .ready)

        pipe.handle(.connected(session: session), sessionId: "s1")

        #expect(conn.sessionStore.sessions.count == 1)
        #expect(conn.sessionStore.sessions[0].status == .ready)
    }

    @Test func routeState() {
        let (conn, pipe) = makeTestConnection()
        let session = makeTestSession(status: .busy)

        pipe.handle(.state(session: session), sessionId: "s1")

        #expect(conn.sessionStore.sessions.count == 1)
        #expect(conn.sessionStore.sessions[0].status == .busy)
    }

    @Test func routeStopRequestedMarksStopping() {
        let (conn, pipe) = makeTestConnection()
        conn.sessionStore.upsert(makeTestSession(status: .busy))

        pipe.handle(
            .stopRequested(source: .user, reason: "Stopping current turn"),
            sessionId: "s1"
        )
        pipe.flushNow()

        #expect(conn.sessionStore.sessions.first?.status == .stopping)

        let system = pipe.reducer.items.filter {
            if case .systemEvent = $0 { return true }
            return false
        }
        #expect(system.count == 1)
    }

    @Test func routeStopFailedRestoresBusyAndEmitsError() {
        let (conn, pipe) = makeTestConnection()
        conn.sessionStore.upsert(makeTestSession(status: .stopping))

        pipe.handle(
            .stopFailed(source: .timeout, reason: "Stop timed out after 8000ms"),
            sessionId: "s1"
        )
        pipe.flushNow()

        #expect(conn.sessionStore.sessions.first?.status == .busy)

        let errors = pipe.reducer.items.filter {
            if case .error = $0 { return true }
            return false
        }
        #expect(errors.count == 1)
    }

    @Test func routeStopConfirmedRestoresReady() {
        let (conn, pipe) = makeTestConnection()
        conn.sessionStore.upsert(makeTestSession(status: .stopping))

        pipe.handle(
            .stopConfirmed(source: .user, reason: nil),
            sessionId: "s1"
        )
        pipe.flushNow()

        #expect(conn.sessionStore.sessions.first?.status == .ready)
    }

    @Test func routeStateSyncsThinkingLevelOnlyWhenChanged() {
        let (conn, pipe) = makeTestConnection()
        #expect(conn.chatState.thinkingLevel == .medium)

        pipe.handle(
            .connected(session: makeTestSession(status: .ready, thinkingLevel: "medium")),
            sessionId: "s1"
        )
        #expect(conn.chatState.thinkingLevel == .medium)

        pipe.handle(
            .state(session: makeTestSession(status: .ready, thinkingLevel: "high")),
            sessionId: "s1"
        )
        #expect(conn.chatState.thinkingLevel == .high)
    }

    @Test func routeConnectedRequestsSlashCommands() async {
        let (conn, pipe) = makeTestConnection()
        let counter = GetCommandsCounter()

        conn._sendMessageForTesting = { message in
            await counter.record(message: message)
        }

        pipe.handle(.connected(session: makeTestSession(status: .ready)), sessionId: "s1")

        #expect(await waitForTestCondition(timeoutMs: 500) { await counter.count() == 1 })
    }

    @Test func routeStateWorkspaceChangeRequestsSlashCommands() async {
        let (conn, pipe) = makeTestConnection()
        let counter = GetCommandsCounter()

        conn._sendMessageForTesting = { message in
            await counter.record(message: message)
        }

        var initial = makeTestSession(status: .ready)
        initial.workspaceId = "w1"
        pipe.handle(.connected(session: initial), sessionId: "s1")
        #expect(await waitForTestCondition(timeoutMs: 500) { await counter.count() == 1 })

        // Same workspace should not re-fetch.
        pipe.handle(.state(session: initial), sessionId: "s1")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await counter.count() == 1)

        // Workspace switch should refresh.
        var switched = initial
        switched.workspaceId = "w2"
        pipe.handle(.state(session: switched), sessionId: "s1")
        #expect(await waitForTestCondition(timeoutMs: 500) { await counter.count() == 2 })
    }

    @Test func routeGetCommandsResultUpdatesSlashCommandCache() {
        let (conn, pipe) = makeTestConnection()
        let session = makeTestSession(status: .ready)
        pipe.handle(.connected(session: session), sessionId: "s1")

        pipe.handle(
            .commandResult(
                command: "get_commands",
                requestId: nil,
                success: true,
                data: makeGetCommandsPayload([
                    ("compact", "Compact context", "prompt"),
                    ("skill:lint", "Run linter skill", "skill"),
                ]),
                error: nil
            ),
            sessionId: "s1"
        )

        #expect(conn.chatState.slashCommands.count == 2)
        #expect(conn.chatState.slashCommands.map(\.name) == ["compact", "skill:lint"])
    }




    @Test func routeAgentStartAndTextAndEnd() {
        let (conn, pipe) = makeTestConnection()

        pipe.handle(.agentStart, sessionId: "s1")
        pipe.flushNow()
        pipe.handle(.textDelta(delta: "Hello"), sessionId: "s1")
        pipe.handle(.agentEnd, sessionId: "s1")
        pipe.flushNow()

        let assistants = pipe.reducer.items.filter {
            if case .assistantMessage = $0 { return true }
            return false
        }
        #expect(assistants.count == 1)
        guard case .assistantMessage(_, let text, _) = assistants[0] else {
            Issue.record("Expected assistantMessage")
            return
        }
        #expect(text == "Hello")
    }

    @Test func routeAgentStartSetsSessionBusyWithoutStateMessage() {
        let (conn, pipe) = makeTestConnection()
        conn.sessionStore.upsert(makeTestSession(status: .ready))

        pipe.handle(.agentStart, sessionId: "s1")

        #expect(conn.sessionStore.sessions.first?.status == .busy)
    }

    @Test func routeAgentEndSetsSessionReadyWithoutStateMessage() {
        let (conn, pipe) = makeTestConnection()
        conn.sessionStore.upsert(makeTestSession(status: .busy))

        pipe.handle(.agentEnd, sessionId: "s1")

        #expect(conn.sessionStore.sessions.first?.status == .ready)
    }

    @Test func routeThinkingDelta() {
        let (conn, pipe) = makeTestConnection()

        pipe.handle(.agentStart, sessionId: "s1")
        pipe.handle(.thinkingDelta(delta: "thinking..."), sessionId: "s1")
        pipe.handle(.agentEnd, sessionId: "s1")
        pipe.flushNow()

        let thinking = pipe.reducer.items.filter {
            if case .thinking = $0 { return true }
            return false
        }
        #expect(thinking.count == 1)
    }

    @Test func routeToolStartOutputEnd() {
        let (conn, pipe) = makeTestConnection()

        pipe.handle(.agentStart, sessionId: "s1")
        pipe.handle(.toolStart(tool: "bash", args: ["command": "ls"], toolCallId: "tc-1", callSegments: nil), sessionId: "s1")
        pipe.flushNow()
        pipe.handle(.toolOutput(output: "file.txt", isError: false, toolCallId: "tc-1", mode: .append, truncated: false, totalBytes: nil, details: nil), sessionId: "s1")
        pipe.flushNow()
        pipe.handle(.toolEnd(tool: "bash", toolCallId: "tc-1", details: nil, isError: false, resultSegments: nil), sessionId: "s1")
        pipe.flushNow()
        pipe.handle(.agentEnd, sessionId: "s1")
        pipe.flushNow()

        let tools = pipe.reducer.items.filter {
            if case .toolCall = $0 { return true }
            return false
        }
        #expect(tools.count == 1)
        guard case .toolCall(_, let tool, _, _, _, _, let isDone) = tools[0] else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(tool == "bash")
        #expect(isDone)
    }

    @Test func routeSessionEnded() {
        let (conn, pipe) = makeTestConnection()
        conn.sessionStore.upsert(makeTestSession(status: .busy))

        pipe.handle(.sessionEnded(reason: "stopped"), sessionId: "s1")
        pipe.flushNow()

        #expect(conn.sessionStore.sessions.first?.status == .stopped)

        let system = pipe.reducer.items.filter {
            if case .systemEvent = $0 { return true }
            return false
        }
        #expect(system.count == 1)
    }

    @Test func routeError() {
        let (conn, pipe) = makeTestConnection()

        pipe.handle(.error(message: "Something failed", code: nil, fatal: false), sessionId: "s1")
        pipe.flushNow()

        let errors = pipe.reducer.items.filter {
            if case .error = $0 { return true }
            return false
        }
        #expect(errors.count == 1)
    }

    @Test func routeExtensionUIRequest() {
        let (conn, pipe) = makeTestConnection()
        let request = ExtensionUIRequest(
            id: "ext1",
            sessionId: "s1",
            method: "editor",
            title: "Edit value",
            message: "Review before submitting."
        )

        pipe.handle(.extensionUIRequest(request), sessionId: "s1")

        #expect(conn.activeExtensionDialog?.id == "ext1")
    }

    @Test func routeExtensionUINotification() {
        let (conn, pipe) = makeTestConnection()

        pipe.handle(
            .extensionUINotification(
                ExtensionUINotification(
                    method: "notify",
                    message: "Task complete",
                    notifyType: "info",
                    statusKey: nil,
                    statusText: nil,
                    title: nil,
                    text: nil,
                    widgetKey: nil,
                    widgetLines: nil,
                    widgetPlacement: nil
                )
            ),
            sessionId: "s1"
        )

        #expect(conn.extensionToast == "Task complete")
    }

    @Test func routeExtensionSetStatusStoresSurfaceState() {
        let (conn, pipe) = makeTestConnection()

        pipe.handle(
            .extensionUINotification(
                ExtensionUINotification(
                    method: "setStatus",
                    message: nil,
                    notifyType: nil,
                    statusKey: "review",
                    statusText: "running",
                    title: nil,
                    text: nil,
                    widgetKey: nil,
                    widgetLines: nil,
                    widgetPlacement: nil
                )
            ),
            sessionId: "s1"
        )

        #expect(conn.extensionSurfaceBySession["s1"]?.statuses["review"]?.text == "running")
    }

    @Test func routeExtensionWorkingNotificationsStoreTimelineState() {
        let (conn, pipe) = makeTestConnection()

        pipe.handle(
            .extensionUINotification(
                ExtensionUINotification(
                    method: "setWorkingMessage",
                    message: "Running checks",
                    notifyType: nil,
                    statusKey: nil,
                    statusText: nil,
                    title: nil,
                    text: nil,
                    widgetKey: nil,
                    widgetLines: nil,
                    widgetPlacement: nil
                )
            ),
            sessionId: "s1"
        )
        pipe.handle(
            .extensionUINotification(
                ExtensionUINotification(
                    method: "setWorkingVisible",
                    message: nil,
                    notifyType: nil,
                    statusKey: nil,
                    statusText: nil,
                    title: nil,
                    text: nil,
                    widgetKey: nil,
                    widgetLines: nil,
                    widgetPlacement: nil,
                    workingVisible: false
                )
            ),
            sessionId: "s1"
        )
        pipe.handle(
            .extensionUINotification(
                ExtensionUINotification(
                    method: "setWorkingIndicator",
                    message: nil,
                    notifyType: nil,
                    statusKey: nil,
                    statusText: nil,
                    title: nil,
                    text: nil,
                    widgetKey: nil,
                    widgetLines: nil,
                    widgetPlacement: nil,
                    workingIndicator: ExtensionUIWorkingIndicator(frames: ["●"], intervalMs: 250)
                )
            ),
            sessionId: "s1"
        )

        let working = conn.extensionSurfaceBySession["s1"]?.working
        #expect(working?.message == "Running checks")
        #expect(working?.visible == false)
        #expect(working?.indicator?.frames == ["●"])
        #expect(working?.indicator?.intervalMs == 250)
    }

    @Test func routeExtensionHiddenThinkingLabelStoresAndClearsTimelineState() {
        let (conn, pipe) = makeTestConnection()

        pipe.handle(
            .extensionUINotification(
                ExtensionUINotification(
                    method: "setHiddenThinkingLabel",
                    message: nil,
                    notifyType: nil,
                    statusKey: nil,
                    statusText: nil,
                    title: nil,
                    text: nil,
                    widgetKey: nil,
                    widgetLines: nil,
                    widgetPlacement: nil,
                    hiddenThinkingLabel: " Private reasoning "
                )
            ),
            sessionId: "s1"
        )

        #expect(conn.extensionSurfaceBySession["s1"]?.hiddenThinkingLabel == "Private reasoning")

        pipe.handle(
            .extensionUINotification(
                ExtensionUINotification(
                    method: "setHiddenThinkingLabel",
                    message: nil,
                    notifyType: nil,
                    statusKey: nil,
                    statusText: nil,
                    title: nil,
                    text: nil,
                    widgetKey: nil,
                    widgetLines: nil,
                    widgetPlacement: nil
                )
            ),
            sessionId: "s1"
        )

        #expect(conn.extensionSurfaceBySession["s1"] == nil)
    }

    @Test func routeExtensionToolsExpandedStoresTimelineState() {
        let (conn, pipe) = makeTestConnection()

        pipe.handle(
            .extensionUINotification(
                ExtensionUINotification(
                    method: "setToolsExpanded",
                    message: nil,
                    notifyType: nil,
                    statusKey: nil,
                    statusText: nil,
                    title: nil,
                    text: nil,
                    widgetKey: nil,
                    widgetLines: nil,
                    widgetPlacement: nil,
                    toolsExpanded: true
                )
            ),
            sessionId: "s1"
        )

        #expect(conn.extensionSurfaceBySession["s1"]?.toolsExpanded == true)

        pipe.handle(
            .extensionUINotification(
                ExtensionUINotification(
                    method: "setToolsExpanded",
                    message: nil,
                    notifyType: nil,
                    statusKey: nil,
                    statusText: nil,
                    title: nil,
                    text: nil,
                    widgetKey: nil,
                    widgetLines: nil,
                    widgetPlacement: nil,
                    toolsExpanded: false
                )
            ),
            sessionId: "s1"
        )

        #expect(conn.extensionSurfaceBySession["s1"]?.toolsExpanded == false)
    }

    @Test func routeExtensionNativeWidgetStoresPlacement() {
        let (conn, pipe) = makeTestConnection()
        let nativeSurface = ExtensionUINativeSurface(
            version: 1,
            id: "widget:below",
            source: "widget",
            presentation: ExtensionUINativePresentation(
                style: "surfacePanel",
                title: "Below editor",
                subtitle: nil
            ),
            blocks: [
                .text(
                    base: ExtensionUIBlockBase(id: "body", accessibility: nil),
                    spans: [
                        ExtensionUITextSpan(
                            text: "Rendered below the composer",
                            role: nil,
                            traits: nil,
                            link: nil
                        ),
                    ]
                ),
            ],
            fallback: nil
        )

        pipe.handle(
            .extensionUINotification(
                ExtensionUINotification(
                    method: "setWidget",
                    message: nil,
                    notifyType: nil,
                    statusKey: nil,
                    statusText: nil,
                    title: nil,
                    text: nil,
                    widgetKey: "below",
                    widgetLines: ["Rendered below the composer"],
                    widgetPlacement: "belowEditor",
                    nativeSurface: nativeSurface
                )
            ),
            sessionId: "s1"
        )

        let stored = conn.extensionSurfaceBySession["s1"]?.nativeSurfaces["widget:below"]
        #expect(stored?.surface.id == "widget:below")
        #expect(stored?.placement == "belowEditor")
        #expect(conn.extensionSurfaceBySession["s1"]?.widgets["below"] == nil)
    }

    @Test func routeMixedNativeAndTextWidgetsPreservesPiTUIOrder() throws {
        let (conn, pipe) = makeTestConnection()
        let nativeSurface = ExtensionUINativeSurface(
            version: 1,
            id: "widget:jobs",
            source: "widget",
            presentation: ExtensionUINativePresentation(
                style: "surfacePanel",
                title: "Agents",
                subtitle: nil
            ),
            blocks: [
                .text(
                    base: ExtensionUIBlockBase(id: "agents-body", accessibility: nil),
                    spans: [ExtensionUITextSpan(text: "Agents active", role: nil, traits: nil, link: nil)]
                ),
            ],
            fallback: nil
        )

        pipe.handle(
            .extensionUINotification(
                ExtensionUINotification(
                    method: "setWidget",
                    message: nil,
                    notifyType: nil,
                    statusKey: nil,
                    statusText: nil,
                    title: nil,
                    text: nil,
                    widgetKey: "jobs",
                    widgetLines: ["Agents active"],
                    widgetPlacement: nil,
                    nativeSurface: nativeSurface
                )
            ),
            sessionId: "s1"
        )
        pipe.handle(
            .extensionUINotification(
                ExtensionUINotification(
                    method: "setWidget",
                    message: nil,
                    notifyType: nil,
                    statusKey: nil,
                    statusText: nil,
                    title: nil,
                    text: nil,
                    widgetKey: "goal",
                    widgetLines: ["Goal active"],
                    widgetPlacement: nil
                )
            ),
            sessionId: "s1"
        )

        let surface = try #require(conn.extensionSurfaceBySession["s1"])
        #expect(surface.nativeSurfaces["widget:jobs"]?.key == "jobs")
        #expect(surface.nativeSurfaces["widget:jobs"]?.order == 1)
        #expect(surface.widgets["goal"]?.order == 2)
        #expect(surface.widgetEntries(in: .aboveEditor).map(\.id) == ["native:jobs", "widget:goal"])
    }

    @Test func routeReplacingWidgetMovesItToLatestPiTUIPosition() throws {
        let (conn, pipe) = makeTestConnection()
        let nativeSurface = ExtensionUINativeSurface(
            version: 1,
            id: "widget:jobs",
            source: "widget",
            presentation: ExtensionUINativePresentation(
                style: "surfacePanel",
                title: "Agents",
                subtitle: nil
            ),
            blocks: [
                .text(
                    base: ExtensionUIBlockBase(id: "agents-body", accessibility: nil),
                    spans: [ExtensionUITextSpan(text: "Agents active", role: nil, traits: nil, link: nil)]
                ),
            ],
            fallback: nil
        )

        for notification in [
            ExtensionUINotification(
                method: "setWidget",
                message: nil,
                notifyType: nil,
                statusKey: nil,
                statusText: nil,
                title: nil,
                text: nil,
                widgetKey: "jobs",
                widgetLines: ["Agents active"],
                widgetPlacement: nil,
                nativeSurface: nativeSurface
            ),
            ExtensionUINotification(
                method: "setWidget",
                message: nil,
                notifyType: nil,
                statusKey: nil,
                statusText: nil,
                title: nil,
                text: nil,
                widgetKey: "goal",
                widgetLines: ["Goal active"],
                widgetPlacement: nil
            ),
            ExtensionUINotification(
                method: "setWidget",
                message: nil,
                notifyType: nil,
                statusKey: nil,
                statusText: nil,
                title: nil,
                text: nil,
                widgetKey: "jobs",
                widgetLines: ["Agents updated"],
                widgetPlacement: nil,
                nativeSurface: nativeSurface
            ),
        ] {
            pipe.handle(.extensionUINotification(notification), sessionId: "s1")
        }

        let surface = try #require(conn.extensionSurfaceBySession["s1"])
        #expect(surface.nativeSurfaces["widget:jobs"]?.order == 3)
        #expect(surface.widgets["goal"]?.order == 2)
        #expect(surface.widgetEntries(in: .aboveEditor).map(\.id) == ["widget:goal", "native:jobs"])
    }

    @Test func routeStatusDoesNotBecomeWidgetEntry() throws {
        let (conn, pipe) = makeTestConnection()

        pipe.handle(
            .extensionUINotification(
                ExtensionUINotification(
                    method: "setStatus",
                    message: nil,
                    notifyType: nil,
                    statusKey: "jobs",
                    statusText: "1 running agent",
                    title: nil,
                    text: nil,
                    widgetKey: nil,
                    widgetLines: nil,
                    widgetPlacement: nil
                )
            ),
            sessionId: "s1"
        )
        pipe.handle(
            .extensionUINotification(
                ExtensionUINotification(
                    method: "setWidget",
                    message: nil,
                    notifyType: nil,
                    statusKey: nil,
                    statusText: nil,
                    title: nil,
                    text: nil,
                    widgetKey: "goal",
                    widgetLines: ["Goal active"],
                    widgetPlacement: nil
                )
            ),
            sessionId: "s1"
        )

        let surface = try #require(conn.extensionSurfaceBySession["s1"])
        #expect(surface.hasVisibleMetadata(in: .aboveEditor))
        #expect(surface.widgetEntries(in: .aboveEditor).map(\.id) == ["widget:goal"])
    }

    @Test func statusWithSameRawKeyAttachesToScopedNativeSurface() throws {
        let surface = ExtensionSurfaceState(
            statuses: [
                "goal": ExtensionStatusState(
                    key: "goal",
                    text: "goal: Active 1/25"
                ),
            ],
            nativeSurfaces: [
                "widget:goal": ExtensionNativeSurfaceState(
                    key: "goal",
                    surface: ExtensionUINativeSurface(
                        version: 1,
                        id: "widget:goal",
                        source: "widget",
                        presentation: ExtensionUINativePresentation(
                            style: "surfacePanel",
                            title: "Goal",
                            subtitle: nil
                        ),
                        blocks: [
                            .activityList(
                                base: ExtensionUIBlockBase(id: "goal-status", accessibility: nil),
                                rows: [
                                    ExtensionUIActivityRow(
                                        id: "goal-1",
                                        title: "Keep working",
                                        subtitle: "Active",
                                        detail: nil,
                                        state: "running",
                                        progress: nil,
                                        link: nil,
                                        children: nil
                                    ),
                                ]
                            ),
                        ],
                        fallback: nil
                    ),
                    placement: "aboveEditor",
                    extensionScopeId: "repo:goal",
                    extensionDisplayName: "Goal"
                ),
            ]
        )

        #expect(surface.standaloneStatusEntries().isEmpty)
        #expect(
            surface.attachedStatusText(
                for: "goal",
                extensionScopeId: "repo:goal"
            ) == "goal: Active 1/25"
        )
    }

    @Test func scopedSingletonStatusStillAttachesWhenKeysDiffer() {
        let surface = ExtensionSurfaceState(
            statuses: [
                "subagents": ExtensionStatusState(
                    key: "subagents",
                    text: "1 running agent",
                    extensionScopeId: "repo:subagents",
                    extensionDisplayName: "Subagents"
                ),
            ],
            widgets: [
                "agents": ExtensionWidgetState(
                    key: "agents",
                    lines: ["Agents active"],
                    placement: "aboveEditor",
                    extensionScopeId: "repo:subagents",
                    extensionDisplayName: "Subagents"
                ),
            ]
        )

        #expect(surface.standaloneStatusEntries().isEmpty)
        #expect(
            surface.attachedStatusText(
                for: "agents",
                extensionScopeId: "repo:subagents"
            ) == "1 running agent"
        )
    }

    @Test func standaloneStatusEntriesCollapseVisibleDuplicates() throws {
        let surface = ExtensionSurfaceState(
            statuses: [
                "first": ExtensionStatusState(
                    key: "oppi-dev",
                    text: "running Oppi install"
                ),
                "second": ExtensionStatusState(
                    key: "oppi-dev ",
                    text: "running Oppi install"
                ),
            ]
        )

        let entries = surface.standaloneStatusEntries()
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.key == "oppi-dev")
        #expect(entry.text == "running Oppi install")
    }

    @Test func routeDefocusedTerminalStateKeepsFocusedExtensionSurface() {
        let (conn, pipe) = makeTestConnection(sessionId: "focused")
        conn.extensionSurfaceBySession["focused"] = ExtensionSurfaceState(
            widgets: [
                "goal": ExtensionWidgetState(
                    key: "goal",
                    lines: ["Goal: Pursuing goal"],
                    placement: "aboveEditor"
                )
            ]
        )
        let other = makeTestSession(id: "other", status: .stopped)

        pipe.handle(.state(session: other), sessionId: "focused")

        #expect(conn.extensionSurfaceBySession["focused"]?.widgets["goal"]?.lines == ["Goal: Pursuing goal"])
    }

    @Test func routeReadyStateKeepsPersistentExtensionSurface() {
        let (conn, pipe) = makeTestConnection(sessionId: "s1")
        conn.extensionSurfaceBySession["s1"] = ExtensionSurfaceState(
            widgets: [
                "goal": ExtensionWidgetState(
                    key: "goal",
                    lines: ["Goal: Pursuing goal"],
                    placement: "aboveEditor"
                )
            ]
        )

        pipe.handle(.state(session: makeTestSession(id: "s1", status: .ready)), sessionId: "s1")

        #expect(conn.extensionSurfaceBySession["s1"]?.widgets["goal"]?.lines == ["Goal: Pursuing goal"])
    }

    @Test func routeExtensionStatusWithAnyKeyStoresChatSurfaceEntry() {
        let (conn, pipe) = makeTestConnection()

        pipe.handle(
            .extensionUINotification(
                ExtensionUINotification(
                    method: "setStatus",
                    message: nil,
                    notifyType: nil,
                    statusKey: "extension-status",
                    statusText: "live",
                    title: nil,
                    text: nil,
                    widgetKey: nil,
                    widgetLines: nil,
                    widgetPlacement: nil
                )
            ),
            sessionId: "s1"
        )

        #expect(conn.extensionSurfaceBySession["s1"]?.statuses["extension-status"]?.text == "live")
    }

    @Test func routeExtensionStatusWithAnyKeyUpdatesExistingChatSurfaceEntry() {
        let (conn, pipe) = makeTestConnection()
        conn.extensionSurfaceBySession["s1"] = ExtensionSurfaceState(
            statuses: [
                "extension-status": ExtensionStatusState(key: "extension-status", text: "live"),
            ]
        )

        pipe.handle(
            .extensionUINotification(
                ExtensionUINotification(
                    method: "setStatus",
                    message: nil,
                    notifyType: nil,
                    statusKey: "extension-status",
                    statusText: "updated",
                    title: nil,
                    text: nil,
                    widgetKey: nil,
                    widgetLines: nil,
                    widgetPlacement: nil
                )
            ),
            sessionId: "s1"
        )

        #expect(conn.extensionSurfaceBySession["s1"]?.statuses["extension-status"]?.text == "updated")
    }

    @Test func routeExtensionSetEditorTextUpdatesComposerState() {
        let (conn, pipe) = makeTestConnection()

        pipe.handle(
            .extensionUINotification(
                ExtensionUINotification(
                    method: "set_editor_text",
                    message: nil,
                    notifyType: nil,
                    statusKey: nil,
                    statusText: nil,
                    title: nil,
                    text: "Act on the review findings",
                    widgetKey: nil,
                    widgetLines: nil,
                    widgetPlacement: nil
                )
            ),
            sessionId: "s1"
        )

        #expect(conn.chatState.extensionEditorTextUpdate?.sessionId == "s1")
        #expect(conn.chatState.extensionEditorTextUpdate?.text == "Act on the review findings")
    }

    @Test func routeUnknownIsNoOp() {
        let (conn, pipe) = makeTestConnection()
        let preCount = pipe.reducer.items.count

        pipe.handle(.unknown(type: "future_type"), sessionId: "s1")

        #expect(pipe.reducer.items.count == preCount)
    }

    // MARK: - Stale session guard

    @Test func staleSessionMessageIgnored() {
        let (conn, pipe) = makeTestConnection(sessionId: "s1")

        // Send message for a different session
        let session = makeTestSession(id: "s2", status: .busy)
        pipe.handle(.connected(session: session), sessionId: "s2")

        // Session store should NOT have s2 (message was for wrong active session)
        #expect(conn.sessionStore.sessions.isEmpty)
    }

    // MARK: - Pipeline flush

    @Test func pipelineFlushDelivers() {
        let (conn, pipe) = makeTestConnection()

        pipe.handle(.agentStart, sessionId: "s1")
        pipe.handle(.textDelta(delta: "buffered"), sessionId: "s1")
        // textDelta is buffered in coalescer — not yet in reducer
        // flushNow forces delivery
        pipe.flushNow()

        let has = pipe.reducer.items.contains {
            if case .assistantMessage = $0 { return true }
            return false
        }
        #expect(has)
    }

    // MARK: - Send ACK integration

    @Test func sendAckSuccessForPromptSteerAndFollowUp() async throws {
        for command in AckCommand.allCases {
            let conn = ServerConnection()
            conn._setActiveSessionIdForTesting("s1")
            let pipe = TestEventPipeline(sessionId: "s1", connection: conn)

            var sentRequestId: String?
            conn._sendMessageForTesting = { message in
                guard let sent = extractAckRequest(from: message) else {
                    Issue.record("Expected prompt/steer/follow_up message")
                    return
                }
                #expect(sent.command == command.rawValue)
                #expect(sent.clientTurnId != nil)
                sentRequestId = sent.requestId

                if let requestId = sent.requestId {
                    pipe.handle(
                        .commandResult(
                            command: sent.command,
                            requestId: requestId,
                            success: true,
                            data: nil,
                            error: nil
                        ),
                        sessionId: "s1"
                    )
                }
            }

            try await command.send(using: conn, text: "hello")
            #expect(sentRequestId != nil, "\(command.rawValue) should include requestId")
        }
    }

    @Test func sendAckUsesTurnAckStages() async throws {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("s1")
        let pipe = TestEventPipeline(sessionId: "s1", connection: conn)

        conn._sendMessageForTesting = { message in
            guard let sent = extractAckRequest(from: message),
                  let clientTurnId = sent.clientTurnId else {
                Issue.record("Expected turn command with clientTurnId")
                return
            }

            pipe.handle(
                .turnAck(
                    command: sent.command,
                    clientTurnId: clientTurnId,
                    stage: .accepted,
                    requestId: sent.requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )

            pipe.handle(
                .turnAck(
                    command: sent.command,
                    clientTurnId: clientTurnId,
                    stage: .dispatched,
                    requestId: sent.requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )
        }

        try await conn.sendPrompt("hello")
    }

    @Test func sendAckStageCallbackReceivesProgressStages() async throws {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("s1")
        let pipe = TestEventPipeline(sessionId: "s1", connection: conn)

        let stageRecorder = AckStageRecorder()

        conn._sendMessageForTesting = { message in
            guard let sent = extractAckRequest(from: message),
                  let clientTurnId = sent.clientTurnId,
                  let requestId = sent.requestId else {
                Issue.record("Expected turn command with requestId/clientTurnId")
                return
            }

            pipe.handle(
                .turnAck(
                    command: sent.command,
                    clientTurnId: clientTurnId,
                    stage: .accepted,
                    requestId: requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )

            pipe.handle(
                .turnAck(
                    command: sent.command,
                    clientTurnId: clientTurnId,
                    stage: .dispatched,
                    requestId: requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )

            pipe.handle(
                .turnAck(
                    command: sent.command,
                    clientTurnId: clientTurnId,
                    stage: .started,
                    requestId: requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )
        }

        try await conn.sendPrompt("hello", onAckStage: { stage in
            Task { await stageRecorder.record(stage) }
        })

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await stageRecorder.snapshot() == [.accepted, .dispatched, .started]
        })
    }

    @Test func sendRetryReusesClientTurnId() async throws {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("s1")
        conn._turnSendRetryDelayForTesting = .milliseconds(1)
        let pipe = TestEventPipeline(sessionId: "s1", connection: conn)

        var attempt = 0
        var seenTurnIds: [String] = []
        var seenRequestIds: [String] = []

        conn._sendMessageForTesting = { message in
            guard let sent = extractAckRequest(from: message),
                  let clientTurnId = sent.clientTurnId,
                  let requestId = sent.requestId else {
                Issue.record("Expected turn command with requestId/clientTurnId")
                return
            }

            attempt += 1
            seenTurnIds.append(clientTurnId)
            seenRequestIds.append(requestId)

            if attempt == 1 {
                throw WebSocketError.notConnected
            }

            pipe.handle(
                .turnAck(
                    command: sent.command,
                    clientTurnId: clientTurnId,
                    stage: .dispatched,
                    requestId: requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )
        }

        try await conn.sendPrompt("hello")

        #expect(attempt == 2)
        #expect(seenTurnIds.count == 2)
        #expect(seenTurnIds[0] == seenTurnIds[1])
        #expect(seenRequestIds.count == 2)
        #expect(seenRequestIds[0] == seenRequestIds[1])
    }

    @Test func sendPromptChurnAlwaysResolvesWithoutSilentDrop() async {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("s1")
        let pipe = TestEventPipeline(sessionId: "s1", connection: conn)
        conn._sendAckTimeoutForTesting = .milliseconds(160)
        conn._turnSendRetryDelayForTesting = .milliseconds(1)

        var requestOrder: [String: Int] = [:]
        var attemptsByRequest: [String: Int] = [:]
        var turnIdsByRequest: [String: Set<String>] = [:]
        var nextOrder = 0

        conn._sendMessageForTesting = { message in
            guard let sent = extractAckRequest(from: message),
                  let requestId = sent.requestId,
                  let clientTurnId = sent.clientTurnId else {
                Issue.record("Expected prompt/steer/follow_up with ids")
                return
            }

            if requestOrder[requestId] == nil {
                nextOrder += 1
                requestOrder[requestId] = nextOrder
            }

            attemptsByRequest[requestId, default: 0] += 1
            turnIdsByRequest[requestId, default: Set<String>()].insert(clientTurnId)

            let order = requestOrder[requestId] ?? 0
            let attempt = attemptsByRequest[requestId] ?? 0

            // Forced churn pattern:
            // - even-numbered logical sends always fail (both attempts)
            // - odd-numbered logical sends fail first, then succeed on retry
            if order.isMultiple(of: 2) {
                throw WebSocketError.notConnected
            }

            if attempt == 1 {
                throw WebSocketError.notConnected
            }

            pipe.handle(
                .turnAck(
                    command: sent.command,
                    clientTurnId: clientTurnId,
                    stage: .dispatched,
                    requestId: requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )
        }

        var delivered = 0
        var failed = 0

        for i in 0..<12 {
            do {
                try await conn.sendPrompt("msg-\(i)")
                delivered += 1
            } catch let error as WebSocketError {
                switch error {
                case .notConnected:
                    failed += 1
                default:
                    Issue.record("Unexpected WebSocket error: \(error)")
                }
            } catch let error as SendAckError {
                switch error {
                case .timeout:
                    failed += 1
                case .rejected:
                    Issue.record("Unexpected rejection during churn test: \(error)")
                }
            } catch {
                Issue.record("Unexpected churn send failure: \(error)")
            }
        }

        #expect(delivered + failed == 12)
        #expect(delivered == 6)
        #expect(failed == 6)
        #expect(requestOrder.count == 12)
        #expect(attemptsByRequest.values.allSatisfy { $0 == 2 })
        #expect(turnIdsByRequest.values.allSatisfy { $0.count == 1 })

        // Recovery check: after repeated churn/failures, a new send still resolves.
        do {
            try await conn.sendPrompt("recovery")
            delivered += 1
        } catch {
            Issue.record("Expected recovery prompt to succeed, got \(error)")
        }

        #expect(delivered == 7)
    }

    @Test func sendAckRejectedForPromptSteerAndFollowUp() async {
        for command in AckCommand.allCases {
            let conn = ServerConnection()
            conn._setActiveSessionIdForTesting("s1")
            let pipe = TestEventPipeline(sessionId: "s1", connection: conn)

            conn._sendMessageForTesting = { message in
                guard let sent = extractAckRequest(from: message) else {
                    Issue.record("Expected prompt/steer/follow_up message")
                    return
                }
                #expect(sent.clientTurnId != nil)

                if let requestId = sent.requestId {
                    pipe.handle(
                        .commandResult(
                            command: sent.command,
                            requestId: requestId,
                            success: false,
                            data: nil,
                            error: "rejected-by-test"
                        ),
                        sessionId: "s1"
                    )
                }
            }

            do {
                try await command.send(using: conn, text: "hello")
                Issue.record("Expected \(command.rawValue) rejection")
            } catch let error as SendAckError {
                switch error {
                case .rejected(let rejectedCommand, let reason):
                    #expect(rejectedCommand == command.rawValue)
                    #expect(reason == "rejected-by-test")
                default:
                    Issue.record("Expected rejected error, got \(error)")
                }
            } catch {
                Issue.record("Expected SendAckError.rejected, got \(error)")
            }
        }
    }

    @Test func sendAckTimeoutForPromptSteerAndFollowUp() async {
        for command in AckCommand.allCases {
            let conn = ServerConnection()
            conn._setActiveSessionIdForTesting("s1")
            conn._sendAckTimeoutForTesting = .milliseconds(40)
            conn._turnSendRetryDelayForTesting = .milliseconds(1)

            // Simulate successful socket write with no command_result ack arriving.
            conn._sendMessageForTesting = { _ in }

            do {
                try await command.send(using: conn, text: "hello")
                Issue.record("Expected \(command.rawValue) timeout")
            } catch let error as SendAckError {
                switch error {
                case .timeout(let timedOutCommand):
                    #expect(timedOutCommand == command.rawValue)
                default:
                    Issue.record("Expected timeout error, got \(error)")
                }
            } catch {
                Issue.record("Expected SendAckError.timeout, got \(error)")
            }
        }
    }

    // MARK: - Fork

    @Test func forkFromTimelineEntryUsesGetForkMessagesThenFork() async throws {
        let (conn, pipe) = makeTestConnection()
        var sentTypes: [String] = []
        var forkEntryId: String?

        conn._sendMessageForTesting = { message in
            switch message {
            case .getForkMessages(let requestId):
                sentTypes.append("get_fork_messages")
                pipe.handle(
                    .commandResult(
                        command: "get_fork_messages",
                        requestId: requestId,
                        success: true,
                        data: .object([
                            "messages": .array([
                                .object([
                                    "entryId": .string("entry-123"),
                                    "text": .string("Original user prompt"),
                                ]),
                            ]),
                        ]),
                        error: nil
                    ),
                    sessionId: "s1"
                )

            case .fork(let entryId, let requestId):
                sentTypes.append("fork")
                forkEntryId = entryId
                pipe.handle(
                    .commandResult(
                        command: "fork",
                        requestId: requestId,
                        success: true,
                        data: .object([:]),
                        error: nil
                    ),
                    sessionId: "s1"
                )

            default:
                Issue.record("Unexpected message sent: \(message.typeLabel)")
            }
        }

        try await conn.forkFromTimelineEntry("entry-123")

        #expect(sentTypes == ["get_fork_messages", "fork"])
        #expect(forkEntryId == "entry-123")
    }

    @Test func forkFromTimelineEntryParsesForkMessageIdField() async throws {
        let (conn, pipe) = makeTestConnection()
        var sentTypes: [String] = []
        var forkEntryId: String?

        conn._sendMessageForTesting = { message in
            switch message {
            case .getForkMessages(let requestId):
                sentTypes.append("get_fork_messages")
                pipe.handle(
                    .commandResult(
                        command: "get_fork_messages",
                        requestId: requestId,
                        success: true,
                        data: .object([
                            "messages": .array([
                                .object([
                                    "id": .string("fork-entry-123"),
                                    "text": .string("Original user prompt"),
                                ]),
                            ]),
                        ]),
                        error: nil
                    ),
                    sessionId: "s1"
                )

            case .fork(let entryId, let requestId):
                sentTypes.append("fork")
                forkEntryId = entryId
                pipe.handle(
                    .commandResult(
                        command: "fork",
                        requestId: requestId,
                        success: true,
                        data: .object([:]),
                        error: nil
                    ),
                    sessionId: "s1"
                )

            default:
                Issue.record("Unexpected message sent: \(message.typeLabel)")
            }
        }

        try await conn.forkFromTimelineEntry("fork-entry-123")

        #expect(sentTypes == ["get_fork_messages", "fork"])
        #expect(forkEntryId == "fork-entry-123")
    }

    @Test func forkFromTimelineEntryNormalizesTraceSyntheticIDs() async throws {
        let (conn, pipe) = makeTestConnection()
        var sentTypes: [String] = []
        var forkEntryId: String?

        conn._sendMessageForTesting = { message in
            switch message {
            case .getForkMessages(let requestId):
                sentTypes.append("get_fork_messages")
                pipe.handle(
                    .commandResult(
                        command: "get_fork_messages",
                        requestId: requestId,
                        success: true,
                        data: .object([
                            "messages": .array([
                                .object([
                                    "entryId": .string("entry-123"),
                                    "text": .string("Original user prompt"),
                                ]),
                            ]),
                        ]),
                        error: nil
                    ),
                    sessionId: "s1"
                )

            case .fork(let entryId, let requestId):
                sentTypes.append("fork")
                forkEntryId = entryId
                pipe.handle(
                    .commandResult(
                        command: "fork",
                        requestId: requestId,
                        success: true,
                        data: .object([:]),
                        error: nil
                    ),
                    sessionId: "s1"
                )

            default:
                Issue.record("Unexpected message sent: \(message.typeLabel)")
            }
        }

        try await conn.forkFromTimelineEntry("entry-123-text-0")

        #expect(sentTypes == ["get_fork_messages", "fork"])
        #expect(forkEntryId == "entry-123")
    }

    @Test func forkFromTimelineEntryRejectsNonForkableEntry() async {
        let (conn, pipe) = makeTestConnection()
        var sentTypes: [String] = []

        conn._sendMessageForTesting = { message in
            switch message {
            case .getForkMessages(let requestId):
                sentTypes.append("get_fork_messages")
                pipe.handle(
                    .commandResult(
                        command: "get_fork_messages",
                        requestId: requestId,
                        success: true,
                        data: .object([
                            "messages": .array([
                                .object([
                                    "entryId": .string("entry-allowed"),
                                    "text": .string("Allowed"),
                                ]),
                            ]),
                        ]),
                        error: nil
                    ),
                    sessionId: "s1"
                )

            case .fork:
                sentTypes.append("fork")

            default:
                Issue.record("Unexpected message sent: \(message.typeLabel)")
            }
        }

        do {
            try await conn.forkFromTimelineEntry("entry-denied")
            Issue.record("Expected entryNotForkable error")
        } catch let error as ForkRequestError {
            #expect(error == .entryNotForkable)
        } catch {
            Issue.record("Expected ForkRequestError.entryNotForkable, got \(error)")
        }

        #expect(sentTypes == ["get_fork_messages"])
    }

    // MARK: - requestState

    @Test func requestStateUsesDispatchSendHook() async throws {
        let conn = ServerConnection()
        var sawGetState = false

        conn._sendMessageForTesting = { message in
            if case .getState = message {
                sawGetState = true
            }
        }

        try await conn.requestState()
        #expect(sawGetState)
    }

    // MARK: - isConnected

    @Test func isConnectedDefaultFalse() {
        let conn = ServerConnection()
        #expect(!conn.isConnected)
    }

    // MARK: - switchServer

    @Test func switchServerConfiguresNewServer() {
        let conn = ServerConnection()
        let creds = ServerCredentials(
            host: "studio.ts.net", port: 7749, token: "sk_studio",
            name: "studio", serverFingerprint: "sha256:studio-fp"
        )
        let server = PairedServer(from: creds)!

        let result = conn.switchServer(to: server)
        #expect(result == true)
        #expect(conn.currentServerId == "sha256:studio-fp")
        #expect(conn.apiClient != nil)
    }

    @Test func switchServerSkipsIfAlreadyTargeting() {
        let conn = ServerConnection()
        let creds = ServerCredentials(
            host: "studio.ts.net", port: 7749, token: "sk_a",
            name: "studio", serverFingerprint: "sha256:same-fp"
        )
        let server = PairedServer(from: creds)!

        _ = conn.switchServer(to: server)
        // Switch to the same server again — should return true immediately
        let result = conn.switchServer(to: server)
        #expect(result == true)
        #expect(conn.currentServerId == "sha256:same-fp")
    }

    @Test func switchServerChangesTarget() {
        let conn = ServerConnection()
        let creds1 = ServerCredentials(
            host: "studio.ts.net", port: 7749, token: "sk_a",
            name: "studio", serverFingerprint: "sha256:fp-a"
        )
        let creds2 = ServerCredentials(
            host: "mini.ts.net", port: 7749, token: "sk_b",
            name: "mini", serverFingerprint: "sha256:fp-b"
        )
        let server1 = PairedServer(from: creds1)!
        let server2 = PairedServer(from: creds2)!

        _ = conn.switchServer(to: server1)
        #expect(conn.currentServerId == "sha256:fp-a")

        _ = conn.switchServer(to: server2)
        #expect(conn.currentServerId == "sha256:fp-b")
    }

    @Test func currentServerIdNilByDefault() {
        let conn = ServerConnection()
        #expect(conn.currentServerId == nil)
    }
}

private enum AckCommand: CaseIterable {
    case prompt
    case steer
    case followUp

    var rawValue: String {
        switch self {
        case .prompt: return "prompt"
        case .steer: return "steer"
        case .followUp: return "follow_up"
        }
    }

    func send(using connection: ServerConnection, text: String) async throws {
        switch self {
        case .prompt:
            try await connection.sendPrompt(text)
        case .steer:
            try await connection.sendSteer(text)
        case .followUp:
            try await connection.sendFollowUp(text)
        }
    }
}

private func extractAckRequest(from message: ClientMessage) -> (command: String, requestId: String?, clientTurnId: String?)? {
    switch message {
    case .prompt(_, _, _, let requestId, let clientTurnId):
        return ("prompt", requestId, clientTurnId)
    case .steer(_, _, let requestId, let clientTurnId):
        return ("steer", requestId, clientTurnId)
    case .followUp(_, _, let requestId, let clientTurnId):
        return ("follow_up", requestId, clientTurnId)
    default:
        return nil
    }
}

private func makeGetCommandsPayload(
    _ commands: [(name: String, description: String, source: String)]
) -> JSONValue {
    .object([
        "commands": .array(commands.map { command in
            .object([
                "name": .string(command.name),
                "description": .string(command.description),
                "source": .string(command.source),
            ])
        }),
    ])
}

private actor GetCommandsCounter {
    private var value = 0

    func record(message: ClientMessage) {
        if case .getCommands = message {
            value += 1
        }
    }

    func count() -> Int {
        value
    }
}

private actor AckStageRecorder {
    private var stages: [TurnAckStage] = []

    func record(_ stage: TurnAckStage) {
        stages.append(stage)
    }

    func snapshot() -> [TurnAckStage] {
        stages
    }
}

// MARK: - Foreground Recovery

@Suite("Foreground Recovery")
@MainActor
struct ForegroundRecoveryTests {
    @Test func reconnectIfNeededWithoutApiClientIsNoOp() async {
        let conn = ServerConnection()
        // No configure() call — apiClient is nil
        await conn.reconnectIfNeeded()
        // Should return immediately without crash
        #expect(!conn.foregroundRecoveryInFlight)
    }

    @Test func reconnectIfNeededReentrancyGuard() async {
        let conn = makeLegacyForegroundRecoveryConnection()

        // Simulate the flag being set (as if another call is in progress)
        // by calling reconnectIfNeeded and checking the flag is reset after.
        await conn.reconnectIfNeeded()
        #expect(!conn.foregroundRecoveryInFlight, "Flag should be reset after completion")
    }

    @Test func reconnectDoesNotTouchReducerTimeline() async {
        let conn = makeLegacyForegroundRecoveryConnection()
        conn._setActiveSessionIdForTesting("s1")
        let pipe = TestEventPipeline(sessionId: "s1", connection: conn)

        // Pre-populate reducer with items
        pipe.reducer.process(.agentStart(sessionId: "s1"))
        pipe.reducer.process(.textDelta(sessionId: "s1", delta: "hello world"))
        pipe.reducer.process(.agentEnd(sessionId: "s1"))
        let countBefore = pipe.reducer.items.count
        #expect(countBefore > 0)

        // reconnectIfNeeded should NOT call reducer.loadSession() which would
        // replace the timeline. API calls will fail (unreachable host) but the
        // reducer must remain untouched.
        await conn.reconnectIfNeeded()

        #expect(pipe.reducer.items.count == countBefore,
                "Foreground recovery must not replace timeline — ChatSessionManager owns that")
    }

    @Test func reconnectRefreshesWithoutActiveSession() async {
        let conn = makeLegacyForegroundRecoveryConnection()
        // No activeSessionId set — should still attempt session list refresh
        // (API calls fail to unreachable host, but no crash)
        await conn.reconnectIfNeeded()
        #expect(!conn.foregroundRecoveryInFlight)
    }

    @Test func reconnectSkipsFullListRefreshWhenRecentSyncIsFresh() async {
        let conn = makeLegacyForegroundRecoveryConnection()

        let now = Date()
        conn.sessionStore.applyServerSnapshot([makeTestSession(workspaceId: "w1")])
        conn.sessionStore.markSyncSucceeded(at: now)
        conn.workspaceStore.isLoaded = true
        conn.workspaceStore.markSyncSucceeded(at: now)

        await conn.reconnectIfNeeded()

        // If full refresh ran, unreachable host would mark these as failed.
        #expect(conn.sessionStore.lastSyncFailed == false)
        #expect(conn.workspaceStore.lastSyncFailed == false)
        #expect(!conn.foregroundRecoveryInFlight)
    }

    @Test func reconnectPerformsFullListRefreshWhenCachedDataIsStale() async {
        let conn = makeLegacyForegroundRecoveryConnection()

        let stale = Date().addingTimeInterval(-600)
        conn.sessionStore.applyServerSnapshot([makeTestSession(workspaceId: "w1")])
        conn.sessionStore.markSyncSucceeded(at: stale)
        conn.workspaceStore.isLoaded = true
        conn.workspaceStore.markSyncSucceeded(at: stale)

        await conn.reconnectIfNeeded()

        #expect(conn.sessionStore.lastSyncFailed == true)
        #expect(conn.workspaceStore.lastSyncFailed == true)
        #expect(!conn.foregroundRecoveryInFlight)
    }

    @Test func refreshSessionListSkipsNetworkWhenFreshAndNotForced() async {
        let conn = makeLegacyForegroundRecoveryConnection()

        let now = Date()
        conn.sessionStore.applyServerSnapshot([makeTestSession(workspaceId: "w1")])
        conn.sessionStore.markSyncSucceeded(at: now)

        await conn.refreshSessionList(force: false)

        #expect(conn.sessionStore.lastSyncFailed == false)
    }

    @Test func refreshSessionListSkipEmitsStructuredRefreshEvent() async {
        let conn = makeLegacyForegroundRecoveryConnection()

        let now = Date()
        conn.sessionStore.applyServerSnapshot([makeTestSession(workspaceId: "w1")])
        conn.sessionStore.markSyncSucceeded(at: now)

        var skipMetadata: [String: String] = [:]
        conn._onRefreshEventForTesting = { message, metadata, _ in
            if message == "session_list.skip" {
                skipMetadata = metadata
            }
        }

        await conn.refreshSessionList(force: false)

        #expect(skipMetadata["force"] == "0")
        #expect(skipMetadata["cachedSessionCount"] == "1")
        #expect(skipMetadata["durationMs"] != nil)
    }

    @Test func refreshSessionListForceRefreshesEvenWhenFresh() async {
        let conn = makeLegacyForegroundRecoveryConnection()

        let now = Date()
        conn.sessionStore.applyServerSnapshot([makeTestSession(workspaceId: "w1")])
        conn.sessionStore.markSyncSucceeded(at: now)

        await conn.refreshSessionList(force: true)

        #expect(conn.sessionStore.lastSyncFailed == true)
    }

    @Test func refreshWorkspaceCatalogSkipsNetworkWhenFreshAndNotForced() async {
        let conn = makeLegacyForegroundRecoveryConnection()

        let now = Date()
        conn.workspaceStore.workspaces = [makeTestWorkspace()]
        conn.workspaceStore.isLoaded = true
        conn.workspaceStore.markSyncSucceeded(at: now)

        await conn.refreshWorkspaceCatalog(force: false)

        #expect(conn.workspaceStore.lastSyncFailed == false)
    }

    @Test func syncWorkspaceSummaryFallsBackToLocalProjectionWhenNoStoredSnapshot() {
        let conn = makeLegacyForegroundRecoveryConnection()

        let rootBusy = makeTestSession(
            id: "root-busy",
            workspaceId: "w1",
            status: .busy,
            lastActivity: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let rootStopped = makeTestSession(
            id: "root-stopped",
            workspaceId: "w1",
            status: .stopped,
            lastActivity: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let errorSession = makeTestSession(
            id: "error-session",
            workspaceId: "w1",
            status: .error,
            lastActivity: Date(timeIntervalSince1970: 1_700_000_300)
        )

        conn.sessionStore.applyServerSnapshot([rootBusy, rootStopped, errorSession])
        conn.syncWorkspaceSummary(workspaceId: "w1")

        let summary = conn.workspaceStore.workspaceSummaries["w1"]
        #expect(summary?.activeCount == 2)
        #expect(summary?.stoppedCount == 1)
        #expect(summary?.hasAttention == true)
        #expect(summary?.hasErrorRoot == true)
        #expect(summary?.latestActivity == errorSession.lastActivity)
    }

    @Test func syncWorkspaceSummaryPreservesStoredCountsAndUsesLiveAttentionOverlay() {
        let conn = makeLegacyForegroundRecoveryConnection()

        conn.workspaceStore.setStoredWorkspaceSummariesForTesting([
            "w1": WorkspaceListSummary(
                workspaceId: "w1",
                activeCount: 4,
                stoppedCount: 12,
                hasAttention: true,
                hasErrorRoot: false,
                latestActivity: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ])
        conn.sessionStore.applyServerSnapshot([
            makeTestSession(
                id: "ready-root",
                workspaceId: "w1",
                status: .ready,
                lastActivity: Date(timeIntervalSince1970: 1_700_000_500)
            )
        ])

        conn.syncWorkspaceSummary(workspaceId: "w1")

        let idleSummary = conn.workspaceStore.workspaceSummaries["w1"]
        #expect(idleSummary?.activeCount == 4)
        #expect(idleSummary?.stoppedCount == 12)
        #expect(idleSummary?.hasAttention == false)
        #expect(idleSummary?.hasErrorRoot == false)
        #expect(idleSummary?.latestActivity == Date(timeIntervalSince1970: 1_700_000_500))

    }

    @Test func syncWorkspaceSummaryUsesPendingExtensionDialogAttention() {
        let conn = makeLegacyForegroundRecoveryConnection()
        let session = makeTestSession(id: "ready-root", workspaceId: "w1", status: .ready)
        conn.sessionStore.applyServerSnapshot([session])

        conn.syncWorkspaceSummary(workspaceId: "w1")
        #expect(conn.workspaceStore.workspaceSummaries["w1"]?.hasAttention == false)

        conn.storeExtensionDialog(
            ExtensionUIRequest(
                id: "ui-1",
                sessionId: "ready-root",
                method: "editor",
                title: "Dangerous command",
                prefill: "Review this change before continuing."
            ),
            for: "ready-root",
            isFocusedSession: false
        )
        #expect(conn.hasPendingExtensionDialog(for: "ready-root") == true)
        #expect(conn.workspaceStore.workspaceSummaries["w1"]?.hasAttention == true)

        conn.clearExtensionDialog(id: "ui-1")
        #expect(conn.hasPendingExtensionDialog(for: "ready-root") == false)
        #expect(conn.workspaceStore.workspaceSummaries["w1"]?.hasAttention == false)
    }

    @Test func syncWorkspaceSummaryUsesListProjectionAttentionCounts() {
        let conn = makeLegacyForegroundRecoveryConnection()
        var summary = SessionSummary(from: makeTestSession(id: "ready-root", workspaceId: "w1", status: .ready))
        summary.pendingAskCount = 1

        conn.sessionStore.upsertManySummaries([summary])
        conn.syncWorkspaceSummary(workspaceId: "w1")
        #expect(conn.workspaceStore.workspaceSummaries["w1"]?.hasAttention == true)

        summary.pendingAskCount = 0
        conn.sessionStore.upsertManySummaries([summary])
        conn.syncWorkspaceSummary(workspaceId: "w1")
        #expect(conn.workspaceStore.workspaceSummaries["w1"]?.hasAttention == false)
    }

    @Test func syncWorkspaceSummaryClearsLocalErrorOverlayOnceLiveStateRecovers() {
        let conn = makeLegacyForegroundRecoveryConnection()

        conn.workspaceStore.setStoredWorkspaceSummariesForTesting([
            "w1": WorkspaceListSummary(
                workspaceId: "w1",
                activeCount: 2,
                stoppedCount: 8,
                hasAttention: false,
                hasErrorRoot: false,
                latestActivity: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ])

        let rootError = makeTestSession(id: "root", workspaceId: "w1", status: .error)
        conn.sessionStore.applyServerSnapshot([rootError])
        conn.syncWorkspaceSummary(workspaceId: "w1")
        #expect(conn.workspaceStore.workspaceSummaries["w1"]?.hasErrorRoot == true)
        #expect(conn.workspaceStore.workspaceSummaries["w1"]?.hasAttention == true)

        let recoveredRoot = makeTestSession(id: "root", workspaceId: "w1", status: .ready)
        conn.sessionStore.applyServerSnapshot([recoveredRoot])
        conn.syncWorkspaceSummary(workspaceId: "w1")
        #expect(conn.workspaceStore.workspaceSummaries["w1"]?.hasErrorRoot == false)
        #expect(conn.workspaceStore.workspaceSummaries["w1"]?.hasAttention == false)
    }

    @Test func syncAllWorkspaceSummariesRemovesFallbackOnlyWorkspaceWhenLocalStateDisappears() {
        let conn = makeLegacyForegroundRecoveryConnection()

        conn.sessionStore.applyServerSnapshot([
            makeTestSession(id: "root", workspaceId: "w1", status: .ready)
        ])
        conn.syncAllWorkspaceSummariesFromLocalState()
        #expect(conn.workspaceStore.workspaceSummaries["w1"]?.activeCount == 1)

        conn.sessionStore.remove(id: "root")
        conn.syncAllWorkspaceSummariesFromLocalState()
        #expect(conn.workspaceStore.workspaceSummaries["w1"] == nil)
    }

    @Test func refreshWorkspaceCatalogForceEmitsEndRefreshEventWithCounts() async {
        let conn = makeLegacyForegroundRecoveryConnection()

        var endMetadata: [String: String] = [:]
        var endLevel: ClientLogLevel?
        conn._onRefreshEventForTesting = { message, metadata, level in
            if message == "workspace_catalog.end" {
                endMetadata = metadata
                endLevel = level
            }
        }

        await conn.refreshWorkspaceCatalog(force: true)

        #expect(endMetadata["force"] == "1")
        #expect(endMetadata["durationMs"] != nil)
        #expect(endMetadata["workspaceCount"] != nil)
        #expect(endMetadata["sessionCount"] != nil)
        #expect(endMetadata["skillCount"] != nil)
        #expect(endLevel != nil)
    }
}

@MainActor
private func makeLegacyForegroundRecoveryConnection() -> ServerConnection {
    let conn = ServerConnection()
    conn.configure(credentials: ServerCredentials(
        host: "test.local", port: 7749, token: "sk_test", name: "Test"
    ))
    conn.setAPIClientForTesting(makeLegacyForegroundRecoveryFailingAPIClient())
    return conn
}

private func makeLegacyForegroundRecoveryFailingAPIClient() -> APIClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [LegacyForegroundRecoveryFailingURLProtocol.self]
    config.timeoutIntervalForRequest = 0.1
    config.timeoutIntervalForResource = 0.1
    config.waitsForConnectivity = false
    return APIClient(
        baseURL: URL(string: "http://test.local:7749")!,
        token: "sk_test",
        configuration: config
    )
}

private final class LegacyForegroundRecoveryFailingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    override func stopLoading() {}
}

// MARK: - Stream Lifecycle

@Suite("Stream Lifecycle")
@MainActor
struct StreamLifecycleTests {

    // MARK: - connectStream idempotency

    @Test func connectStreamIsIdempotentWhileActive() {
        let (conn, pipe) = makeTestConnection()

        // Simulate an active consumption task by setting it directly
        let sentinel = Task<Void, Never> { }
        conn.streamConsumptionTask = sentinel
        conn.wsClient?._setStatusForTesting(.connected)

        conn.connectStream()

        // Should not replace the existing task (identity check via cancel state)
        #expect(!sentinel.isCancelled,
                "Should not cancel existing task when one is active and WS is connected")
    }

    @Test func connectStreamRestartsWhenTaskExistsButWSDisconnected() {
        let (conn, pipe) = makeTestConnection()

        // Simulate a zombie consumption task (completed but non-nil)
        // with a disconnected WS
        conn.streamConsumptionTask = Task { }
        conn.wsClient?._setStatusForTesting(.disconnected)

        conn.connectStream()

        // Should have created a NEW task (the old zombie was replaced)
        #expect(conn.streamConsumptionTask != nil,
                "Should create new task when WS is disconnected")
    }

    @Test func connectStreamCreatesTaskWhenNil() {
        let (conn, pipe) = makeTestConnection()

        #expect(conn.streamConsumptionTask == nil)

        conn.connectStream()

        #expect(conn.streamConsumptionTask != nil,
                "Should create task when none exists")
    }

    // MARK: - streamConsumptionTask self-cleanup

    @Test func consumptionTaskNilsItselfWhenStreamEnds() async {
        let (conn, pipe) = makeTestConnection()

        // Create a stream that immediately ends
        let (stream, continuation) = AsyncStream<StreamMessage>.makeStream()
        continuation.finish()

        conn.streamConsumptionTask = Task { [weak conn] in
            for await msg in stream {
                conn?.routeStreamMessage(msg)
            }
            await MainActor.run { [weak conn] in
                conn?.streamConsumptionTask = nil
            }
        }

        // Wait for the task to complete and nil itself out
        let cleaned = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { conn.streamConsumptionTask == nil }
        }

        #expect(cleaned, "streamConsumptionTask should nil itself after stream ends")
    }

    // MARK: - disconnectStream cleanup

    @Test func disconnectStreamCleansUpEverything() {
        let (conn, pipe) = makeTestConnection()
        conn.streamConsumptionTask = Task { }

        // Add a session continuation
        let (_, continuation) = AsyncStream<SessionStreamEvent>.makeStream()
        conn.sessionEventContinuations["s1"] = continuation

        conn.disconnectStream()

        #expect(conn.streamConsumptionTask == nil,
                "Should nil out consumption task")
        #expect(conn.sessionEventContinuations.isEmpty,
                "Should clear all session continuations")
    }

    @Test func disconnectStreamResetsAsrAvailability() {
        let (conn, _) = makeTestConnection()
        conn.setServerDictationAvailableForTesting(true)

        conn.disconnectStream()

        #expect(conn.serverDictationAvailable == false,
                "disconnectStream should clear stale serverDictationAvailable state")
    }

    // MARK: - stream_connected refresh handling

    @Test func streamConnectedMessageTriggersRefresh() {
        let (conn, pipe) = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")

        // Track that routeStreamMessage correctly identifies stream_connected
        // and does not yield it to session continuations (it's handled at stream level)
        var yieldedToSession = false
        let stream = AsyncStream<SessionStreamEvent> { continuation in
            conn.sessionEventContinuations["s1"] = continuation
        }
        let consumeTask = Task {
            for await _ in stream {
                await MainActor.run { yieldedToSession = true }
            }
        }

        // stream_connected should NOT be yielded to session continuations
        let streamMsg = StreamMessage(
            sessionId: nil,
            seq: nil,
            currentSeq: nil,
            message: .streamConnected(userName: "test", serverDictationAvailable: false)
        )
        conn.routeStreamMessage(streamMsg)

        // stream_connected returns early — should not reach session continuation
        #expect(!yieldedToSession,
                "stream_connected should be handled at stream level, not yielded to sessions")
        consumeTask.cancel()
    }

    // MARK: - routeStreamMessage routing

    @Test func routeStreamMessageYieldsToSessionContinuation() async {
        let (conn, pipe) = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")

        var receivedMessages: [ServerMessage] = []
        let stream = AsyncStream<SessionStreamEvent> { continuation in
            conn.sessionEventContinuations["s1"] = continuation
        }

        // Start consuming
        let consumeTask = Task {
            for await event in stream {
                await MainActor.run { receivedMessages.append(event.message) }
            }
        }

        let streamMsg = StreamMessage(
            sessionId: "s1",
            seq: 1,
            currentSeq: nil,
            message: .agentStart
        )
        conn.routeStreamMessage(streamMsg)

        let received = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { !receivedMessages.isEmpty }
        }

        consumeTask.cancel()

        #expect(received, "Message should be yielded to session continuation")
    }


    // MARK: - reconnectIfNeeded restarts dead stream

    @Test func reconnectIfNeededRestartsDeadBoundSessionStream() async {
        let (conn, _) = makeTestConnection()
        let now = Date()
        conn.sessionStore.applyServerSnapshot([makeTestSession(id: "s1")])
        conn.sessionStore.markSyncSucceeded(at: now)
        conn.workspaceStore.workspaces = [makeTestWorkspace(id: "w1")]
        conn.workspaceStore.isLoaded = true
        conn.workspaceStore.markSyncSucceeded(at: now)
        conn.setFocusedSessionStreamEndpointKindForTesting("split_session")
        let streamFactory = ScriptedFrameStreamFactory()
        conn._connectStreamForTesting = { streamFactory.makeStream() }

        // Simulate a dead bound WS (disconnected, no consumption task)
        conn.wsClient?._setStatusForTesting(.disconnected)
        conn.streamConsumptionTask = nil

        // Track whether connectStream re-creates the task
        #expect(conn.streamConsumptionTask == nil)

        await conn.reconnectIfNeeded()

        // connectStream should have been called, creating a new task
        #expect(await streamFactory.waitForCreated(1, timeoutMs: 100))
        #expect(conn.streamConsumptionTask != nil,
                "reconnectIfNeeded should restart a prepared bound session stream")

        streamFactory.finish(index: 0)
        conn.streamConsumptionTask?.cancel()
        conn.disconnectStream()
    }

    @Test func reconnectIfNeededSkipsFocusedSessionWithoutBoundStreamEndpoint() async {
        let (conn, _) = makeTestConnection()
        let now = Date()
        conn.sessionStore.applyServerSnapshot([makeTestSession(id: "s1")])
        conn.sessionStore.markSyncSucceeded(at: now)
        conn.workspaceStore.workspaces = [makeTestWorkspace(id: "w1")]
        conn.workspaceStore.isLoaded = true
        conn.workspaceStore.markSyncSucceeded(at: now)

        conn.wsClient?._setStatusForTesting(.disconnected)
        conn.streamConsumptionTask = nil

        await conn.reconnectIfNeeded()

        #expect(conn.streamConsumptionTask == nil,
                "Foreground recovery should not open a focused-session WebSocket before a bound stream endpoint is prepared")
        #expect(conn.wsClient?.status == .disconnected)
    }

    @Test func reconnectIfNeededSkipsAliveStream() async {
        let (conn, pipe) = makeTestConnection()

        // Simulate an active WS
        conn.wsClient?._setStatusForTesting(.connected)
        let sentinel = Task<Void, Never> { }
        conn.streamConsumptionTask = sentinel

        await conn.reconnectIfNeeded()

        // The existing task should not have been cancelled/replaced
        #expect(!sentinel.isCancelled,
                "Should not replace an active consumption task")
    }

    // MARK: - routeStreamMessage resolves command waiters at stream boundary


    @Test func routeStreamMessageResolvesCommandResultsAtBoundary() async {
        let (conn, pipe) = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")

        let pending = PendingCommand(command: "set_model", requestId: "req-m")
        conn.commands.registerCommand(pending)

        _ = AsyncStream<SessionStreamEvent> { continuation in
            conn.sessionEventContinuations["s1"] = continuation
        }

        let streamMsg = StreamMessage(
            sessionId: "s1",
            seq: 1,
            currentSeq: nil,
            message: .commandResult(
                command: "set_model", requestId: "req-m",
                success: true, data: nil, error: nil
            )
        )
        conn.routeStreamMessage(streamMsg)

        let result = try? await pending.waiter.wait()
        #expect(result != nil, "All requestId command results should resolve at stream boundary")
        _ = pipe
    }

    // MARK: - Workspace summary attention sync

    @Test func workspaceAttentionSnapshotClearsStaleWorkspaceBadge() {
        let (conn, _) = makeTestConnection()
        conn.sessionStore.upsert(makeTestSession(id: "s1", workspaceId: "w1"))
        conn.workspaceStore.setStoredWorkspaceSummariesForTesting([
            "w1": WorkspaceListSummary(
                workspaceId: "w1",
                activeCount: 1,
                stoppedCount: 12,
                hasAttention: true,
                hasErrorRoot: false
            )
        ])
        conn.storeAskRequest(
            AskRequest(id: "a1", sessionId: "s1", questions: [], allowCustom: true, timeout: nil, workspaceId: "w1"),
            for: "s1",
            isFocusedSession: true
        )

        conn.applyWorkspaceAttentionSnapshot(
            APIClient.WorkspaceAttentionResponse(
                workspaceId: "w1",
                serverNow: 0,
                attention: .init(asks: [])
            )
        )

        #expect(conn.askRequestStore.pending.isEmpty)
        #expect(conn.workspaceStore.workspaceSummaries["w1"]?.hasAttention == false)
        #expect(conn.workspaceStore.workspaceSummaries["w1"]?.hasErrorRoot == false)
    }

    @Test func workspaceAttentionSnapshotPreservesRootErrorAttention() {
        let (conn, _) = makeTestConnection()
        conn.sessionStore.upsert(makeTestSession(id: "s1", workspaceId: "w1"))
        conn.workspaceStore.setStoredWorkspaceSummariesForTesting([
            "w1": WorkspaceListSummary(
                workspaceId: "w1",
                activeCount: 1,
                stoppedCount: 12,
                hasAttention: true,
                hasErrorRoot: true
            )
        ])
        conn.storeAskRequest(
            AskRequest(id: "a1", sessionId: "s1", questions: [], allowCustom: true, timeout: nil, workspaceId: "w1"),
            for: "s1",
            isFocusedSession: true
        )

        conn.applyWorkspaceAttentionSnapshot(
            APIClient.WorkspaceAttentionResponse(
                workspaceId: "w1",
                serverNow: 0,
                attention: .init(asks: [])
            )
        )

        #expect(conn.workspaceStore.workspaceSummaries["w1"]?.hasAttention == true)
        #expect(conn.workspaceStore.workspaceSummaries["w1"]?.hasErrorRoot == true)
    }


    @Test func askLifecycleSyncsWorkspaceSummaryAttention() {
        let (conn, _) = makeTestConnection()
        conn.sessionStore.upsert(makeTestSession(id: "s1", workspaceId: "w1"))
        conn.workspaceStore.setStoredWorkspaceSummariesForTesting([
            "w1": WorkspaceListSummary(
                workspaceId: "w1",
                activeCount: 1,
                stoppedCount: 0,
                hasAttention: false,
                hasErrorRoot: false
            )
        ])
        let ask = AskRequest(
            id: "a1",
            sessionId: "s1",
            questions: [],
            allowCustom: true,
            timeout: nil,
            workspaceId: "w1"
        )

        conn.storeAskRequest(ask, for: "s1", isFocusedSession: true)
        #expect(conn.workspaceStore.workspaceSummaries["w1"]?.hasAttention == true)

        conn.clearAskState(for: "s1")
        #expect(conn.workspaceStore.workspaceSummaries["w1"]?.hasAttention == false)
    }

    // MARK: - Split stream disconnect cleanup


}
