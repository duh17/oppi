import SwiftUI
import UIKit

enum QuickSessionSheetLayout {
    static let compactDetentHeight: CGFloat = 150
    /// Stable target for normal multiline composer growth. This is tall enough
    /// for wrapped dictation text without the old large blank header, and stable
    /// enough to avoid retargeting the sheet on every measured text-row change.
    static let multilineComposerDetentHeight: CGFloat = 224
    private static let detentIncrement: CGFloat = 4

    static func normalizedContentHeight(_ height: CGFloat) -> CGFloat {
        guard height.isFinite, height > 0 else { return 0 }
        return ceil(height / detentIncrement) * detentIncrement
    }

    static func detentHeight(forContentHeight height: CGFloat) -> CGFloat {
        let contentHeight = normalizedContentHeight(height)
        guard contentHeight > 0 else { return compactDetentHeight }

        // `.height` detents already reserve the sheet presentation chrome/safe area.
        // Keep the compact rest height for short input. Once wrapped dictation
        // text needs more room, hold a smaller stable multiline detent instead
        // of retargeting the sheet for every TextKit measurement change.
        guard contentHeight > compactDetentHeight else { return compactDetentHeight }
        guard contentHeight > multilineComposerDetentHeight else {
            return multilineComposerDetentHeight
        }
        return contentHeight
    }

    static func shouldApplyContentHeightChange(currentContentHeight: CGFloat, incomingContentHeight: CGFloat) -> Bool {
        let currentDetentHeight = detentHeight(forContentHeight: currentContentHeight)
        let incomingDetentHeight = detentHeight(forContentHeight: incomingContentHeight)
        return currentDetentHeight != incomingDetentHeight
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
        .sheet(isPresented: $nav.showQuickSession, onDismiss: {
            QuickSessionTrigger.shared.isPresented = false
            completePendingQuickSessionNavigation()
            quickSessionMeasuredContentHeight = 0
            quickSessionSelectedDetent = .height(QuickSessionSheetLayout.compactDetentHeight)
        }, content: {
            QuickSessionSheet { height in
                let normalized = QuickSessionSheetLayout.normalizedContentHeight(height)
                guard QuickSessionSheetLayout.shouldApplyContentHeightChange(
                    currentContentHeight: quickSessionMeasuredContentHeight,
                    incomingContentHeight: normalized
                ) else { return }
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
            presentQuickSessionIfPossible(requestID: newValue)
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
        .overlay(alignment: .topLeading) {
            e2eDiagnosticsOverlay
        }
    }

    @ViewBuilder
    private var e2eDiagnosticsOverlay: some View {
#if DEBUG
        if ProcessInfo.processInfo.environment["PI_E2E_INVITE_URL"] != nil
            || ProcessInfo.processInfo.environment["OPPI_E2E_DIAGNOSTICS"] == "1" {
            E2EWebSocketDiagnosticsView(
                connection: connection,
                quickSessionContentHeight: quickSessionMeasuredContentHeight,
                quickSessionDetentHeight: quickSessionDetentHeight
            )
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

    private func presentQuickSessionIfPossible(requestID: Int) {
        guard requestID > 0 else { return }
        guard navigation.launchPhase == .ready, !navigation.showOnboarding else { return }
        guard !navigation.showQuickSession else { return }
        QuickSessionTrigger.shared.isPresented = true
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
    let quickSessionContentHeight: CGFloat
    let quickSessionDetentHeight: CGFloat
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
            diagnosticText("e2e.quickSession.contentHeight", value: heightLabel(quickSessionContentHeight))
            diagnosticText("e2e.quickSession.detentHeight", value: heightLabel(quickSessionDetentHeight))
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

    private func heightLabel(_ height: CGFloat) -> String {
        String(format: "%.0f", height)
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
                        .foregroundStyle(.secondary)
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
