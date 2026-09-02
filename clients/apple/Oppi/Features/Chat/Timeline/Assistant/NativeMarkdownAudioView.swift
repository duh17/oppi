import SwiftUI
import UIKit

typealias MarkdownAudioMediaSourceProvider = (
    _ embed: MarkdownAudioEmbed
) async throws -> AuthenticatedMediaSource

enum MarkdownInlineAudioLayout {
    static let autoplay = false
    static let compactHeight: CGFloat = 64

    static func reservedHeight(forWidth width: CGFloat) -> CGFloat {
        _ = width
        return compactHeight
    }
}

/// Compact native player host for Oppi wiki-file audio embeds.
///
/// Playback stays user-initiated. Source resolution uses the same authenticated
/// range routes as inline video. Expand presents the lyrics-first full-screen player.
@MainActor
final class NativeMarkdownAudioView: UIView {
    private let strip = NativeAudioPlayerStripView()
    private var heightConstraint: NSLayoutConstraint?
    private var currentEmbed: MarkdownAudioEmbed?
    private var currentIdentity: String?
    private var currentSource: AuthenticatedMediaSource?
    private var resolutionTask: Task<Void, Never>?
    private var sourceProvider: MarkdownAudioMediaSourceProvider?
    private var audioPlayer: AudioPlayerService?
    private var renderingMode: ContentRenderingMode = .live
    private(set) var reservedHeight: CGFloat = MarkdownInlineAudioLayout.reservedHeight(forWidth: .nan)
    private var isUnavailable = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        resolutionTask?.cancel()
    }

    func prepareForRemoval() {
        resolutionTask?.cancel()
        resolutionTask = nil
        currentIdentity = nil
        currentSource = nil
    }

    func apply(
        embed: MarkdownAudioEmbed,
        sourceProvider: MarkdownAudioMediaSourceProvider?,
        audioPlayer: AudioPlayerService?,
        renderingMode: ContentRenderingMode,
        preferredDisplayWidth: CGFloat?
    ) {
        let width = preferredDisplayWidth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? (bounds.width > 0 ? bounds.width : 320)
        let identity = [
            embed.reference.target,
            embed.reference.fileCandidatePath ?? "",
            String(describing: renderingMode),
        ].joined(separator: "|")
        let nextHeight = MarkdownInlineAudioLayout.reservedHeight(forWidth: width)
        applyReservedHeight(nextHeight)

        if identity == currentIdentity {
            refreshStrip()
            return
        }

        currentIdentity = identity
        currentEmbed = embed
        self.renderingMode = renderingMode
        self.sourceProvider = sourceProvider
        self.audioPlayer = audioPlayer
        currentSource = nil
        isUnavailable = false
        resolutionTask?.cancel()

        let fileName = (embed.filePath as NSString).lastPathComponent
        strip.apply(
            itemID: playbackItemID(for: embed),
            title: fileName,
            durationSeconds: nil,
            audioPlayer: audioPlayer,
            showsTitle: true,
            isUnavailable: false,
            onPlay: { [weak self] in self?.togglePlayback() },
            onExpand: { [weak self] in self?.expand() }
        )

        if renderingMode == .export {
            strip.apply(
                itemID: playbackItemID(for: embed),
                title: fileName,
                durationSeconds: nil,
                audioPlayer: nil,
                showsTitle: true,
                isUnavailable: false,
                onPlay: {},
                onExpand: {}
            )
            return
        }

        guard let sourceProvider else {
            showUnavailable()
            return
        }

        resolutionTask = Task { [weak self] in
            do {
                let source = try await sourceProvider(embed)
                guard let self, !Task.isCancelled, self.currentIdentity == identity else { return }
                self.currentSource = source
                self.isUnavailable = false
                self.refreshStrip()
            } catch {
                guard let self, !Task.isCancelled, self.currentIdentity == identity else { return }
                self.showUnavailable()
            }
        }
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip)
        let heightConstraint = heightAnchor.constraint(
            equalToConstant: MarkdownInlineAudioLayout.reservedHeight(forWidth: .nan)
        )
        self.heightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            heightConstraint,
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func applyReservedHeight(_ height: CGFloat) {
        reservedHeight = height
        heightConstraint?.constant = height
    }

    private func playbackItemID(for embed: MarkdownAudioEmbed) -> String {
        "markdown-audio:\(embed.reference.kind):\(embed.filePath)"
    }

    private func refreshStrip() {
        guard let embed = currentEmbed else { return }
        strip.apply(
            itemID: playbackItemID(for: embed),
            title: (embed.filePath as NSString).lastPathComponent,
            durationSeconds: nil,
            audioPlayer: audioPlayer,
            showsTitle: true,
            isUnavailable: isUnavailable,
            onPlay: { [weak self] in self?.togglePlayback() },
            onExpand: { [weak self] in self?.expand() }
        )
    }

    private func showUnavailable() {
        isUnavailable = true
        currentSource = nil
        refreshStrip()
    }

    private func togglePlayback() {
        guard renderingMode != .export else { return }
        guard let embed = currentEmbed, let audioPlayer else { return }
        let itemID = playbackItemID(for: embed)
        if audioPlayer.playingItemID == itemID {
            if audioPlayer.isPaused {
                audioPlayer.resume()
            } else {
                audioPlayer.pause()
            }
            refreshStrip()
            return
        }
        guard let source = currentSource else {
            showUnavailable()
            return
        }
        audioPlayer.toggleMediaPlayback(source: source, itemID: itemID)
        refreshStrip()
    }

    private func expand() {
        guard let embed = currentEmbed else { return }
        if isUnavailable {
            NotificationCenter.default.post(name: .resourceReferenceTapped, object: embed.reference)
            return
        }
        AudioLyricsPlayerPresenter.present(
            from: self,
            title: (embed.filePath as NSString).lastPathComponent,
            lyrics: nil,
            itemID: playbackItemID(for: embed),
            audioPlayer: audioPlayer,
            play: { [weak self] in self?.ensurePlaying() },
            openFile: { [weak self] in
                guard let reference = self?.currentEmbed?.reference else { return }
                NotificationCenter.default.post(name: .resourceReferenceTapped, object: reference)
            }
        )
    }

    private func ensurePlaying() {
        guard let embed = currentEmbed, let audioPlayer else { return }
        let itemID = playbackItemID(for: embed)
        if audioPlayer.playingItemID == itemID {
            if audioPlayer.isPaused { audioPlayer.resume() }
            return
        }
        guard let source = currentSource else { return }
        audioPlayer.toggleMediaPlayback(source: source, itemID: itemID)
    }
}
