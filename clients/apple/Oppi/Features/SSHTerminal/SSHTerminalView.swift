import GhosttyVt
import SwiftUI
import UIKit

struct SSHTerminalView: View {
    let channel: SSHTerminalChannel
    let reconnect: () -> Void
    let editHost: () -> Void
    @Environment(\.themeID) private var themeID
    @Environment(\.scenePhase) private var scenePhase
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
                               useChatBar: {
                                   if detectedMode != .chat { modeOverride = .chat }
                                   focusComposerAfterRaw = true
                               },
                               topBarHiddenChanged: { hidden in
                                   guard hidden != topBarHidden else { return }
                                   withAnimation(.easeInOut(duration: 0.2)) { topBarHidden = hidden }
                               })
                .overlay(alignment: .bottomTrailing) {
                    if detached {
                        Button("Back to Live", systemImage: "arrow.down.to.line") {
                            channel.engine.backToLive()
                            detached = false
                        }.buttonStyle(.borderedProminent).padding(8)
                            .accessibilityIdentifier("sshTerminal.backToLive")
                    }
                }
            // An agent gets the chat bar; a shell gets direct typing. Raw typing
            // has its own key bar above the keyboard; the chat bar returns when
            // that keyboard goes down.
            if inputMode == .chat && !rawKeyboard {
                SSHTerminalComposer(channel: channel, focusRequest: composerFocusRequest, keyActions: keymap.actions) {
                    keyboardRequest += 1
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
                        Button("Type in Terminal", systemImage: "keyboard") { modeOverride = .terminal }
                            .accessibilityIdentifier("sshTerminal.useTerminalInput")
                    } else {
                        Button("Use Chat Bar", systemImage: "text.bubble") { modeOverride = .chat }
                            .accessibilityIdentifier("sshTerminal.useChatBar")
                    }
                    Button("Edit Host", systemImage: "pencil", action: editHost)
                    if channel.connected {
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
        // Dragging toward newer output hides the bar for more rows; dragging
        // back brings it. A broken connection always shows it.
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
                do { try channel.paste(text, confirmed: true) }
                catch { pasteFailure = "Paste was not sent. \(error.localizedDescription)" }
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
            do { try channel.paste(text) }
            catch { pasteFailure = "Paste was not sent. \(error.localizedDescription)" }
        }
    }
}

private struct SSHTerminalSurface: UIViewRepresentable {
    let channel: SSHTerminalChannel
    let themeID: ThemeID
    /// Bumped by the composer's keyboard button: raw typing into the grid. In
    /// a mouse-reporting app a tap clicks, so this cannot be a tap.
    let keyboardRequest: Int
    /// Bumped to put the raw keyboard down.
    let resignRequest: Int
    /// Shell input: a tap opens the raw keyboard instead of the chat bar.
    let tapTypesInTerminal: Bool
    let keyActions: [SSHTerminalKeyAction]
    let paste: () -> Void
    let followChanged: (Bool) -> Void
    let rawKeyboardChanged: (Bool) -> Void
    let focusComposer: () -> Void
    let useChatBar: () -> Void
    let topBarHiddenChanged: (Bool) -> Void

    func makeUIView(context: Context) -> SSHTerminalGridView {
        let view = SSHTerminalGridView(channel: channel, paste: paste, followChanged: followChanged)
        view.rawKeyboardChanged = rawKeyboardChanged
        view.focusComposer = focusComposer
        view.useChatBar = useChatBar
        view.topBarHiddenChanged = topBarHiddenChanged
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
    var topBarHiddenChanged: (Bool) -> Void = { _ in }
    /// Finger travel in one direction since the last top-bar decision.
    private var barTravel: CGFloat = 0
    var paintedChangeCount = -1
    private let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var cellSize = CGSize(width: 8, height: 17)
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
        cellSize = CGSize(width: ceil(("M" as NSString).size(withAttributes: [.font: font]).width),
                          height: ceil(font.lineHeight))
        isOpaque = true
        clipsToBounds = true
        accessibilityIdentifier = "sshTerminal.grid"
        accessibilityLabel = "SSH terminal. Tap to type or to hide the keyboard. Drag to scroll."
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(scrollHistory(_:))))
        bar = makeAccessoryBar()
        applyTheme(ThemeRuntimeState.currentThemeID())
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }
    var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }
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

    func applyTheme(_ themeID: ThemeID) {
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

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let frame = channel.engine.frame()
        UIColor(frame.background).setFill()
        context.fill(bounds)
        for (y, row) in frame.rows.enumerated() {
            for (x, cell) in row.enumerated() {
                // The head painted both cells. A wide tail must not erase it.
                guard cell.width > 0 else { continue }
                let style = cell.style
                let fg = UIColor(style.inverse ? cell.background : cell.foreground)
                let bg = UIColor(style.inverse ? cell.foreground : cell.background)
                let origin = CGPoint(x: CGFloat(x) * cellSize.width, y: CGFloat(y) * cellSize.height)
                let area = CGRect(origin: origin, size: CGSize(width: cellSize.width * CGFloat(max(1, cell.width)), height: cellSize.height))
                bg.setFill()
                context.fill(area)
                guard !style.invisible else { continue }
                var traits: UIFontDescriptor.SymbolicTraits = []
                if style.bold { traits.insert(.traitBold) }
                if style.italic { traits.insert(.traitItalic) }
                let face = font.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
                var attributes: [NSAttributedString.Key: Any] = [.font: face, .foregroundColor: style.faint ? fg.withAlphaComponent(0.5) : fg]
                if style.underline != 0 { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                context.saveGState()
                context.clip(to: area)
                (cell.text as NSString).draw(at: origin, withAttributes: attributes)
                context.restoreGState()
            }
        }
        if frame.cursor.visible, frame.cursor.viewport_has_value {
            var area = CGRect(x: CGFloat(frame.cursor.viewport_x) * cellSize.width,
                              y: CGFloat(frame.cursor.viewport_y) * cellSize.height,
                              width: cellSize.width, height: cellSize.height)
            foreground.withAlphaComponent(0.65).setStroke()
            if frame.cursor.visual_style == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR { area.size.width = 2 }
            if frame.cursor.visual_style == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE {
                area.origin.y += cellSize.height - 2
                area.size.height = 2
            }
            context.stroke(area.insetBy(dx: 0.5, dy: 0.5))
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
    /// A tap first dismisses whichever keyboard is up (raw or composer). With
    /// it down, a tap is a click for an app that asked for mouse reports
    /// (Herdr tabs, panes and agents) and otherwise starts typing: in the
    /// terminal for a shell, in the chat bar for an agent.
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        if isFirstResponder {
            _ = resignFirstResponder()
        } else if let window, Self.hasFirstResponder(in: window) {
            window.endEditing(true)
        } else if channel.connected, channel.engine.mouseTracking {
            let cell = self.cell(at: gesture.location(in: self))
            channel.mouse(.click, column: cell.column, row: cell.row)
        } else if tapTypesInTerminal {
            _ = becomeFirstResponder()
        } else {
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
            barTravel = 0
        }
        trackTopBar(travel)
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

    /// Finger up (toward newer output) hides the top bar; finger down shows it.
    private func trackTopBar(_ travel: CGFloat) {
        guard travel != 0 else { return }
        if (travel < 0) != (barTravel < 0) { barTravel = 0 }
        barTravel += travel
        guard abs(barTravel) >= 24 else { return }
        topBarHiddenChanged(barTravel < 0)
        barTravel = 0
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
            if view.needsPaint || view.paintedChangeCount != changes || view.channel.engine.renderHeld {
                view.needsPaint = false
                view.paintedChangeCount = changes
                view.setNeedsDisplay()
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
