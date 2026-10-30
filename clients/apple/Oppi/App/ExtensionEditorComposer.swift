import UIKit

/// The extension editor dialog: the expanded composer in an editor
/// configuration, plus the dialog's response and voice lifecycle.
@MainActor
enum ExtensionEditorComposer {
    static func make(request: ExtensionUIRequest, connection: ServerConnection) -> UIViewController {
        let session = Session(request: request, connection: connection)
        let controller = session.makeComposer()
        session.composer = controller
        controller.isModalInPresentation = true
        session.start()
        return controller
    }

    /// Lives as long as the composer: the composer's configuration closures
    /// hold it, and closing the dialog tears it down.
    @MainActor
    final class Session {
        let request: ExtensionUIRequest
        let connection: ServerConnection
        var inputValue: String
        var isSubmitting = false
        var isVisible = true
        let voiceInputManager = VoiceInputManager.shared
        var editorVoiceComposerGeneration: Int?
        weak var composer: ExpandedComposerViewController?
        private var startTask: Task<Void, Never>?
        private var themeObserver: NSObjectProtocol?

        init(request: ExtensionUIRequest, connection: ServerConnection) {
            self.request = request
            self.connection = connection
            self.inputValue = request.prefill ?? ""
        }

        func makeComposer() -> ExpandedComposerViewController {
            let colors = ComposerThemeColors(palette: ThemeRuntimeState.currentPalette())
            let title: String = {
                guard let trimmed = request.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !trimmed.isEmpty else { return "Extension" }
                return trimmed
            }()
            let configuration = ExpandedComposerConfiguration(
                voiceInputManager: voiceInputManager,
                onPrepareVoiceInput: { manager in self.configureEditorVoiceInput(manager) },
                onSend: { self.submitCurrentValue() },
                onCancel: { self.cancelRequest() },
                onTextChange: { self.inputValue = $0 },
                onClose: { self.teardown() },
                titleOverride: title,
                headerMessage: request.message,
                cancelTitle: "Cancel",
                submitTitle: "Submit",
                showsAttachmentControls: false,
                showsSessionToolbar: false,
                usesCommandPrefixMode: false,
                autoFocusOnAppear: true,
                dismissesOnCancel: false,
                dismissesOnSubmit: false,
                editorAccessibilityIdentifier: "extension.dialog.editor",
                cancelAccessibilityIdentifier: "extension.dialog.cancel",
                submitAccessibilityIdentifier: "extension.dialog.submit"
            )
            let live = ExpandedComposerLiveState(
                text: inputValue,
                allowsEmptySubmit: true,
                colors: colors,
                thinkingTint: colors.blue
            )
            return ExpandedComposerViewController(configuration: configuration, live: live)
        }

        /// Drop a capture another surface left running, claim the editor's
        /// voice generation, and warm dictation so the first mic tap is quick.
        func start() {
            themeObserver = NotificationCenter.default.addObserver(
                forName: .oppiThemeDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    let colors = ComposerThemeColors(palette: ThemeRuntimeState.currentPalette())
                    self?.composer?.live.colors = colors
                    self?.composer?.live.thinkingTint = colors.blue
                }
            }
            let manager = voiceInputManager
            startTask = Task { [weak self] in
                await ComposerShared.cancelVoiceInputOnDismiss(manager: manager)
                guard let self, !Task.isCancelled, self.isVisible else { return }
                self.configureEditorVoiceInput(manager)
                await manager.prewarm(source: "extension_editor_task")
            }
        }

        func teardown() {
            isVisible = false
            startTask?.cancel()
            startTask = nil
            if let themeObserver {
                NotificationCenter.default.removeObserver(themeObserver)
                self.themeObserver = nil
            }
            let manager = voiceInputManager
            let takeIdentity = ComposerShared.takeIdentityForDismissedComposer(
                manager: manager,
                generation: editorVoiceComposerGeneration
            )
            if let generation = editorVoiceComposerGeneration {
                manager.endComposer(generation: generation)
                editorVoiceComposerGeneration = nil
            }
            Task {
                await ComposerShared.cancelVoiceInputOnDismiss(
                    manager: manager,
                    matching: takeIdentity
                )
            }
        }

        private var editorVoiceServerId: String {
            connection.currentServerId
                ?? connection.credentials.map { "\($0.host):\($0.port)" }
                ?? ""
        }

        func configureEditorVoiceInput(_ manager: VoiceInputManager) {
            editorVoiceComposerGeneration = ComposerShared.prepareStandaloneVoiceInput(
                manager: manager,
                serverId: editorVoiceServerId,
                credentials: connection.credentials,
                connection: connection,
                playbackInterrupter: connection.audioPlayer,
                ownedGeneration: editorVoiceComposerGeneration
            )
        }

        func submitCurrentValue() {
            submitResponsePayload(
                ExtensionUIResponsePayload(value: inputValue),
                failurePrefix: "Failed to respond"
            )
        }

        func cancelRequest() {
            submitResponsePayload(.cancelled, failurePrefix: "Failed to cancel")
        }

        func submitResponsePayload(
            _ payload: ExtensionUIResponsePayload,
            failurePrefix: String
        ) {
            guard !isSubmitting else { return }
            isSubmitting = true
            composer?.live.isSubmitInFlight = true
            Task { @MainActor in
                do {
                    try await connection.respondToExtensionUI(
                        id: request.id,
                        sessionId: request.sessionId,
                        payload: payload
                    )
                    if isVisible, let composer {
                        Router.finish(composer)
                    }
                } catch {
                    isSubmitting = false
                    composer?.live.isSubmitInFlight = false
                    connection.extensionToast = "\(failurePrefix): \(error.localizedDescription)"
                }
            }
        }
    }
}
