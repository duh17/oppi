import SwiftUI

struct ContentView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation
    @State private var quickSessionTrigger = QuickSessionTrigger.shared
    @State private var showCrossSessionPermissionSheet = false

    /// Pending permissions from ALL servers, excluding the active session's
    /// (those are shown inline in the chat view's PermissionOverlay).
    private var crossSessionPending: [PermissionRequest] {
        let activeSessionId = coordinator.activeConnection.sessionStore.activeSessionId
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

    private let quickSessionCompactDetentHeight: CGFloat = 150

    /// Sheet detents: keep Quick Session as a compact composer instead of
    /// expanding into a mostly empty half sheet when the keyboard appears.
    private var quickSessionDetents: Set<PresentationDetent> {
        [.height(quickSessionCompactDetentHeight)]
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
                    NavigationStack(path: $nav.workspacePath) {
                        WorkspaceHomeView()
                    }
                    .task {
                        navigation.routeLegacySelectedTabIfNeeded()
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            topInsetBanners
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
                .interactiveDismissDisabled()
                .presentationDetents(request.method == "editor" ? [.large] : [.medium, .large])
                .presentationDragIndicator(.hidden)
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
            completePendingQuickSessionNavigation()
        }, content: {
            QuickSessionSheet()
                .presentationDetents(quickSessionDetents)
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(
                    .enabled(upThrough: .height(quickSessionCompactDetentHeight))
                )
                .presentationCornerRadius(24)
        })
        .onChange(of: quickSessionTrigger.presentationRequestID) { _, newValue in
            handleQuickSessionPresentationRequestChange(newValue)
        }
        .onChange(of: navigation.selectedTab) { _, _ in
            navigation.routeLegacySelectedTabIfNeeded()
        }
        .overlay(alignment: .topLeading) {
            e2eDiagnosticsOverlay
        }
    }

    @ViewBuilder
    private var e2eDiagnosticsOverlay: some View {
#if DEBUG
        if ProcessInfo.processInfo.environment["PI_E2E_INVITE_URL"] != nil
            || ProcessInfo.processInfo.environment["OPPI_E2E_DIAGNOSTICS"] == "1" {
            E2EWebSocketDiagnosticsView(connection: connection)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        }
#endif
    }

    @ViewBuilder
    private var topInsetBanners: some View {
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

    private func handleQuickSessionPresentationRequestChange(_ newValue: Int) {
        let shouldPresent = newValue > 0
        let showingOnboarding = navigation.showOnboarding
        guard shouldPresent, !showingOnboarding else { return }
        navigation.showQuickSession = true
    }

    private func completePendingQuickSessionNavigation() {
        guard let pending = navigation.pendingQuickSessionNav else { return }
        navigation.pendingQuickSessionNav = nil

        // Switch server FIRST so coordinator.activeConnection (and all
        // environment-injected stores) reflect the target server by the time
        // ChatView renders. Without this, cross-server quick sessions can
        // capture the OLD connection in ChatView's .task.
        guard coordinator.switchToServer(pending.target.serverId) else {
            return
        }

        // Keep the existing send path intact. ChatView will upload any pending
        // local attachments and dispatch the message through the focused stream.
        navigation.pendingQuickSessionMessage = pending.autoSendMessage
        navigation.pendingQuickSessionAttachments = pending.autoSendAttachments

        // Quick Session is just "new session from here". Preserve the current
        // stack and push the new chat route instead of popping to Workspaces
        // first, which made the transition visibly jump through multiple places.
        navigation.selectedTab = .workspaces
        var path = navigation.workspacePath
        path.append(
            WorkspaceSessionNavTarget(
                serverId: pending.target.serverId,
                sessionId: pending.sessionId
            )
        )
        navigation.workspacePath = path
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
        guard crossSessionPending.count == 1, let request = crossSessionPrimary else {
            navigation.selectedTab = .workspaces
            showCrossSessionPermissionSheet = true
            return
        }

        openSessionForPermission(request)
    }

    private func openSessionForPermission(_ request: PermissionRequest) {
        if let found = coordinator.findSession(id: request.sessionId) {
            coordinator.switchToServer(found.serverId)
            found.connection.sessionStore.activeSessionId = request.sessionId
            found.connection.prepareForSessionReentry(request.sessionId)
            navigation.selectedTab = .workspaces
            navigation.setWorkspaceSessionPath(serverId: found.serverId, sessionId: request.sessionId)
            return
        }

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

#if DEBUG
private struct E2EWebSocketDiagnosticsView: View {
    let connection: ServerConnection
    @State private var refreshTick = 0

    var body: some View {
        let _ = refreshTick
        VStack(spacing: 0) {
            diagnosticText("e2e.ws.status", value: wsStatusLabel)
            diagnosticText("e2e.stream.requiredCapabilities", value: connection.requiredSplitStreamCapabilitiesStatusForDiagnostics)
            diagnosticText("e2e.stream.sessionEndpoint", value: connection.focusedSessionStreamEndpointKind)
            diagnosticText("e2e.ws.focusedSession", value: connection.focusedSessionId ?? "none")
            diagnosticText("e2e.ws.desiredSubscriptions", value: desiredSubscriptionsLabel)
            diagnosticText("e2e.ws.ackedSubscriptions", value: ackedSubscriptionsLabel)
            diagnosticText("e2e.audio.liveTransportSession", value: connection.audioPlayer.activeLiveTransportSessionID ?? "none")
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    refreshTick &+= 1
                }
            }
        }
    }

    private func diagnosticText(_ id: String, value: String) -> some View {
        Text(value)
            .font(.caption2.monospaced())
            .lineLimit(1)
            .accessibilityIdentifier(id)
            .accessibilityLabel(value)
    }

    private var wsStatusLabel: String {
        switch connection.wsClient?.status {
        case .connected:
            return "connected"
        case .connecting:
            return "connecting"
        case .disconnected:
            return "disconnected"
        case .reconnecting(let attempt):
            return "reconnecting:\(attempt)"
        case nil:
            return "none"
        }
    }

    private var desiredSubscriptionsLabel: String {
        guard let focusedSessionId = connection.focusedSessionId else { return "none" }
        return "\(focusedSessionId):full"
    }

    private var ackedSubscriptionsLabel: String {
        guard let focusedSessionId = connection.focusedSessionId else { return "none" }
        if connection.sessionStreamCoordinator.hasFullSubscription(sessionId: focusedSessionId) {
            return "\(focusedSessionId):full"
        }
        let state: String = switch connection.sessionStreamCoordinator.state {
        case .idle:
            "idle"
        case .connectingTransport:
            "connecting"
        case .queueSync:
            "queueSync"
        case .streaming:
            "streaming"
        case .resubscribing:
            "resubscribing"
        }
        return "\(focusedSessionId):\(state)"
    }
}
#endif

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
        .accessibilityHint(totalCount == 1 ? "Opens the session needing approval" : "Opens approval sheet")
    }
}

private struct ExtensionDialogSheet: View {
    let request: ExtensionUIRequest

    @Environment(ServerConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss

    @State private var inputValue: String = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Group {
                if isTUICompatibilityRequest {
                    compatibilityContent
                } else {
                    nativeDialogContent
                }
            }
            .navigationTitle(dialogTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        cancelRequest()
                    }
                    .disabled(isSubmitting)
                }

                if request.method == "confirm" || showsTextInput {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(primaryActionTitle) {
                            submitCurrentValue()
                        }
                        .disabled(isSubmitting || (request.method == "input" && inputValue.isEmpty))
                    }
                }
            }
        }
        .task(id: request.id) {
            inputValue = request.prefill ?? ""
            isSubmitting = false
        }
    }

    private var nativeDialogContent: some View {
        Form {
            if let message = request.message, !message.isEmpty {
                Section {
                    Text(message)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }

            switch request.method {
            case "select":
                Section {
                    ForEach(request.options ?? [], id: \.self) { option in
                        Button {
                            submitSelect(option)
                        } label: {
                            HStack(spacing: 12) {
                                Text(option)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .disabled(isSubmitting)
                    }
                } header: {
                    Text("Choose one")
                }

            case "confirm":
                Section {
                    Button {
                        submitCurrentValue()
                    } label: {
                        Label(primaryActionTitle, systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting)
                }

            case "input":
                Section {
                    TextField(request.placeholder ?? "Value", text: $inputValue, axis: .vertical)
                        .lineLimit(1...4)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onSubmit { submitCurrentValue() }
                } header: {
                    Text(request.placeholder ?? "Value")
                }

            case "editor":
                Section {
                    TextEditor(text: $inputValue)
                        .font(.body)
                        .frame(minHeight: 240)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .scrollContentBackground(.hidden)
                        .themedTextInputCard()
                } header: {
                    Text(request.placeholder ?? "Edit text")
                }

            default:
                Section {
                    ContentUnavailableView(
                        "Unsupported extension UI",
                        systemImage: "questionmark.app",
                        description: Text("This extension asked for \"\(request.method)\". Cancel and try the task another way.")
                    )
                }
            }

            if let timeoutSummary {
                Section {
                    Label(timeoutSummary, systemImage: "timer")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .themedListSurface()
    }

    private var compatibilityContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(request.message ?? "")
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding()
            }
            .background(Color(.systemGroupedBackground))

            VStack(spacing: 12) {
                Text("Compatibility mode")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    compatButton("Up", systemImage: "arrow.up", value: "↑ Up")
                    compatButton("Down", systemImage: "arrow.down", value: "↓ Down")
                    compatButton("Return", systemImage: "return", value: "⏎ Enter")
                }

                HStack(spacing: 10) {
                    compatButton("Type Text", systemImage: "keyboard", value: "Type text…")
                    compatButton("Cancel", systemImage: "xmark.circle", value: "Cancel", role: .cancel)
                }
            }
            .padding()
            .background(.bar)
        }
    }

    @ViewBuilder
    private func compatButton(
        _ title: String,
        systemImage: String,
        value: String,
        role: ButtonRole? = nil
    ) -> some View {
        let isDisabled = isSubmitting || !(request.options ?? []).contains(value)

        if role == .cancel {
            Button(role: role) {
                cancelRequest()
            } label: {
                compatButtonLabel(title: title, systemImage: systemImage)
            }
            .buttonStyle(.bordered)
            .disabled(isDisabled)
        } else {
            Button(role: role) {
                submitSelect(value)
            } label: {
                compatButtonLabel(title: title, systemImage: systemImage)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isDisabled)
        }
    }

    private func compatButtonLabel(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, minHeight: 44)
    }

    private var dialogTitle: String {
        guard let trimmedTitle = request.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedTitle.isEmpty else {
            return "Extension"
        }
        return trimmedTitle
    }

    private var primaryActionTitle: String {
        request.method == "confirm" ? "Confirm" : "Submit"
    }

    private var timeoutSummary: String? {
        let remainingSeconds: Int?
        if let timeoutAt = request.timeoutAt {
            remainingSeconds = max(1, Int(ceil(timeoutAt.timeIntervalSinceNow)))
        } else if let timeout = request.timeout, timeout > 0 {
            remainingSeconds = max(1, (timeout + 999) / 1000)
        } else {
            remainingSeconds = nil
        }

        guard let remainingSeconds else { return nil }
        return "Expires in about \(remainingSeconds) seconds"
    }

    private var showsTextInput: Bool {
        request.method == "input" || request.method == "editor"
    }

    private var isTUICompatibilityRequest: Bool {
        request.method == "select"
            && request.title == "Extension (TUI compatibility mode)"
            && Set(request.options ?? []).isSuperset(of: ["↑ Up", "↓ Down", "⏎ Enter", "Type text…", "Cancel"])
    }

    private func submitSelect(_ option: String) {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task { @MainActor in
            do {
                try await connection.respondToExtensionUI(id: request.id, sessionId: request.sessionId, value: option)
                dismiss()
            } catch {
                isSubmitting = false
                connection.extensionToast = "Failed to respond: \(error.localizedDescription)"
            }
        }
    }

    private func submitCurrentValue() {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task { @MainActor in
            do {
                if request.method == "confirm" {
                    try await connection.respondToExtensionUI(id: request.id, sessionId: request.sessionId, confirmed: true)
                } else {
                    try await connection.respondToExtensionUI(id: request.id, sessionId: request.sessionId, value: inputValue)
                }
                dismiss()
            } catch {
                isSubmitting = false
                connection.extensionToast = "Failed to respond: \(error.localizedDescription)"
            }
        }
    }

    private func cancelRequest() {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task { @MainActor in
            do {
                try await connection.respondToExtensionUI(id: request.id, sessionId: request.sessionId, cancelled: true)
                dismiss()
            } catch {
                isSubmitting = false
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
