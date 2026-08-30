import SwiftUI

enum MacToolDocumentMediaPlayback {
    static func playback(
        media: ToolContentDescriptor.Media,
        workspaceID: String?,
        sessionID: String?,
        worktreeId: String? = nil,
        routeScope: SessionRouteScope? = nil,
        ownerToken: String? = MacAPIClient.readOwnerToken(),
        socketPath: String = MacLocalAPISocket.path(
            dataDir: NSString("~/.config/oppi").expandingTildeInPath
        )
    ) -> MacAVPlayback? {
        guard let token = ownerToken, !token.isEmpty else { return nil }
        if let audio = media.audio,
           !audio.attachmentId.isEmpty,
           let sessionID, !sessionID.isEmpty,
           let source = MacOwnerMediaSource.sessionAttachment(
            sessionID: sessionID,
            attachmentID: audio.attachmentId,
            mimeType: audio.mimeType,
            token: token,
            socketPath: socketPath,
            scope: routeScope
           ) {
            return .ownerSocket(source)
        }
        if let attachment = media.attachments.first(where: isPlayableAttachment),
           let sessionID, !sessionID.isEmpty,
           let source = MacOwnerMediaSource.sessionAttachment(
            sessionID: sessionID,
            attachmentID: attachment.id,
            mimeType: attachment.mimeType,
            token: token,
            socketPath: socketPath,
            scope: routeScope
           ) {
            return .ownerSocket(source)
        }
        if let path = media.filePath, isPlayablePath(path), let workspaceID, !workspaceID.isEmpty {
            if let sessionID, !sessionID.isEmpty,
               let source = MacOwnerMediaSource.sessionFile(
                workspaceID: workspaceID,
                sessionID: sessionID,
                path: path,
                token: token,
                socketPath: socketPath
               ) {
                return .ownerSocket(source)
            }
            if let source = MacOwnerMediaSource.workspaceFile(
                workspaceID: workspaceID,
                path: path,
                token: token,
                socketPath: socketPath,
                worktreeId: worktreeId
            ) {
                return .ownerSocket(source)
            }
        }
        return nil
    }

    static func playerHeight(for media: ToolContentDescriptor.Media) -> CGFloat {
        if media.audio != nil { return 88 }
        if case .audio = FileType.detect(from: media.filePath) { return 88 }
        if let mime = media.attachments.first(where: isPlayableAttachment)?.mimeType,
           mime.lowercased().hasPrefix("audio/") {
            return 88
        }
        return 360
    }

    private static func isPlayablePath(_ path: String) -> Bool {
        switch FileType.detect(from: path) {
        case .audio, .video:
            return true
        default:
            return false
        }
    }

    private static func isPlayableAttachment(_ attachment: ToolContentMediaAttachment) -> Bool {
        let mime = attachment.mimeType.lowercased()
        if mime.hasPrefix("audio/") || mime.hasPrefix("video/") {
            return true
        }
        return isPlayablePath(attachment.fileName ?? "")
    }
}

enum MacToolDocumentMediaPaint {
    /// Inline audio payloads can be megabytes long. Keep the readable text and
    /// let the real playback control represent the binary part.
    static func visibleOutput(for media: ToolContentDescriptor.Media) -> String {
        var output = media.output
        for clip in AudioExtractor.extract(from: output).reversed() {
            output.removeSubrange(clip.range)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MacToolDocumentMediaView: View {
    let media: ToolContentDescriptor.Media
    var itemID: String? = nil
    var workspaceID: String? = nil
    var sessionID: String? = nil
    var worktreeId: String? = nil
    var routeScope: SessionRouteScope? = nil
    @Environment(\.theme) private var theme

    private var audioSource: MacToolAudioSource? {
        MacToolAudioSourceResolver.source(
            media: media,
            sessionID: sessionID,
            routeScope: routeScope
        )
    }

    private var playback: MacAVPlayback? {
        MacToolDocumentMediaPlayback.playback(
            media: media,
            workspaceID: workspaceID,
            sessionID: sessionID,
            worktreeId: worktreeId,
            routeScope: routeScope
        )
    }

    private var visibleOutput: String {
        MacToolDocumentMediaPaint.visibleOutput(for: media)
    }

    private func audioItemID(for source: MacToolAudioSource) -> String {
        if let itemID, !itemID.isEmpty { return itemID }
        return "document-audio-\(source.identity)"
    }

    var body: some View {
        let resolvedAudioSource = audioSource
        VStack(alignment: .leading, spacing: 10) {
            Label(
                media.filePath ?? (resolvedAudioSource == nil ? "Media" : "Voice message"),
                systemImage: resolvedAudioSource == nil && playback == nil ? "photo.on.rectangle" : "waveform"
            )
                .font(.headline)
            if let resolvedAudioSource {
                // Completed playNow rows are user-initiated here. Live WAV
                // autoplay remains exclusively owned by MacVoiceReplyPlayer.
                HStack(spacing: 10) {
                    MacToolAudioPlaybackButton(
                        itemID: audioItemID(for: resolvedAudioSource),
                        source: resolvedAudioSource
                    )
                    if let duration = media.audio?.durationSeconds, duration.isFinite, duration >= 0 {
                        Text(duration.formatted(.number.precision(.fractionLength(1))) + "s")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(theme.text.secondary)
                    }
                }
                .accessibilityIdentifier("mac.documentColumn.mediaPlayer")
            } else if let playback {
                // Completed playNow cards stay tap-to-play: live WAV already
                // autoplayed through MacVoiceReplyPlayer (iOS suppressAutoplay).
                MacAuthenticatedAVPlayerView(playback: playback)
                    .frame(maxHeight: MacToolDocumentMediaPlayback.playerHeight(for: media))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("mac.documentColumn.mediaPlayer")
            }
            if !visibleOutput.isEmpty {
                Text(visibleOutput)
                    .textSelection(.enabled)
            }
            ForEach(media.attachments, id: \.id) { attachment in
                HStack(spacing: 8) {
                    Image(systemName: "paperclip")
                    Text(attachment.fileName ?? attachment.id)
                    Text(attachment.mimeType)
                        .foregroundStyle(theme.text.secondary)
                }
                .font(.callout)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("mac.documentColumn.media")
    }
}
