import Foundation
import Testing
@testable import Oppi

/// The viewer's output window over successive reads (`InternalURLOutputWindow`)
/// and the duration it shows (`InternalURLView.duration`).
@Suite("InternalURLView")
struct InternalURLViewTests {
    private func output(_ start: Int, _ text: String) -> InternalURLView.Output {
        InternalURLView.Output(start: start, text: text, truncated: false)
    }

    @Test func appendsAReadThatContinuesAndReplacesAnyOther() {
        var window = InternalURLOutputWindow()
        window.apply(output(0, "héllo\n"))
        // The next read asks from the UTF-16 end, which an emoji counts as two.
        window.apply(output(6, "🚀 go\n"))
        #expect(window.text == "héllo\n🚀 go\n")
        #expect(window.end == 12)
        window.apply(output(12, ""))
        #expect(window.text == "héllo\n🚀 go\n")
        // The producer dropped its start: the read is the whole window again.
        window.apply(output(40, "tail only\n"))
        #expect(window.text == "tail only\n")
        #expect(window.end == 50)
    }

    @Test func keepsOnlyTheNewestOutputTheServerWouldAndMovesItsStart() {
        var window = InternalURLOutputWindow()
        let limit = InternalURLOutputWindow.limit
        window.apply(output(0, String(repeating: "a", count: limit - 1)))
        // Appending past the limit drops the front; the next read still asks from the true end.
        window.apply(output(limit - 1, "bcd"))
        #expect(window.text.utf16.count == limit)
        #expect(window.start == 2)
        #expect(window.end == limit + 2)
        #expect(window.text.hasSuffix("abcd"))
        // A cut never splits an emoji's surrogate pair: it keeps one unit less.
        window.apply(output(0, "🚀" + String(repeating: "x", count: limit - 1)))
        #expect(window.text == String(repeating: "x", count: limit - 1))
        #expect(window.start == 2)
    }

    @Test func showsHowLongItRanOrHasRun() throws {
        func view(live: Bool, endedAt: Double?) throws -> InternalURLView {
            let status: [String: Any] = [
                "text": live ? "Running" : "Exit 65", "tone": live ? "accent" : "danger", "live": live,
                "startedAt": 1_000_000,
            ].merging(endedAt.map { ["endedAt": $0] } ?? [:]) { $1 }
            let json: [String: Any] = [
                "url": "proc://bash-3", "title": "make", "status": status, "facts": [],
                "output": ["start": 0, "text": "", "truncated": false], "stoppable": live,
            ]
            return try JSONDecoder().decode(InternalURLView.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let now = Date(timeIntervalSince1970: (1_000_000 + 3_725_000) / 1000)
        #expect(try view(live: true, endedAt: nil).duration(at: now) == "1:02:05")
        #expect(try view(live: false, endedAt: 1_108_000).duration(at: now) == "1:48")
        // Ended before its end was kept: no duration rather than a wrong one.
        #expect(try view(live: false, endedAt: nil).duration(at: now) == nil)
    }
}
