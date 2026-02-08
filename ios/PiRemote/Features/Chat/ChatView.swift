import SwiftUI

struct ChatView: View {
    let sessionId: String

    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var sessionStore
    @Environment(PermissionStore.self) private var permissionStore
    @Environment(TimelineReducer.self) private var reducer

    /// Non-reactive scroll anchor. Using a reference type avoids triggering
    /// SwiftUI body re-evaluations when the sentinel appears/disappears.
    /// A `@State` Bool here creates a layout feedback loop: sentinel flickers
    /// → state change → body re-eval → layout → sentinel flickers → freeze.
    @State private var scrollAnchor = ScrollAnchorState()
    /// Debounce task for scroll-to-bottom during streaming.
    @State private var scrollTask: Task<Void, Never>?
    @State private var inputText = ""
    @State private var isStopping = false
    @State private var showForceStop = false
    @State private var isForceStopInFlight = false
    @State private var forceStopTask: Task<Void, Never>?
    /// Auto-fetches session state from REST if WS `agentEnd` was lost after stop.
    @State private var reconcileTask: Task<Void, Never>?
    /// Bumped on re-appear to force `.task(id:)` restart even for same sessionId.
    @State private var connectionGeneration = 0
    /// Tracks first appearance so initial connection doesn't double-start.
    @State private var hasAppeared = false
    /// Set after initial load to trigger scroll-to-bottom.
    @State private var needsInitialScroll = false
    /// Set by outline view to scroll to a specific item.
    @State private var scrollTargetID: String?
    /// Shows the session outline sheet.
    @State private var showOutline = false
    /// Shows the model picker sheet.
    @State private var showModelPicker = false
    /// Shows the rename session alert.
    @State private var showRenameAlert = false
    /// Text field value for rename alert.
    @State private var renameText = ""

    private var session: Session? {
        sessionStore.sessions.first { $0.id == sessionId }
    }

    private var isBusy: Bool {
        session?.status == .busy
    }

    private var isStopped: Bool {
        session?.status == .stopped
    }

    private var pendingPermissions: [PermissionRequest] {
        permissionStore.pending(for: sessionId)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Interactive toolbar — model, thinking, context, overflow menu
            SessionToolbar(
                session: session,
                thinkingLevel: connection.thinkingLevel,
                onModelTap: { showModelPicker = true },
                onThinkingCycle: cycleThinkingLevel,
                onCompact: compactContext,
                onRename: {
                    renameText = session?.name ?? ""
                    showRenameAlert = true
                },
                onNewSession: newSessionInWorkspace
            )

            if let runtime = session?.runtime {
                RuntimeModeStrip(runtime: runtime)
            }

            // Chat timeline + permission pill
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(reducer.items) { item in
                            ChatItemRow(
                                item: item,
                                isStreaming: item.id == reducer.streamingAssistantID
                            )
                            .id(item.id)
                        }

                        // Working indicator — shows when busy with no streaming content
                        if isBusy && reducer.streamingAssistantID == nil {
                            WorkingIndicator()
                                .id("working-indicator")
                        }

                        // Invisible bottom sentinel for auto-scroll.
                        // Uses non-reactive scrollAnchor to avoid @State
                        // toggling that can cause layout feedback loops.
                        Color.clear
                            .frame(height: 1)
                            .id("bottom-sentinel")
                            .onAppear { scrollAnchor.isNearBottom = true }
                            .onDisappear { scrollAnchor.isNearBottom = false }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
                .background(Color.tokyoBg)
                .overlay {
                    if reducer.items.isEmpty && !isBusy {
                        ChatEmptyState()
                    }
                }
                .onChange(of: reducer.renderVersion) { _, _ in
                    guard scrollAnchor.isNearBottom else { return }
                    // Throttle: if a scroll is already scheduled, let it
                    // complete instead of cancelling + restarting. The
                    // debounce pattern (cancel + reschedule) creates a
                    // cancel loop during 33ms streaming — the 150ms wait
                    // is always interrupted, so the scroll never fires.
                    guard scrollTask == nil else { return }
                    scrollTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        scrollTask = nil
                        guard !Task.isCancelled else { return }
                        // Re-check AFTER throttle — user may have scrolled
                        // up during the wait, flipping isNearBottom to false.
                        guard scrollAnchor.isNearBottom else { return }
                        withAnimation(nil) {
                            proxy.scrollTo("bottom-sentinel", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: needsInitialScroll) { _, needs in
                    guard needs else { return }
                    needsInitialScroll = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(nil) {
                            proxy.scrollTo("bottom-sentinel", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: scrollTargetID) { _, target in
                    guard let target else { return }
                    scrollTargetID = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(target, anchor: .top)
                        }
                    }
                }

                // Permission pill banner
                if !pendingPermissions.isEmpty {
                    PermissionPillBanner(count: pendingPermissions.count)
                        .onTapGesture {
                            guard let firstPendingId = pendingPermissions.first?.id else {
                                return
                            }
                            withAnimation {
                                proxy.scrollTo(firstPendingId, anchor: .center)
                            }
                        }
                }
            }

            // Input bar or session-ended footer
            if isStopped {
                SessionEndedFooter(session: session)
            } else {
                ChatInputBar(
                    text: $inputText,
                    isBusy: isBusy,
                    isStopping: isStopping,
                    showForceStop: showForceStop,
                    isForceStopInFlight: isForceStopInFlight,
                    onSend: sendPrompt,
                    onBash: sendBashCommand,
                    onStop: stopAgent,
                    onForceStop: forceStopSession
                )
            }
        }
        .background(Color.tokyoBg.ignoresSafeArea())
        .navigationTitle(session?.name ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    if !reducer.items.isEmpty {
                        Button {
                            showOutline = true
                        } label: {
                            Image(systemName: "list.bullet")
                                .font(.subheadline)
                        }
                    }
                    Circle()
                        .fill(session?.status.color ?? .tokyoComment)
                        .frame(width: 10, height: 10)
                }
            }
        }
        .sheet(isPresented: $showOutline) {
            SessionOutlineView(
                items: reducer.items,
                onSelect: { targetID in
                    scrollTargetID = targetID
                },
                onFork: { entryId in
                    // Guard against local in-flight IDs (UUID placeholders)
                    // that are not valid ancestry entry IDs on the server.
                    if UUID(uuidString: entryId) != nil {
                        reducer.process(.error(sessionId: sessionId, message: "Wait for this turn to finish before forking."))
                        return
                    }

                    Task {
                        do {
                            try await connection.send(.fork(entryId: entryId))
                        } catch {
                            reducer.process(.error(sessionId: sessionId, message: "Fork failed: \(error.localizedDescription)"))
                        }
                    }
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(currentModel: session?.model) { model in
                let previousModel = session?.model
                let fullModelId = model.id.hasPrefix("\(model.provider)/")
                    ? model.id
                    : "\(model.provider)/\(model.id)"

                // Optimistic model label update in toolbar.
                if var optimistic = session {
                    optimistic.model = fullModelId
                    sessionStore.upsert(optimistic)
                }

                Task { @MainActor in
                    do {
                        // model.id is "provider/model-name" — strip prefix for RPC
                        let modelId: String
                        if model.id.hasPrefix("\(model.provider)/") {
                            modelId = String(model.id.dropFirst(model.provider.count + 1))
                        } else {
                            modelId = model.id
                        }
                        try await connection.setModel(provider: model.provider, modelId: modelId)
                        try? await connection.requestState()
                    } catch {
                        // Roll back optimistic model on failure.
                        if var rollback = sessionStore.sessions.first(where: { $0.id == sessionId }) {
                            rollback.model = previousModel
                            sessionStore.upsert(rollback)
                        }
                        reducer.process(.error(sessionId: sessionId, message: "Failed to set model: \(error.localizedDescription)"))
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .alert("Rename Session", isPresented: $showRenameAlert) {
            TextField("Session name", text: $renameText)
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }

                let previousName = session?.name

                // Optimistic title update in nav + session list.
                if var optimistic = session {
                    optimistic.name = name
                    sessionStore.upsert(optimistic)
                }

                Task { @MainActor in
                    do {
                        try await connection.setSessionName(name)
                        try? await connection.requestState()
                    } catch {
                        // Roll back optimistic rename on failure.
                        if var rollback = sessionStore.sessions.first(where: { $0.id == sessionId }) {
                            rollback.name = previousName
                            sessionStore.upsert(rollback)
                        }
                        reducer.process(.error(sessionId: sessionId, message: "Rename failed: \(error.localizedDescription)"))
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a new name for this session.")
        }
        .task(id: connectionGeneration) {
            let generation = connectionGeneration
            await connectToSession(generation: generation)
        }
        .onAppear {
            if hasAppeared {
                connectionGeneration &+= 1
            } else {
                hasAppeared = true
                if let draft = connection.composerDraft, !draft.isEmpty {
                    inputText = draft
                    connection.composerDraft = nil
                }
            }
        }
        .onChange(of: session?.status) { _, newStatus in
            if newStatus != .busy {
                isStopping = false
                showForceStop = false
                isForceStopInFlight = false
                forceStopTask?.cancel()
                forceStopTask = nil
                reconcileTask?.cancel()
                reconcileTask = nil
            }
        }
        .onDisappear {
            forceStopTask?.cancel()
            forceStopTask = nil
            reconcileTask?.cancel()
            reconcileTask = nil
            scrollTask?.cancel()
            scrollTask = nil
            let draft = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            connection.composerDraft = draft.isEmpty ? nil : draft
            connection.disconnectSession()
        }
    }

    // MARK: - Actions

    @MainActor
    private func connectToSession(generation: Int) async {
        let switchingSessions = sessionStore.activeSessionId != sessionId

        connection.disconnectSession()
        if switchingSessions {
            reducer.reset()
        }

        sessionStore.activeSessionId = sessionId

        let sessionName = session?.name ?? "Session"
        LiveActivityManager.shared.start(sessionId: sessionId, sessionName: sessionName)

        if let api = connection.apiClient {
            _ = await loadBestAvailableHistory(api: api)
        }

        guard !Task.isCancelled else {
            disconnectIfCurrentGeneration(generation)
            return
        }

        guard let stream = connection.streamSession(sessionId) else {
            reducer.process(.error(sessionId: sessionId, message: "WebSocket unavailable"))
            return
        }

        if Task.isCancelled {
            disconnectIfCurrentGeneration(generation)
            return
        }

        do {
            try await connection.requestState()
        } catch {
            // Best-effort sync
        }

        if Task.isCancelled {
            disconnectIfCurrentGeneration(generation)
            return
        }

        for await message in stream {
            if Task.isCancelled {
                break
            }
            connection.handleServerMessage(message, sessionId: sessionId)
        }

        disconnectIfCurrentGeneration(generation)
    }

    @MainActor
    @discardableResult
    private func loadBestAvailableHistory(api: APIClient) async -> Bool {
        do {
            let (traceSession, trace) = try await api.getSessionTrace(id: sessionId)
            guard !Task.isCancelled else {
                return false
            }
            sessionStore.upsert(traceSession)

            // Prefer full trace when it appears complete. If trace misses older
            // turns (parser/file gaps), fall back to REST messages to preserve
            // canonical conversation history.
            if !trace.isEmpty, traceAppearsComplete(trace, messageCount: traceSession.messageCount) {
                reducer.loadFromTrace(trace)
                needsInitialScroll = true
                return true
            }

            do {
                let (restSession, messages) = try await api.getSession(id: sessionId)
                guard !Task.isCancelled else {
                    return false
                }
                sessionStore.upsert(restSession)
                reducer.loadFromREST(messages)
                needsInitialScroll = !messages.isEmpty
                return true
            } catch {
                guard !Task.isCancelled else {
                    return false
                }
                if !trace.isEmpty {
                    reducer.loadFromTrace(trace)
                    needsInitialScroll = true
                    return true
                }
                return false
            }
        } catch {
            guard !Task.isCancelled else {
                return false
            }

            do {
                let (restSession, messages) = try await api.getSession(id: sessionId)
                guard !Task.isCancelled else {
                    return false
                }
                sessionStore.upsert(restSession)
                reducer.loadFromREST(messages)
                needsInitialScroll = !messages.isEmpty
                return true
            } catch {
                guard !Task.isCancelled else {
                    return false
                }
                return false
            }
        }
    }

    private func traceAppearsComplete(_ trace: [TraceEvent], messageCount: Int) -> Bool {
        guard messageCount > 0 else {
            return true
        }

        let traceMessageCount = trace.reduce(into: 0) { count, event in
            if event.type == .user || event.type == .assistant {
                count += 1
            }
        }
        return traceMessageCount >= messageCount
    }

    @MainActor
    private func disconnectIfCurrentGeneration(_ generation: Int) {
        guard generation == connectionGeneration else {
            return
        }
        connection.disconnectSession()
    }

    private func sendPrompt() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""

        if isBusy {
            // Steer the running agent — don't start a new turn.
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            reducer.appendSystemEvent("→ \(text)")

            Task { @MainActor in
                do {
                    try await connection.send(.steer(message: text))
                } catch {
                    inputText = text
                    reducer.process(.error(sessionId: sessionId, message: "Steer failed: \(error.localizedDescription)"))
                }
            }
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            let messageId = reducer.appendUserMessage(text)

            Task { @MainActor in
                do {
                    try await connection.sendPrompt(text)
                } catch {
                    reducer.removeItem(id: messageId)
                    inputText = text
                    reducer.process(.error(sessionId: sessionId, message: "Failed to send: \(error.localizedDescription)"))
                }
            }
        }
    }

    private func sendBashCommand(_ command: String) {
        inputText = ""
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // Show the command as a system event before output arrives
        reducer.appendSystemEvent("$ \(command)")

        Task { @MainActor in
            do {
                try await connection.runBash(command)
            } catch {
                reducer.process(.error(sessionId: sessionId, message: "Bash failed: \(error.localizedDescription)"))
            }
        }
    }

    private func cycleThinkingLevel() {
        Task {
            do {
                try await connection.cycleThinkingLevel()
            } catch {
                reducer.process(.error(sessionId: sessionId, message: "Failed to cycle thinking: \(error.localizedDescription)"))
            }
        }
    }

    private func newSessionInWorkspace() {
        Task { @MainActor in
            do {
                try await connection.newSession()
                try? await connection.requestState()
            } catch {
                reducer.process(.error(sessionId: sessionId, message: "New session failed: \(error.localizedDescription)"))
            }
        }
    }

    private func compactContext() {
        Task { @MainActor in
            do {
                try await connection.compact()
                try? await connection.requestState()
            } catch {
                reducer.process(.error(sessionId: sessionId, message: "Compact failed: \(error.localizedDescription)"))
            }
        }
    }

    private func stopAgent() {
        isStopping = true
        showForceStop = false

        forceStopTask?.cancel()
        forceStopTask = nil

        Task { @MainActor in
            do {
                try await connection.sendStop()
            } catch {
                isStopping = false
                reducer.process(.error(sessionId: sessionId, message: "Failed to stop: \(error.localizedDescription)"))
                return
            }

            forceStopTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                if isBusy {
                    showForceStop = true
                }
            }

            reconcileTask?.cancel()
            reconcileTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                if isBusy {
                    await reconcileSessionState()
                }
            }
        }
    }

    private func reconcileSessionState() async {
        guard let api = connection.apiClient else { return }
        do {
            let (session, _) = try await api.getSession(id: sessionId)
            sessionStore.upsert(session)
        } catch {
            // Next foreground transition will retry
        }
    }

    private func forceStopSession() {
        guard let api = connection.apiClient, !isForceStopInFlight else { return }

        isForceStopInFlight = true

        Task { @MainActor in
            do {
                let updatedSession = try await api.stopSession(id: sessionId)
                sessionStore.upsert(updatedSession)
                reducer.appendSystemEvent("Session force-stopped")
            } catch {
                reducer.process(.error(sessionId: sessionId, message: "Force stop failed: \(error.localizedDescription)"))
            }
            isForceStopInFlight = false
        }
    }
}

// MARK: - Empty State

private struct ChatEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("π")
                .font(.system(size: 48, design: .monospaced).weight(.bold))
                .foregroundStyle(.tokyoPurple.opacity(0.5))
            Text("Send a message to start")
                .font(.subheadline)
                .foregroundStyle(.tokyoComment)
            Text("Tip: prefix with $ for shell commands")
                .font(.caption)
                .foregroundStyle(.tokyoComment.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Working Indicator

private struct WorkingIndicator: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("π")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(.tokyoPurple)

            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.tokyoComment)
                        .frame(width: 6, height: 6)
                        .opacity(dotOpacity(index: i))
                }
            }
            .padding(.top, 8)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func dotOpacity(index: Int) -> Double {
        let offset = Double(index) / 3.0
        let adjusted = (phase + offset).truncatingRemainder(dividingBy: 1.0)
        return 0.3 + 0.7 * max(0, 1 - abs(adjusted - 0.5) * 4)
    }
}

// MARK: - Runtime Mode Strip

private struct RuntimeModeStrip: View {
    let runtime: String

    private var isHost: Bool { runtime == "host" }

    private var icon: String {
        isHost ? "exclamationmark.triangle.fill" : "shippingbox.fill"
    }

    private var title: String {
        isHost ? "HOST MODE" : "CONTAINER MODE"
    }

    private var subtitle: String {
        isHost
            ? "Direct access to macOS host filesystem and tools"
            : "Isolated workspace runtime"
    }

    private var foreground: Color {
        isHost ? .tokyoOrange : .tokyoGreen
    }

    private var background: Color {
        isHost ? .tokyoOrange.opacity(0.20) : .tokyoGreen.opacity(0.18)
    }

    private var border: Color {
        isHost ? .tokyoOrange.opacity(0.8) : .tokyoGreen.opacity(0.75)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.bold())
                .foregroundStyle(foreground)

            Text(title)
                .font(.caption.monospaced().bold())
                .foregroundStyle(foreground)

            Text("•")
                .font(.caption)
                .foregroundStyle(.tokyoComment)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.tokyoFgDim)

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 7)
        .background(background)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(border)
                .frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(border)
                .frame(height: 1)
        }
    }
}

// MARK: - Session Ended Footer

private struct SessionEndedFooter: View {
    let session: Session?

    var body: some View {
        VStack(spacing: 6) {
            Divider()
                .overlay(Color.tokyoComment.opacity(0.3))

            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.tokyoComment)

                Text("Session ended")
                    .font(.subheadline)
                    .foregroundStyle(.tokyoComment)

                if let session {
                    Spacer()

                    let totalTokens = session.tokens.input + session.tokens.output
                    if totalTokens > 0 {
                        Text(formatTokenCount(totalTokens) + " tokens")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tokyoComment)
                    }

                    if session.cost > 0 {
                        Text(String(format: "$%.3f", session.cost))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tokyoComment)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Scroll Anchor (non-reactive)

/// Tracks whether the user is near the bottom of the scroll view.
///
/// Deliberately NOT `@Observable` — mutations must NOT trigger SwiftUI
/// body re-evaluations. A reactive version (`@State Bool`) creates a
/// feedback loop: sentinel onAppear/onDisappear toggles state → body
/// re-evaluates → layout pass → sentinel visibility changes → loop.
///
/// This class is stored in `@State` (reference survives re-renders)
/// but property changes are invisible to SwiftUI's observation system.
private final class ScrollAnchorState {
    var isNearBottom = true
}

// MARK: - Permission Pill

private struct PermissionPillBanner: View {
    let count: Int

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.tokyoOrange)
            Text("\(count) pending — tap to review")
                .font(.subheadline.bold())
                .foregroundStyle(.tokyoFg)
            Spacer()
            Image(systemName: "chevron.down")
                .font(.caption)
                .foregroundStyle(.tokyoComment)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.tokyoBgHighlight)
    }
}
