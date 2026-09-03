import Combine
import SwiftUI

/// Whether the player draws its own title in its header.
///
/// Embedded surfaces (the file browser) already show the filename in the host
/// navigation bar, so the player must not repeat it. Modal, timeline, and
/// full-screen Now Playing surfaces own their header and draw the title once.
/// This is an explicit presentation choice, independent of `showsCloseButton`.
enum AudioLyricsPlayerTitlePresentation: Equatable {
    case playerShowsTitle
    case hostOwnsTitle

    var showsInternalTitle: Bool {
        switch self {
        case .playerShowsTitle: return true
        case .hostOwnsTitle: return false
        }
    }
}

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
        play: @escaping (TimedText.LoadResult?) -> Void,
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
    let play: (TimedText.LoadResult?) -> Void
    let openFile: (() -> Void)?
    var autoplayOnAppear = false
    var showsCloseButton = true
    var titlePresentation: AudioLyricsPlayerTitlePresentation = .playerShowsTitle
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

    private var playbackTimedText: TimedText.LoadResult? {
        Self.selectedTimedTextForPlayback(
            resolvedTimedText,
            selectedTrackIndex: selectedTrackIndex
        )
    }

    static func selectedTimedTextForPlayback(
        _ timedText: TimedText.LoadResult?,
        selectedTrackIndex: Int?
    ) -> TimedText.LoadResult? {
        guard var selected = timedText else { return nil }
        if let selectedTrackIndex,
           selected.tracks.indices.contains(selectedTrackIndex) {
            selected.selectedIndex = selectedTrackIndex
        }
        return selected
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

    var body: some View {
        ZStack {
            Color.themeBg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                lyricsBody
                AudioPlaybackTransportControls(
                    itemID: itemID,
                    audioPlayer: audioPlayer,
                    play: { play(playbackTimedText) },
                    openFile: openFile,
                    density: .fullScreen
                )
            }
        }
        .task {
            guard let sidecarLoader else { return }
            let loaded = await sidecarLoader()
            guard !Task.isCancelled else { return }
            loadedTimedText = loaded
        }
        .onAppear {
            if autoplayOnAppear {
                play(playbackTimedText)
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
                    .foregroundStyle(.themeCyan)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.themeBgHighlight.opacity(0.9), in: Capsule())
            }
            Spacer()
            if titlePresentation.showsInternalTitle {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)
            }
            Spacer()
            // File browser embeds this view with the shared player and
            // `showsCloseButton: false`. Stop belongs only on presented
            // Now Playing chrome so it cannot kill unrelated playback.
            if showsCloseButton, let audioPlayer {
                InAppNowPlayingStopButton(
                    audioPlayer: audioPlayer,
                    accessibilityIdentifier: "audioLyrics.stop"
                )
            }
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
                        selectTrack(index, in: resolvedTimedText)
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

    private func selectTrack(_ index: Int, in timedText: TimedText.LoadResult) {
        selectedTrackIndex = index
        var selected = timedText
        selected.selectedIndex = index
        audioPlayer?.setNowPlayingTimedText(selected, for: itemID)
    }
}

struct AudioLoadingCancelControl: View {
    nonisolated static let cancelSymbolName = "xmark"
    let size: CGFloat

    var body: some View {
        ZStack {
            ProgressView()
                .controlSize(.regular)
                .tint(.themeComment)
            Image(systemName: Self.cancelSymbolName)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.themeFg)
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }
}

enum AudioPlaybackControlAction: Equatable {
    case start
    case cancelLoading
    case pause
    case resume

    static func resolve(
        isLoading: Bool,
        isActive: Bool,
        isPaused: Bool
    ) -> Self {
        if isLoading { return .cancelLoading }
        guard isActive else { return .start }
        return isPaused ? .resume : .pause
    }
}

enum AudioPlaybackTransportDensity {
    case fullScreen
    case drawer

    var stackSpacing: CGFloat { self == .fullScreen ? 16 : 10 }
    var controlSpacing: CGFloat { self == .fullScreen ? 28 : 24 }
    var playSize: CGFloat { self == .fullScreen ? 56 : 44 }
    var playSymbolSize: CGFloat { self == .fullScreen ? 36 : 24 }
    var horizontalPadding: CGFloat { self == .fullScreen ? 24 : 0 }
    var bottomPadding: CGFloat { self == .fullScreen ? 28 : 0 }
    var topPadding: CGFloat { self == .fullScreen ? 8 : 0 }
}

/// Shared seek and transport controls for full-screen and expanded Now Playing.
struct AudioPlaybackTransportControls: View {
    let itemID: String
    let audioPlayer: AudioPlayerService?
    let play: () -> Void
    var openFile: (() -> Void)? = nil
    var density: AudioPlaybackTransportDensity = .fullScreen
    var accessibilityPrefix = "audioLyrics"

    @State private var progressTick = 0
    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0

    var body: some View {
        VStack(spacing: density.stackSpacing) {
            VStack(spacing: 6) {
                AudioPlaybackSeekBar(
                    fraction: displayedFraction,
                    isSeekable: isSeekable,
                    accessibilityIdentifier: "\(accessibilityPrefix).seek",
                    onScrub: { fraction in
                        isScrubbing = true
                        scrubFraction = fraction
                    },
                    onCommit: commitSeek
                )
                HStack {
                    Text(AudioPlaybackTimeFormatting.clock(elapsed))
                    Spacer()
                    Text(AudioPlaybackTimeFormatting.clock(duration))
                }
                .font(.caption)
                .foregroundStyle(.themeComment)
            }

            HStack(spacing: density.controlSpacing) {
                skipButton(
                    interval: -AudioPlayerService.skipInterval,
                    symbol: "gobackward.15",
                    label: "Skip back 15 seconds",
                    identifier: "\(accessibilityPrefix).skipBack"
                )
                Button(action: togglePlay) {
                    if controlAction == .cancelLoading {
                        AudioLoadingCancelControl(size: density.playSize)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: density.playSymbolSize, weight: .semibold))
                            .foregroundStyle(.themeFg)
                            .frame(width: density.playSize, height: density.playSize)
                            .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(controlAccessibilityLabel)
                .accessibilityIdentifier("\(accessibilityPrefix).playPause")
                skipButton(
                    interval: AudioPlayerService.skipInterval,
                    symbol: "goforward.15",
                    label: "Skip forward 15 seconds",
                    identifier: "\(accessibilityPrefix).skipForward"
                )
            }

            if !matchesPlayback, openFile != nil {
                Button("Open file", action: { openFile?() })
                    .font(.subheadline)
                    .foregroundStyle(.themePurple)
            }
        }
        .padding(.horizontal, density.horizontalPadding)
        .padding(.bottom, density.bottomPadding)
        .padding(.top, density.topPadding)
        .onReceive(NotificationCenter.default.publisher(for: AudioPlayerService.stateDidChangeNotification)) { _ in
            progressTick += 1
        }
    }

    private var matchesPlayback: Bool {
        guard let audioPlayer else { return false }
        return audioPlayer.playingItemID == itemID
            || audioPlayer.isStreamingPlaybackActive(itemID: itemID)
    }

    private var controlAction: AudioPlaybackControlAction {
        AudioPlaybackControlAction.resolve(
            isLoading: audioPlayer?.loadingItemID == itemID,
            isActive: matchesPlayback,
            isPaused: audioPlayer?.isPaused == true
        )
    }

    private var controlAccessibilityLabel: String {
        switch controlAction {
        case .start: return "Play"
        case .cancelLoading: return "Cancel Loading"
        case .pause: return "Pause"
        case .resume: return "Play"
        }
    }

    private var elapsed: TimeInterval {
        _ = progressTick
        if isScrubbing,
           let time = AudioPlaybackSeek.time(forFraction: scrubFraction, duration: duration) {
            return time
        }
        guard matchesPlayback else { return 0 }
        return audioPlayer?.currentTime ?? 0
    }

    private var duration: TimeInterval? {
        matchesPlayback ? audioPlayer?.duration : nil
    }

    private var isPlaying: Bool {
        matchesPlayback && audioPlayer?.isPaused == false
    }

    private var isSeekable: Bool {
        matchesPlayback && AudioPlaybackSeek.isSeekable(duration: duration)
    }

    private var displayedFraction: Double {
        if isScrubbing { return scrubFraction }
        return AudioPlaybackSeek.fraction(elapsed: elapsed, duration: duration)
    }

    private func commitSeek(_ fraction: Double) {
        isScrubbing = false
        scrubFraction = fraction
        guard isSeekable,
              let time = AudioPlaybackSeek.time(forFraction: fraction, duration: duration) else {
            return
        }
        audioPlayer?.seek(to: time)
    }

    private func skipButton(
        interval: TimeInterval,
        symbol: String,
        label: String,
        identifier: String
    ) -> some View {
        Button {
            guard matchesPlayback else { return }
            audioPlayer?.skip(by: interval)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.themeFg)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSeekable)
        .opacity(isSeekable ? 1 : 0.45)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func togglePlay() {
        switch controlAction {
        case .start:
            play()
        case .cancelLoading:
            audioPlayer?.stop()
        case .pause:
            audioPlayer?.pause()
        case .resume:
            audioPlayer?.resume()
        }
    }
}

/// 44pt track that scrubs on drag and tap-to-position. Native Slider is thumb-only.
private struct AudioPlaybackSeekBar: View {
    var fraction: Double
    var isSeekable: Bool
    var accessibilityIdentifier = "audioLyrics.seek"
    var onScrub: (Double) -> Void
    var onCommit: (Double) -> Void

    /// `@GestureState` tracks the drag so the back-swipe claim is released even
    /// when the gesture is cancelled (e.g. `isSeekable` flips off mid-scrub).
    @GestureState private var isTrackingSeek = false
    @State private var scrubClaim: BackSwipeExclusiveClaim?

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let clamped = min(1, max(0, fraction))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.themeComment.opacity(0.35))
                    .frame(height: 4)
                Capsule()
                    .fill(.themeFg)
                    .frame(width: width * clamped, height: 4)
                Circle()
                    .fill(.themeFg)
                    .frame(width: 12, height: 12)
                    .offset(x: (width * clamped) - 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .updating($isTrackingSeek) { _, state, _ in
                        state = true
                    }
                    .onChanged { value in
                        beginClaim()
                        onScrub(Self.fraction(forX: value.location.x, width: width))
                    }
                    .onEnded { value in
                        onCommit(Self.fraction(forX: value.location.x, width: width))
                    }
            )
        }
        .frame(height: 44)
        .allowsHitTesting(isSeekable)
        .opacity(isSeekable ? 1 : 0.55)
        .onChange(of: isTrackingSeek) { _, tracking in
            if !tracking {
                releaseClaim()
            }
        }
        .onChange(of: isSeekable) { _, seekable in
            if !seekable {
                releaseClaim()
            }
        }
        .onDisappear { releaseClaim() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(percentValue)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityAdjustableAction { direction in
            guard isSeekable else { return }
            let step = 0.05
            switch direction {
            case .increment:
                onCommit(min(1, fraction + step))
            case .decrement:
                onCommit(max(0, fraction - step))
            @unknown default:
                break
            }
        }
    }

    private var percentValue: String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded())) percent"
    }

    /// Acquire inside the gesture callback so a fast flick cannot reach the
    /// parent's first `onChanged` before the claim exists.
    private func beginClaim() {
        guard scrubClaim == nil else { return }
        scrubClaim = HorizontalBackSwipeGesturePolicy.acquireExclusiveClaim()
    }

    private func releaseClaim() {
        if let claim = scrubClaim {
            HorizontalBackSwipeGesturePolicy.releaseExclusiveClaim(claim)
            scrubClaim = nil
        }
    }

    private static func fraction(forX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(1, max(0, Double(x / width)))
    }
}
