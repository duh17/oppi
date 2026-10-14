import Foundation
import Testing
@testable import Oppi

@Suite("Long-form listening: chapters, resume, sleep timer, speed")
struct AudioLongformListeningTests {
    private let chapters = [
        AudioChapter(title: "One", start: 0),
        AudioChapter(title: "Two", start: 100),
        AudioChapter(title: "Three", start: 250),
    ]

    @Test("chapter lookup, end, and CD-style previous/next targets")
    func chapterNavigation() {
        #expect(AudioChapters.index(in: chapters, at: 0) == 0)
        #expect(AudioChapters.index(in: chapters, at: 99.9) == 0)
        #expect(AudioChapters.index(in: chapters, at: 100) == 1)
        #expect(AudioChapters.index(in: [], at: 5) == nil)
        #expect(AudioChapters.end(of: 1, in: chapters, duration: 400) == 250)
        #expect(AudioChapters.end(of: 2, in: chapters, duration: 400) == 400)

        // Back restarts the chapter, or goes to the previous one within its first 3 s.
        #expect(AudioChapters.previousTarget(in: chapters, at: 120) == 100)
        #expect(AudioChapters.previousTarget(in: chapters, at: 102) == 0)
        #expect(AudioChapters.previousTarget(in: chapters, at: 1) == 0)
        #expect(AudioChapters.nextTarget(in: chapters, at: 120) == 250)
        #expect(AudioChapters.nextTarget(in: chapters, at: 260) == nil)
    }

    @Test("long recordings resume mid-way; clips, edges, and finished books do not")
    func resumePolicy() throws {
        let defaults = try #require(UserDefaults(suiteName: "AudioResumeStoreTests-\(UUID().uuidString)"))
        let store = AudioResumeStore(defaults: defaults)
        let hour: TimeInterval = 3600

        store.save(600, duration: hour, for: "book")
        #expect(store.position(for: "book", duration: hour) == 600)

        store.save(60, duration: 120, for: "clip")
        #expect(store.position(for: "clip", duration: 120) == nil)

        store.save(10, duration: hour, for: "start")
        #expect(store.position(for: "start", duration: hour) == nil)

        // Reaching the last 30 s, or clearing on completion, forgets the position.
        store.save(hour - 5, duration: hour, for: "book")
        #expect(store.position(for: "book", duration: hour) == nil)
        store.save(900, duration: hour, for: "book")
        store.clear("book")
        #expect(store.position(for: "book", duration: hour) == nil)
    }

    @Test("resume keeps the most recently saved positions when full")
    func resumeEvictsOldest() throws {
        let defaults = try #require(UserDefaults(suiteName: "AudioResumeStoreTests-\(UUID().uuidString)"))
        let store = AudioResumeStore(defaults: defaults)
        let base = Date(timeIntervalSince1970: 1_000_000)
        for index in 0...AudioResumeStore.maximumEntries {
            store.save(600, duration: 3600, for: "book-\(index)", now: base.addingTimeInterval(TimeInterval(index)))
        }
        #expect(store.position(for: "book-0", duration: 3600) == nil)
        #expect(store.position(for: "book-1", duration: 3600) == 600)
        #expect(store.position(for: "book-\(AudioResumeStore.maximumEntries)", duration: 3600) == 600)
    }

    @Test("minute sleep timer counts listening time only")
    func sleepTimerMinutes() throws {
        let start = Date(timeIntervalSince1970: 0)
        var timer = AudioSleepTimer(.minutes(15), now: start, isPlaying: true, time: 0, chapters: [], duration: nil)
        #expect(!timer.shouldPause(now: start.addingTimeInterval(14 * 60), time: 0))

        // Paused for an hour after 10 minutes: 5 minutes of listening remain.
        timer.pause(now: start.addingTimeInterval(10 * 60))
        #expect(!timer.shouldPause(now: start.addingTimeInterval(70 * 60), time: 0))
        let remaining = try #require(timer.remainingTime(now: start.addingTimeInterval(70 * 60)))
        #expect(abs(remaining - 5 * 60) < 0.001)
        timer.resume(now: start.addingTimeInterval(70 * 60))
        #expect(!timer.shouldPause(now: start.addingTimeInterval(74 * 60), time: 0))
        #expect(timer.shouldPause(now: start.addingTimeInterval(75 * 60), time: 0))

        // Set while paused, the countdown waits for playback.
        var idle = AudioSleepTimer(.minutes(15), now: start, isPlaying: false, time: 0, chapters: [], duration: nil)
        #expect(!idle.shouldPause(now: start.addingTimeInterval(3600), time: 0))
        idle.resume(now: start.addingTimeInterval(3600))
        #expect(idle.shouldPause(now: start.addingTimeInterval(3600 + 15 * 60), time: 0))
    }

    @Test("end-of-chapter timer follows seeks into another chapter")
    func sleepTimerEndOfChapter() {
        let now = Date()
        var timer = AudioSleepTimer(.endOfChapter, now: now, isPlaying: true, time: 120, chapters: chapters, duration: 400)
        #expect(!timer.shouldPause(now: now, time: 249))
        #expect(timer.shouldPause(now: now, time: 250))

        timer.seek(to: 260, chapters: chapters, duration: 400)
        #expect(!timer.shouldPause(now: now, time: 300))
        #expect(timer.shouldPause(now: now, time: 400))
    }

    @Test("speed preference keeps only offered rates")
    func playbackRatePreference() throws {
        let defaults = try #require(UserDefaults(suiteName: "AudioPlaybackRateTests-\(UUID().uuidString)"))
        #expect(AudioPlaybackRate.stored(in: defaults) == 1)
        AudioPlaybackRate.store(1.5, in: defaults)
        #expect(AudioPlaybackRate.stored(in: defaults) == 1.5)
        defaults.set(Float(3), forKey: AudioPlaybackRate.preferenceKey)
        #expect(AudioPlaybackRate.stored(in: defaults) == 1)
    }
}
