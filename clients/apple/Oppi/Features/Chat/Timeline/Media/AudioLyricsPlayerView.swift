import Combine
import SwiftUI

enum AudioLyricsPlayerPresenter {
    @MainActor
    static func present(
        from view: UIView,
        title: String,
        lyrics: String?,
        itemID: String,
        audioPlayer: AudioPlayerService?,
        play: @escaping () -> Void,
        openFile: (() -> Void)?
    ) {
        guard let presenter = nearestViewController(from: view) else { return }
        let root = AudioLyricsPlayerView(
            title: title,
            lyrics: lyrics,
            itemID: itemID,
            audioPlayer: audioPlayer,
            play: play,
            openFile: openFile,
            autoplayOnAppear: true,
            showsCloseButton: true
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
    var autoplayOnAppear = true
    var showsCloseButton = true

    @Environment(\.dismiss) private var dismiss
    @State private var progressTick = 0

    private var lines: [AudioLyrics.Line] {
        AudioLyrics.lines(from: lyrics)
    }

    private var currentIndex: Int? {
        guard let audioPlayer, AudioLyrics.allowsKaraoke(lines) else { return nil }
        return AudioLyrics.currentIndex(in: lines, at: audioPlayer.currentTime)
    }

    private var elapsed: TimeInterval {
        _ = progressTick
        guard let audioPlayer, audioPlayer.playingItemID == itemID else { return 0 }
        return audioPlayer.currentTime
    }

    private var duration: TimeInterval? {
        audioPlayer?.playingItemID == itemID ? audioPlayer?.duration : nil
    }

    private var isPlaying: Bool {
        audioPlayer?.playingItemID == itemID && audioPlayer?.isPaused == false
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
            Color.clear.frame(width: 72, height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var lyricsBody: some View {
        let verses = lines
        if verses.isEmpty {
            Spacer()
            Text("No lyrics")
                .font(.title2)
                .foregroundStyle(.themeComment)
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
                        lyricLine(line, index: index, current: index == 0 ? 0 : nil)
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
            if audioPlayer?.playingItemID != itemID, openFile != nil {
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
        if audioPlayer.playingItemID == itemID {
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
