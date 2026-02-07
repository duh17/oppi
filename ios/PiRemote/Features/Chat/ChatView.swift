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
    @State private var forceStopTask: Task<Void, Never>?
    /// Bumped on re-appear to force `.task(id:)` restart even for same sessionId.
    @State private var connectionGeneration = 0
    /// Tracks first appearance so initial connection doesn't double-start.
    @State private var hasAppeared = false
    /// Set after initial load to trigger scroll-to-bottom.
    @State private var needsInitialScroll = false

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
            // Chat timeline + permission pill (inside ScrollViewReader for scroll-to)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(reducer.items) { item in
                            ChatItemRow(item: item)
                                .id(item.id)
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
                .onChange(of: reducer.renderVersion) { _, _ in
                    guard isNearBottom else { return }
                    withAnimation(nil) {
                        proxy.scrollTo("bottom-sentinel", anchor: .bottom)
                    }
                }
                .onChange(of: needsInitialScroll) { _, needs in
                    guard needs else { return }
                    needsInitialScroll = false
                    // Delay to let LazyVStack layout
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(nil) {
                            proxy.scrollTo("bottom-sentinel", anchor: .bottom)
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

            // Input bar
            if !isStopped {
                ChatInputBar(
                    text: $inputText,
                    isBusy: isBusy,
                    isStopping: isStopping,
                    showForceStop: showForceStop,
                    onSend: sendPrompt,
                    onStop: stopAgent,
                    onForceStop: forceStopSession
                )
            } else {
                // Session ended — disabled input
                Text("Session ended")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
        .navigationTitle(session?.name ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
            }
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
                forceStopTask?.cancel()
                forceStopTask = nil
            }
        }
        .onDisappear {
            forceStopTask?.cancel()
            forceStopTask = nil
            // Save draft before disconnect
            let draft = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            connection.composerDraft = draft.isEmpty ? nil : draft
            connection.disconnectSession()
        }
    }

    // MARK: - Actions

    private func connectToSession() async {
        sessionStore.activeSessionId = sessionId

        // Load message history first
        if let api = connection.apiClient {
            do {
                let (session, messages) = try await api.getSession(id: sessionId)
                sessionStore.upsert(session)
                reducer.loadFromREST(messages)
                if !messages.isEmpty {
                    needsInitialScroll = true
                }
            } catch {
                // Continue without history
            }
        }

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
        guard !text.isEmpty else { return }
        inputText = ""
        reducer.appendUserMessage(text)

        Task { @MainActor in
            do {
                try await connection.sendPrompt(text)
            } catch {
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
                guard !Task.isCancelled else { return }
                if isBusy {
                    showForceStop = true
                }
            }
        }
    }

    private func forceStopSession() {
        guard let api = connection.apiClient else { return }

        Task { @MainActor in
            do {
                let updatedSession = try await api.stopSession(id: sessionId)
                sessionStore.upsert(updatedSession)
            } catch {
                reducer.process(.error(sessionId: sessionId, message: "Force stop failed: \(error.localizedDescription)"))
            }
        }
    }

    private var statusColor: Color {
        switch session?.status {
        case .ready: return .green
        case .busy: return .yellow
        case .starting: return .blue
        case .error: return .red
        case .stopped, .none: return .gray
        }
    }
}

// MARK: - Permission Pill

private struct PermissionPillBanner: View {
    let count: Int

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("\(count) pending — tap to review")
                .font(.subheadline.bold())
            Spacer()
            Image(systemName: "chevron.down")
                .font(.caption)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}
