import Foundation

/// Untimed transcript becomes verse lines. Timed cues are optional and never invented.
enum AudioLyrics {
    struct Line: Equatable, Sendable {
        var text: String
        var startTime: TimeInterval?
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
