import CoreText
import GhosttyVt
import SwiftUI
import UIKit

struct SSHTerminalView: View {
    let channel: SSHTerminalChannel
    let reconnect: () -> Void
    let editHost: () -> Void
    @Environment(\.themeID) private var themeID
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pendingPaste: String?
    @State private var pasteConfirmation = false
    @State private var pasteFailure: String?
    @State private var detached = false
    @State private var pasteNotice: String?
    @State private var pasteNoticeTask: Task<Void, Never>?
    @State private var keyboardRequest = 0
    @State private var composerFocusRequest = 0
    @State private var rawKeyboard = false
    @State private var herdr = HerdrMonitor()
    @State private var showsHerdr = false
    @State private var detector = SSHTerminalAgentDetector()
    @State private var keymap = SSHTerminalKeymapLoader()
    /// The user's choice; dropped when the detected mode changes.
    @State private var modeOverride: SSHTerminalInputMode?
    @State private var resignRawKeyboardRequest = 0
    /// Focus the chat bar once the raw keyboard is down and the bar is mounted.
    @State private var focusComposerAfterRaw = false
    @State private var topBarHidden = false

    private var detectedMode: SSHTerminalInputMode? { detector.mode(herdr: herdr.snapshot) }
    /// A shell gets direct typing until a probe finds an agent.
    private var inputMode: SSHTerminalInputMode { modeOverride ?? detectedMode ?? .terminal }
    /// Whose key bindings the strips offer: the foreground program, or the
    /// agent in Herdr's focused pane.
    private var keymapProgram: String? {
        switch detector.foreground {
        case nil: nil
        case .shell: "shell"
        case .agent(let name): name
        case .herdr: herdr.snapshot?.focusedAgent?.agent ?? "shell"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // A healthy connection shows no status row; the terminal gets the space.
            if channel.connecting || !channel.connected || channel.networkChanged {
                HStack(spacing: 6) {
                    if channel.connecting || channel.networkChanged {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "xmark.circle").foregroundStyle(.themeRed)
                    }
                    Text(statusText).lineLimit(2)
                    Spacer(minLength: 4)
                    if !channel.connected && !channel.connecting {
                        Button("Reconnect", action: reconnect).accessibilityIdentifier("sshTerminal.reconnect")
                    }
                }
                .font(.caption).padding(.horizontal, 10).padding(.vertical, 4).foregroundStyle(.themeFg)
                // Without .contain the identifier replaces Reconnect's own.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("sshTerminal.status")
            }
            if !channel.inputNotice.isEmpty {
                Text(channel.inputNotice).font(.footnote).foregroundStyle(.themeOrange)
                    .accessibilityIdentifier("sshTerminal.inputNotice")
            }
            if let pasteNotice {
                Text(pasteNotice).font(.footnote).foregroundStyle(.themeOrange)
                    .accessibilityIdentifier("sshTerminal.pasteNotice")
            }
            SSHTerminalSurface(channel: channel, themeID: themeID, keyboardRequest: keyboardRequest,
                               resignRequest: resignRawKeyboardRequest, tapTypesInTerminal: inputMode == .terminal,
                               keyActions: keymap.actions,
                               paste: requestPaste, followChanged: { detached = !$0 },
                               rawKeyboardChanged: { rawKeyboard = $0 },
                               focusComposer: { composerFocusRequest += 1 },
                               useChatBar: showChatBar)
                .overlay(alignment: .top) {
                    // Only while hidden: a visible bar already has Hide Bar in the menu,
                    // and a control on the first row would cover the prompt for no reason.
                    if topBarHidden, channel.connected {
                        SSHTerminalTopBarHandle(show: { setTopBarHidden(false) })
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if detached {
                        Button("Back to Live", systemImage: "arrow.down.to.line") {
                            channel.engine.backToLive()
                            detached = false
                        }.buttonStyle(.borderedProminent).padding(8)
                            .accessibilityIdentifier("sshTerminal.backToLive")
                    }
                }
            // An agent gets the chat bar; a shell gets direct typing. The chat
            // bar's keyboard button and Type in Terminal both stay in direct
            // typing until Use Chat Bar or a foreground change.
            if inputMode == .chat && !rawKeyboard {
                SSHTerminalComposer(channel: channel, focusRequest: composerFocusRequest,
                                    profile: keymap.profile, userFile: keymap.userFile) {
                    showTerminalKeyboard()
                }
            }
        }
        .background(.themeBg)
        .navigationTitle(channel.title.isEmpty ? "SSH Terminal" : channel.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(channel.title.isEmpty ? "SSH Terminal" : channel.title)
                    .font(.headline).foregroundStyle(.themeFg).lineLimit(1)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if herdr.available {
                    Button { showsHerdr = true } label: {
                        Image(systemName: "square.grid.2x2")
                            .overlay(alignment: .topTrailing) {
                                if let count = herdr.snapshot?.needsAttention, count > 0 {
                                    Text("\(count)").font(.caption2.bold()).foregroundStyle(.themeBg)
                                        .padding(.horizontal, 4).background(.themeOrange, in: .capsule)
                                        .offset(x: 8, y: -6)
                                }
                            }
                    }
                    .accessibilityLabel("Herdr agents")
                    .accessibilityValue(herdr.snapshot.map { "\($0.needsAttention) need you" } ?? "")
                    .accessibilityIdentifier("sshTerminal.herdr")
                }
                Menu {
                    if inputMode == .chat {
                        Button("Type in Terminal", systemImage: "keyboard", action: showTerminalKeyboard)
                            .accessibilityIdentifier("sshTerminal.useTerminalInput")
                    } else {
                        Button("Use Chat Bar", systemImage: "text.bubble", action: showChatBar)
                            .accessibilityIdentifier("sshTerminal.useChatBar")
                    }
                    Button("Edit Host", systemImage: "pencil", action: editHost)
                    if channel.connected {
                        Button("Hide Bar", systemImage: "chevron.up") { setTopBarHidden(true) }
                            .accessibilityIdentifier("sshTerminal.hideBar")
                        Button("Disconnect", systemImage: "xmark", role: .destructive) { channel.close(reason: "Closed by you.") }
                            .accessibilityIdentifier("sshTerminal.disconnect")
                    } else if !channel.connecting {
                        Button("Reconnect", systemImage: "arrow.clockwise", action: reconnect)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Terminal actions")
                .accessibilityIdentifier("sshTerminal.menu")
            }
        }
        .sheet(isPresented: $showsHerdr) {
            HerdrAgentsView(monitor: herdr, channel: channel)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: showsHerdr) { _, open in herdr.watching = open }
        .onChange(of: detector.foreground) { _, foreground in herdr.attached = foreground == .herdr }
        .onChange(of: detectedMode) { _, mode in
            modeOverride = nil
            // Starting an agent from the raw keyboard moves typing to the chat bar.
            if mode == .chat && rawKeyboard {
                focusComposerAfterRaw = true
                resignRawKeyboardRequest += 1
            }
        }
        .onChange(of: rawKeyboard) { _, raw in
            guard !raw, focusComposerAfterRaw else { return }
            focusComposerAfterRaw = false
            if inputMode == .chat { composerFocusRequest += 1 }
        }
        .onChange(of: channel.connected) { _, connected in if !connected { topBarHidden = false } }
        // One poller per connected generation; it ends with the connection.
        .task(id: channel.connected) {
            guard channel.connected else { return }
            await herdr.run(on: channel)
        }
        .task(id: channel.connected) {
            guard channel.connected else { return }
            await detector.run(on: channel)
        }
        .task(id: [channel.connected ? "connected" : "closed", keymapProgram ?? ""]) {
            await keymap.load(program: channel.connected ? keymapProgram : nil, on: channel)
        }
        // The terminal paints with the app theme, not the system appearance.
        // Keep the bar's title and back chevron legible against it in both.
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color.themeBg, for: .navigationBar)
        .toolbarColorScheme(themeID.preferredColorScheme, for: .navigationBar)
        // Scrolling must not show or hide this bar: visibility changes the
        // row count and resizes the remote terminal. Hide Bar and the top
        // handle are the only switches. A broken connection always shows it.
        .toolbarVisibility(topBarHidden && channel.connected ? .hidden : .visible, for: .navigationBar)
        .task { await channel.watchNetwork() }
        .onDisappear {
            pasteNoticeTask?.cancel()
            channel.close(reason: "Terminal dismissed.")
        }
        .onChange(of: scenePhase) { _, phase in
            // Explicit background recovery: close rather than silently losing
            // bytes while suspended. Host tmux can preserve the remote work.
            if phase == .background { channel.close(reason: "Oppi went to the background.") }
        }
        .alert("Paste \(pasteLineCount) \(pasteLineCount == 1 ? "line" : "lines")?", isPresented: $pasteConfirmation) {
            Button("Cancel", role: .cancel) { pendingPaste = nil }
            Button("Paste") {
                guard let text = pendingPaste else { return }
                pendingPaste = nil
                do { try channel.paste(text, confirmed: true) } catch { pasteFailure = "Paste was not sent. \(error.localizedDescription)" }
            }
        } message: { Text("This text contains a newline or terminal control sequence and may run commands. Paste only text you trust.") }
        .alert("Paste Not Sent", isPresented: Binding(get: { pasteFailure != nil }, set: { if !$0 { pasteFailure = nil } })) {
            Button("OK", role: .cancel) { pasteFailure = nil }
        } message: { Text(pasteFailure ?? "") }
    }

    private var statusText: String {
        if channel.networkChanged { return "Network changed \u{2014} checking the connection\u{2026}" }
        return channel.connecting ? channel.reason : "Disconnected \u{00b7} \(channel.reason)"
    }

    private var pasteLineCount: Int { SSHTerminalEngine.pasteLineCount(pendingPaste ?? "") }

    /// Chat bar keyboard button and Type in Terminal: stay in direct typing and
    /// open the keyboard. A later tap opens it again, even if the app wants clicks.
    private func showTerminalKeyboard() {
        modeOverride = .terminal
        keyboardRequest += 1
    }

    private func setTopBarHidden(_ hidden: Bool) {
        guard hidden != topBarHidden else { return }
        withAnimation(ThemeMotion.easeInOut(duration: 0.2, reduceMotion: reduceMotion)) {
            topBarHidden = hidden
        }
    }

    /// Use Chat Bar, from the menu or the terminal keyboard. Clears a typing
    /// override when the foreground program already wants the chat bar.
    private func showChatBar() {
        modeOverride = detectedMode == .chat ? nil : .chat
        focusComposerAfterRaw = true
        resignRawKeyboardRequest += 1
    }

    private func showPasteNotice(_ text: String) {
        pasteNotice = text
        pasteNoticeTask?.cancel()
        pasteNoticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { pasteNotice = nil }
        }
    }

    private func requestPaste() {
        guard channel.connected else { channel.send(Data()); return }
        // Nil when the clipboard holds no text or iOS refused the read.
        guard let text = UIPasteboard.general.string else {
            showPasteNotice("Nothing pasted \u{2014} the clipboard has no text, or paste access was not allowed.")
            return
        }
        guard text.utf8.count <= SSHTerminalEngine.maximumPasteBytes else {
            pasteFailure = "Pastes are limited to 64 KiB."
            return
        }
        if SSHTerminalEngine.pasteNeedsConfirmation(text) {
            pendingPaste = text
            pasteConfirmation = true
        } else {
            do { try channel.paste(text) } catch { pasteFailure = "Paste was not sent. \(error.localizedDescription)" }
        }
    }
}

/// What a tap on the terminal grid does. Direct typing owns a tap while the
/// keyboard is down, so it can come back after leaving the chat bar. While
/// that keyboard is up, a mouse-reporting app keeps the tap as a click
/// (Herdr's switch, a tmux pane) and the keyboard stays; its bar hides it.
enum SSHTerminalTapAction: Equatable {
    case hideKeyboard
    case typeInTerminal
    case dismissOtherInput
    case mouseClick
    case focusChatBar

    static func resolve(
        terminalTyping: Bool,
        keyboardUp: Bool,
        otherInputFocused: Bool,
        appWantsClicks: Bool
    ) -> Self {
        if keyboardUp { return appWantsClicks ? .mouseClick : .hideKeyboard }
        if terminalTyping { return .typeInTerminal }
        if otherInputFocused { return .dismissOtherInput }
        if appWantsClicks { return .mouseClick }
        return .focusChatBar
    }
}

/// How one cell paints: colors after inverse, and the attributes text drawing
/// reads. Equal neighbours on a row share one fill and one text draw.
struct SSHTerminalPaintStyle: Equatable {
    let foreground: UInt32
    let background: UInt32
    let bold: Bool
    let italic: Bool
    let faint: Bool
    let invisible: Bool
    let underline: Bool
    let strikethrough: Bool

    init(_ cell: SSHTerminalCell) {
        let style = cell.style
        foreground = Self.pack(style.inverse ? cell.background : cell.foreground)
        background = Self.pack(style.inverse ? cell.foreground : cell.background)
        bold = style.bold
        italic = style.italic
        faint = style.faint
        invisible = style.invisible
        underline = style.underline != 0
        strikethrough = style.strikethrough
    }

    static func pack(_ rgb: GhosttyColorRgb) -> UInt32 { UInt32(rgb.r) << 16 | UInt32(rgb.g) << 8 | UInt32(rgb.b) }
}

/// A stretch of one row painted with one fill and one text draw. Printable
/// ASCII neighbours of one style share a run, kerned onto the cell grid. Any
/// other grapheme (wide, combining, non-ASCII) is its own run, so a fallback
/// font's advance cannot shift the columns after it.
struct SSHTerminalPaintRun: Equatable {
    let column: Int
    let columns: Int
    let text: String
    let style: SSHTerminalPaintStyle
    let fixedPitch: Bool
}

/// What a repaint touches. Agent TUIs redraw a spinner or a status line many
/// times a second; repainting the whole grid one cell at a time for each of
/// those cost about 73 ms per frame at 48x40 and pinned the main thread.
enum SSHTerminalPaintPlan {
    static func runs(_ row: [SSHTerminalCell]) -> [SSHTerminalPaintRun] {
        var runs = [SSHTerminalPaintRun]()
        var start = 0
        var text = ""
        var count = 0
        var style: SSHTerminalPaintStyle?
        func flush() {
            if let style, count > 0 {
                runs.append(.init(column: start, columns: count, text: text, style: style, fixedPitch: true))
            }
            style = nil
            text = ""
            count = 0
        }
        for (column, cell) in row.enumerated() {
            // A wide tail is painted by its head.
            guard cell.width > 0 else { continue }
            let cellStyle = SSHTerminalPaintStyle(cell)
            if cell.width == 1, let character = Self.fixedPitchCharacter(cell.text) {
                if cellStyle != style || start + count != column {
                    flush()
                    start = column
                    style = cellStyle
                }
                text.append(character)
                count += 1
            } else {
                flush()
                runs.append(.init(column: column, columns: cell.width, text: cell.text, style: cellStyle, fixedPitch: false))
            }
        }
        flush()
        return runs
    }

    /// Rows whose cells or cursor differ from the last painted frame. Nil when
    /// the grid's shape or default background changed: repaint everything.
    static func changedRows(from old: SSHTerminalFrame?, to new: SSHTerminalFrame) -> IndexSet? {
        guard let old, old.rows.count == new.rows.count,
              SSHTerminalPaintStyle.pack(old.background) == SSHTerminalPaintStyle.pack(new.background) else { return nil }
        var rows = IndexSet()
        for y in new.rows.indices {
            let before = old.rows[y], after = new.rows[y]
            guard before.count == after.count else { return nil }
            let same = zip(before, after).allSatisfy {
                $0.text == $1.text && $0.width == $1.width && SSHTerminalPaintStyle($0) == SSHTerminalPaintStyle($1)
            }
            if !same { rows.insert(y) }
        }
        if !sameCursor(old.cursor, new.cursor) {
            for y in [cursorRow(old), cursorRow(new)].compactMap({ $0 }) where new.rows.indices.contains(y) { rows.insert(y) }
        }
        return rows
    }

    /// The next rows to invalidate within one tick's paint budget, from the
    /// first pending row. A window, not a scattered pick: UIKit draws the
    /// bounding box of what is invalidated, so the box is what costs time.
    static func rowsWithinBudget(_ pending: IndexSet, secondsPerRow: Double, budget: Double) -> IndexSet {
        guard let first = pending.first else { return [] }
        let rows = max(1, Int(budget / max(secondsPerRow, .ulpOfOne)))
        return pending.intersection(IndexSet(integersIn: first..<first + rows))
    }

    /// The rects a tick invalidates: one full-width rect per run of adjacent
    /// rows, plus the strip below the grid when a full pass ends.
    static func invalidationRects(rows: IndexSet, margin: Bool, rowCount: Int, cellHeight: CGFloat, bounds: CGSize) -> [CGRect] {
        var rects = rows.rangeView.map {
            CGRect(x: 0, y: CGFloat($0.lowerBound) * cellHeight, width: bounds.width, height: CGFloat($0.count) * cellHeight)
        }
        let gridBottom = CGFloat(rowCount) * cellHeight
        if margin, bounds.height > gridBottom {
            rects.append(CGRect(x: 0, y: gridBottom, width: bounds.width, height: bounds.height - gridBottom))
        }
        return rects
    }

    static func cursorRow(_ frame: SSHTerminalFrame) -> Int? {
        frame.cursor.visible && frame.cursor.viewport_has_value ? Int(frame.cursor.viewport_y) : nil
    }

    private static func sameCursor(_ a: GhosttyRenderStateCursor, _ b: GhosttyRenderStateCursor) -> Bool {
        a.visible == b.visible && a.viewport_has_value == b.viewport_has_value && a.viewport_x == b.viewport_x
            && a.viewport_y == b.viewport_y && a.wide_tail == b.wide_tail && a.visual_style == b.visual_style
    }

    /// A blank cell paints as a space; printable ASCII keeps the font's one advance.
    private static func fixedPitchCharacter(_ text: String) -> Character? {
        if text.isEmpty { return " " }
        let scalars = text.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first, (0x20...0x7E).contains(scalar.value) else { return nil }
        return Character(scalar)
    }
}

/// Damage waiting to be invalidated. One pass drains front to back before new
/// damage joins it, so a row that changes every frame (a spinner on top, a
/// status line) cannot pull the window back and leave later rows stale for a
/// whole burst. A row still waiting in the pass paints the latest frame when
/// its turn comes; a row already taken waits for the next pass.
struct SSHTerminalRepaintQueue {
    private(set) var pass = IndexSet()
    private(set) var next = IndexSet()
    private(set) var margin = false
    var isEmpty: Bool { pass.isEmpty && next.isEmpty && !margin }

    /// `changed` nil: the grid's shape changed, so the open pass no longer
    /// describes it. Start one full pass, including the strip below the grid.
    mutating func add(_ changed: IndexSet?, rowCount: Int) {
        guard let changed else {
            pass = IndexSet(integersIn: 0..<rowCount)
            next = []
            margin = true
            return
        }
        next.formUnion(changed.subtracting(pass))
    }

    /// This tick's rows, and whether the strip below the grid goes with them.
    mutating func take(secondsPerRow: Double, budget: Double) -> (rows: IndexSet, margin: Bool) {
        if pass.isEmpty {
            pass = next
            next = []
        }
        let rows = SSHTerminalPaintPlan.rowsWithinBudget(pass, secondsPerRow: secondsPerRow, budget: budget)
        pass.subtract(rows)
        let withMargin = margin && pass.isEmpty
        if withMargin { margin = false }
        return (rows, withMargin)
    }
}

/// Draws planned runs with cached faces. Fixed-pitch runs are kerned so each
/// glyph lands on its cell even though the cell width is the font's rounded-up
/// advance.
@MainActor
final class SSHTerminalGridPainter {
    let cellSize: CGSize
    private let font: UIFont
    /// The family's own bold face: bundled code fonts have no bold trait to derive.
    private let boldFont: UIFont
    private var faces = [Int: (font: UIFont, kern: CGFloat)]()

    init(font: UIFont, boldFont: UIFont) {
        self.font = font
        self.boldFont = boldFont
        cellSize = CGSize(width: ceil(("M" as NSString).size(withAttributes: [.font: font]).width),
                          height: ceil(font.lineHeight))
    }

    /// The Code Font family at the Code Text Size, with Nerd Font symbols as a
    /// fallback once they are installed. A 12pt base is 13pt at 100%, the
    /// terminal's size before it followed Code Text Size.
    static func codeFont() -> SSHTerminalGridPainter {
        let family = FontPreferences.codeFont
        let size = FontPreferences.codePointSize(baseSize: 12)
        return SSHTerminalGridPainter(font: family.font(size: size, weight: .regular),
                                      boldFont: family.font(size: size, weight: .bold))
    }

    func paint(_ frame: SSHTerminalFrame, rows: Range<Int>, cursorColor: UIColor, in context: CGContext) {
        for y in rows where frame.rows.indices.contains(y) {
            let top = CGFloat(y) * cellSize.height
            for run in SSHTerminalPaintPlan.runs(frame.rows[y]) { paint(run, top: top, in: context) }
        }
        guard let y = SSHTerminalPaintPlan.cursorRow(frame), rows.contains(y) else { return }
        var area = CGRect(x: CGFloat(frame.cursor.viewport_x) * cellSize.width, y: CGFloat(y) * cellSize.height,
                          width: cellSize.width, height: cellSize.height)
        cursorColor.setStroke()
        if frame.cursor.visual_style == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR { area.size.width = 2 }
        if frame.cursor.visual_style == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE {
            area.origin.y += cellSize.height - 2
            area.size.height = 2
        }
        context.stroke(area.insetBy(dx: 0.5, dy: 0.5))
    }

    private func paint(_ run: SSHTerminalPaintRun, top: CGFloat, in context: CGContext) {
        let style = run.style
        let area = CGRect(x: CGFloat(run.column) * cellSize.width, y: top,
                          width: CGFloat(run.columns) * cellSize.width, height: cellSize.height)
        Self.color(style.background).setFill()
        context.fill(area)
        guard !style.invisible else { return }
        if run.fixedPitch, !style.underline, !style.strikethrough, run.text.allSatisfy({ $0 == " " }) { return }
        let face = face(bold: style.bold, italic: style.italic)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: face.font,
            .foregroundColor: Self.color(style.foreground).withAlphaComponent(style.faint ? 0.5 : 1),
        ]
        if run.fixedPitch { attributes[.kern] = face.kern }
        if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        context.saveGState()
        context.clip(to: area)
        if let text = withSymbols(run, face: face, attributes: attributes) {
            text.draw(at: area.origin)
        } else {
            (run.text as NSString).draw(at: area.origin, withAttributes: attributes)
        }
        context.restoreGState()
    }

    /// Nerd Font icons the face lacks, drawn with the symbols font and kerned to
    /// one cell. nil when the run has none (the common case) or the symbols
    /// are not installed. Explicit, because SF Mono ignores cascade lists.
    private func withSymbols(_ run: SSHTerminalPaintRun, face: (font: UIFont, kern: CGFloat),
                             attributes: [NSAttributedString.Key: Any]) -> NSAttributedString? {
        guard run.text.unicodeScalars.contains(where: NerdFontSymbols.isPrivateUse),
              let symbols = symbolsFace() else { return nil }
        let text = NSMutableAttributedString(string: run.text, attributes: attributes)
        var location = 0
        for character in run.text {
            let length = character.utf16.count
            if character.unicodeScalars.contains(where: NerdFontSymbols.isPrivateUse),
               !Self.covers(face.font, character) {
                let range = NSRange(location: location, length: length)
                text.addAttribute(.font, value: symbols.font, range: range)
                if run.fixedPitch { text.addAttribute(.kern, value: symbols.kern, range: range) }
            }
            location += length
        }
        return text
    }

    private func symbolsFace() -> (font: UIFont, kern: CGFloat)? {
        if let face = faces[Self.symbolsKey] { return face }
        guard let symbols = NerdFontSymbols.font(size: font.pointSize) else { return nil }
        let advance = ("\u{E0B0}" as NSString).size(withAttributes: [.font: symbols]).width
        let face = (symbols, cellSize.width - advance)
        faces[Self.symbolsKey] = face
        return face
    }

    private static let symbolsKey = 4

    private static func covers(_ font: UIFont, _ character: Character) -> Bool {
        let units = Array(character.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font as CTFont, units, &glyphs, units.count)
    }

    private func face(bold: Bool, italic: Bool) -> (font: UIFont, kern: CGFloat) {
        let key = (bold ? 1 : 0) | (italic ? 2 : 0)
        if let face = faces[key] { return face }
        let weighted = bold ? boldFont : font
        // A family without an italic face stays upright.
        let styled = italic
            ? weighted.fontDescriptor.withSymbolicTraits(.traitItalic)
                .map { NerdFontSymbols.withFallback(UIFont(descriptor: $0, size: weighted.pointSize)) } ?? weighted
            : weighted
        let advance = ("M" as NSString).size(withAttributes: [.font: styled]).width
        let face = (styled, cellSize.width - advance)
        faces[key] = face
        return face
    }

    private static func color(_ packed: UInt32) -> UIColor {
        UIColor(red: CGFloat(packed >> 16 & 0xFF) / 255, green: CGFloat(packed >> 8 & 0xFF) / 255,
                blue: CGFloat(packed & 0xFF) / 255, alpha: 1)
    }
}

/// Showing or hiding the navigation bar resizes the remote terminal, so a
/// history drag must not do it. A pull counts only when it is long enough and
/// mostly vertical. Finger down is show; finger up is hide. The reveal handle
/// commits show only.
enum SSHTerminalTopBarGesture {
    /// Shorter than a nav-bar height. The old 24pt scroll threshold resized
    /// the terminal on an ordinary history nudge.
    static let minimumTravel: CGFloat = 44
    static let dominanceRatio: CGFloat = 1.35

    enum Action: Equatable {
        case show
        case hide
    }

    static func action(translation: CGSize) -> Action? {
        let vertical = translation.height
        guard abs(vertical) >= minimumTravel else { return nil }
        guard abs(vertical) > abs(translation.width) * dominanceRatio else { return nil }
        return vertical > 0 ? .show : .hide
    }
}

/// The way back after Hide Bar. A tap shows the bar; a downward pull does too.
/// It is not a scroll catcher: a short or sideways drag leaves the bar hidden.
private struct SSHTerminalTopBarHandle: View {
    let show: () -> Void

    var body: some View {
        Button(action: show) {
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.themeFg)
                .frame(width: 52, height: 22)
                .themedSurface(.floatingControl, in: Capsule())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show terminal bar")
        .accessibilityHint("Shows the host name, Herdr, and terminal actions")
        .accessibilityIdentifier("sshTerminal.showBar")
        // The commit distance, not a short slip, so a tap still reaches the button.
        .simultaneousGesture(
            DragGesture(minimumDistance: SSHTerminalTopBarGesture.minimumTravel)
                .onEnded { value in
                    guard SSHTerminalTopBarGesture.action(translation: value.translation) == .show else { return }
                    show()
                }
        )
    }
}

private struct SSHTerminalSurface: UIViewRepresentable {
    let channel: SSHTerminalChannel
    let themeID: ThemeID
    /// Bumped to open the raw keyboard. A mouse-reporting app would otherwise
    /// treat a tap as a click, so the chat bar's keyboard button cannot be a tap.
    let keyboardRequest: Int
    /// Bumped to put the raw keyboard down.
    let resignRequest: Int
    /// Direct typing: a tap opens the raw keyboard instead of the chat bar.
    let tapTypesInTerminal: Bool
    let keyActions: [SSHTerminalKeyAction]
    let paste: () -> Void
    let followChanged: (Bool) -> Void
    let rawKeyboardChanged: (Bool) -> Void
    let focusComposer: () -> Void
    let useChatBar: () -> Void

    func makeUIView(context: Context) -> SSHTerminalGridView {
        let view = SSHTerminalGridView(channel: channel, paste: paste, followChanged: followChanged)
        view.rawKeyboardChanged = rawKeyboardChanged
        view.focusComposer = focusComposer
        view.useChatBar = useChatBar
        view.keyboardRequest = keyboardRequest
        view.resignRequest = resignRequest
        return view
    }

    func updateUIView(_ view: SSHTerminalGridView, context: Context) {
        view.applyTheme(themeID)
        view.needsPaint = true
        view.tapTypesInTerminal = tapTypesInTerminal
        view.setKeyActions(keyActions)
        view.showModifiers()
        if view.keyboardRequest != keyboardRequest {
            view.keyboardRequest = keyboardRequest
            view.becomeFirstResponder()
        }
        if view.resignRequest != resignRequest {
            view.resignRequest = resignRequest
            _ = view.resignFirstResponder()
        }
    }
}

/// Mounted work is only the viewport grid, not one UITextView for scrollback.
/// libghostty owns history/reflow/alternate screen; UIKit paints copied cells
/// at fixed positions and supplies UIKeyInput and physical-key events.
private final class SSHTerminalGridView: UIView, UIKeyInput {
    let channel: SSHTerminalChannel
    let requestPaste: () -> Void
    let followChanged: (Bool) -> Void
    var needsPaint = true
    var keyboardRequest = 0
    var resignRequest = 0
    var tapTypesInTerminal = false
    var rawKeyboardChanged: (Bool) -> Void = { _ in }
    var focusComposer: () -> Void = {}
    var useChatBar: () -> Void = {}
    var paintedChangeCount = -1
    /// Rebuilt when Code Font, Code Text Size, or the Nerd Font symbols change;
    /// a new cell size resizes the remote terminal on the next layout.
    private var painter = SSHTerminalGridPainter.codeFont()
    private var cellSize: CGSize { painter.cellSize }
    /// The frame `draw(_:)` paints from. Each tick replaces it and invalidates
    /// only the rows that differ from it.
    private var shown: SSHTerminalFrame?
    /// A new bounds size exposes or stretches pixels outside any row.
    private var needsFullPaint = true
    /// Changed rows not yet invalidated: a repaint bigger than one tick's
    /// budget (a resize, a scroll, a screenful of styled cells) spreads over
    /// ticks so the main thread keeps answering between them.
    private var repaints = SSHTerminalRepaintQueue()
    /// Rows invalidated and not yet drawn. `draw(_:)` paints only these.
    private var invalidRows = IndexSet()
    /// Measured paint cost, smoothed. Plain text is a fraction of a millisecond
    /// per row; one style per cell is about two.
    private var secondsPerRow = 0.0005
    private static let paintBudget = 0.008
    var hasPendingPaint: Bool { !repaints.isEmpty }
    private var paintedSize = CGSize.zero
    private var appliedTheme: ThemeID?
    private var lastGeometry: SSHTerminalGeometry?
    private var modifierButtons: [(button: UIButton, modifier: GhosttyMods, label: String)] = []
    private var arrowButtons: [SSHTerminalArrowButton] = []
    /// A hardware key is sent from pressesBegan only. While one is down,
    /// UIKeyInput's insertText/deleteBackward and the edit-menu paste are
    /// echoes of the same press and must not send again.
    private var hardwarePresses = Set<UIPress>()
    /// UIKit does not repeat pressesBegan for a held key, so repeats are ours.
    private let keyRepeater = SSHTerminalKeyRepeater()
    private var repeatingPress: UIPress?
    private var scrollRemainder: CGFloat = 0
    private var displayLink: CADisplayLink?
    private var bar: UIView?
    private var barKeys: UIStackView?
    /// The foreground program's actions, inserted after Paste.
    private var keyActions: [SSHTerminalKeyAction] = []
    private var keyActionButtons: [UIButton] = []
    private var foreground = UIColor(Color.themeFg)

    init(channel: SSHTerminalChannel, paste: @escaping () -> Void, followChanged: @escaping (Bool) -> Void) {
        self.channel = channel
        requestPaste = paste
        self.followChanged = followChanged
        super.init(frame: .zero)
        isOpaque = true
        // Rows not invalidated keep their pixels; a resize must not stretch them.
        clearsContextBeforeDrawing = false
        contentMode = .topLeft
        clipsToBounds = true
        accessibilityIdentifier = "sshTerminal.grid"
        accessibilityLabel = "SSH terminal. Tap to type or to hide the keyboard. Drag to scroll."
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(scrollHistory(_:))))
        bar = makeAccessoryBar()
        applyTheme(ThemeRuntimeState.currentThemeID())
        NotificationCenter.default.addObserver(self, selector: #selector(fontPreferencesChanged),
                                               name: FontPreferences.didChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Posted on the main thread after a Code Font or Code Text Size change and
    /// when Nerd Font symbols finish installing.
    @objc private func fontPreferencesChanged() {
        painter = SSHTerminalGridPainter.codeFont()
        needsFullPaint = true
        needsPaint = true
        setNeedsLayout()
    }
    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set { _ = newValue } }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set { _ = newValue } }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set { _ = newValue } }
    var smartDashesType: UITextSmartDashesType { get { .no } set { _ = newValue } }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set { _ = newValue } }
    var keyboardType: UIKeyboardType { get { .asciiCapable } set { _ = newValue } }
    override var inputAccessoryView: UIView? { bar }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        if window == nil { keyRepeater.stop() }
        guard window != nil else { return }
        let link = CADisplayLink(target: DisplayTarget(self), selector: #selector(DisplayTarget.tick))
        link.preferredFrameRateRange = .init(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if bounds.size != paintedSize {
            paintedSize = bounds.size
            needsFullPaint = true
            needsPaint = true
        }
        let scale = window?.screen.scale ?? 2
        let geometry = SSHTerminalGeometry(
            columns: min(500, max(1, Int(bounds.width / cellSize.width))),
            rows: min(300, max(1, Int(bounds.height / cellSize.height))),
            cellWidth: Int(cellSize.width * scale), cellHeight: Int(cellSize.height * scale))
        if geometry != lastGeometry {
            lastGeometry = geometry
            channel.resize(geometry)
            needsPaint = true
        }
    }

    /// Called on every SwiftUI update; only a different theme changes colors.
    /// The new default background then repaints the whole grid.
    func applyTheme(_ themeID: ThemeID) {
        guard themeID != appliedTheme else { return }
        appliedTheme = themeID
        let theme = themeID.appTheme
        foreground = UIColor(theme.text.primary)
        let background = UIColor(theme.bg.primary)
        backgroundColor = background
        bar?.backgroundColor = background
        bar?.tintColor = foreground
        channel.engine.setColors(foreground: foreground.terminalRGB, background: background.terminalRGB,
                                 dark: themeID.preferredColorScheme != .light)
        needsPaint = true
    }

    /// Paints the invalidated rows of the last planned frame; UIKit keeps the
    /// layer's other pixels. A system redraw (first display, purged backing
    /// store) asks for more than was invalidated and gets every row in `rect`.
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let frame = shown ?? channel.engine.frame()
        shown = frame
        let height = cellSize.height
        let gridBottom = CGFloat(frame.rows.count) * height
        let first = max(0, Int(rect.minY / height))
        let last = min(frame.rows.count, Int(ceil(rect.maxY / height)))
        var rows = IndexSet(integersIn: first..<max(first, last))
        if let low = invalidRows.first, let high = invalidRows.last,
           rect.minY >= CGFloat(low) * height - 0.5, min(rect.maxY, gridBottom) <= CGFloat(high + 1) * height + 0.5 {
            rows.formIntersection(invalidRows)
        }
        invalidRows.removeAll()
        let background = UIColor(frame.background)
        background.setFill()
        if rect.maxY > gridBottom {
            context.fill(CGRect(x: rect.minX, y: max(rect.minY, gridBottom), width: rect.width, height: rect.maxY - max(rect.minY, gridBottom)))
        }
        guard !rows.isEmpty else { return }
        let started = CACurrentMediaTime()
        for range in rows.rangeView {
            background.setFill()
            context.fill(CGRect(x: 0, y: CGFloat(range.lowerBound) * height, width: bounds.width, height: CGFloat(range.count) * height))
            painter.paint(frame, rows: range, cursorColor: foreground.withAlphaComponent(0.65), in: context)
        }
        let perRow = (CACurrentMediaTime() - started) / Double(rows.count)
        secondsPerRow = secondsPerRow * 0.7 + perRow * 0.3
    }

    /// One display-link tick: read the frame, note the rows that changed, and
    /// invalidate as many as the paint budget allows.
    func repaintChangedRows() {
        let next = channel.engine.frame()
        repaints.add(needsFullPaint ? nil : SSHTerminalPaintPlan.changedRows(from: shown, to: next), rowCount: next.rows.count)
        needsFullPaint = false
        shown = next
        let take = repaints.take(secondsPerRow: secondsPerRow, budget: Self.paintBudget)
        invalidRows.formUnion(take.rows)
        for rect in SSHTerminalPaintPlan.invalidationRects(rows: take.rows, margin: take.margin, rowCount: next.rows.count,
                                                            cellHeight: cellSize.height, bounds: bounds.size) {
            setNeedsDisplay(rect)
        }
    }

    func insertText(_ text: String) {
        guard hardwarePresses.isEmpty else { return }
        for character in text {
            let text = String(character)
            let key = Self.logicalKey(text)
            channel.key(key, text: key == GHOSTTY_KEY_ENTER || key == GHOSTTY_KEY_TAB ? "" : text)
        }
        showModifiers()
    }

    func deleteBackward() {
        guard hardwarePresses.isEmpty else { return }
        accessoryKey(GHOSTTY_KEY_BACKSPACE)
    }
    private func accessoryKey(_ key: GhosttyKey) {
        channel.key(key)
        showModifiers()
    }
    func showModifiers() {
        for entry in modifierButtons {
            let armed = channel.modifierLatch.isArmed(entry.modifier)
            entry.button.setTitle(entry.label, for: .normal)
            entry.button.isSelected = armed
            entry.button.backgroundColor = armed ? tintColor.withAlphaComponent(0.2) : .clear
            entry.button.accessibilityValue = armed ? "On" : "Off"
        }
    }
    /// Direct typing owns a tap while the keyboard is down, including after
    /// switching off the chat bar, so it can come back even when the app asked
    /// for mouse reports. While that keyboard is up, the same app keeps the
    /// tap as a click and the keyboard stays. Chat mode still clicks, and
    /// otherwise focuses the chat bar.
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let otherFocused = window.map { Self.hasFirstResponder(in: $0) } ?? false
        switch SSHTerminalTapAction.resolve(
            terminalTyping: tapTypesInTerminal,
            keyboardUp: isFirstResponder,
            otherInputFocused: otherFocused,
            appWantsClicks: channel.connected && channel.engine.mouseTracking
        ) {
        case .hideKeyboard:
            _ = resignFirstResponder()
        case .typeInTerminal:
            _ = becomeFirstResponder()
        case .dismissOtherInput:
            window?.endEditing(true)
        case .mouseClick:
            let cell = self.cell(at: gesture.location(in: self))
            channel.mouse(.click, column: cell.column, row: cell.row)
        case .focusChatBar:
            focusComposer()
        }
    }

    private static func hasFirstResponder(in view: UIView) -> Bool {
        view.isFirstResponder || view.subviews.contains { hasFirstResponder(in: $0) }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        // Deferred: this can run inside a SwiftUI update (updateUIView).
        if became { Task { @MainActor [rawKeyboardChanged] in rawKeyboardChanged(true) } }
        return became
    }

    private func cell(at point: CGPoint) -> (column: Int, row: Int) {
        (Int(point.x / cellSize.width), Int(point.y / cellSize.height))
    }
    override func paste(_ sender: Any?) {
        guard hardwarePresses.isEmpty else { return }
        requestPaste()
    }
    override func resignFirstResponder() -> Bool {
        hardwarePresses.removeAll()
        keyRepeater.stop()
        arrowButtons.forEach { $0.stopRepeating() }
        let resigned = super.resignFirstResponder()
        if resigned { Task { @MainActor [rawKeyboardChanged] in rawKeyboardChanged(false) } }
        return resigned
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { unhandled.insert(press); continue }
            hardwarePresses.insert(press)
            // Modifier keys alone (HID 0xE0...0xE7) send nothing and must not
            // spend the one-shot modifiers.
            if (0xE0...0xE7).contains(key.keyCode.rawValue) { continue }
            if key.modifierFlags.contains(.command), key.charactersIgnoringModifiers.lowercased() == "v" {
                requestPaste()
                continue
            }
            let physical = Self.physicalKey(key.keyCode) ?? Self.logicalKey(key.charactersIgnoringModifiers)
            var mods: GhosttyMods = 0
            if key.modifierFlags.contains(.control) { mods |= GhosttyMods(GHOSTTY_MODS_CTRL) }
            if key.modifierFlags.contains(.alternate) { mods |= GhosttyMods(GHOSTTY_MODS_ALT) }
            if key.modifierFlags.contains(.shift) { mods |= GhosttyMods(GHOSTTY_MODS_SHIFT) }
            if key.modifierFlags.contains(.command) { mods |= GhosttyMods(GHOSTTY_MODS_SUPER) }
            let text = key.characters.unicodeScalars.contains { $0.value < 32 || $0.value == 127 || (0xf700...0xf8ff).contains($0.value) }
                ? "" : key.characters
            // Snapshot for repeats, but only key() may consume the latch.
            let repeatMods = mods | channel.modifierLatch.modifiers
            let accepted = channel.key(physical, text: text, modifiers: mods)
            showModifiers()
            guard accepted else { continue }
            // The held key repeats with the modifiers it was pressed with
            // (including a spent one-shot Ctrl); DECCKM is read at each encode.
            repeatingPress = press
            keyRepeater.start { [weak self] in
                guard let self, self.channel.connected else { return false }
                let accepted = self.channel.key(physical, text: text, modifiers: repeatMods)
                self.showModifiers()
                return accepted
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    private func stopRepeating(_ presses: Set<UIPress>) {
        hardwarePresses.subtract(presses)
        if let repeatingPress, presses.contains(repeatingPress) {
            keyRepeater.stop()
            self.repeatingPress = nil
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopRepeating(presses)
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopRepeating(presses)
        super.pressesCancelled(presses, with: event)
    }

    @objc private func scrollHistory(_ gesture: UIPanGestureRecognizer) {
        let travel = gesture.translation(in: self).y
        gesture.setTranslation(.zero, in: self)
        if gesture.state == .began {
            scrollRemainder = 0
        }
        // History or wheel steps only. The navigation bar resizes the remote
        // terminal, so Hide Bar and the top handle are the only switches.
        // A mouse-reporting app owns its own history (Herdr panes, pi, less):
        // send wheel notches where the finger is instead of moving the local
        // viewport, which an alternate-screen app never fills.
        if channel.engine.mouseTracking {
            scrollRemainder -= travel
            let rows = Int(scrollRemainder / cellSize.height)
            guard rows != 0 else { return }
            scrollRemainder -= CGFloat(rows) * cellSize.height
            let cell = self.cell(at: gesture.location(in: self))
            for _ in 0..<abs(rows) {
                channel.mouse(rows < 0 ? .wheelUp : .wheelDown, column: cell.column, row: cell.row)
            }
            return
        }
        if gesture.state == .began {
            channel.engine.scroll(rows: 0)
            followChanged(false)
        }
        scrollRemainder -= travel
        let rows = Int(scrollRemainder / cellSize.height)
        if rows != 0 {
            scrollRemainder -= CGFloat(rows) * cellSize.height
            channel.engine.scroll(rows: rows)
        }
        needsPaint = true
    }

    func setKeyActions(_ actions: [SSHTerminalKeyAction]) {
        guard actions != keyActions, let barKeys,
              let paste = barKeys.arrangedSubviews.first(where: { $0.accessibilityIdentifier == "sshTerminal.paste" }),
              let anchor = barKeys.arrangedSubviews.firstIndex(of: paste) else { return }
        keyActions = actions
        keyActionButtons.forEach { $0.removeFromSuperview() }
        keyActionButtons = actions.enumerated().map { offset, action in
            let button = Self.barButton(action.title, id: "sshTerminal.action.\(action.id)") { [weak self] in
                self?.channel.keys(action.strokes)
            }
            // Words, unlike the one-glyph keys, need room to read apart.
            var configuration = UIButton.Configuration.plain()
            configuration.title = action.title
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
                return attributes
            }
            button.configuration = configuration
            button.accessibilityHint = "Sends \(action.keyLabel)"
            barKeys.insertArrangedSubview(button, at: anchor + 1 + offset)
            return button
        }
    }

    private func makeAccessoryBar() -> UIView {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 48))
        scroll.autoresizingMask = [.flexibleWidth]
        scroll.showsHorizontalScrollIndicator = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        barKeys = stack
        func button(_ label: String, id: String, action: @escaping () -> Void) -> UIButton {
            let button = Self.barButton(label, id: "sshTerminal.\(id)", action: action)
            stack.addArrangedSubview(button)
            return button
        }
        for fixed in SSHTerminalKeymap.fixed {
            if let modifier = fixed.modifier {
                let modifierButton = button(fixed.label, id: fixed.id) { [weak self] in
                    guard let self else { return }
                    self.channel.modifierLatch.toggle(modifier)
                    self.showModifiers()
                }
                modifierButton.accessibilityLabel = "\(fixed.label) modifier"
                modifierButtons.append((modifierButton, modifier, fixed.label))
            } else if let stroke = fixed.stroke {
                if SSHTerminalArrowRepeat.isArrow(stroke.key) {
                    let arrow = SSHTerminalArrowButton(label: fixed.label, key: stroke.key,
                                                      id: "sshTerminal.\(fixed.id)") { [weak self] key in
                        guard let self, self.isFirstResponder, self.channel.connected,
                              !self.channel.inputClosed else { return false }
                        self.accessoryKey(key)
                        return true
                    }
                    arrow.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
                    stack.addArrangedSubview(arrow)
                    arrowButtons.append(arrow)
                } else {
                    _ = button(fixed.label, id: fixed.id) { [weak self] in self?.accessoryKey(stroke.key) }
                }
            }
        }
        showModifiers()
        _ = button("Paste", id: "paste") { [weak self] in self?.requestPaste() }
        let chat = button("", id: "useChatBar") { [weak self] in
            guard let self else { return }
            self.useChatBar()
            _ = self.resignFirstResponder()
        }
        chat.setImage(UIImage(systemName: "text.bubble"), for: .normal)
        chat.accessibilityLabel = "Use chat bar"
        let hide = button("⌄", id: "hideKeyboard") { [weak self] in self?.resignFirstResponder() }
        hide.accessibilityLabel = "Hide keyboard"
        return scroll
    }

    private static func barButton(_ label: String, id: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(label, for: .normal)
        button.titleLabel?.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        button.accessibilityIdentifier = id
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private static func logicalKey(_ text: String) -> GhosttyKey {
        switch text {
        case "\n", "\r": return GHOSTTY_KEY_ENTER
        case "\t": return GHOSTTY_KEY_TAB
        case " ": return GHOSTTY_KEY_SPACE
        default:
            if let scalar = text.lowercased().unicodeScalars.first, (97...122).contains(scalar.value) {
                return GhosttyKey(rawValue: GHOSTTY_KEY_A.rawValue + Int32(scalar.value) - 97)
            }
            return GHOSTTY_KEY_UNIDENTIFIED
        }
    }

    private static func physicalKey(_ code: UIKeyboardHIDUsage) -> GhosttyKey? {
        switch code {
        case .keyboardEscape: GHOSTTY_KEY_ESCAPE
        case .keyboardTab: GHOSTTY_KEY_TAB
        case .keyboardReturnOrEnter: GHOSTTY_KEY_ENTER
        case .keyboardDeleteOrBackspace: GHOSTTY_KEY_BACKSPACE
        case .keyboardUpArrow: GHOSTTY_KEY_ARROW_UP
        case .keyboardDownArrow: GHOSTTY_KEY_ARROW_DOWN
        case .keyboardLeftArrow: GHOSTTY_KEY_ARROW_LEFT
        case .keyboardRightArrow: GHOSTTY_KEY_ARROW_RIGHT
        case .keyboardHome: GHOSTTY_KEY_HOME
        case .keyboardEnd: GHOSTTY_KEY_END
        case .keyboardPageUp: GHOSTTY_KEY_PAGE_UP
        case .keyboardPageDown: GHOSTTY_KEY_PAGE_DOWN
        case .keyboardDeleteForward: GHOSTTY_KEY_DELETE
        default: nil
        }
    }

    @MainActor private final class DisplayTarget {
        weak var view: SSHTerminalGridView?
        init(_ view: SSHTerminalGridView) { self.view = view }
        @objc func tick() {
            guard let view else { return }
            // A hold has a one-second deadline even if no more bytes arrive.
            let changes = view.channel.engine.changeCount
            if view.needsPaint || view.paintedChangeCount != changes || view.channel.engine.renderHeld || view.hasPendingPaint {
                view.needsPaint = false
                view.paintedChangeCount = changes
                view.repaintChangedRows()
            }
        }
    }
}

private extension UIColor {
    convenience init(_ rgb: GhosttyColorRgb) {
        self.init(red: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }
    var terminalRGB: GhosttyColorRgb {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return .init(r: UInt8(max(0, min(255, r * 255))), g: UInt8(max(0, min(255, g * 255))), b: UInt8(max(0, min(255, b * 255))))
    }
}
