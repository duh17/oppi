import GhosttyVt
import SwiftUI

/// One program-status symbol for the terminal toolbar, the blocked card,
/// Herdr rows, and the status list.
///
/// The toolbar copy is a button that opens the record list. Settle timing for a
/// just-finished root lives here, so the timer does not invalidate
/// `SSHTerminalView` or resize the terminal grid.
struct SSHTerminalStatusGlyph: View {
    enum Style {
        /// Navigation bar: entry effects, and variable colour while working.
        case toolbar
        /// Herdr agent rows: variable colour while working, nothing else.
        case row
        /// Blocked card: a periodic wiggle for attention.
        case banner
        /// Status list rows: still.
        case detail
    }

    let status: SessionStatusKind
    var style: Style = .toolbar
    /// The root record's state and revision. Toolbar only; drives the settle hold.
    var root: SSHTerminalStatusHold.Root?
    /// The roll-up's chip line, without the root. Spoken after the shown state.
    var summary: String = ""
    var hostLabel: String = ""
    var rows: [SSHTerminalStatusRow] = []
    /// Toolbar only: where the blocked card collapses to.
    var frameBox: SSHTerminalGlyphFrame?

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.presentProgramStatusDetail) private var presentDetail
    @State private var showsDetail = false
    @State private var hold: SSHTerminalStatusHold?
    @State private var bounceToken = 0
    @State private var wiggleToken = 0
    /// False while a new Done waits to draw in.
    @State private var checkDrawn = false

    /// A held outcome, else the resolved headline. Never a captured value.
    private var shown: SessionStatusKind { hold?.kind ?? status }

    var body: some View {
        Group {
            if style == .toolbar {
                Button { showsDetail = true } label: {
                    // The symbol is small; the tap target is a full bar item.
                    mark.frame(minWidth: 44, minHeight: 44).contentShape(.rect)
                }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sshTerminal.programStatus")
                    .popover(isPresented: $showsDetail) {
                        SSHTerminalStatusDetail(hostLabel: hostLabel, rows: rows)
                            .presentationCompactAdaptation(.popover)
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frameBox?.rect = $0 }
            } else {
                mark
            }
        }
        .onAppear { if presentDetail, style == .toolbar { showsDetail = true } }
        .onChange(of: SSHTerminalStatusHold.Input(root: root, headline: status)) { old, new in
            hold = SSHTerminalStatusHold.next(hold, from: old.root, to: new.root, headline: new.headline)
        }
        .onChange(of: shown, initial: true) { _, new in noteEntry(of: new) }
        // A new or cleared hold cancels the old wait, so a late wake never
        // overwrites a newer state. On wake the headline shows as it is now.
        .task(id: hold) {
            guard let hold else { return }
            try? await Task.sleep(for: hold.duration)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { self.hold = nil }
        }
        // A new Done mounts undrawn; one beat later it draws in.
        .task(id: drawsCheck) {
            guard drawsCheck else { checkDrawn = false; return }
            try? await Task.sleep(for: .milliseconds(60))
            if !Task.isCancelled { checkDrawn = true }
        }
    }

    private var mark: some View {
        Group {
            if drawsCheck {
                // Its own view, so it starts undrawn instead of being replaced
                // in fully drawn and then erased. Draw On hides while active.
                Image(systemName: SessionStatusKind.done.terminalSymbol)
                    .symbolEffect(.drawOn, isActive: !checkDrawn)
            } else {
                Image(systemName: shown.terminalSymbol)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(
                        .variableColor.iterative,
                        options: .repeating,
                        isActive: shown == .working && !reduceMotion && (style == .toolbar || style == .row)
                    )
                    .symbolEffect(.bounce, value: bounceToken)
                    .symbolEffect(.wiggle, value: wiggleToken)
                    .symbolEffect(
                        .wiggle,
                        options: .repeat(.periodic(delay: 3)),
                        isActive: style == .banner && !reduceMotion
                    )
            }
        }
        .font(.body)
        .imageScale(shown == .idle && style == .toolbar ? .small : .medium)
        .foregroundStyle(shown.tint(theme))
        .modifier(GlyphAccessibility(style: style, label: accessibilityValue))
    }

    /// Every new Done on the toolbar draws in; Reduce Motion shows it plainly.
    private var drawsCheck: Bool { style == .toolbar && shown == .done && !reduceMotion }

    private var accessibilityValue: String {
        summary.isEmpty ? shown.label : "\(shown.label), \(summary)"
    }

    /// One-shot entry effects belong to the toolbar glyph only.
    private func noteEntry(of kind: SessionStatusKind) {
        guard style == .toolbar, !reduceMotion else { return }
        if kind.isBlocked { bounceToken += 1 }
        if kind == .error { wiggleToken += 1 }
    }
}

/// The toolbar glyph is the control VoiceOver reads. Elsewhere the row or
/// card around it already speaks the state.
private struct GlyphAccessibility: ViewModifier {
    let style: SSHTerminalStatusGlyph.Style
    let label: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if style == .toolbar {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Program status")
                .accessibilityValue(label)
                .accessibilityHint("Shows each program's status")
        } else {
            content.accessibilityHidden(true)
        }
    }
}

/// A just-finished root, held in its outcome colour for a moment.
///
/// On screen, done and error are seen at once, so the resolved headline is
/// already Idle. The hold is presentation only: it never touches the seen
/// ledger. It lives while the root is still that same done or error report
/// and the headline is still Idle; anything else ends it at once.
struct SSHTerminalStatusHold: Equatable {
    struct Root: Equatable {
        var state: GhosttyProgramStatusState
        var revision: UInt64
    }

    struct Input: Equatable {
        var root: Root?
        var headline: SessionStatusKind
    }

    /// `.done` or `.error`.
    let kind: SessionStatusKind
    /// The root revision that started the hold. A repeat report keeps it.
    let revision: UInt64

    var duration: Duration { kind == .error ? .seconds(3) : .milliseconds(1500) }

    static func next(_ hold: Self?, from old: Root?, to new: Root?, headline: SessionStatusKind) -> Self? {
        guard headline == .idle, let new else { return nil }
        let outcome: SessionStatusKind? = switch new.state {
        case GHOSTTY_PROGRAM_STATUS_STATE_DONE: .done
        case GHOSTTY_PROGRAM_STATUS_STATE_ERROR: .error
        default: nil
        }
        guard let outcome else { return nil }
        // The same done or error again, or a headline-only change: keep it.
        if let hold, hold.kind == outcome { return hold }
        let wasRunning = old?.state == GHOSTTY_PROGRAM_STATUS_STATE_WORKING
            || old?.state == GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED
        return wasRunning ? Self(kind: outcome, revision: new.revision) : nil
    }
}

/// The toolbar glyph's frame, for the blocked card to collapse into. A plain
/// class written from layout, so a frame change never refreshes a view.
@MainActor
final class SSHTerminalGlyphFrame {
    var rect: CGRect = .zero
}

/// The text the toolbar glyph keeps off the bar.
struct SSHTerminalStatusDetail: View {
    @Environment(\.theme) private var theme

    let hostLabel: String
    let rows: [SSHTerminalStatusRow]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Program status")
                        .font(.headline)
                        .foregroundStyle(.themeFg)
                    Label(SSHTerminalProgramStatusPresentation.hostCaption(hostLabel), systemImage: "network")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                }
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 8) {
                        SSHTerminalStatusGlyph(status: row.status, style: .detail)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(.subheadline)
                                .foregroundStyle(.themeFg)
                                .lineLimit(1)
                            if !row.message.isEmpty {
                                Text(row.message)
                                    .font(.footnote)
                                    .foregroundStyle(.themeComment)
                                    .lineLimit(2)
                            }
                            Text(row.status.label)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(row.status.tint(theme))
                        }
                    }
                    .padding(.leading, CGFloat(row.depth) * 16)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(16)
            .frame(minWidth: 280, alignment: .leading)
        }
        .frame(maxHeight: 360)
        .accessibilityIdentifier("sshTerminal.programStatusDetail")
    }
}

struct SSHTerminalStatusRow: Identifiable, Equatable, Sendable {
    var id: String
    var status: SessionStatusKind
    var title: String
    var message: String
    var depth: Int
}

extension SSHTerminalProgramStatusPresentation {
    /// Root first, then children. Titles and messages are title-grade.
    @MainActor
    static func detailRows(
        store: SSHTerminalProgramStatusStore,
        isStopped: Bool,
        seenAt: Date?
    ) -> [SSHTerminalStatusRow] {
        var records = store.subtree()
        if let root = store.root { records.insert(root, at: 0) }
        return records.compactMap { record in
            guard let status = status(of: record, isStopped: isStopped, seenAt: seenAt) else { return nil }
            let title = remoteText(message: "", title: record.title)
            let app = SSHTerminalDisplayText.sanitized(record.app, limit: SSHTerminalDisplayText.titleLimit)
            let name = title.isEmpty ? (app.isEmpty ? "Program" : app) : title
            return SSHTerminalStatusRow(
                id: record.id.isEmpty ? "root" : record.id,
                status: status,
                title: name,
                message: SSHTerminalDisplayText.sanitized(record.message, limit: SSHTerminalDisplayText.titleLimit),
                depth: record.id.isEmpty ? 0 : record.id.split(separator: "/").count
            )
        }
    }
}

private struct PresentProgramStatusDetailKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Screenshot preview only. A normal launch never sets this.
    var presentProgramStatusDetail: Bool {
        get { self[PresentProgramStatusDetailKey.self] }
        set { self[PresentProgramStatusDetailKey.self] = newValue }
    }
}
