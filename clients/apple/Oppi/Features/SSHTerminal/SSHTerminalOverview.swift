import Foundation

/// One OSC 7501 record a multiplexer passes on for a pane's program: Herdr's
/// `program_status` and Rex's `com.superlogical.terminal.program_status` both
/// carry the record tree the terminal itself keeps from libghostty. The empty
/// id is the program itself; `/` separates a child record from its parent.
struct SSHTerminalPaneRecord: Decodable, Equatable, Hashable, Sendable {
    let id: String
    let state: ProgramStatusState
    let kind: ProgramStatusKind?
    let message: String?
    /// The program the record belongs to, when the multiplexer names it (Rex's
    /// `effective_app`, inherited from a parent record, else the record's `app`).
    let app: String?
    /// When the program last changed this record, when the multiplexer says: Rex
    /// sends it, so a pane row can say how long ago it last moved. Nil for a record
    /// without one, and for a whole pane that reports nothing.
    let updatedAt: Date?

    /// Herdr names the line `message` and always sends `id`; Rex names it `msg`
    /// and leaves `id` out for the root record.
    private enum CodingKeys: String, CodingKey {
        case id, state, kind, message, msg, app, effectiveApp = "effective_app", updatedAt = "updated_at"
    }

    init(
        id: String,
        state: ProgramStatusState,
        kind: ProgramStatusKind? = nil,
        message: String? = nil,
        app: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.state = state
        self.kind = kind
        self.message = message
        self.app = app
        self.updatedAt = updatedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        state = try container.decode(ProgramStatusState.self, forKey: .state)
        kind = try container.decodeIfPresent(ProgramStatusKind.self, forKey: .kind)
        message = try container.decodeIfPresent(String.self, forKey: .message)
            ?? container.decodeIfPresent(String.self, forKey: .msg)
        app = try container.decodeIfPresent(String.self, forKey: .effectiveApp)
            ?? container.decodeIfPresent(String.self, forKey: .app)
        // Rex writes ISO 8601 with fractional seconds; a date this build cannot read
        // is no time at all, never a wrong one.
        updatedAt = Self.date(from: try container.decodeIfPresent(String.self, forKey: .updatedAt))
    }

    /// Rex's `updated_at`: `2026-10-30T00:59:16.372948-07:00`, and the same without
    /// a fraction.
    private static func date(from text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? Date(text, strategy: withFraction) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }

    /// A multiplexer keeps its own seen ledger, which Oppi cannot read: a done
    /// or error it still reports is one nobody has looked at, so every outcome
    /// counts as unseen. An unknown future state is nil.
    static func status(state: ProgramStatusState, kind: ProgramStatusKind?) -> SessionStatusKind? {
        SessionStatusKind.resolve(state: state, kind: kind, since: .distantFuture, seenAt: nil)
    }

    /// A pane's status from its records, rolled up the way the terminal rolls
    /// up its own, so a blocked kind survives the multiplexer. Nil when the
    /// pane's program reported nothing.
    static func headline(of records: [Self]) -> SessionStatusKind? {
        let root = records.first { $0.id.isEmpty }.flatMap { status(state: $0.state, kind: $0.kind) }
        let others = records.filter { !$0.id.isEmpty }.compactMap { status(state: $0.state, kind: $0.kind) }
        return SessionStatusRollup(root: root, others: others).headline
    }
}

/// What a tap on an overview row acts on: a group (a Herdr workspace) or an
/// item (a Herdr agent, a Rex pane) by the multiplexer's own ID, within `scope`
/// (a Herdr machine, a Rex session), because those IDs are only unique there.
struct SSHTerminalOverviewFocus: Hashable, Sendable {
    let scope: String?
    let id: String
    let isGroup: Bool
}

/// One row of a multiplexer overview: the sheet the terminal's bar opens for
/// Herdr or Rex. The source decides the rows; the sheet only draws them, so
/// both multiplexers look and behave the same.
struct SSHTerminalOverviewRow: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A machine heading, with why it cannot be read or what waits there.
        case header(note: String?, failed: Bool)
        case failure
        /// Loading, or an empty list, as plain secondary text.
        case placeholder
        /// A workspace or session. Bold while the multiplexer has it in focus.
        case group(focused: Bool)
        /// An agent or pane under its group.
        case item(subtitle: String?, focused: Bool, status: Status)
        /// A heading inside one list (the Rex panel's sections), with its symbol.
        case section(symbol: String)
        /// A row that does something rather than names something (New Pane).
        case action(symbol: String)
    }

    enum Status: Hashable, Sendable {
        /// The multiplexer has no reading for this row: no mark, no label.
        case none
        /// It has one Oppi does not know: no mark, labelled Unknown.
        case unknown
        case known(SessionStatusKind)
    }

    /// Unique within the overview; the diffable snapshot's identity.
    let id: String
    let title: String
    let kind: Kind
    /// Nil for a row a tap cannot act on.
    let focus: SSHTerminalOverviewFocus?
    /// The row's accessibility identifier, where a test or a driver must tell
    /// rows of one kind apart; else the list's own for the kind.
    var accessibilityID: String? = nil
}

struct SSHTerminalOverviewSection: Hashable, Sendable {
    let id: String
    var rows: [SSHTerminalOverviewRow]
}

/// What an overview list draws (`SSHTerminalOverviewViewController`): the
/// terminal's sheet, or a Rex host's sessions screen.
@MainActor
protocol SSHTerminalOverviewContent: AnyObject {
    /// The list's title, the multiplexer's name.
    var title: String { get }
    /// Prefix of the rows' accessibility identifiers, such as `sshTerminal.rex`.
    var identifierPrefix: String { get }
    var sections: [SSHTerminalOverviewSection] { get }
    /// Why the last tap could not act on its row; the next tap, or closing the
    /// list, clears it.
    var focusFailure: String? { get }
    /// The list is on screen: refresh faster.
    var watching: Bool { get set }
}

/// A multiplexer the terminal can read over its SSH side channel and show in
/// an overview sheet. Herdr and Rex each conform with their own poll; the bar
/// button, badge, attention dot, and sheet treat them alike.
@MainActor
protocol SSHTerminalOverviewSource: SSHTerminalOverviewContent {
    /// The host has answered at least once, so the bar offers the sheet.
    var available: Bool { get }
    /// Rows waiting at an approval, question, or sign-in.
    var needsAttention: Int { get }
    /// Polls until the task is cancelled, the channel disconnects, or the host
    /// turns out not to have the multiplexer.
    func run(on channel: SSHTerminalChannel) async
    func refresh(on channel: SSHTerminalChannel) async
    /// Acts on a tapped row: Herdr focuses it on the host, Rex opens the pane
    /// on this device. True closes the sheet; false sets `focusFailure`.
    func activate(_ focus: SSHTerminalOverviewFocus, on channel: SSHTerminalChannel) async -> Bool
}
