import SwiftUI
import GhosttyVt
import UniformTypeIdentifiers

/// Oppi's chat composer, pointed at a terminal. Text (typed or dictated) is
/// edited locally and sent as one paste followed by Enter, so agent TUIs get a
/// whole prompt instead of a keystroke stream. Photos and files are saved on
/// the host first and the prompt carries their paths. The key strip sends raw
/// keys immediately for approvals, aborts and menus.
struct SSHTerminalComposer: View {
    let channel: SSHTerminalChannel
    let focusRequest: Int
    /// The foreground program's own actions, after the fixed keys.
    let keyActions: [SSHTerminalKeyAction]
    let showRawKeyboard: () -> Void
    @Environment(ServerConnection.self) private var connection: ServerConnection?

    @State private var text = ""
    @State private var textBeforeRecording: String?
    @State private var previousTextBeforeRecording: String?
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
        .onChange(of: text) { old, new in
            // The composer still edits ordinary text locally. Only the next
            // inserted character after Ctrl/Alt is routed as a raw key.
            // Stop clears the recording marker in the same turn as the final
            // text write. Keep its previous value through that update only.
            defer { previousTextBeforeRecording = textBeforeRecording }
            guard channel.modifierLatch.modifiers != 0,
                  let input = Self.modifiedInput(old: old, new: new, textBeforeRecording: textBeforeRecording,
                                                previousTextBeforeRecording: previousTextBeforeRecording),
                  channel.key(input.key, text: input.character) else { return }
            text = input.remaining
        }
        .task { await prepareVoice() }
        .onDisappear(perform: releaseVoice)
    }

    /// Shown while the composer is focused, so the idle terminal stays compact.
    private var keyStrip: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(SSHTerminalKeymap.fixed) { fixed in
                        if let modifier = fixed.modifier {
                            key(fixed.label, id: fixed.id) { channel.modifierLatch.toggle(modifier) }
                                .foregroundStyle(channel.modifierLatch.isArmed(modifier) ? .themeBlue : .themeFg)
                                .accessibilityValue(channel.modifierLatch.isArmed(modifier) ? "On" : "Off")
                        } else if let stroke = fixed.stroke {
                            if SSHTerminalArrowRepeat.isArrow(stroke.key) {
                                SSHTerminalArrowControl(label: fixed.label, key: stroke.key,
                                                        id: "sshTerminal.composer.\(fixed.id)") { arrow in
                                    channel.key(arrow)
                                }
                                .frame(width: 40, height: ComposerInputMetrics.controlDiameter)
                            } else {
                                key(fixed.label, id: fixed.id) {
                                    channel.key(stroke.key, text: stroke.text, modifiers: stroke.modifiers)
                                }
                            }
                        }
                    }
                    ForEach(keyActions) { action in
                        key(action.title, id: action.id) { channel.keys(action.strokes) }
                            .accessibilityHint("Sends \(action.keyLabel)")
                    }
                }
            }
            // Horizontal ScrollView has no intrinsic cross-axis height. Reserve
            // the full key target even when the focused composer is compressed.
            .frame(height: ComposerInputMetrics.controlDiameter)
            .scrollDismissesKeyboard(.never)
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

    /// Dictation rewrites the draft on every partial and on stop; it is not a
    /// keyboard insertion. Otherwise remove only the first inserted character,
    /// leaving the rest of the locally edited draft intact.
    static func modifiedInput(old: String, new: String, textBeforeRecording: String? = nil,
                              previousTextBeforeRecording: String? = nil) -> (key: GhosttyKey, character: String, remaining: String)? {
        guard textBeforeRecording == nil, previousTextBeforeRecording == nil else { return nil }
        let before = Array(old)
        let after = Array(new)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        guard after.count - suffix > prefix else { return nil }
        let character = String(after[prefix])
        let key = SSHTerminalKeymap.parse(character == " " ? "space" : character, syntax: .plus)?.first?.key
            ?? (character == "\n" ? GHOSTTY_KEY_ENTER : GHOSTTY_KEY_UNIDENTIFIED)
        var remaining = after
        remaining.remove(at: prefix)
        return (key, character, String(remaining))
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
