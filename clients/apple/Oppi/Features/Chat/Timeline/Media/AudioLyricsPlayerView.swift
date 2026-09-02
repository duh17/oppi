import Combine
import SwiftUI

enum AudioLyricsPlayerPresenter {
    @MainActor
    static func shouldAutoplayOnAppear(
        itemID: String,
        audioPlayer: AudioPlayerService?,
        playNow: Bool
    ) -> Bool {
        if playNow { return true }
        guard let audioPlayer else { return false }
        return audioPlayer.playingItemID == itemID
            || audioPlayer.isStreamingPlaybackActive(itemID: itemID)
    }

    @MainActor
    static func present(
        from view: UIView,
        title: String,
        lyrics: String?,
        itemID: String,
        audioPlayer: AudioPlayerService?,
        play: @escaping () -> Void,
        openFile: (() -> Void)?,
        autoplayOnAppear: Bool,
        timedText: TimedText.LoadResult? = nil,
        sidecarLoader: (() async -> TimedText.LoadResult)? = nil
    ) {
        // Expand starts playback only when the caller opts in: already playing
        // this item, or a voice `playNow` reply. Markdown and file browser pass false.
        guard let presenter = nearestViewController(from: view) else { return }
        let root = AudioLyricsPlayerView(
            title: title,
            lyrics: lyrics,
            itemID: itemID,
            audioPlayer: audioPlayer,
            play: play,
            openFile: openFile,
            autoplayOnAppear: autoplayOnAppear,
            showsCloseButton: true,
            timedText: timedText,
            sidecarLoader: sidecarLoader
        )
        let host = UIHostingController(rootView: root)
        host.modalPresentationStyle = .fullScreen
        presenter.present(host, animated: true)
    }

    @MainActor
    private static func nearestViewController(from view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController
            }
            responder = current.next
        }
        return nil
    }
}

struct AudioLyricsPlayerView: View {
    let title: String
    let lyrics: String?
    let itemID: String
    let audioPlayer: AudioPlayerService?
    let play: () -> Void
    let openFile: (() -> Void)?
    var autoplayOnAppear = false
    var showsCloseButton = true
    var timedText: TimedText.LoadResult? = nil
    var sidecarLoader: (() async -> TimedText.LoadResult)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var progressTick = 0
    @State private var selectedTrackIndex: Int?
    @State private var loadedTimedText: TimedText.LoadResult?

    private var resolvedTimedText: TimedText.LoadResult? {
        loadedTimedText ?? timedText
    }

    private var resolvedTrackIndex: Int {
        selectedTrackIndex ?? resolvedTimedText?.selectedIndex ?? 0
    }

    private var lines: [AudioLyrics.Line] {
        if let resolvedTimedText, resolvedTimedText.tracks.indices.contains(resolvedTrackIndex) {
            return TimedText.lyricsLines(from: resolvedTimedText.tracks[resolvedTrackIndex].cues)
        }
        return AudioLyrics.lines(from: lyrics)
    }

    private var currentIndex: Int? {
        AudioLyrics.presentationCurrentIndex(in: lines, at: karaokeTime)
    }

    private var matchesPlayback: Bool {
        guard let audioPlayer else { return false }
        return audioPlayer.playingItemID == itemID
            || audioPlayer.isStreamingPlaybackActive(itemID: itemID)
    }

    private var karaokeTime: TimeInterval? {
        guard matchesPlayback else { return nil }
        return audioPlayer?.currentTime
    }

    private var elapsed: TimeInterval {
        _ = progressTick
        guard matchesPlayback else { return 0 }
        return audioPlayer?.currentTime ?? 0
    }

    private var duration: TimeInterval? {
        matchesPlayback ? audioPlayer?.duration : nil
    }

    private var isPlaying: Bool {
        matchesPlayback && audioPlayer?.isPaused == false
    }

    var body: some View {
        ZStack {
            Color.themeBg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                lyricsBody
                transport
            }
        }
        .task {
            guard let sidecarLoader else { return }
            loadedTimedText = await sidecarLoader()
        }
        .onAppear {
            if autoplayOnAppear {
                play()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AudioPlayerService.stateDidChangeNotification)) { _ in
            progressTick += 1
        }
    }

    private var header: some View {
        HStack {
            if showsCloseButton {
                Button("Done") { dismiss() }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.themePurple)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.themeBgHighlight.opacity(0.9), in: Capsule())
            }
            Spacer()
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.themeFg)
                .lineLimit(1)
            Spacer()
            languageControl
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var languageControl: some View {
        if let resolvedTimedText, resolvedTimedText.showsLanguageControl {
            Menu {
                ForEach(resolvedTimedText.tracks.indices, id: \.self) { index in
                    Button(resolvedTimedText.tracks[index].languageLabel) {
                        selectedTrackIndex = index
                    }
                }
            } label: {
                Text(resolvedTimedText.tracks.indices.contains(resolvedTrackIndex)
                     ? resolvedTimedText.tracks[resolvedTrackIndex].languageLabel
                     : "Language")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themePurple)
                    .lineLimit(1)
            }
            .accessibilityLabel("Lyrics language")
            .accessibilityIdentifier("audioLyrics.language")
        } else {
            Color.clear.frame(width: 72, height: 1)
        }
    }

    @ViewBuilder
    private var lyricsBody: some View {
        let verses = lines
        if verses.isEmpty {
            Spacer()
            Text("No lyrics")
                .font(.title2)
                .foregroundStyle(.themeComment)
                .accessibilityIdentifier("audioLyrics.empty")
            Spacer()
        } else if AudioLyrics.allowsKaraoke(verses) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(Array(verses.enumerated()), id: \.offset) { index, line in
                            lyricLine(line, index: index, current: currentIndex)
                                .id(index)
                                .onTapGesture {
                                    guard let start = line.startTime else { return }
                                    audioPlayer?.seek(to: start)
                                }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 36)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: currentIndex) { _, index in
                    guard let index else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(Array(verses.enumerated()), id: \.offset) { index, line in
                        lyricLine(line, index: index, current: nil)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func lyricLine(_ line: AudioLyrics.Line, index: Int, current: Int?) -> some View {
        let isCurrent = current == index
        let isNeighbor = current.map { abs($0 - index) == 1 } ?? false
        return Text(line.text)
            .font(isCurrent ? .title.weight(.semibold) : .title2)
            .foregroundStyle(isCurrent ? Color.themeFg : Color.themeComment.opacity(isNeighbor ? 0.85 : 0.55))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(line.startTime == nil ? [] : .isButton)
    }

    private var transport: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                ProgressView(value: progressValue)
                    .tint(.themePurple)
                HStack {
                    Text(AudioPlaybackTimeFormatting.clock(elapsed))
                    Spacer()
                    Text(AudioPlaybackTimeFormatting.clock(duration))
                }
                .font(.caption)
                .foregroundStyle(.themeComment)
            }
            Button(action: togglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.themePurple)
                    .frame(width: 56, height: 56)
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            if !matchesPlayback, openFile != nil {
                Button("Open file", action: { openFile?() })
                    .font(.subheadline)
                    .foregroundStyle(.themePurple)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
        .padding(.top, 8)
    }

    private var progressValue: Double {
        guard let duration, duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    private func togglePlay() {
        guard let audioPlayer else {
            play()
            return
        }
        if audioPlayer.playingItemID == itemID
            || audioPlayer.isStreamingPlaybackActive(itemID: itemID) {
            if audioPlayer.isPaused {
                audioPlayer.resume()
            } else {
                audioPlayer.pause()
            }
        } else {
            play()
        }
    }
}
