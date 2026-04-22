import SwiftUI

struct ContentView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AppNavigation.self) private var navigation
    @State private var quickSessionTrigger = QuickSessionTrigger.shared
    @State private var showCrossSessionPermissionSheet = false

    /// Pending permissions from ALL servers, excluding the active session's
    /// (those are shown inline in the chat view's PermissionOverlay).
    private var crossSessionPending: [PermissionRequest] {
        let activeSessionId = sessionStore.activeSessionId
        return coordinator.allPendingPermissions
            .filter { request in
                guard let activeSessionId else {
                    return true
                }
                return request.sessionId != activeSessionId
            }
            .sorted { lhs, rhs in
                if lhs.timeoutAt != rhs.timeoutAt {
                    return lhs.timeoutAt < rhs.timeoutAt
                }
                return lhs.id < rhs.id
            }
    }

    private var crossSessionPrimary: PermissionRequest? {
        crossSessionPending.first
    }

    /// Sheet detents: taller when active sessions are shown.
    private var quickSessionDetents: Set<PresentationDetent> {
        coordinator.hasActiveSessions
            ? [.medium, .large]
            : [.height(130), .medium]
    }

    var body: some View {
        @Bindable var nav = navigation
        @Bindable var liveConnection = connection

        Group {
            switch navigation.launchPhase {
            case .resolving:
                // Blank canvas while credential check + cache load runs.
                // Prevents flash of onboarding or empty workspace list.
                Color.themeBg
                    .ignoresSafeArea()

            case .ready:
                if navigation.showOnboarding {
                    OnboardingView()
                } else {
                    TabView(selection: $nav.selectedTab) {
                        SwiftUI.Tab("Workspaces", systemImage: "square.grid.2x2", value: AppTab.workspaces) {
                            NavigationStack(path: $nav.workspacePath) {
                                WorkspaceHomeView()
                            }
                        }
                        SwiftUI.Tab("Server", systemImage: "server.rack", value: AppTab.server) {
                            NavigationStack {
                                ServerView()
                            }
                        }
                        SwiftUI.Tab("Settings", systemImage: "gear", value: AppTab.settings) {
                            NavigationStack {
                                SettingsView()
                            }
                        }
                    }
                    .tabBarMinimizeBehavior(.onScrollDown)
                    .toolbarBackground(Color.themeBg, for: .tabBar)
                    .ignoresSafeArea(.container, edges: .bottom)
                }
            }
        }
        .environment(\.selectedTextPiActionRouter, navigation.makeQuickSessionPiRouter())
        .safeAreaInset(edge: .top, spacing: 0) {
            if !navigation.showOnboarding,
               let request = crossSessionPrimary {
                CrossSessionPermissionBanner(
                    request: request,
                    totalCount: crossSessionPending.count,
                    sessionLabel: sessionLabel(for: request.sessionId),
                    serverLabel: serverLabel(for: request),
                    onReview: reviewCrossSessionPermissions
                )
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showCrossSessionPermissionSheet) {
            PermissionSheet(
                requests: crossSessionPending,
                onRespond: handleCrossSessionPermissionChoice
            )
            .presentationDetents([.height(340), .medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: crossSessionPending.isEmpty) { _, isEmpty in
            if isEmpty {
                showCrossSessionPermissionSheet = false
            }
        }
        .sheet(item: $liveConnection.activeExtensionDialog) { request in
            ExtensionDialogSheet(request: request)
        }
        .sheet(
            isPresented: Binding(
                get: { connection.extensionToast != nil },
                set: { showing in
                    if !showing {
                        connection.extensionToast = nil
                    }
                }
            )
        ) {
            if let toast = connection.extensionToast {
                ExtensionToastSheet(message: toast)
            }
        }
        .fullScreenCover(isPresented: $nav.showWhatsNew) {
            WhatsNewView {
                navigation.showWhatsNew = false
            }
        }
        .sheet(isPresented: $nav.showQuickSession, onDismiss: {
            // Navigate to the pending session after the sheet animation completes
            if let pending = navigation.pendingQuickSessionNav {
                navigation.pendingQuickSessionNav = nil

                // Switch server FIRST so coordinator.activeConnection (and all
                // environment-injected stores) reflect the target server by the
                // time views render. Without this, cross-server quick sessions
                // capture the OLD connection in ChatView's .task.
                guard coordinator.switchToServer(pending.target.serverId) else {
                    return
                }

                // Unpack auto-send data for ChatView consumption.
                navigation.pendingQuickSessionMessage = pending.autoSendMessage
                navigation.pendingQuickSessionImages = pending.autoSendImages

                // Deep-link: push workspace + session in one path update.
                // NavigationPath resolves step-by-step — WorkspaceDetailView
                // renders first (registering its navigationDestination for
                // String), then the session ID resolves to ChatView.
                navigation.selectedTab = .workspaces
                navigation.workspacePath = NavigationPath()
                navigation.workspacePath.append(pending.target)
                navigation.workspacePath.append(pending.sessionId)
            }
        }, content: {
            QuickSessionSheet()
                .presentationDetents(quickSessionDetents)
                .presentationDragIndicator(coordinator.hasActiveSessions ? .visible : .hidden)
                .presentationBackgroundInteraction(
                    coordinator.hasActiveSessions
                        ? .enabled(upThrough: .medium)
                        : .enabled(upThrough: .height(130))
                )
                .presentationCornerRadius(24)
        })
        .onChange(of: quickSessionTrigger.presentationRequestID) { _, newValue in
            guard newValue > 0, !navigation.showOnboarding else { return }
            navigation.showQuickSession = true
        }
    }

    private func sessionLabel(for sessionId: String) -> String {
        if let found = coordinator.findSession(id: sessionId) {
            return found.session.displayTitle
        }
        return "Session \(String(sessionId.prefix(8)))"
    }

    /// Find the server name for a permission request (for cross-server context).
    private func serverLabel(for request: PermissionRequest) -> String? {
        guard coordinator.connections.count > 1 else { return nil }
        // Find which server owns this permission
        for (serverId, conn) in coordinator.connections
        where conn.permissionStore.pending.contains(where: { $0.id == request.id }) {
            if let server = coordinator.serverStore.server(for: serverId) {
                return server.name
            }
        }
        return nil
    }

    private func reviewCrossSessionPermissions() {
        navigation.selectedTab = .workspaces
        showCrossSessionPermissionSheet = true
    }

    private func handleCrossSessionPermissionChoice(_ id: String, _ choice: PermissionResponseChoice) {
        Task { @MainActor in
            // Find the correct server connection for this permission
            let targetConnection = findConnectionForPermission(id: id) ?? connection

            if choice.action == .allow,
               BiometricService.shared.requiresBiometric,
               let request = targetConnection.permissionStore.pending.first(where: { $0.id == id }) {
                let reason = "Approve \(request.tool): \(request.displaySummary)"
                let authenticated = await BiometricService.shared.authenticate(reason: reason)
                guard authenticated else {
                    return
                }
            }

            do {
                try await targetConnection.respondToPermission(
                    id: id,
                    action: choice.action,
                    scope: choice.scope,
                    expiresInMs: choice.expiresInMs
                )
            } catch {
                connection.extensionToast = "Failed to respond to permission: \(error.localizedDescription)"
            }
        }
    }

    /// Find which server's connection holds a specific permission.
    private func findConnectionForPermission(id: String) -> ServerConnection? {
        for (_, conn) in coordinator.connections where conn.permissionStore.pending.contains(where: { $0.id == id }) {
            return conn
        }
        return nil
    }
}

private struct CrossSessionPermissionBanner: View {
    let request: PermissionRequest
    let totalCount: Int
    let sessionLabel: String
    let serverLabel: String?
    let onReview: () -> Void

    var body: some View {
        Button(action: onReview) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.themeOrange)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    if let serverLabel {
                        Text("[\(serverLabel)] Approval needed in \(sessionLabel)")
                            .font(.caption.bold())
                            .foregroundStyle(.themeFg)
                            .lineLimit(1)
                    } else {
                        Text("Approval needed in \(sessionLabel)")
                            .font(.caption.bold())
                            .foregroundStyle(.themeFg)
                            .lineLimit(1)
                    }

                    Text(request.displaySummary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)

                    if !request.reason.isEmpty {
                        Text(request.reason)
                            .font(.caption2)
                            .foregroundStyle(.themeComment)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    if totalCount > 1 {
                        Text("+\(totalCount - 1)")
                            .font(.caption2.bold())
                            .foregroundStyle(.themeFg)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.themeComment.opacity(0.18), in: Capsule())
                    }

                    if request.hasExpiry {
                        Text(request.timeoutAt, style: .timer)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.themeComment)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.themeOrange.opacity(0.45), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cross-session permission request")
        .accessibilityHint("Opens approval sheet")
    }
}

private struct ExtensionDialogSheet: View {
    let request: ExtensionUIRequest

    @Environment(ServerConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss

    @State private var inputValue: String = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let message = request.message {
                    Text(message)
                        .font(.body)
                }

                if showsTextInput {
                    TextField(request.placeholder ?? "Value", text: $inputValue)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                if request.method == "select", let options = request.options {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(options, id: \.self) { option in
                            Button(option) {
                                submitSelect(option)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle(request.title ?? "Extension")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancelRequest()
                    }
                }

                if request.method == "confirm" || showsTextInput {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Submit") {
                            submitCurrentValue()
                        }
                    }
                }
            }
        }
        .onAppear {
            inputValue = request.prefill ?? ""
        }
    }

    private var showsTextInput: Bool {
        request.method == "input" || request.method == "editor"
    }

    private func submitSelect(_ option: String) {
        Task { @MainActor in
            do {
                try await connection.respondToExtensionUI(id: request.id, value: option)
                dismiss()
            } catch {
                connection.extensionToast = "Failed to respond: \(error.localizedDescription)"
            }
        }
    }

    private func submitCurrentValue() {
        Task { @MainActor in
            do {
                if request.method == "confirm" {
                    try await connection.respondToExtensionUI(id: request.id, confirmed: true)
                } else {
                    try await connection.respondToExtensionUI(id: request.id, value: inputValue)
                }
                dismiss()
            } catch {
                connection.extensionToast = "Failed to respond: \(error.localizedDescription)"
            }
        }
    }

    private func cancelRequest() {
        Task { @MainActor in
            do {
                try await connection.respondToExtensionUI(id: request.id, cancelled: true)
                dismiss()
            } catch {
                connection.extensionToast = "Failed to cancel: \(error.localizedDescription)"
            }
        }
    }
}

private struct ExtensionToastSheet: View {
    let message: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(parsedLines) { line in
                        if let url = line.url {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(line.label)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 12) {
                                    Button(action: { UIApplication.shared.open(url) }) {
                                        Text(url.absoluteString)
                                            .font(.body)
                                            .lineLimit(1)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.blue)

                                    Spacer()

                                    Button {
                                        UIPasteboard.general.string = url.absoluteString
                                        let feedback = UIImpactFeedbackGenerator(style: .light)
                                        feedback.impactOccurred(intensity: 0.8)
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                            .imageScale(.medium)
                                    }
                                }
                            }
                        } else {
                            Text(line.text)
                                .font(.body)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Extension")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.fraction(0.35), .medium])
    }

    private var parsedLines: [ParsedLine] {
        message.components(separatedBy: .newlines).compactMap { raw -> ParsedLine? in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }

            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let range = NSRange(location: 0, length: trimmed.utf16.count)
            guard let match = detector?.firstMatch(in: trimmed, options: [], range: range),
                  let urlRange = Range(match.range, in: trimmed),
                  let url = URL(string: String(trimmed[urlRange])),
                  url.scheme?.hasPrefix("http") == true else {
                return ParsedLine(text: trimmed, label: trimmed, url: nil)
            }

            let prefix = String(trimmed[..<urlRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let label = prefix.isEmpty ? "Link" : prefix
            return ParsedLine(text: trimmed, label: label, url: url)
        }
    }
}

private struct ParsedLine: Identifiable {
    let id = UUID()
    let text: String
    let label: String
    let url: URL?
}
