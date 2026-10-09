import GhosttyVt
import SwiftUI
import UIKit

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

/// The SwiftUI bridge to the UIKit grid: the screen drives it with request
/// counters and hears back through callbacks.
struct SSHTerminalSurface: UIViewRepresentable {
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
final class SSHTerminalGridView: UIView, UIKeyInput {
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
        setNeedsLayout()
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
        // Zero until the view has a window; a zero scale would size the PTY and
        // the grid at zero pixels. didMoveToWindow queues another layout pass.
        let scale = traitCollection.displayScale
        guard scale > 0 else { return }
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
