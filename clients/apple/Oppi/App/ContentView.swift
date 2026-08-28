import AppIntents
import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.composerDraftStore) private var composerDraftStore
    @State private var quickSessionTrigger = QuickSessionTrigger.shared
    @State private var quickSessionLaunchAccessibilityElement: AnyObject?

    var body: some View {
        @Bindable var nav = navigation
        @Bindable var liveConnection = connection

        Group {
            switch navigation.launchPhase {
            case .resolving:
                // Brief local-only gate while pairing identity and cache load.
                // Network transport preparation begins after the paired shell appears.
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
        .disabled(nav.showQuickSession)
        .allowsHitTesting(!nav.showQuickSession)
        .accessibilityHidden(nav.showQuickSession)
        .sheet(
            item: Binding<ExtensionUIRequest?>(
                get: {
                    guard let request = liveConnection.activeExtensionDialog else { return nil }
                    switch request.nativePresentation {
                    case .editorSheet, .fallbackSheet:
                        return request
                    case .askCard, .inlineAskCard:
                        return nil
                    }
                },
                set: { value in
                    liveConnection.activeExtensionDialog = value
                }
            )
        ) { request in
            ExtensionDialogSheet(request: request)
                .interactiveDismissDisabled()
                .presentationDetents(ExtensionSheetLayout.detents(for: request))
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
        .overlay {
            if nav.showQuickSession {
                ZStack(alignment: .bottom) {
                    Button(action: dismissQuickSession) {
                        Color.black.opacity(0.34)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("quickSession.overlay")

                    QuickSessionSheet(onDismiss: dismissQuickSession)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: NavigationSwipeGesturePolicy.minimumDistance)
                        .onEnded { value in
                            guard NavigationSwipeGesturePolicy.isSwipe(
                                translation: value.translation,
                                direction: .down
                            ) else { return }
                            dismissQuickSession()
                        }
                )
                .ignoresSafeArea(.container, edges: .horizontal)
                .accessibilityAddTraits(.isModal)
                .accessibilityAction(.escape, dismissQuickSession)
                .accessibilityAction(named: "Dismiss Quick Session", dismissQuickSession)
                .zIndex(100)
            }
        }
        .onAppIntentExecution(QuickSessionOpenIntent.self) { intent in
            quickSessionTrigger.requestPresentation(for: intent)
        }
        .onChange(of: quickSessionTrigger.presentationRequestID) { _, newValue in
            presentQuickSessionIfPossible(requestID: newValue)
        }
        .onChange(of: nav.showQuickSession) { wasShowing, isShowing in
            guard !wasShowing, isShowing else { return }
            captureQuickSessionLaunchAccessibilityElement()
        }
        .onChange(of: navigation.launchPhase) { _, _ in
            presentQuickSessionIfPossible(requestID: quickSessionTrigger.presentationRequestID)
        }
        .onChange(of: navigation.showOnboarding) { _, _ in
            presentQuickSessionIfPossible(requestID: quickSessionTrigger.presentationRequestID)
        }
        .onChange(of: navigation.selectedTab) { _, _ in
            navigation.routeLegacySelectedTabIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .workspaceMediaOverlayDidBegin)) { _ in
            navigation.beginMediaOverlay(activeServerId: coordinator.activeServerId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .workspaceMediaOverlayDidEnd)) { _ in
            restoreWorkspaceAfterMediaOverlay()
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

    private func restoreWorkspaceAfterMediaOverlay() {
        let restoreServerId = navigation.endMediaOverlay(
            currentServerId: coordinator.activeServerId
        )
        guard let restoreServerId else { return }
        _ = coordinator.restoreActiveServer(restoreServerId)
    }

    private func presentQuickSessionIfPossible(requestID: Int) {
        guard requestID > 0 else { return }
        guard navigation.launchPhase == .ready, !navigation.showOnboarding else { return }
        guard !navigation.showQuickSession else { return }
        QuickSessionTrigger.shared.isPresented = true
        navigation.showQuickSession = true
    }

    private func dismissQuickSession() {
        guard navigation.showQuickSession else { return }
        let launchAccessibilityElement = navigation.pendingQuickSessionNav == nil
            ? quickSessionLaunchAccessibilityElement
            : nil
        quickSessionLaunchAccessibilityElement = nil
        composerDraftStore?.saveQuickSessionLifecycleFallback()
        navigation.pendingQuickSessionLaunchContext = nil
        navigation.showQuickSession = false
        QuickSessionTrigger.shared.isPresented = false
        Task { @MainActor in
            await completePendingQuickSessionNavigation()
        }

        // A custom overlay has no presentation controller to restore focus.
        // Return VoiceOver to the exact launch button it focused before the
        // modal appeared; sending a nil argument would let the system guess.
        if let launchAccessibilityElement {
            DispatchQueue.main.async {
                UIAccessibility.post(
                    notification: .screenChanged,
                    argument: launchAccessibilityElement
                )
            }
        }
    }

    private func captureQuickSessionLaunchAccessibilityElement() {
        guard let focusedElement = UIAccessibility.focusedElement(using: .notificationVoiceOver),
              let identifiedElement = focusedElement as? UIAccessibilityIdentification,
              let identifier = identifiedElement.accessibilityIdentifier,
              ["workspace.quickSession.start", "agents.detail.launch"].contains(identifier) else {
            quickSessionLaunchAccessibilityElement = nil
            return
        }
        quickSessionLaunchAccessibilityElement = focusedElement as AnyObject
    }

    private func completePendingQuickSessionNavigation() async {
        guard let pending = navigation.pendingQuickSessionNav else { return }

        // Switch server FIRST so coordinator.activeConnection (and all
        // environment-injected stores) reflect the target server by the time
        // ChatView renders. Without this, cross-server quick sessions can
        // capture the OLD connection in ChatView's .task.
        guard await coordinator.switchToServerReady(pending.target.serverId) else {
            return
        }
        navigation.pendingQuickSessionNav = nil

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
            diagnosticText("e2e.ws.connectionID", value: String(connection.wsClient?.diagnosticConnectionID ?? 0))
            diagnosticText("e2e.transport.path", value: connection.transportPath.rawValue)
            diagnosticText("e2e.stream.requiredCapabilities", value: connection.requiredSplitStreamCapabilitiesStatusForDiagnostics)
            diagnosticText("e2e.stream.sessionEndpoint", value: connection.focusedSessionStreamEndpointKind)
            diagnosticText("e2e.ws.focusedSession", value: connection.focusedSessionId ?? "none")
            diagnosticText("e2e.ws.desiredSubscriptions", value: desiredSubscriptionsLabel)
            diagnosticText("e2e.ws.ackedSubscriptions", value: ackedSubscriptionsLabel)
            diagnosticText("e2e.audio.liveTransportSession", value: connection.audioPlayer.activeLiveTransportSessionID ?? "none")
            diagnosticText("e2e.lifecycle", value: E2ELifecycleDiagnostics.shared.accessibilityValue)
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

private enum ExtensionSheetLayout {
    static func detents(for request: ExtensionUIRequest) -> Set<PresentationDetent> {
        switch request.nativePresentation {
        case .editorSheet:
            [.large]
        case .fallbackSheet:
            [.medium, .large]
        case .askCard, .inlineAskCard:
            []
        }
    }
}

private struct ExtensionDialogSheet: View {
    let request: ExtensionUIRequest

    @Environment(ServerConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss

    @State private var inputValue: String = ""
    @State private var isSubmitting = false
    @State private var editorTextBeforeRecording: String?
    @State private var editorPendingAttachments: [PendingAttachment] = []
    @State private var editorPendingRepoPointers: [PendingFileReference] = []
    @State private var editorVoiceInputManager = VoiceInputManager()

    var body: some View {
        Group {
            if request.nativePresentation == .editorSheet {
                extensionEditorContent
            } else {
                NavigationStack {
                    sheetContent
                        .navigationTitle(dialogTitle)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel", role: .cancel) {
                                    cancelRequest()
                                }
                                .disabled(isSubmitting)
                                .accessibilityIdentifier("extension.dialog.cancel")
                            }
                        }
                }
            }
        }
        .task(id: request.id) {
            inputValue = request.prefill ?? ""
            isSubmitting = false
            editorTextBeforeRecording = nil
            editorPendingAttachments = []
            editorPendingRepoPointers = []
            configureEditorVoiceInput()
            if ReleaseFeatures.voiceInputEnabled {
                await editorVoiceInputManager.prewarm(source: "extension_editor_task")
            }
        }
    }

    private var sheetContent: some View {
        Form {
            if let message = request.message, !message.isEmpty {
                Section {
                    Text(message)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }

            Section {
                ContentUnavailableView(
                    "Unsupported extension UI",
                    systemImage: "questionmark.app",
                    description: Text("This extension asked for \"\(request.method)\". Cancel and try the task another way.")
                )
            }

            if let timeoutSummary {
                Section {
                    Label(timeoutSummary, systemImage: "timer")
                        .foregroundStyle(.themeComment)
                }
            }
        }
        .themedListSurface()
    }

    private var extensionEditorContent: some View {
        ExpandedComposerView(
            text: $inputValue,
            textBeforeRecording: $editorTextBeforeRecording,
            pendingAttachments: $editorPendingAttachments,
            pendingRepoPointers: $editorPendingRepoPointers,
            isBusy: false,
            busyStreamingBehavior: .followUp,
            slashCommands: [],
            fileSuggestions: [],
            onFileSuggestionQuery: nil,
            session: nil,
            thinkingLevel: .medium,
            voiceInputManager: ReleaseFeatures.voiceInputEnabled ? editorVoiceInputManager : nil,
            onPrepareVoiceInput: prepareEditorVoiceInput,
            onSend: submitCurrentValue,
            onModelTap: {},
            onThinkingSelect: { _ in },
            titleOverride: dialogTitle,
            headerMessage: request.message,
            cancelTitle: "Cancel",
            submitTitle: "Submit",
            showsAttachmentControls: false,
            showsVoiceInputControl: true,
            showsSessionToolbar: false,
            showsCounters: true,
            usesCommandPrefixMode: false,
            allowsEmptySubmit: true,
            isSubmitInFlight: isSubmitting,
            autoFocusOnAppear: true,
            dismissesOnCancel: false,
            dismissesOnSubmit: false,
            editorAccessibilityIdentifier: "extension.dialog.editor",
            cancelAccessibilityIdentifier: "extension.dialog.cancel",
            submitAccessibilityIdentifier: "extension.dialog.submit",
            onCancel: cancelRequest
        )
    }

    private var dialogTitle: String {
        guard let trimmedTitle = request.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedTitle.isEmpty else {
            return "Extension"
        }
        return trimmedTitle
    }

    private func configureEditorVoiceInput(_ manager: VoiceInputManager? = nil) {
        let manager = manager ?? editorVoiceInputManager
        manager.activeSessionId = request.sessionId
        manager.setServerCredentials(connection.credentials)
        manager.setServerConnection(connection)
        manager.setPlaybackInterrupter(connection.audioPlayer)
    }

    private func prepareEditorVoiceInput(_ manager: VoiceInputManager) async throws {
        configureEditorVoiceInput(manager)
        manager.setServerDictationTarget(nil)
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

    private func submitCurrentValue() {
        submitResponsePayload(
            ExtensionUIResponsePayload(value: inputValue),
            failurePrefix: "Failed to respond"
        )
    }

    private func cancelRequest() {
        submitResponsePayload(.cancelled, failurePrefix: "Failed to cancel")
    }

    private func submitResponsePayload(
        _ payload: ExtensionUIResponsePayload,
        failurePrefix: String
    ) {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task { @MainActor in
            do {
                try await connection.respondToExtensionUI(
                    id: request.id,
                    sessionId: request.sessionId,
                    payload: payload
                )
                dismiss()
            } catch {
                isSubmitting = false
                connection.extensionToast = "\(failurePrefix): \(error.localizedDescription)"
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
                                    .foregroundStyle(.themeComment)
                                HStack(spacing: 12) {
                                    Button(action: { UIApplication.shared.open(url) }) {
                                        Text(url.absoluteString)
                                            .font(.body)
                                            .lineLimit(1)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.themeBlue)

                                    Spacer()

                                    Button {
                                        UIPasteboard.general.string = url.absoluteString
                                        AppHaptics.impact(style: .light, intensity: 0.8)
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                            .imageScale(.medium)
                                            .foregroundStyle(.themeFgDim)
                                    }
                                }
                            }
                        } else {
                            Text(line.text)
                                .font(.body)
                                .foregroundStyle(.themeFg)
                        }
                    }
                }
                .padding()
            }
            .background(.themeBg)
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
