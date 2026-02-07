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

    private var session: Session? {
        sessionStore.sessions.first { $0.id == sessionId }
    }

    private var isBusy: Bool {
        session?.status == .busy
    }

    private var isStopped: Bool {
        session?.status == .stopped
    }

    var body: some View {
        VStack(spacing: 0) {
            // Chat timeline
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
                .onChange(of: reducer.items.count) { _, _ in
                    if isNearBottom {
                        withAnimation(nil) {
                            proxy.scrollTo("bottom-sentinel", anchor: .bottom)
                        }
                    }
                }
            }

            // Permission pill banner
            if !permissionStore.pending(for: sessionId).isEmpty {
                PermissionPillBanner(count: permissionStore.pending(for: sessionId).count)
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
        .task(id: sessionId) {
            await connectToSession()
        }
        .onChange(of: session?.status) { _, newStatus in
            if newStatus != .busy {
                isStopping = false
                showForceStop = false
            }
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
            } catch {
                // Continue without history
            }
        }

        // Connect WebSocket for live streaming
        connection.connectToSession(sessionId)
    }

    private func sendPrompt() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        reducer.appendUserMessage(text)

        Task {
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

        Task {
            try? await connection.sendStop()

            // Show force-stop after 5s if still busy
            try? await Task.sleep(for: .seconds(5))
            if isBusy {
                showForceStop = true
            }
        }
    }

    private func forceStopSession() {
        guard let api = connection.apiClient else { return }
        Task {
            _ = try? await api.stopSession(id: sessionId)
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
