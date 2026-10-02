import GhosttyVt
import SwiftUI
import UIKit

struct SSHTerminalView: View {
    let channel: SSHTerminalChannel
    let reconnect: () -> Void
    @Environment(\.themeID) private var themeID
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingPaste: String?
    @State private var pasteConfirmation = false
    @State private var pasteFailure: String?
    @State private var detached = false
    @State private var pasteNotice: String?
    @State private var pasteNoticeTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if channel.connecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: channel.connected ? "checkmark.circle" : "xmark.circle")
                }
                Text(channel.connecting || channel.connected ? channel.reason : "Disconnected · \(channel.reason)").lineLimit(3)
                Spacer()
                if (!channel.connected || channel.networkChanged) && !channel.connecting {
                    Button("Reconnect", action: reconnect).accessibilityIdentifier("sshTerminal.reconnect")
                } else if channel.connected {
                    Button("Disconnect") { channel.close(reason: "Closed by you.") }
                        .accessibilityIdentifier("sshTerminal.disconnect")
                }
            }
            .font(.footnote).padding(10).foregroundStyle(.themeFg)
            // Without .contain the identifier replaces the Reconnect and
            // Disconnect buttons' own identifiers.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sshTerminal.status")
            if channel.networkChanged && channel.connected {
                Text("Network changed — this shell may be stale. Reconnect opens a fresh shell.")
                    .font(.footnote).foregroundStyle(.themeOrange)
                    .accessibilityIdentifier("sshTerminal.networkChanged")
            }
            if !channel.inputNotice.isEmpty {
                Text(channel.inputNotice).font(.footnote).foregroundStyle(.themeOrange)
                    .accessibilityIdentifier("sshTerminal.inputNotice")
            }
            if let pasteNotice {
                Text(pasteNotice).font(.footnote).foregroundStyle(.themeOrange)
                    .accessibilityIdentifier("sshTerminal.pasteNotice")
            }
            SSHTerminalSurface(channel: channel, themeID: themeID,
                               paste: requestPaste, followChanged: { detached = !$0 })
                .overlay(alignment: .bottomTrailing) {
                    if detached {
                        Button("Back to Live", systemImage: "arrow.down.to.line") {
                            channel.engine.backToLive()
                            detached = false
                        }.buttonStyle(.borderedProminent).padding(8)
                            .accessibilityIdentifier("sshTerminal.backToLive")
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
        }
        // The terminal paints with the app theme, not the system appearance.
        // Keep the bar's title and back chevron legible against it in both.
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color.themeBg, for: .navigationBar)
        .toolbarColorScheme(themeID.preferredColorScheme, for: .navigationBar)
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
    let paste: () -> Void
    let followChanged: (Bool) -> Void

    func makeUIView(context: Context) -> SSHTerminalGridView {
        SSHTerminalGridView(channel: channel, paste: paste, followChanged: followChanged)
    }

    func updateUIView(_ view: SSHTerminalGridView, context: Context) {
        view.applyTheme(themeID)
        view.needsPaint = true
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
    var paintedChangeCount = -1
    private let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var cellSize = CGSize(width: 8, height: 17)
    private var lastGeometry: SSHTerminalGeometry?
    private var ctrl = SSHTerminalCtrlLatch()
    private var ctrlButton: UIButton?
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
        accessibilityLabel = "SSH terminal. Tap to show or hide the keyboard. Drag to read local history."
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleKeyboard)))
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
            channel.key(key, text: key == GHOSTTY_KEY_ENTER || key == GHOSTTY_KEY_TAB ? "" : text,
                        modifiers: takeCtrl())
        }
    }

    func deleteBackward() {
        guard hardwarePresses.isEmpty else { return }
        accessoryKey(GHOSTTY_KEY_BACKSPACE)
    }
    private func accessoryKey(_ key: GhosttyKey) {
        channel.key(key, modifiers: takeCtrl())
    }
    /// Ctrl applies to the next key only, then shows as off.
    private func takeCtrl() -> GhosttyMods {
        let mods = ctrl.take()
        showCtrl()
        return mods
    }
    private func showCtrl() {
        ctrlButton?.setTitle(ctrl.armed ? "Ctrl \u{2713}" : "Ctrl", for: .normal)
        ctrlButton?.accessibilityValue = ctrl.armed ? "On" : "Off"
    }
    @objc private func toggleKeyboard() {
        if isFirstResponder { _ = resignFirstResponder() } else { becomeFirstResponder() }
    }
    override func paste(_ sender: Any?) {
        guard hardwarePresses.isEmpty else { return }
        requestPaste()
    }
    override func resignFirstResponder() -> Bool {
        hardwarePresses.removeAll()
        keyRepeater.stop()
        return super.resignFirstResponder()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { unhandled.insert(press); continue }
            hardwarePresses.insert(press)
            // Modifier keys alone (HID 0xE0...0xE7) send nothing and must not
            // spend the one-shot Ctrl.
            if (0xE0...0xE7).contains(key.keyCode.rawValue) { continue }
            if key.modifierFlags.contains(.command), key.charactersIgnoringModifiers.lowercased() == "v" {
                requestPaste()
                continue
            }
            let physical = Self.physicalKey(key.keyCode) ?? Self.logicalKey(key.charactersIgnoringModifiers)
            var mods = takeCtrl()
            if key.modifierFlags.contains(.control) { mods |= GhosttyMods(GHOSTTY_MODS_CTRL) }
            if key.modifierFlags.contains(.alternate) { mods |= GhosttyMods(GHOSTTY_MODS_ALT) }
            if key.modifierFlags.contains(.shift) { mods |= GhosttyMods(GHOSTTY_MODS_SHIFT) }
            if key.modifierFlags.contains(.command) { mods |= GhosttyMods(GHOSTTY_MODS_SUPER) }
            let text = key.characters.unicodeScalars.contains { $0.value < 32 || $0.value == 127 || (0xf700...0xf8ff).contains($0.value) }
                ? "" : key.characters
            channel.key(physical, text: text, modifiers: mods)
            // The held key repeats with the modifiers it was pressed with
            // (including a spent one-shot Ctrl); DECCKM is read at each encode.
            repeatingPress = press
            keyRepeater.start { [weak self] in
                guard let self, self.channel.connected else { return false }
                self.channel.key(physical, text: text, modifiers: mods)
                return true
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
        if gesture.state == .began {
            scrollRemainder = 0
            channel.engine.scroll(rows: 0)
            followChanged(false)
        }
        scrollRemainder -= gesture.translation(in: self).y
        gesture.setTranslation(.zero, in: self)
        let rows = Int(scrollRemainder / cellSize.height)
        if rows != 0 {
            scrollRemainder -= CGFloat(rows) * cellSize.height
            channel.engine.scroll(rows: rows)
        }
        needsPaint = true
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
        func button(_ label: String, id: String, action: @escaping () -> Void) -> UIButton {
            let button = UIButton(type: .system)
            button.setTitle(label, for: .normal)
            button.titleLabel?.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
            button.accessibilityIdentifier = "sshTerminal.\(id)"
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
            stack.addArrangedSubview(button)
            return button
        }
        _ = button("Esc", id: "escape") { [weak self] in self?.accessoryKey(GHOSTTY_KEY_ESCAPE) }
        _ = button("Tab", id: "tab") { [weak self] in self?.accessoryKey(GHOSTTY_KEY_TAB) }
        ctrlButton = button("Ctrl", id: "control") { [weak self] in
            guard let self else { return }
            self.ctrl.toggle()
            self.showCtrl()
        }
        ctrlButton?.accessibilityLabel = "Control modifier"
        ctrlButton?.accessibilityValue = "Off"
        for (label, key, id) in [("←", GHOSTTY_KEY_ARROW_LEFT, "left"), ("↓", GHOSTTY_KEY_ARROW_DOWN, "down"),
                                 ("↑", GHOSTTY_KEY_ARROW_UP, "up"), ("→", GHOSTTY_KEY_ARROW_RIGHT, "right")] {
            let arrow = button(label, id: id) { [weak self] in self?.accessoryKey(key) }
            arrow.accessibilityLabel = "Move cursor \(id)"
        }
        _ = button("Paste", id: "paste") { [weak self] in self?.requestPaste() }
        let hide = button("⌄", id: "hideKeyboard") { [weak self] in self?.resignFirstResponder() }
        hide.accessibilityLabel = "Hide keyboard"
        return scroll
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
