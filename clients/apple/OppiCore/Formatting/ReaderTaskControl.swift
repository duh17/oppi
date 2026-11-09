import Foundation

/// The source line of a task item, carried through a Markdown text that is
/// parsed again: `<oppi-line n="12"/>` at the start of the item, which
/// CommonMark keeps as one inline HTML node. The converter that knows the line
/// writes it, and the Markdown parse takes it back off the item.
enum MarkdownSourceLineMarker {
    private static let prefix = "<oppi-line n=\""
    private static let suffix = "\"/>"

    static func markup(line: Int) -> String {
        "\(prefix)\(line)\(suffix)"
    }

    /// The line `html` names, when it is exactly one marker. Zero says the item
    /// has no box to toggle (a plain item that shares a list with tasks).
    static func line(in html: String) -> Int? {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix), trimmed.hasSuffix(suffix) else { return nil }
        let digits = trimmed.dropFirst(prefix.count).dropLast(suffix.count)
        guard let line = Int(digits), line >= 0 else { return nil }
        return line
    }
}

/// Carries Org's `[-]` (some but not all of an item's own sub-items are
/// done) through a Markdown round trip. GFM's task-list syntax has no
/// partial state, so the item still serializes as an ordinary unchecked box;
/// this marker rides in the item's content, right after the source-line
/// marker when both are present, and is stripped the same way.
enum MarkdownPartialTaskMarker {
    static let markup = "<oppi-partial/>"

    static func isPartial(in html: String) -> Bool {
        html.trimmingCharacters(in: .whitespacesAndNewlines) == markup
    }
}

/// A control the reader draws for a line of its Org or Markdown source, and
/// the line it edits.
///
/// The renderers know the line (a task item's, or the heading a state or date
/// belongs to) and stamp it on what they draw; the reader turns a tap or a
/// VoiceOver action on that into `TaskSourceEdit`. A control never names a
/// file, a tool, or an extension: it is a position in whatever document the
/// reader shows.
struct ReaderTaskControl: Equatable, Hashable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
        /// The box on a task-list item.
        case checkbox
        /// An Org heading's TODO state.
        case state
        /// An Org heading's Scheduled or Deadline stamp.
        case date(OrgPlanningKind)
        /// An Org heading's disclosure: tapping the heading folds or unfolds
        /// its section. Unlike the rest it edits nothing, so it works in a
        /// file the reader cannot save.
        case fold(isExpanded: Bool)
    }

    let kind: Kind
    /// 1-based source line: the task line, or the heading the control belongs to.
    /// A fold names its heading by ordinal instead (`OrgFolding`), which a save
    /// does not move.
    let line: Int

    /// The control's name in the badge markup and in accessibility identifiers.
    var kindName: String {
        switch kind {
        case .checkbox: "checkbox"
        case .state: "state"
        case .date(.scheduled): "scheduled"
        case .date(.deadline): "deadline"
        case .date(.closed): "closed"
        case .fold(let isExpanded): isExpanded ? "fold-expanded" : "fold-collapsed"
        }
    }

    var isFold: Bool {
        if case .fold = kind { return true }
        return false
    }

    /// `fileViewer.task.<kind>.<line>`: the line is the control's stable key in
    /// the document, so a test finds the same control after the view redraws.
    var accessibilityIdentifier: String {
        // A fold's name carries its state, which an identifier must not.
        isFold ? "fileViewer.heading.fold.\(line)" : "fileViewer.task.\(kindName).\(line)"
    }

    init(kind: Kind, line: Int) {
        self.kind = kind
        self.line = line
    }

    /// From the markup attributes of a badge (`control="state" line="12"`).
    init?(name: String, line: String) {
        guard let line = Int(line), line > 0 else { return nil }
        switch name {
        case "state": self.init(kind: .state, line: line)
        case "scheduled": self.init(kind: .date(.scheduled), line: line)
        case "deadline": self.init(kind: .date(.deadline), line: line)
        case "fold-expanded": self.init(kind: .fold(isExpanded: true), line: line)
        case "fold-collapsed": self.init(kind: .fold(isExpanded: false), line: line)
        default: return nil
        }
    }
}
