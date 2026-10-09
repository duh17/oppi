import Foundation
import GhosttyVt
import Observation

/// Text from the remote that is shown outside the terminal grid (window title,
/// program status labels). libghostty already rejects control characters in
/// OSC 7501 text; this also removes invisible formatting such as bidi overrides.
enum SSHTerminalDisplayText {
    static let titleLimit = 120
    static let messageLimit = 256

    /// Combining marks kept after one base character. Two covers stacked
    /// accents (Vietnamese) and keycaps; a longer run is a tower of marks
    /// that grows one line of text tall enough to cover the screen.
    static let marksPerBase = 2

    /// Line and paragraph separators (U+2028/U+2029) become one space so the
    /// result is a single line and neighboring words stay apart.
    static func sanitized(_ raw: String, limit: Int) -> String {
        var kept = String.UnicodeScalarView()
        // UnicodeScalarView.count walks the scalars, so checking it each
        // iteration is O(input × limit). A running count stays O(input).
        var count = 0
        var marks = 0
        for scalar in raw.unicodeScalars {
            if count >= limit { break }
            switch scalar.properties.generalCategory {
            case .lineSeparator, .paragraphSeparator:
                kept.append(" ")
                count += 1
                marks = 0
            case .format:
                continue
            case .nonspacingMark, .enclosingMark:
                if marks >= marksPerBase { continue }
                kept.append(scalar)
                count += 1
                marks += 1
            default:
                if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.illegalCharacters.contains(scalar) { continue }
                kept.append(scalar)
                count += 1
                marks = 0
            }
        }
        return String(kept)
    }
}

/// What programs in one terminal said about themselves with OSC 7501, kept as
/// the specification requires (https://www.superlogical.com/rex/docs/build/program-status):
/// one record per id, each report replaces its record, `clear` removes a subtree,
/// at most 256 records with the least recently updated evicted first.
///
/// libghostty validates reports and stores nothing, so every lifetime rule lives
/// here. The store is plain Swift state with no path back into the terminal,
/// which keeps the engine's effect callbacks copy-only. Record values keep the
/// Ghostty C enums; `progress == -1` means the program sent none.
@MainActor @Observable
final class SSHTerminalProgramStatusStore {
    static let maximumRecords = 256

    /// A validated report, copied out of the callback's borrowed memory.
    struct Report: Sendable {
        var state: GhosttyProgramStatusState
        var kind = GHOSTTY_PROGRAM_STATUS_KIND_NONE
        var progress = -1
        var id = ""
        var app = ""
        var title = ""
        var message = ""
    }

    struct Record: Equatable, Sendable, Identifiable {
        /// Empty for the root record; `/` separates ancestors from children.
        let id: String
        let state: GhosttyProgramStatusState
        let kind: GhosttyProgramStatusKind
        let progress: Int
        /// As the program reported it for this record. `SSHTerminalProgramStatusStore.app(of:)`
        /// applies the ancestor fallback; it is deliberately not stored per record.
        let app: String
        let title: String
        let message: String
        /// Increases with every update across the store. The eviction order.
        let revision: UInt64
        /// When this state and kind began. A repeat of the same state keeps it,
        /// so a re-report is not a new unseen outcome.
        let since: Date
        /// The store revision when this state and kind began; a repeat keeps it.
        /// Unlike `since`, two episodes never share it.
        let episode: UInt64
    }

    private(set) var records = [String: Record]()
    @ObservationIgnored private var revision: UInt64 = 0

    var root: Record? { records[""] }

    func record(id: String) -> Record? { records[id] }

    /// Direct children of `id` (`""` = the root's children), sorted by id. A
    /// record whose parent never reported is not a child of anything shown here;
    /// `subtree(of:)` finds it.
    func children(of id: String = "") -> [Record] {
        let prefix = id.isEmpty ? "" : id + "/"
        return records.values.filter {
            !$0.id.isEmpty && $0.id.hasPrefix(prefix) && !$0.id.dropFirst(prefix.count).contains("/")
        }.sorted { $0.id < $1.id }
    }

    /// Every record beneath `id` (everything but the root record for `""`), sorted by id.
    func subtree(of id: String = "") -> [Record] {
        records.values.filter { Self.isBeneath($0.id, id) }.sorted { $0.id < $1.id }
    }

    /// The record's own `app`, else the nearest ancestor's non-empty `app`,
    /// the root record being the last ancestor.
    func app(of id: String) -> String {
        var current = id
        while true {
            if let app = records[current]?.app, !app.isEmpty { return app }
            guard !current.isEmpty else { return "" }
            current = current.lastIndex(of: "/").map { String(current[..<$0]) } ?? ""
        }
    }

    func apply(_ report: Report) {
        let kind = report.kind
        switch report.state {
        case GHOSTTY_PROGRAM_STATUS_STATE_CLEAR:
            clear(id: report.id)
        case GHOSTTY_PROGRAM_STATUS_STATE_IDLE, GHOSTTY_PROGRAM_STATUS_STATE_WORKING,
             GHOSTTY_PROGRAM_STATUS_STATE_DONE, GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED,
             GHOSTTY_PROGRAM_STATUS_STATE_ERROR:
            if records[report.id] == nil, records.count >= Self.maximumRecords,
               let oldest = records.values.min(by: { $0.revision < $1.revision }) {
                records[oldest.id] = nil
            }
            revision &+= 1
            let storedKind = report.state == GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED ? kind : GHOSTTY_PROGRAM_STATUS_KIND_NONE
            let since: Date
            let episode: UInt64
            if let previous = records[report.id], previous.state == report.state, previous.kind == storedKind {
                since = previous.since
                episode = previous.episode
            } else {
                since = Date()
                episode = revision
            }
            records[report.id] = Record(
                id: report.id,
                state: report.state,
                kind: storedKind,
                progress: (0...100).contains(report.progress) ? report.progress : -1,
                app: report.app,
                title: SSHTerminalDisplayText.sanitized(report.title, limit: SSHTerminalDisplayText.titleLimit),
                message: SSHTerminalDisplayText.sanitized(report.message, limit: SSHTerminalDisplayText.messageLimit),
                revision: revision,
                since: since,
                episode: episode)
        default:
            break // A state this build does not know is ignored, as the spec says.
        }
    }

    /// OSC 133 prompt start: the program that reported has returned to the shell.
    func promptStarted() { dropRunning() }

    /// The remote process or the connection ended.
    func processEnded() { dropRunning() }

    /// RIS.
    func removeAll() {
        if !records.isEmpty { records = [:] }
    }

    private func clear(id: String) {
        guard !id.isEmpty else { return removeAll() }
        let doomed = records.keys.filter { $0 == id || Self.isBeneath($0, id) }
        for key in doomed { records[key] = nil }
    }

    /// `done` and `error` survive; `idle` may go and does, so a program that
    /// exited does not leave "idle" behind its shell prompt.
    private func dropRunning() {
        let doomed = records.filter { $0.value.state != GHOSTTY_PROGRAM_STATUS_STATE_DONE
            && $0.value.state != GHOSTTY_PROGRAM_STATUS_STATE_ERROR
        }.keys
        for key in doomed { records[key] = nil }
    }

    private static func isBeneath(_ id: String, _ ancestor: String) -> Bool {
        ancestor.isEmpty ? !id.isEmpty : id.hasPrefix(ancestor + "/")
    }
}
