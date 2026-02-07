import SwiftUI

struct ChatView: View {
    let sessionId: String

    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var sessionStore
    @Environment(PermissionStore.self) private var permissionStore
    @Environment(TimelineReducer.self) private var reducer

    @State private var isNearBottom = true
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

    /// Short model display name (e.g. "claude-opus-4-6" from "anthropic/claude-opus-4-6").
    private var modelShortName: String? {
        guard let model = session?.model else { return nil }
        return model.split(separator: "/").last.map(String.init) ?? model
    }

    /// Context usage string like "44.4%/200k".
    private var contextDisplay: String? {
        guard let window = resolvedContextWindow, window > 0 else {
            return nil
        }

        let used = max(
            0,
            session?.contextTokens ?? ((session?.tokens.input ?? 0) + (session?.tokens.output ?? 0))
        )
        let percent = Double(used) / Double(window) * 100
        let windowK = formatTokenCount(window)
        return String(format: "%.1f%%/%@", percent, windowK)
    }

    private var resolvedContextWindow: Int? {
        if let window = session?.contextWindow, window > 0 {
            return window
        }
        guard let model = session?.model else { return nil }
        return inferContextWindow(from: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Status bar — model + context usage (like pi TUI footer)
            if modelShortName != nil || contextDisplay != nil {
                HStack(spacing: 8) {
                    if let context = contextDisplay {
                        Text(context)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tokyoFg)
                    }

                    if let model = modelShortName {
                        Text(model)
                            .font(.caption)
                            .foregroundStyle(.tokyoFgDim)
                    }

                    if let cost = session?.cost, cost > 0 {
                        Spacer()
                        Text(String(format: "$%.3f", cost))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tokyoFgDim)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(Color.tokyoBgHighlight)
            }

            // Chat timeline + permission pill (inside ScrollViewReader for scroll-to)
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

                        // Invisible bottom sentinel for auto-scroll
                        Color.clear
                            .frame(height: 1)
                            .id("bottom-sentinel")
                            .onAppear { isNearBottom = true }
                            .onDisappear { isNearBottom = false }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
                .background(Color.tokyoBg)
                .overlay {
                    // Empty state — only when truly empty (not loading)
                    if reducer.items.isEmpty && !isBusy {
                        ChatEmptyState()
                    }
                }
                .onChange(of: reducer.renderVersion) { _, _ in
                    guard isNearBottom else {
                        return
                    }
                    withAnimation(nil) {
                        proxy.scrollTo("bottom-sentinel", anchor: .bottom)
                    }
                }
                .onChange(of: needsInitialScroll) { _, needs in
                    guard needs else {
                        return
                    }
                    needsInitialScroll = false
                    // Delay to let LazyVStack layout
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(nil) {
                            proxy.scrollTo("bottom-sentinel", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: scrollTargetID) { _, target in
                    guard let target else {
                        return
                    }
                    scrollTargetID = nil
                    // Brief delay to let sheet dismiss
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(target, anchor: .top)
                        }
                    }
                }

                // Permission pill banner — taps scroll to first pending permission
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
            SessionOutlineView(items: reducer.items) { targetID in
                scrollTargetID = targetID
            }
            .presentationDetents([.medium, .large])
        }
        .task(id: connectionGeneration) {
            await connectToSession()
        }
        .onAppear {
            if hasAppeared {
                connectionGeneration &+= 1
            } else {
                hasAppeared = true
                // Restore draft from background if available
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
            // Save draft before disconnect
            let draft = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            connection.composerDraft = draft.isEmpty ? nil : draft
            connection.disconnectSession()
        }
    }

    // MARK: - Actions

    private func connectToSession() async {
        // Disconnect any prior session and clear stale timeline.
        // This runs first to prevent stale data from a previous session
        // bleeding into a new one on rapid switches.
        connection.disconnectSession()
        reducer.reset()

        sessionStore.activeSessionId = sessionId

        // Start Live Activity for this session
        let sessionName = session?.name ?? "Session"
        LiveActivityManager.shared.start(sessionId: sessionId, sessionName: sessionName)

        // Load full trace (tool calls + results) or fall back to messages.
        // Check Task.isCancelled after each async boundary to bail early
        // when the user switches sessions during loading.
        if let api = connection.apiClient {
            do {
                let (session, trace) = try await api.getSessionTrace(id: sessionId)
                guard !Task.isCancelled else { return }
                sessionStore.upsert(session)
                if !trace.isEmpty {
                    reducer.loadFromTrace(trace)
                    needsInitialScroll = true
                }
            } catch {
                guard !Task.isCancelled else { return }
                // Fall back to basic messages if trace endpoint unavailable
                do {
                    let (session, messages) = try await api.getSession(id: sessionId)
                    guard !Task.isCancelled else { return }
                    sessionStore.upsert(session)
                    reducer.loadFromREST(messages)
                    if !messages.isEmpty {
                        needsInitialScroll = true
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    // Continue without history
                }
            }
        }

        guard !Task.isCancelled else { return }
        guard let stream = connection.streamSession(sessionId) else {
            reducer.process(.error(sessionId: sessionId, message: "WebSocket unavailable"))
            return
        }

        for await message in stream {
            if Task.isCancelled {
                break
            }
            connection.handleServerMessage(message, sessionId: sessionId)
        }

        // Ensure pending deltas are flushed when stream ends.
        connection.disconnectSession()
    }

    private func sendPrompt() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return
        }
        inputText = ""
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let messageId = reducer.appendUserMessage(text)

        Task { @MainActor in
            do {
                try await connection.sendPrompt(text)
            } catch {
                // Retract the optimistic message and restore input text for retry
                reducer.removeItem(id: messageId)
                inputText = text
                reducer.process(.error(sessionId: sessionId, message: "Failed to send: \(error.localizedDescription)"))
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
                guard !Task.isCancelled else {
                    return
                }
                if isBusy {
                    showForceStop = true
                }
            }

            // Safety net: if still busy after 10s, the WS agentEnd may have been lost.
            // Fetch session state from REST to reconcile.
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

    /// Fetch session state from REST to reconcile a possibly-stale local status.
    /// Called after stop timeout as a safety net for lost WS messages.
    private func reconcileSessionState() async {
        guard let api = connection.apiClient else { return }
        do {
            let (session, _) = try await api.getSession(id: sessionId)
            sessionStore.upsert(session)
        } catch {
            // Silently fail — next foreground transition will retry
        }
    }

    private func forceStopSession() {
        guard let api = connection.apiClient, !isForceStopInFlight else {
            return
        }

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

// MARK: - Token Formatting

/// Best-effort context window fallback when older sessions don't store it yet.
private func inferContextWindow(from model: String) -> Int? {
    let known: [String: Int] = [
        "anthropic/claude-opus-4-6": 200_000,
        "anthropic/claude-sonnet-4-0": 200_000,
        "anthropic/claude-haiku-3-5": 200_000,
        "openai/o3": 200_000,
        "openai/o4-mini": 200_000,
        "openai/gpt-4.1": 1_000_000,
        "google/gemini-2.5-pro": 1_000_000,
        "google/gemini-2.5-flash": 1_000_000,
        "lmstudio/qwen3-32b": 32_768,
        "lmstudio/deepseek-r1-0528-qwen3-8b": 32_768,
    ]
    if let value = known[model] {
        return value
    }

    // Generic "...-272k" / "..._128k" model naming convention fallback.
    if let match = model.range(of: #"(?i)(\d{2,4})k\b"#, options: .regularExpression) {
        let raw = model[match].dropLast() // remove trailing k/K
        if let thousands = Int(raw) {
            return thousands * 1_000
        }
    }

    return nil
}

/// Format token count as compact string: 200000 → "200k", 1000000 → "1M".
private func formatTokenCount(_ count: Int) -> String {
    if count >= 1_000_000 {
        let m = Double(count) / 1_000_000
        if m == m.rounded() {
            return String(format: "%.0fM", m)
        }
        return String(format: "%.1fM", m)
    }
    if count >= 1_000 {
        let k = Double(count) / 1_000
        if k == k.rounded() {
            return String(format: "%.0fk", k)
        }
        return String(format: "%.1fk", k)
    }
    return "\(count)"
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
        // Fade in from 0.3 to 1.0 and back
        return 0.3 + 0.7 * max(0, 1 - abs(adjusted - 0.5) * 4)
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

                    // Token + cost summary
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
