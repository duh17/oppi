import SwiftUI
import UIKit

typealias MarkdownAudioMediaSourceProvider = (
    _ embed: MarkdownAudioEmbed
) async throws -> AuthenticatedMediaSource

/// Playback identity for markdown embeds and file-browser audio. Same relative
/// path in different workspace/session/worktree scopes must not share an item ID.
enum AudioPlaybackItemID {
    static func markdown(embed: MarkdownAudioEmbed, worktreeID: String?) -> String {
        scoped(
            prefix: "markdown-audio",
            kind: embed.reference.kind.rawValue,
            serverID: embed.reference.sourceServerID,
            workspaceID: embed.reference.workspaceID,
            sessionID: embed.reference.sourceSessionID,
            worktreeID: worktreeID,
            path: embed.filePath
        )
    }

    static func fileBrowser(
        path: String,
        workspaceID: String,
        sessionID: String?,
        worktreeID: String?
    ) -> String {
        scoped(
            prefix: "file-audio",
            kind: "workspaceFile",
            serverID: nil,
            workspaceID: workspaceID,
            sessionID: sessionID,
            worktreeID: worktreeID,
            path: path
        )
    }

    static func scoped(
        prefix: String,
        kind: String,
        serverID: String?,
        workspaceID: String?,
        sessionID: String?,
        worktreeID: String?,
        path: String
    ) -> String {
        [prefix, kind, serverID ?? "", workspaceID ?? "", sessionID ?? "", worktreeID ?? "", path]
            .joined(separator: "|")
    }
}

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
    private var worktreeID: String?
    private var sidecarProvider: TimedTextSidecarProvider?

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
        preferredDisplayWidth: CGFloat?,
        worktreeID: String? = nil,
        sidecarProvider: TimedTextSidecarProvider? = nil
    ) {
        let width = preferredDisplayWidth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? (bounds.width > 0 ? bounds.width : 320)
        let identity = [
            embed.reference.target,
            embed.reference.fileCandidatePath ?? "",
            embed.reference.workspaceID ?? "",
            embed.reference.sourceSessionID ?? "",
            worktreeID ?? "",
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
        self.worktreeID = worktreeID
        self.sidecarProvider = sidecarProvider
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
        AudioPlaybackItemID.markdown(embed: embed, worktreeID: worktreeID)
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
        if audioPlayer.loadingItemID == itemID {
            audioPlayer.stop()
            refreshStrip()
            return
        }
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
        audioPlayer.toggleMediaPlayback(
            source: source,
            itemID: itemID,
            timedTextLoader: makeTimedTextLoader(for: embed)
        )
        refreshStrip()
    }

    private func expand() {
        guard let embed = currentEmbed else { return }
        if isUnavailable {
            NotificationCenter.default.post(name: .resourceReferenceTapped, object: embed.reference)
            return
        }
        let title = (embed.filePath as NSString).lastPathComponent
        let itemID = playbackItemID(for: embed)
        let presentedTimedText = timedTextForPresentation(itemID: itemID)
        let loader = makeTimedTextLoader(for: embed)
        AudioLyricsPlayerPresenter.present(
            from: self,
            title: title,
            lyrics: nil,
            itemID: itemID,
            audioPlayer: audioPlayer,
            play: { [weak self] timedText in
                self?.ensurePlaying(timedText: timedText)
            },
            openFile: { [weak self] in
                guard let reference = self?.currentEmbed?.reference else { return }
                NotificationCenter.default.post(name: .resourceReferenceTapped, object: reference)
            },
            autoplayOnAppear: false,
            timedText: presentedTimedText,
            sidecarLoader: presentedTimedText == nil ? loader : nil
        )
    }

    private func ensurePlaying(timedText: TimedText.LoadResult?) {
        guard let embed = currentEmbed, let audioPlayer else { return }
        let itemID = playbackItemID(for: embed)
        if audioPlayer.playingItemID == itemID {
            if audioPlayer.isPaused { audioPlayer.resume() }
            return
        }
        guard let source = currentSource else { return }
        audioPlayer.toggleMediaPlayback(
            source: source,
            itemID: itemID,
            timedText: timedText ?? .empty,
            timedTextLoader: makeTimedTextLoader(for: embed)
        )
    }

    private func timedTextForPresentation(itemID: String) -> TimedText.LoadResult? {
        guard let audioPlayer,
              audioPlayer.playingItemID == itemID || audioPlayer.loadingItemID == itemID,
              !audioPlayer.nowPlayingTimedText.tracks.isEmpty else {
            return nil
        }
        return audioPlayer.nowPlayingTimedText
    }

    private func makeTimedTextLoader(
        for embed: MarkdownAudioEmbed
    ) -> (() async -> TimedText.LoadResult)? {
        guard let sidecarProvider else { return nil }
        let filePath = embed.filePath
        let reference = embed.reference
        return {
            await sidecarProvider(filePath, .audio, reference)
        }
    }
}
