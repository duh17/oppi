#if DEBUG
import SwiftUI
import UIKit

// MARK: - Global Audio Banner Preview

struct GlobalAudioBannerPreview: View {
    var body: some View {
        TabView {
            NavigationStack {
                List {
                    Section("Recent") {
                        Label("Albert TTS plan", systemImage: "waveform")
                        Label("Branch + fork UX", systemImage: "arrow.triangle.branch")
                        Label("Release checklist", systemImage: "checklist")
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.themeBg)
                .navigationTitle("Workspaces")
            }
            .tabItem {
                Label("Workspaces", systemImage: "square.grid.2x2")
            }

            NavigationStack {
                Color.themeBg
                    .navigationTitle("Settings")
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
        }
        .toolbarBackground(Color.themeBg, for: .tabBar)
        .background(Color.themeBg.ignoresSafeArea())
        .accessibilityIdentifier("screenshot.ready")
    }
}

// MARK: - Script Reader Preview

/// Speaker-tagged WebVTT in the full-screen player. Plays a generated silent clip,
/// seeks into a dialogue line, and pauses so the current-line highlight is stable.
struct AudioScriptReaderPreview: View {
    @State private var audioPlayer = AudioPlayerService()
    private static let itemID = "audio-script-reader-preview"

    private static let sidecar = """
    WEBVTT

    STYLE
    ::cue(v[voice="旁白"]) { color: #9a9aa6; }
    ::cue(v[voice="萧峰"]) { color: #ffb347; }

    00:00:06.000 --> 00:00:23.192
    <v 旁白>少林寺前，山门大开。天下英雄聚在青石广场上，刀剑如林，杀气冲天。忽然山道上马蹄声急，十八骑黑衣武士护着一条大汉，直冲进人群之中。</v>

    00:00:23.664 --> 00:00:29.158
    <v 萧峰>萧某今日到此，只为了结旧账。哪一位要取我性命，尽管上来！</v>

    00:00:30.198 --> 00:00:35.546
    <v 慕容复>[sneers] 萧峰，你一个契丹人，也配在少林寺前大呼小叫？</v>

    00:00:37.650 --> 00:00:44.964
    <v 丁春秋>[laughs] 慕容公子说得好。老夫今日倒要看看，这位北乔峰究竟有几斤几两。</v>

    00:00:47.602 --> 00:00:55.660
    <v 旁白>话音未落，慕容复长剑出鞘，剑光如水；丁春秋大袖一挥，一股腥风直扑而来。</v>

    00:00:57.682 --> 00:00:58.162
    <v 萧峰>[shouts] 来得好！</v>

    00:00:59.726 --> 00:01:07.612
    <v 旁白>萧峰双掌齐出，掌风如龙吟虎啸，震得广场尘土飞扬，前排的人纷纷后退。</v>

    00:01:09.394 --> 00:01:14.498
    <v 虚竹>[shouts] 大哥，小弟来助你！丁老怪，你的对手是我！</v>

    00:01:16.330 --> 00:01:19.566
    <v 段誉>[laughs] 慕容公子，在下也来凑个热闹！</v>
    """

    private static var timedText: TimedText.LoadResult {
        let candidate = TimedText.Candidate(
            fileName: "shaolin.vtt",
            path: "shaolin.vtt",
            format: .vtt,
            language: nil
        )
        guard let track = TimedText.track(candidate: candidate, text: sidecar) else { return .empty }
        return TimedText.LoadResult(tracks: [track], selectedIndex: 0)
    }

    var body: some View {
        AudioLyricsPlayerView(
            title: "shaolin.m4a",
            lyrics: nil,
            itemID: Self.itemID,
            audioPlayer: audioPlayer,
            play: { _ in },
            openFile: nil,
            autoplayOnAppear: false,
            showsCloseButton: true,
            timedText: Self.timedText
        )
        .task {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("audio-script-reader-preview.wav")
            try? Self.silentWAV(seconds: 90).write(to: url)
            audioPlayer.toggleFilePlayback(fileURL: url, itemID: Self.itemID)
            audioPlayer.seek(to: 31)
            audioPlayer.pause()
        }
        .accessibilityIdentifier("screenshot.ready")
    }

    /// 8 kHz mono 16-bit PCM silence.
    private static func silentWAV(seconds: Int) -> Data {
        let sampleRate: UInt32 = 8000
        let dataSize = UInt32(seconds) * sampleRate * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(sampleRate)
        append(sampleRate * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }
}

// MARK: - Voice Message Preview

struct VoiceMessageExpandedPreview: View {
    private static let previewConfiguration = ToolTimelineRowConfiguration(
        itemID: "voice-preview-1",
        title: "Voice message",
        preview: nil,
        expandedContent: .audioMessage(
            text: "Got it. I’m reinstalling the iPhone app now, and I’ll launch it as part of the install so it comes back up cleanly.",
            attachmentId: "att-voice-preview-1",
            mimeType: "audio/wav",
            durationSeconds: 4.2,
            playbackBehavior: nil
        ),
        copyCommandText: nil,
        copyOutputText: nil,
        languageBadge: nil,
        trailing: nil,
        titleLineBreakMode: .byTruncatingTail,
        toolNamePrefix: "voice_speak",
        toolNameColor: .systemPurple,
        editAdded: nil,
        editRemoved: nil,
        collapsedImageBase64: nil,
        collapsedImageMimeType: nil,
        isExpanded: true,
        isDone: true,
        isError: false,
        startedAt: nil,
        elapsedSeconds: nil,
        segmentAttributedTitle: nil,
        segmentAttributedTrailing: nil
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Expanded voice message")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.themeFg)

                Text("Regression preview for the compact expanded voice-message card.")
                    .font(.caption)
                    .foregroundStyle(.themeComment)

                VoiceMessageToolRowRepresentable(configuration: Self.previewConfiguration, width: 370)
                    .frame(width: 370)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .background(Color.themeBg.ignoresSafeArea())
        .accessibilityIdentifier("screenshot.ready")
    }
}

private struct VoiceMessageToolRowRepresentable: UIViewRepresentable {
    let configuration: ToolTimelineRowConfiguration
    let width: CGFloat

    func makeUIView(context: Context) -> VoiceMessageToolRowHostView {
        VoiceMessageToolRowHostView(configuration: configuration, width: width)
    }

    func updateUIView(_ uiView: VoiceMessageToolRowHostView, context: Context) {
        uiView.update(configuration: configuration, width: width)
    }
}

private final class VoiceMessageToolRowHostView: UIView {
    private let contentView: ToolTimelineRowContentView
    private var widthConstraint: NSLayoutConstraint?
    private var targetWidth: CGFloat

    init(configuration: ToolTimelineRowConfiguration, width: CGFloat) {
        self.contentView = ToolTimelineRowContentView(configuration: configuration)
        self.targetWidth = width
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        let widthConstraint = contentView.widthAnchor.constraint(equalToConstant: width)
        self.widthConstraint = widthConstraint
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(configuration: ToolTimelineRowConfiguration, width: CGFloat) {
        targetWidth = width
        widthConstraint?.constant = width
        contentView.configuration = configuration
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        layoutIfNeeded()
        return contentView.systemLayoutSizeFitting(
            CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
    }
}
#endif
