import Foundation
import SwiftUI
import UIKit

/// Owns collapsed voice-message playback for native tool timeline rows.
///
/// Keeps audio side effects out of `ToolTimelineRowContentView`: replayability
/// detection, play/stop button state, attachment/base64 decoding, and
/// AudioPlayerService state observation.
@MainActor
final class ToolRowAudioController: NSObject {
    private let button: UIButton
    private var currentConfiguration: ToolTimelineRowConfiguration?
    private var decodeTask: Task<Void, Never>?
    nonisolated(unsafe) private var audioStateObserver: NSObjectProtocol?

    init(button: UIButton) {
        self.button = button
        super.init()
        button.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
    }

    deinit {
        decodeTask?.cancel()
        if let audioStateObserver {
            NotificationCenter.default.removeObserver(audioStateObserver)
        }
    }

    func apply(configuration: ToolTimelineRowConfiguration) {
        currentConfiguration = configuration

        let hasReplayableVoiceAudio = (collapsedVoiceAudioAttachment(in: configuration) != nil && configuration.sessionAttachmentMediaSourceProvider != nil)
            || collapsedVoiceAudioBase64(in: configuration) != nil
        let hasLiveStreamPlayback = configuration.audioPlayer?.isStreamingPlaybackActive(itemID: configuration.itemID) ?? false
        guard hasReplayableVoiceAudio || hasLiveStreamPlayback else {
            button.isHidden = true
            button.accessibilityIdentifier = nil
            button.accessibilityLabel = nil
            return
        }

        bindAudioStateObservationIfNeeded()
        button.isHidden = false
        button.tintColor = UIColor(Color.themePurple)
        button.accessibilityIdentifier = "chat.timeline.row.\(configuration.itemID).audio.play"
        updateButtonImage(configuration: configuration)
    }

    func cancel() {
        decodeTask?.cancel()
        decodeTask = nil
    }

    private func bindAudioStateObservationIfNeeded() {
        guard audioStateObserver == nil else { return }
        audioStateObserver = NotificationCenter.default.addObserver(
            forName: AudioPlayerService.stateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let configuration = self.currentConfiguration else { return }
                self.updateButtonImage(configuration: configuration)
            }
        }
    }

    private func updateButtonImage(configuration: ToolTimelineRowConfiguration) {
        let isPlaying = isCollapsedVoiceAudioPlaying(configuration: configuration)
        button.accessibilityLabel = isPlaying ? "Stop voice message" : "Play voice message"
        let imageName = isPlaying ? "stop.fill" : "play.fill"
        let image = UIImage(
            systemName: imageName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        )
        button.setImage(image, for: .normal)
    }

    private func isCollapsedVoiceAudioPlaying(configuration: ToolTimelineRowConfiguration) -> Bool {
        guard let itemID = collapsedVoiceAudioItemID(in: configuration) else { return false }
        return configuration.audioPlayer?.playingItemID == itemID
            || configuration.audioPlayer?.loadingItemID == itemID
            || (configuration.audioPlayer?.isStreamingPlaybackActive(itemID: itemID) ?? false)
    }

    private func collapsedVoiceAudioBase64(in configuration: ToolTimelineRowConfiguration) -> String? {
        guard case .readMedia(let output, let filePath, _, _) = configuration.expandedContent,
              filePath == "Voice message",
              let clip = AudioExtractor.extract(from: output).first,
              MediaMimeType.normalized(clip.mimeType) == "audio/wav" else {
            return nil
        }
        return clip.base64.filter { !$0.isWhitespace }
    }

    private func collapsedVoiceAudioAttachment(in configuration: ToolTimelineRowConfiguration) -> String? {
        guard case .audioMessage(_, let attachmentId, let mimeType, _, _) = configuration.expandedContent,
              !attachmentId.isEmpty,
              MediaMimeType.normalized(mimeType) == "audio/wav" else {
            return nil
        }
        return attachmentId
    }

    private func collapsedVoiceAudioItemID(in configuration: ToolTimelineRowConfiguration) -> String? {
        guard (collapsedVoiceAudioAttachment(in: configuration) != nil && configuration.sessionAttachmentMediaSourceProvider != nil)
            || collapsedVoiceAudioBase64(in: configuration) != nil
            || configuration.audioPlayer?.isStreamingPlaybackActive(itemID: configuration.itemID) == true else {
            return nil
        }
        return configuration.itemID
    }

    @objc
    private func togglePlayback() {
        guard let configuration = currentConfiguration,
              let audioPlayer = configuration.audioPlayer,
              let itemID = collapsedVoiceAudioItemID(in: configuration) else {
            return
        }

        if audioPlayer.playingItemID == itemID
            || audioPlayer.loadingItemID == itemID
            || audioPlayer.isStreamingPlaybackActive(itemID: itemID) {
            audioPlayer.stop()
            updateButtonImage(configuration: configuration)
            return
        }

        if let attachmentId = collapsedVoiceAudioAttachment(in: configuration),
           let mediaSourceProvider = configuration.sessionAttachmentMediaSourceProvider {
            decodeTask?.cancel()
            decodeTask = Task { [attachmentId, itemID, weak audioPlayer] in
                do {
                    let source = try await mediaSourceProvider(attachmentId, "audio/wav", "wav")
                    await MainActor.run {
                        guard let audioPlayer else { return }
                        audioPlayer.toggleMediaPlayback(source: source, itemID: itemID)
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, let configuration = self.currentConfiguration else { return }
                        self.updateButtonImage(configuration: configuration)
                    }
                }
            }
            return
        }

        guard let base64 = collapsedVoiceAudioBase64(in: configuration) else { return }
        decodeTask?.cancel()
        decodeTask = Task.detached(priority: .userInitiated) { [base64, itemID, weak audioPlayer] in
            let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
            await MainActor.run {
                guard let data, let audioPlayer else { return }
                audioPlayer.toggleDataPlayback(data: data, itemID: itemID)
            }
        }
    }

}
