#if DEBUG
import UIKit

/// `SCREENSHOT_SCREEN=audio-script-reader`: speaker-tagged WebVTT in the
/// full-screen player, over the theme background the way a reader page shows it.
/// It plays a generated silent clip, seeks into a dialogue line, and pauses so
/// the current-line highlight is stable.
final class AudioScriptReaderPreviewController: PreviewRootController {
    private let audioPlayer: AudioPlayerService
    /// The clip the SwiftUI preview's `.task` set up; the controller owns it so a
    /// preview that goes away stops touching the player.
    private var setup: Task<Void, Never>?
    private static let itemID = "audio-script-reader-preview"

    init(themeStore: ThemeStore) {
        let audioPlayer = AudioPlayerService()
        self.audioPlayer = audioPlayer
        let root = AppRootEnvironment.preview(
            coordinator: ConnectionCoordinator(serverStore: ServerStore()),
            themeStore: themeStore
        )
        super.init(
            root: root,
            themeStore: themeStore,
            content: AudioLyricsPlayerViewController(configuration: .init(
                title: "shaolin.m4a",
                lyrics: nil,
                itemID: Self.itemID,
                audioPlayer: audioPlayer,
                play: { _ in },
                openFile: nil,
                autoplayOnAppear: false,
                showsCloseButton: true,
                timedText: Self.timedText
            ))
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        setup?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let audioPlayer = self.audioPlayer
        setup = Task { @MainActor in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("audio-script-reader-preview.wav")
            try? Self.silentWAV(seconds: 90).write(to: url)
            audioPlayer.toggleFilePlayback(fileURL: url, itemID: Self.itemID)
            audioPlayer.seek(to: 31)
            audioPlayer.pause()
        }
    }

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

    /// 8 kHz mono 16-bit PCM silence.
    static func silentWAV(seconds: Int) -> Data {
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
#endif
