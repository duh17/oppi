import Foundation

/// One internal URL of a session (`proc://bash-3`) as the viewer shows it
/// (`GET …/sessions/{id}/internal-url`, server `InternalUrlView`): a status
/// line, facts, the command, and terminal output. The scheme's plugin fills it;
/// the app reads only these fields, so every scheme with a viewer shows the same
/// way.
struct InternalURLView: Decodable, Equatable, Sendable {
    struct Status: Decodable, Equatable, Sendable {
        /// `Running`, `Exit 65`, `Done`.
        let text: String
        /// `neutral`, `accent`, `success`, `warning` or `danger`.
        let tone: String
        /// Still changing: the viewer reads it again while it shows it.
        let live: Bool
        /// Epoch milliseconds.
        let startedAt: Double?
        let endedAt: Double?
    }

    struct Fact: Decodable, Equatable, Sendable {
        let label: String
        let value: String?
        /// Epoch milliseconds, shown in the device's clock.
        let time: Double?
    }

    /// The output from UTF-16 offset `start`: what came after the `from` the
    /// request named, or the whole window the server keeps.
    struct Output: Decodable, Equatable, Sendable {
        let start: Int
        let text: String
        let truncated: Bool
    }

    let url: String
    let title: String

    /// How long it ran, or has run so far while live: `0:42`, `5:07`, `1:05:10`.
    /// Nil without a start, or an end once it is no longer live.
    func duration(at now: Date) -> String? {
        guard let startedAt = status.startedAt,
              let end = status.live ? now.timeIntervalSince1970 * 1000 : status.endedAt else { return nil }
        let total = max(0, Int(((end - startedAt) / 1000).rounded(.down)))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
    let status: Status
    let facts: [Fact]
    let command: String?
    let output: Output
    let stoppable: Bool
}

/// The output a viewer holds, kept in step with reads that append to it
/// (`InternalURLView.Output`).
struct InternalURLOutputWindow: Equatable, Sendable {
    private(set) var start = 0
    private(set) var text = ""

    /// The UTF-16 offset the next read asks from: everything held so far.
    var end: Int { start + text.utf16.count }

    /// What the window keeps, as the server keeps the last 64,000 characters of
    /// a job's output: a long-running viewer holds no more than a fresh one.
    static let limit = 64_000

    /// A read that continues where the window ends appends; any other read is
    /// the whole window again and replaces it. Past `limit` UTF-16 units, the
    /// front drops off and `start` moves with it.
    mutating func apply(_ output: InternalURLView.Output) {
        if output.start == end {
            text += output.text
        } else {
            start = output.start
            text = output.text
        }
        let utf16 = text.utf16
        let excess = utf16.count - Self.limit
        guard excess > 0 else { return }
        var cut = utf16.index(utf16.startIndex, offsetBy: excess)
        // Never split a surrogate pair: keep one unit less.
        if UTF16.isTrailSurrogate(utf16[cut]) { cut = utf16.index(after: cut) }
        start += utf16.distance(from: utf16.startIndex, to: cut)
        text = String(text[cut...])
    }
}
