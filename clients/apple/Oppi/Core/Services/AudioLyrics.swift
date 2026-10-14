import Foundation

/// Untimed transcript becomes verse lines. Timed cues are optional and never invented.
enum AudioLyrics {
    struct Line: Equatable, Sendable {
        var text: String
        var startTime: TimeInterval?
        var speaker: String? = nil
    }

    static func lines(from text: String?) -> [Line] {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return [] }

        let newlinePieces = trimmed
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if newlinePieces.count >= 2 {
            return newlinePieces.map { Line(text: $0, startTime: nil) }
        }

        let source = newlinePieces.first ?? trimmed
        return splitSentences(source).map { Line(text: $0, startTime: nil) }
    }

    static func allowsKaraoke(_ lines: [Line]) -> Bool {
        lines.contains { $0.startTime != nil }
    }

    /// Full-screen highlight index. Untimed verse lists never treat line 0 as current.
    static func presentationCurrentIndex(in lines: [Line], at time: TimeInterval?) -> Int? {
        guard allowsKaraoke(lines), let time else { return nil }
        return currentIndex(in: lines, at: time)
    }

    static func currentIndex(in lines: [Line], at time: TimeInterval) -> Int? {
        guard time.isFinite else { return nil }
        var bestIndex: Int?
        var bestStart: TimeInterval?
        for (index, line) in lines.enumerated() {
            guard let start = line.startTime, start.isFinite, start <= time else { continue }
            if let bestStart, start < bestStart {
                continue
            }
            bestIndex = index
            bestStart = start
        }
        return bestIndex
    }

    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".!?".contains(character) {
                let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty {
                    sentences.append(piece)
                }
                current = ""
            }
        }
        let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty {
            sentences.append(trailing)
        }
        return sentences.isEmpty ? [text] : sentences
    }
}

/// Speaker-tagged timed text reads as a script. The cast is listed in order of first line.
enum AudioReaderCast {
    struct Member: Equatable, Sendable {
        var name: String
        /// Authored `#RRGGBB`; `nil` means the view picks a theme color by `paletteIndex`.
        var colorHex: String?
        var paletteIndex: Int
    }

    static func isScript(_ lines: [AudioLyrics.Line]) -> Bool {
        lines.contains { $0.speaker != nil }
    }

    static func members(in lines: [AudioLyrics.Line], voiceColors: [String: String]) -> [Member] {
        var seen = Set<String>()
        var members: [Member] = []
        for speaker in lines.compactMap(\.speaker) where seen.insert(speaker).inserted {
            members.append(Member(
                name: speaker,
                colorHex: voiceColors[speaker],
                paletteIndex: members.count
            ))
        }
        return members
    }

    /// A speaker's label shows when the line opens a new turn, like a printed script.
    static func startsTurn(_ lines: [AudioLyrics.Line], at index: Int) -> Bool {
        guard lines.indices.contains(index), lines[index].speaker != nil else { return false }
        return index == 0 || lines[index - 1].speaker != lines[index].speaker
    }
}

/// Full-screen player and Control Center map a 0...1 bar onto a known duration.
enum AudioPlaybackSeek {
    static func isSeekable(duration: TimeInterval?) -> Bool {
        guard let duration, duration.isFinite, duration > 0 else { return false }
        return true
    }

    static func time(forFraction fraction: Double, duration: TimeInterval?) -> TimeInterval? {
        guard isSeekable(duration: duration), let duration, fraction.isFinite else { return nil }
        let clampedFraction = min(1, max(0, fraction))
        return clampedFraction * duration
    }

    static func clampedTime(_ time: TimeInterval, duration: TimeInterval?) -> TimeInterval? {
        guard isSeekable(duration: duration), let duration, time.isFinite else { return nil }
        return min(duration, max(0, time))
    }

    static func fraction(elapsed: TimeInterval, duration: TimeInterval?) -> Double {
        guard isSeekable(duration: duration), let duration, elapsed.isFinite else { return 0 }
        return min(1, max(0, elapsed / duration))
    }
}

enum AudioPlaybackTimeFormatting {
    static func clock(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded(.towardZero))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", secs))"
        }
        return "\(minutes):\(String(format: "%02d", secs))"
    }

    static func elapsedDuration(elapsed: TimeInterval?, duration: TimeInterval?) -> String {
        "\(clock(elapsed ?? 0)) / \(clock(duration))"
    }
}
