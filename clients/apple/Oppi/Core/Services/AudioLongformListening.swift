import Foundation

/// Listening speeds offered by the full-screen player and the lock screen.
enum AudioPlaybackRate {
    static let options: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]
    static let preferenceKey = "\(AppIdentifiers.subsystem).audio.playbackRate"

    static func label(_ rate: Float) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return "\(formatter.string(from: NSNumber(value: rate)) ?? "1")\u{00D7}"
    }

    /// Unknown stored values fall back to normal speed.
    static func stored(in defaults: UserDefaults = .standard) -> Float {
        let value = defaults.float(forKey: preferenceKey)
        return options.contains(value) ? value : 1
    }

    static func store(_ rate: Float, in defaults: UserDefaults = .standard) {
        defaults.set(rate, forKey: preferenceKey)
    }
}

/// One chapter from the audio file's own chapter metadata (M4B/MP4).
struct AudioChapter: Equatable, Sendable {
    var title: String
    var start: TimeInterval
}

enum AudioChapters {
    /// Chapter that contains `time`: the last one starting at or before it.
    static func index(in chapters: [AudioChapter], at time: TimeInterval) -> Int? {
        guard time.isFinite else { return nil }
        return chapters.lastIndex { $0.start <= time }
    }

    /// End of the chapter at `index`: the next chapter's start, else the recording's end.
    static func end(of index: Int, in chapters: [AudioChapter], duration: TimeInterval?) -> TimeInterval? {
        guard chapters.indices.contains(index) else { return nil }
        return chapters.indices.contains(index + 1) ? chapters[index + 1].start : duration
    }

    /// Back restarts the current chapter unless playback is within its first
    /// three seconds, then it goes to the previous chapter, like a CD player.
    static func previousTarget(in chapters: [AudioChapter], at time: TimeInterval) -> TimeInterval? {
        guard let index = index(in: chapters, at: time) else { return chapters.first?.start }
        if time - chapters[index].start > 3 || index == 0 {
            return chapters[index].start
        }
        return chapters[index - 1].start
    }

    static func nextTarget(in chapters: [AudioChapter], at time: TimeInterval) -> TimeInterval? {
        guard let index = index(in: chapters, at: time) else { return chapters.first?.start }
        return chapters.indices.contains(index + 1) ? chapters[index + 1].start : nil
    }
}

/// Where to pick up a long recording, keyed by the file or media URL that played.
/// Short clips (voice replies) never resume.
struct AudioResumeStore {
    static let minimumDuration: TimeInterval = 5 * 60
    /// Positions this close to either end restart from the beginning.
    static let edgeMargin: TimeInterval = 30
    static let maximumEntries = 200
    static let preferenceKey = "\(AppIdentifiers.subsystem).audio.resumePositions"

    var defaults: UserDefaults = .standard

    func position(for key: String, duration: TimeInterval?) -> TimeInterval? {
        guard Self.isLong(duration), let duration,
              let saved = entries()[key]?["t"],
              saved > Self.edgeMargin, saved < duration - Self.edgeMargin else { return nil }
        return saved
    }

    func save(_ time: TimeInterval, duration: TimeInterval?, for key: String, now: Date = Date()) {
        guard Self.isLong(duration), let duration, time.isFinite else { return }
        var all = entries()
        if time <= Self.edgeMargin || time >= duration - Self.edgeMargin {
            all.removeValue(forKey: key)
        } else {
            all[key] = ["t": time, "at": now.timeIntervalSince1970]
        }
        if all.count > Self.maximumEntries {
            let oldest = all.sorted { ($0.value["at"] ?? 0) < ($1.value["at"] ?? 0) }
                .prefix(all.count - Self.maximumEntries)
                .map(\.key)
            for key in oldest { all.removeValue(forKey: key) }
        }
        defaults.set(all, forKey: Self.preferenceKey)
    }

    func clear(_ key: String) {
        var all = entries()
        guard all.removeValue(forKey: key) != nil else { return }
        defaults.set(all, forKey: Self.preferenceKey)
    }

    private func entries() -> [String: [String: Double]] {
        defaults.dictionary(forKey: Self.preferenceKey) as? [String: [String: Double]] ?? [:]
    }

    private static func isLong(_ duration: TimeInterval?) -> Bool {
        guard let duration, duration.isFinite else { return false }
        return duration >= minimumDuration
    }
}

/// Sleep timer. Minute timers count listening time only, so a manual pause
/// does not spend it; end-of-chapter follows seeks into another chapter.
struct AudioSleepTimer: Equatable {
    enum Option: Equatable, Hashable {
        case minutes(Int)
        case endOfChapter
    }

    static let minuteOptions = [15, 30, 45, 60]

    let option: Option
    private var remaining: TimeInterval?
    private var deadline: Date?
    private var chapterEnd: TimeInterval?

    init(
        _ option: Option,
        now: Date,
        isPlaying: Bool,
        time: TimeInterval,
        chapters: [AudioChapter],
        duration: TimeInterval?
    ) {
        self.option = option
        switch option {
        case .minutes(let minutes):
            remaining = TimeInterval(minutes * 60)
            if isPlaying { deadline = now.addingTimeInterval(TimeInterval(minutes * 60)) }
        case .endOfChapter:
            chapterEnd = Self.chapterEnd(at: time, chapters: chapters, duration: duration)
        }
    }

    /// Listening time left on a minute timer.
    func remainingTime(now: Date) -> TimeInterval? {
        if let deadline { return max(0, deadline.timeIntervalSince(now)) }
        return remaining
    }

    mutating func pause(now: Date) {
        guard let deadline else { return }
        remaining = max(0, deadline.timeIntervalSince(now))
        self.deadline = nil
    }

    mutating func resume(now: Date) {
        guard deadline == nil, let remaining else { return }
        deadline = now.addingTimeInterval(remaining)
    }

    mutating func seek(to time: TimeInterval, chapters: [AudioChapter], duration: TimeInterval?) {
        guard option == .endOfChapter else { return }
        chapterEnd = Self.chapterEnd(at: time, chapters: chapters, duration: duration)
    }

    func shouldPause(now: Date, time: TimeInterval) -> Bool {
        if let deadline { return now >= deadline }
        if let chapterEnd { return time >= chapterEnd }
        return false
    }

    private static func chapterEnd(at time: TimeInterval, chapters: [AudioChapter], duration: TimeInterval?) -> TimeInterval? {
        guard let index = AudioChapters.index(in: chapters, at: time) else { return duration }
        return AudioChapters.end(of: index, in: chapters, duration: duration)
    }
}
