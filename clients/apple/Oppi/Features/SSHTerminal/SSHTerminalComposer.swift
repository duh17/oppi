import SwiftUI
import UniformTypeIdentifiers

/// Oppi's chat composer, pointed at a terminal. Text (typed or dictated) is
/// edited locally and sent as one paste followed by Enter, so agent TUIs get a
/// whole prompt instead of a keystroke stream. Photos and files are saved on
/// the host first and the prompt carries their paths. The key row is three
/// pages: agent controls, arrows, then exit chords. Exit is not first.
struct SSHTerminalComposer: View {
    let channel: SSHTerminalChannel
    let focusRequest: Int
    /// The foreground program and its keybinding file. Nil means the default slots.
    let profile: SSHTerminalKeymap.Profile?
    let userFile: String?
    let showRawKeyboard: () -> Void
    @Environment(ServerConnection.self) private var connection: ServerConnection?

    @State private var text = ""
    @State private var keyPage = 0
    @State private var textBeforeRecording: String?
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var pendingRepoPointers: [PendingFileReference] = []
    @State private var streamingBehavior: StreamingBehavior = .followUp
    @State private var voiceInputManager: VoiceInputManager?
    @State private var voiceComposerGeneration: Int?
    @State private var failure: String?
    @State private var uploading = false

    var body: some View {
        VStack(spacing: 4) {
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.themeRed)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                    .accessibilityIdentifier("sshTerminal.composer.failure")
            }
            ChatInputBar(
                text: $text,
                textBeforeRecording: $textBeforeRecording,
                pendingAttachments: $pendingAttachments,
                pendingRepoPointers: $pendingRepoPointers,
                isBusy: false,
                busyStreamingBehavior: $streamingBehavior,
                isSending: uploading,
                placeholderOverride: "",
                // Empty Send is a bare Enter: accept a default, continue a pager.
                allowsEmptySubmit: true,
                sendProgressText: uploading ? "Uploading" : nil,
                isStopping: false,
                voiceInputManager: ReleaseFeatures.voiceInputEnabled ? voiceInputManager : nil,
                onPrepareVoiceInput: { configureVoiceInput($0) },
                showForceStop: false,
                isForceStopInFlight: false,
                slashCommands: [],
                fileSuggestions: [],
                onFileSuggestionQuery: nil,
                onSend: send,
                onStop: {},
                onForceStop: {},
                onExpand: {},
                externalFocusRequestID: focusRequest,
                appliesOuterPadding: true,
                allowsExpansion: false,
                allowsAttachments: true,
                attachmentButtonPlacement: .leading,
                actionRowMinimumHeight: ComposerInputMetrics.controlDiameter,
                autocorrectionEnabled: false,
                actionRow: { keyStrip }
            )
            .disabled(!channel.connected)
        }
        .task { await prepareVoice() }
        .onDisappear(perform: releaseVoice)
    }

    /// Shown while the composer is focused, so the idle terminal stays compact.
    /// The open page is the agent controls. The pager is the only way onto exit.
    private var keyStrip: some View {
        let pages = SSHTerminalKeymap.composerPages(for: profile, userFile: userFile)
        let index = min(max(keyPage, 0), pages.count - 1)
        return keyPageRow(pages: pages, index: index)
    }

    private func keyPageRow(pages: [SSHTerminalKeymap.ComposerPage], index: Int) -> some View {
        let page = pages[index]
        let next = pages[(index + 1) % pages.count]
        return HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(page.items) { item in
                        if item.kind == .arrow, let stroke = item.strokes.first {
                            SSHTerminalArrowControl(label: item.label, key: stroke.key,
                                                    id: "sshTerminal.composer.\(item.id)") { arrow in
                                channel.key(arrow)
                            }
                            .frame(width: 40, height: ComposerInputMetrics.controlDiameter)
                        } else {
                            key(item.label, id: item.id) { channel.keys(item.strokes) }
                                .accessibilityLabel(item.accessibilityLabel)
                                .accessibilityHint("Sends \(item.hint)")
                        }
                    }
                }
            }
            // Horizontal ScrollView has no intrinsic cross-axis height. Reserve
            // the full key target even when the focused composer is compressed.
            .frame(height: ComposerInputMetrics.controlDiameter)
            .scrollDismissesKeyboard(.never)
            Button {
                keyPage = (index + 1) % pages.count
            } label: {
                Text("\(index + 1)/\(pages.count)")
                    .fixedSize()
                    .frame(minWidth: 44, minHeight: ComposerInputMetrics.controlDiameter)
            }
            .accessibilityLabel("Key page \(index + 1) of \(pages.count), \(page.title)")
            .accessibilityHint("Shows \(next.title)")
            .accessibilityIdentifier("sshTerminal.composer.page")
            Button(action: showRawKeyboard) {
                Image(systemName: "keyboard")
                    .frame(minWidth: 40, minHeight: ComposerInputMetrics.controlDiameter)
            }
            .accessibilityLabel("Type directly into the terminal")
            .accessibilityIdentifier("sshTerminal.composer.rawKeyboard")
        }
        .font(.system(.subheadline, design: .monospaced).weight(.medium))
        .foregroundStyle(.themeFg)
    }

    private func key(_ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
                .frame(minWidth: 40, minHeight: ComposerInputMetrics.controlDiameter)
        }
            .accessibilityIdentifier("sshTerminal.composer.\(id)")
    }

    private func send() {
        failure = nil
        guard !pendingAttachments.isEmpty else {
            do {
                try channel.submit(text)
                text = ""
            } catch {
                failure = "Not sent. \(error.localizedDescription)"
            }
            return
        }
        guard !uploading else { return }
        uploading = true
        let attachments = pendingAttachments
        Task {
            defer { uploading = false }
            do {
                var paths = [String]()
                for attachment in attachments {
                    let (data, ext) = try await Self.fileContents(attachment)
                    paths.append(try await channel.upload(data, fileExtension: ext))
                }
                try channel.submit(Self.prompt(text, paths: paths))
                text = ""
                pendingAttachments.removeAll { sent in attachments.contains { $0.id == sent.id } }
            } catch {
                failure = "Not sent. \(error.localizedDescription)"
            }
        }
    }

    /// The prompt, then one host path per line. Agents read images by path.
    static func prompt(_ text: String, paths: [String]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([trimmed].filter { !$0.isEmpty } + [paths.joined(separator: "\n")]).joined(separator: "\n\n")
    }

    private static func fileContents(_ attachment: PendingAttachment) async throws -> (Data, String) {
        let mimeType = attachment.imageAttachment?.mimeType ?? attachment.localMimeType
        let named = (attachment.displayName as NSString).pathExtension
        let ext = named.isEmpty ? mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? "" : named
        if let data = attachment.composerDraftData { return (data, ext) }
        if let url = attachment.localFileURL {
            let data = try await Task.detached { try Data(contentsOf: url, options: .mappedIfSafe) }.value
            return (data, ext)
        }
        throw SSHTerminalUpload.Failure.rejected("\(attachment.displayName) has no local data to send.")
    }

    private func configureVoiceInput(_ manager: VoiceInputManager) {
        guard let connection else { return }
        let serverId = connection.currentServerId ?? connection.credentials.map { "\($0.host):\($0.port)" } ?? ""
        voiceComposerGeneration = ComposerShared.prepareStandaloneVoiceInput(
            manager: manager, serverId: serverId, credentials: connection.credentials,
            connection: connection, playbackInterrupter: connection.audioPlayer,
            ownedGeneration: voiceComposerGeneration
        )
    }

    /// Same dictation route as the other standalone composers: the shared
    /// manager, transcribed by the paired server's ASR.
    private func prepareVoice() async {
        guard ReleaseFeatures.voiceInputEnabled, connection != nil else { return }
        let manager = VoiceInputManager.shared
        await ComposerShared.cancelVoiceInputOnDismiss(manager: manager)
        if Task.isCancelled { return }
        configureVoiceInput(manager)
        voiceInputManager = manager
    }

    private func releaseVoice() {
        let manager = voiceInputManager
        let take = ComposerShared.takeIdentityForDismissedComposer(manager: manager, generation: voiceComposerGeneration)
        if let generation = voiceComposerGeneration {
            manager?.endComposer(generation: generation)
            voiceComposerGeneration = nil
        }
        Task { await ComposerShared.cancelVoiceInputOnDismiss(manager: manager, matching: take) }
    }
}
