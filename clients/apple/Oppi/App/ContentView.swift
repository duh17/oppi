import SwiftUI
import UIKit

enum QuickSessionSheetLayout {
    static let compactDetentHeight: CGFloat = 150

    private static let sheetChromeAllowance: CGFloat = 18
    private static let detentIncrement: CGFloat = 4

    static func normalizedContentHeight(_ height: CGFloat) -> CGFloat {
        guard height.isFinite, height > 0 else { return 0 }
        return ceil(height / detentIncrement) * detentIncrement
    }

    static func detentHeight(forContentHeight height: CGFloat) -> CGFloat {
        let contentHeight = normalizedContentHeight(height)
        guard contentHeight > 0 else { return compactDetentHeight }
        return max(compactDetentHeight, contentHeight + sheetChromeAllowance)
    }
}

struct ContentView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation
    @State private var quickSessionTrigger = QuickSessionTrigger.shared
    @State private var quickSessionMeasuredContentHeight: CGFloat = 0
    @State private var quickSessionSelectedDetent: PresentationDetent = .height(
        QuickSessionSheetLayout.compactDetentHeight
    )
    /// Sheet detents: keep Quick Session compact at rest, but let the composer
    /// grow to its measured chat-input height for dictation and attachments.
    private var quickSessionDetentHeight: CGFloat {
        QuickSessionSheetLayout.detentHeight(forContentHeight: quickSessionMeasuredContentHeight)
    }

    private var quickSessionDetents: Set<PresentationDetent> {
        [
            .height(QuickSessionSheetLayout.compactDetentHeight),
            .height(quickSessionDetentHeight),
        ]
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
                    WorkspaceAdaptiveRootView()
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            topInsetBanners
        }
        .sheet(
            item: Binding<ExtensionUIRequest?>(
                get: {
                    guard liveConnection.activeExtensionDialog?.shouldPresentAsSheet == true else { return nil }
                    return liveConnection.activeExtensionDialog
                },
                set: { value in
                    liveConnection.activeExtensionDialog = value
                }
            )
        ) { request in
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
            quickSessionMeasuredContentHeight = 0
            quickSessionSelectedDetent = .height(QuickSessionSheetLayout.compactDetentHeight)
        }, content: {
            QuickSessionSheet { height in
                let normalized = QuickSessionSheetLayout.normalizedContentHeight(height)
                guard quickSessionMeasuredContentHeight != normalized else { return }
                quickSessionMeasuredContentHeight = normalized
                quickSessionSelectedDetent = .height(
                    QuickSessionSheetLayout.detentHeight(forContentHeight: normalized)
                )
            }
            .presentationDetents(quickSessionDetents, selection: $quickSessionSelectedDetent)
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(
                .enabled(upThrough: .height(quickSessionDetentHeight))
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
        EmptyView()
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
        // compact stack, or select the session detail column on iPad.
        navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(
                serverId: pending.target.serverId,
                sessionId: pending.sessionId
            ),
            workspace: pending.target
        )
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

private struct ExtensionDialogSheet: View {
    let request: ExtensionUIRequest

    @Environment(ServerConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss

    @State private var inputValue: String = ""
    @State private var isSubmitting = false
    @State private var editorKeyboardLanguage: String?
    @State private var editorFocusRequestID = 0

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

    @ViewBuilder
    private var nativeDialogContent: some View {
        if request.method == "editor" {
            extensionEditorContent
        } else {
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
                EmptyView()

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
    }

    private var extensionEditorContent: some View {
        VStack(spacing: 0) {
            if let message = request.message, !message.isEmpty {
                Text(message)
                    .font(.body)
                    .foregroundStyle(.themeFg)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.themeBgDark)
            }

            FullSizeTextView(
                text: $inputValue,
                keyboardLanguage: $editorKeyboardLanguage,
                font: .preferredFont(forTextStyle: .body),
                textColor: UIColor(Color.themeFg),
                tintColor: UIColor(Color.themeBlue),
                volatileSuffixLength: 0,
                correctionRanges: [],
                autocorrectionEnabled: true,
                onPasteImages: { _ in },
                onCommandEnter: submitCurrentValue,
                onAlternateEnter: submitCurrentValue,
                autoFocusOnAppear: true,
                focusRequestID: editorFocusRequestID,
                suppressKeyboard: false,
                allowKeyboardRestoreOnTap: true,
                onKeyboardRestoreRequest: nil
            )
            .background(Color.themeBg)
        }
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
