import GhosttyVt
import QuartzCore
import UIKit
import UniformTypeIdentifiers

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

/// When the grid display link runs, and whether it may request 120 Hz.
struct SSHTerminalDisplayLinkPolicy: Equatable {
    var running: Bool
    var highFrameRate: Bool

    static let normalRate = CAFrameRateRange(minimum: 15, maximum: 60, preferred: 60)
    static let scrollingRate = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)

    static func resolve(
        hasWindow: Bool,
        sceneActive: Bool,
        needsFullPaint: Bool,
        pictureChanged: Bool,
        renderHeld: Bool,
        scrolling: Bool
    ) -> Self {
        guard hasWindow, sceneActive else {
            return .init(running: false, highFrameRate: false)
        }
        let work = needsFullPaint || pictureChanged || renderHeld || scrolling
        return .init(running: work, highFrameRate: scrolling)
    }
}

/// Mounted work is only the viewport grid, not one UITextView for scrollback.
/// libghostty owns history/reflow/alternate screen; UIKit paints copied cells
/// at fixed positions and supplies UITextInput and physical-key events.
/// Software ⌫ auto-repeats only for UITextInput; UIKeyInput fires once.
final class SSHTerminalGridView: UIView, UITextInput, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let channel: SSHTerminalChannel
    let requestPaste: (String?) -> Void
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
    private var metrics = SSHTerminalCellMetrics.codeFont()
    private var cellSize: CGSize { metrics.cellSize }
    private var renderer: SSHTerminalMetalRenderer?
    /// Theme, font, or bounds changed: encode the whole grid even if libghostty
    /// reported no dirty rows.
    private var needsFullPaint = true
    private var paintedSize = CGSize.zero
    private var sceneActive = true
    private var appliedTheme: ThemeID?
    private var lastGeometry: SSHTerminalGeometry?
    private var keyStrip: SSHTerminalKeyStripView?
    /// A hardware key is sent from pressesBegan only. While one is down,
    /// insertText/deleteBackward and the edit-menu paste are echoes of the
    /// same press and must not send again. Ended or cancelled presses are
    /// ignored so a stale UIPress cannot swallow software ⌫ repeats.
    private var hardwarePresses = Set<UIPress>()
    /// Dummy document the software keyboard deletes from; never echoed.
    var textInputStorage = SSHTerminalTextInputStorage()
    weak var inputDelegate: UITextInputDelegate?
    var markedTextStyle: [NSAttributedString.Key: Any]?
    lazy var textInputTokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)
    var ignoresSoftwareKeyEcho: Bool {
        hardwarePresses.contains { $0.phase != .ended && $0.phase != .cancelled }
    }
    /// UIKit does not repeat pressesBegan for a held key, so repeats are ours.
    private let keyRepeater = SSHTerminalKeyRepeater()
    private var repeatingPress: UIPress?
    private var appScroll = SSHTerminalAppScrollAccumulator()
    private var appliedScrollAction = SSHTerminalScrollAction.history
    private var displayLink: CADisplayLink?
    private var displayLinkGeneration: UInt64 = 0
    private(set) var displayLinkTickCount: UInt64 = 0
    var isDisplayLinkRunning: Bool { displayLink.map { !$0.isPaused } ?? false }
    private let metalHost = SSHTerminalMetalHostView()
    private let historyScroll = SSHTerminalHistoryScrollView()
    private let selectionOverlay = SSHTerminalSelectionOverlay()

    private var longPress: UILongPressGestureRecognizer?
    private var tapRecognizer: UITapGestureRecognizer?
    private var tapIgnore = SSHTerminalTapIgnore()
    private var tapSequence = SSHTerminalTapSequence()
    private var pendingHide: Task<Void, Never>?
    private var dragTarget: SSHTerminalDragTarget?
    private var dragSnapshot: SSHTerminalSelectionSnapshot?
    private var highlightClear: Task<Void, Never>?
    private var highlightGeneration = 0
    private var isSyncingHistoryScroll = false
    private var lastFollow = true
    private var bar: UIView?
    /// The foreground program's actions, inserted after Paste.
    private var keyActions: [SSHTerminalKeyAction] = []
    private var foreground = UIColor.label

    private var metalLayer: CAMetalLayer? { metalHost.metalLayer }

    init(channel: SSHTerminalChannel, paste: @escaping (String?) -> Void, followChanged: @escaping (Bool) -> Void) {
        self.channel = channel
        requestPaste = paste
        self.followChanged = followChanged
        super.init(frame: .zero)
        SSHTerminalMetalPipeline.prewarm()
        isOpaque = true
        clipsToBounds = true
        metalHost.isUserInteractionEnabled = false
        selectionOverlay.isUserInteractionEnabled = false
        addSubview(metalHost)
        addSubview(selectionOverlay)
        configureHistoryScroll()
        addSubview(historyScroll)
        // The bar's UIPasteControl delivers to paste(itemProviders:). A
        // programmatic UIPasteboard read from a plain button shows iOS's
        // Allow Paste alert and blocks the main thread until it is answered.
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.plainText.identifier])
        accessibilityIdentifier = "sshTerminal.grid"
        accessibilityLabel = "SSH terminal. Tap to type or hide the keyboard. Double-tap a word to copy it. Drag to scroll. Touch and hold, then drag, to select."
        installGestures()
        bar = makeAccessoryBar()
        applyTheme(ThemeRuntimeState.currentThemeID())
        channel.engine.onPictureChange = { [weak self] in
            guard let self else { return }
            self.needsPaint = true
            self.requestDisplayLink()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(fontPreferencesChanged),
                                               name: FontPreferences.didChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Posted on the main thread after a Code Font or Code Text Size change and
    /// when Nerd Font symbols finish installing.
    @objc private func fontPreferencesChanged() {
        metrics = SSHTerminalCellMetrics.codeFont()
        renderer?.setMetrics(metrics, scale: max(traitCollection.displayScale, 1))
        needsFullPaint = true
        needsPaint = true
        requestDisplayLink()
        setNeedsLayout()
    }
    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set { _ = newValue } }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set { _ = newValue } }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set { _ = newValue } }
    var smartDashesType: UITextSmartDashesType { get { .no } set { _ = newValue } }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set { _ = newValue } }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set { _ = newValue } }
    var inlinePredictionType: UITextInlinePredictionType { get { .no } set { _ = newValue } }
    var textContentType: UITextContentType? { get { nil } set { _ = newValue } }
    /// Writing Tools rewrites through `replace`, which would type its result.
    var writingToolsBehavior: UIWritingToolsBehavior { get { .none } set { _ = newValue } }
    var keyboardType: UIKeyboardType { get { .asciiCapable } set { _ = newValue } }
    override var inputAccessoryView: UIView? { bar }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        stopDisplayLink()
        if window == nil {
            keyRepeater.stop()
            NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
            return
        }
        setNeedsLayout()
        sceneActive = window?.windowScene?.activationState == .foregroundActive
        needsPaint = true
        needsFullPaint = true
        requestDisplayLink()
        let center = NotificationCenter.default
        center.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
        center.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneBecameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneResignedActive), name: UIApplication.willResignActiveNotification, object: nil)
    }

    @objc private func sceneBecameActive() {
        sceneActive = true
        needsPaint = true
        needsFullPaint = true
        requestDisplayLink()
    }

    @objc private func sceneResignedActive() {
        sceneActive = false
        stopDisplayLink()
    }

    func requestDisplayLink() {
        displayLinkGeneration &+= 1
        startDisplayLinkIfNeeded()
        displayLink?.isPaused = false
        publishDisplayLinkDebug()
    }

    private func startDisplayLinkIfNeeded() {
        guard window != nil, sceneActive else { return }
        if let displayLink {
            displayLink.isPaused = false
            return
        }
        let link = CADisplayLink(target: DisplayTarget(self), selector: #selector(DisplayTarget.tick))
        link.preferredFrameRateRange = SSHTerminalDisplayLinkPolicy.normalRate
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func pauseDisplayLink() {
        displayLink?.isPaused = true
        publishDisplayLinkDebug()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        publishDisplayLinkDebug()
    }

    private var isHistoryScrolling: Bool {
        historyScroll.isTracking || historyScroll.isDragging || historyScroll.isDecelerating
    }

    private func applyFrameRate(scrolling: Bool) {
        let desired = scrolling
            ? SSHTerminalDisplayLinkPolicy.scrollingRate
            : SSHTerminalDisplayLinkPolicy.normalRate
        displayLink?.preferredFrameRateRange = desired
    }

    private func publishDisplayLinkDebug() {
        #if DEBUG
        accessibilityValue = isDisplayLinkRunning
            ? "display-link running ticks \(displayLinkTickCount)"
            : "display-link stopped ticks \(displayLinkTickCount)"
        #endif
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        metalHost.frame = bounds
        selectionOverlay.frame = bounds
        historyScroll.frame = bounds
        if bounds.size != paintedSize {
            paintedSize = bounds.size
            needsFullPaint = true
            needsPaint = true
            requestDisplayLink()
        }
        // Zero until the view has a window; a zero scale would size the PTY and
        // the grid at zero pixels. didMoveToWindow queues another layout pass.
        let scale = traitCollection.displayScale
        guard scale > 0 else { return }
        if let metalLayer {
            metalLayer.contentsScale = scale
            let drawable = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            if metalLayer.drawableSize != drawable {
                metalLayer.drawableSize = drawable
                needsFullPaint = true
                needsPaint = true
                requestDisplayLink()
            }
        }
        renderer?.setMetrics(metrics, scale: scale)
        let geometry = SSHTerminalGeometry(
            columns: min(500, max(1, Int(bounds.width / cellSize.width))),
            rows: min(300, max(1, Int(bounds.height / cellSize.height))),
            cellWidth: Int(cellSize.width * scale), cellHeight: Int(cellSize.height * scale))
        if geometry != lastGeometry {
            lastGeometry = geometry
            channel.resize(geometry)
            needsPaint = true
        }
        syncHistoryScrollFromEngine()
        updateTouchMode()
    }

    /// Only a different theme changes colors.
    /// The new default background then repaints the whole grid.
    func applyTheme(_ themeID: ThemeID) {
        guard themeID != appliedTheme else { return }
        appliedTheme = themeID
        let theme = themeID.appTheme
        foreground = UIColor(theme.text.primary)
        let background = UIColor(theme.bg.primary)
        backgroundColor = background
        metalHost.backgroundColor = background
        bar?.backgroundColor = .clear
        bar?.tintColor = foreground
        applyKeyStripTheme(background: background)
        channel.engine.setColors(foreground: foreground.terminalRGB, background: background.terminalRGB,
                                 dark: themeID.preferredColorScheme != .light)
        historyScroll.indicatorStyle = themeID.preferredColorScheme == .light ? .black : .white
        needsFullPaint = true
        needsPaint = true
        requestDisplayLink()
    }

    /// One display-link tick: snapshot the engine and encode the complete grid
    /// when it changed. Returns true when the gate can be consumed: a frame
    /// was submitted, the snapshot had nothing new to draw, or encode reported
    /// a deterministic miss. Transient misses (pipeline not ready, ring full,
    /// nil drawable, nil command buffer/encoder) leave `needsPaint` set.
    /// Deterministic misses still set `needsFullPaint` so a later changeCount,
    /// theme, font, or bounds change retries.
    @discardableResult
    func presentIfNeeded() -> Bool {
        guard window != nil, sceneActive, bounds.width > 0, bounds.height > 0 else { return false }
        guard let renderer = rendererIfReady() else { return false }
        if renderer.inFlightCount >= SSHTerminalMetalRenderer.ringSize { return false }
        guard let metalLayer else { return false }
        let frame = channel.engine.frame()
        let shouldDraw = needsFullPaint || !frame.rebuiltRows.isEmpty
        if !shouldDraw { return true }
        metalLayer.device = renderer.device
        let scale = max(traitCollection.displayScale, 1)
        if metalLayer.drawableSize.width < 1 {
            metalLayer.contentsScale = scale
            metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        }
        guard let drawable = metalLayer.nextDrawable() else {
            needsFullPaint = true
            return false
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        foreground.withAlphaComponent(0.65).getRed(&r, green: &g, blue: &b, alpha: &a)
        let cursor = SIMD4<Float>(Float(r), Float(g), Float(b), Float(a))
        let cost = renderer.encode(
            frame: frame, cursorColor: cursor, drawable: drawable, fullRebuild: needsFullPaint
        )
        if cost.submitted {
            needsFullPaint = false
            return true
        }
        needsFullPaint = true
        // Pack/staging cannot succeed on retry with the same grid and metrics.
        // Consume the gate so tick does not re-rasterize at 60 Hz.
        return cost.miss == .deterministic
    }

    private func rendererIfReady() -> SSHTerminalMetalRenderer? {
        if let renderer { return renderer }
        guard let pipeline = SSHTerminalMetalPipeline.peek() else {
            SSHTerminalMetalPipeline.prewarm()
            return nil
        }
        let scale = max(traitCollection.displayScale, 1)
        guard let built = try? SSHTerminalMetalRenderer(pipeline: pipeline, metrics: metrics, scale: scale) else {
            return nil
        }
        metalLayer?.device = built.device
        renderer = built
        return built
    }

    func insertText(_ text: String) {
        applyTextInput(textInputStorage.insertText(text, hardwareKeysDown: ignoresSoftwareKeyEcho))
    }

    func deleteBackward() {
        applyTextInput(textInputStorage.deleteBackward(hardwareKeysDown: ignoresSoftwareKeyEcho))
    }

    func applyTextInput(_ actions: [SSHTerminalTextInputStorage.Action]) {
        guard !actions.isEmpty else { return }
        for action in actions {
            switch action {
            case .insert(let text):
                // Dictation, Writing Tools, and system replacements can hand
                // over a phrase at once. A lone Return is Enter; any other
                // text that could run a command takes the paste confirmation.
                if text != "\n", text != "\r", SSHTerminalEngine.pasteNeedsConfirmation(text) {
                    requestPaste(text)
                    continue
                }
                for character in text {
                    let piece = String(character)
                    let key = Self.logicalKey(piece)
                    channel.key(key, text: key == GHOSTTY_KEY_ENTER || key == GHOSTTY_KEY_TAB ? "" : piece)
                }
            case .backspace:
                channel.key(GHOSTTY_KEY_BACKSPACE)
            }
        }
        showModifiers()
    }
    private func accessoryKey(_ key: GhosttyKey) {
        channel.key(key)
        showModifiers()
    }
    func showModifiers() {
        keyStrip?.showModifiers()
    }
    /// Direct typing owns a tap while the keyboard is down, including after
    /// switching off the chat bar, so it can come back even when the app asked
    /// for mouse reports. While that keyboard is up, the same app keeps the
    /// tap as a click and the keyboard stays. Chat mode still clicks, and
    /// otherwise focuses the chat bar.
    ///
    /// Single tap does not wait for double-tap failure. The ~300 ms delay
    /// would lag keyboard focus and mouse clicks; tap 1 stays immediate. Tap 2
    /// only copies the word captured under the finger at tap 1, before any
    /// first-responder change, and never runs the single-tap action.
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        handleTap(at: gesture.location(in: self), now: CACurrentMediaTime())
    }

    /// Backup when tap 1 hid the keyboard and the second single-tap is lost.
    /// Copies the tap-1 snapshot only; never runs the single-tap action.
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        copyPendingWord()
    }

    func handleTap(at point: CGPoint, now: TimeInterval) {
        if tapIgnore.consumeTap() { return }
        let cell = self.cell(at: point)
        let snapshot = channel.engine.selectWord(column: cell.column, row: cell.row)
        switch tapSequence.recognize(location: point, time: now, snapshot: snapshot) {
        case .firstTap:
            performSingleTap(at: point)
        case .secondTap:
            copyPendingWord()
        }
    }

    private func performSingleTap(at point: CGPoint) {
        let otherFocused = window.map { Self.hasFirstResponder(in: $0) } ?? false
        switch SSHTerminalTapAction.resolve(
            terminalTyping: tapTypesInTerminal,
            keyboardUp: isFirstResponder,
            otherInputFocused: otherFocused,
            appWantsClicks: channel.connected && channel.engine.mouseTracking
        ) {
        case .hideKeyboard:
            // Delay hide so a second tap can still land. Focus and mouse
            // clicks stay immediate.
            scheduleHideKeyboard()
        case .typeInTerminal:
            cancelHideKeyboard()
            _ = becomeFirstResponder()
        case .dismissOtherInput:
            cancelHideKeyboard()
            window?.endEditing(true)
        case .mouseClick:
            cancelHideKeyboard()
            let cell = self.cell(at: point)
            channel.mouse(.click, column: cell.column, row: cell.row)
        case .focusChatBar:
            cancelHideKeyboard()
            focusComposer()
        }
    }

    private func scheduleHideKeyboard() {
        pendingHide?.cancel()
        pendingHide = Task { @MainActor [weak self] in
            let nanos = UInt64(SSHTerminalTapSequence.doubleTapTimeout * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            _ = self.resignFirstResponder()
            self.pendingHide = nil
        }
    }

    private func cancelHideKeyboard() {
        pendingHide?.cancel()
        pendingHide = nil
    }

    private func copyPendingWord() {
        cancelHideKeyboard()
        guard let snapshot = tapSequence.takePendingSnapshot() else { return }
        channel.copyLocalSelection(snapshot.text)
        showHighlight(snapshot, lingering: true)
        needsPaint = true
    }

    func backToLive() {
        channel.engine.backToLive()
        syncHistoryScrollFromEngine()
        needsPaint = true
    }

    private static func hasFirstResponder(in view: UIView) -> Bool {
        view.isFirstResponder || view.subviews.contains { hasFirstResponder(in: $0) }
    }

    override func becomeFirstResponder() -> Bool {
        // Hide shortcut-bar items such as Write with Siri, which insert text.
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        let became = super.becomeFirstResponder()
        // Deferred: this can run inside a layout or observation pass.
        if became { Task { @MainActor [rawKeyboardChanged] in rawKeyboardChanged(true) } }
        return became
    }

    private func cell(at point: CGPoint) -> (column: Int, row: Int) {
        (Int(point.x / cellSize.width), Int(point.y / cellSize.height))
    }
    /// The edit menu's Paste. iOS grants that read without the Allow Paste alert.
    override func paste(_ sender: Any?) {
        guard !ignoresSoftwareKeyEcho else { return }
        requestPaste(UIPasteboard.general.string)
    }

    /// The accessory bar's UIPasteControl. Its tap is the consent, so there is
    /// no alert, and the text loads off the main thread.
    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: String.self) }) else {
            requestPaste(nil)
            return
        }
        _ = provider.loadObject(ofClass: String.self) { [weak self] text, _ in
            Task { @MainActor in self?.requestPaste(text) }
        }
    }
    override func resignFirstResponder() -> Bool {
        hardwarePresses.removeAll()
        textInputStorage.reset()
        keyRepeater.stop()
        keyStrip?.stopRepeating()
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
                requestPaste(UIPasteboard.general.string)
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

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: self)
        let cell = self.cell(at: location)
        let scale = max(traitCollection.displayScale, 1)
        let surface = CGPoint(x: location.x * scale, y: location.y * scale)
        switch gesture.state {
        case .began:
            tapIgnore.arm()
            tapSequence.reset()
            cancelHideKeyboard()
            historyScroll.isScrollEnabled = false
            let target = SSHTerminalDragTarget.resolve(mouseReporting: channel.engine.mouseTracking)
            dragTarget = target
            dragSnapshot = nil
            switch target {
            case .mouse:
                channel.mouse(.press, column: cell.column, row: cell.row)
            case .selection:
                channel.engine.beginSelection(column: cell.column, row: cell.row, surfacePoint: surface)
            }
        case .changed:
            switch dragTarget {
            case .mouse:
                channel.mouse(.motion, column: cell.column, row: cell.row)
            case .selection:
                if let snapshot = channel.engine.dragSelection(
                    column: cell.column, row: cell.row, surfacePoint: surface
                ) {
                    dragSnapshot = snapshot
                    showHighlight(snapshot, lingering: false)
                }
            case nil:
                break
            }
        case .ended, .cancelled, .failed:
            let target = dragTarget
            dragTarget = nil
            switch target {
            case .mouse:
                channel.mouse(.release, column: cell.column, row: cell.row)
            case .selection:
                channel.engine.endSelection(column: cell.column, row: cell.row)
                if gesture.state == .ended, let snapshot = dragSnapshot {
                    channel.copyLocalSelection(snapshot.text)
                    showHighlight(snapshot, lingering: true)
                } else {
                    clearHighlight()
                    channel.engine.cancelSelection()
                }
            case nil:
                break
            }
            dragSnapshot = nil
            let tapFailed = tapRecognizer?.state == .failed || tapRecognizer?.state == .cancelled
            tapIgnore.longPressEnded(tapFailed: tapFailed)
            updateTouchMode()
        default:
            break
        }
        needsPaint = true
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === historyScroll, !isSyncingHistoryScroll else { return }
        if reconcileScrollAction() {
            requestDisplayLink()
            return
        }
        guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }
        switch channel.engine.scrollAction {
        case .history:
            applyHistoryScrollOffset()
        case .mouseWheel, .alternateKeys:
            consumeAppScrollOffset()
        }
        requestDisplayLink()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === historyScroll else { return }
        appScroll.cancelQueuedSteps()
        appScroll.wheelRemainder = SSHTerminalWheelScaling.Accumulator()
        appScroll.altRemainder = 0
        if channel.engine.scrollAction != .history {
            let pan = scrollView.panGestureRecognizer
            let slop = SSHTerminalAppScrollSlop.uncountedTravel(
                panTranslationY: pan.translation(in: scrollView).y,
                firstTouchY: historyScroll.firstTouchY,
                panLocationY: pan.location(in: scrollView).y
            )
            appScroll.lastOffset = scrollView.contentOffset.y + slop
            appScroll.pendingWheelCell = cell(at: pan.location(in: self))
        }
        requestDisplayLink()
        applyFrameRate(scrolling: true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === historyScroll, !decelerate else { return }
        settleScroll()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === historyScroll else { return }
        settleScroll()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === longPress { return false }
        if other === longPress { return false }
        return true
    }

    private func configureHistoryScroll() {
        historyScroll.delegate = self
        historyScroll.alwaysBounceVertical = true
        historyScroll.showsHorizontalScrollIndicator = false
        historyScroll.showsVerticalScrollIndicator = true
        historyScroll.delaysContentTouches = false
        historyScroll.contentInsetAdjustmentBehavior = .never
        historyScroll.backgroundColor = .clear
        historyScroll.isOpaque = false
        historyScroll.keyboardDismissMode = .none
        historyScroll.decelerationRate = .normal
        historyScroll.accessibilityElementsHidden = true
    }

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.delegate = self
        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        press.minimumPressDuration = 0.45
        press.allowableMovement = 12
        press.delegate = self
        historyScroll.touchBegan = { [weak self] in
            guard let self else { return }
            self.tapIgnore.touchBegan()
            self.appScroll.cancelQueuedSteps()
        }
        historyScroll.addGestureRecognizer(tap)
        historyScroll.addGestureRecognizer(doubleTap)
        historyScroll.addGestureRecognizer(press)
        tapRecognizer = tap
        longPress = press
        updateTouchMode()
    }

    private func updateTouchMode() {
        reconcileScrollAction()
        let history = channel.engine.scrollAction == .history
        historyScroll.isScrollEnabled = dragTarget == nil
        historyScroll.showsVerticalScrollIndicator = history && dragTarget == nil
        if history {
            syncHistoryScrollFromEngine()
        } else {
            prepareAppScrollSurface()
            publishFollowState()
        }
    }

    /// Stop a coasting fling and drop an in-flight drag when the remote
    /// changes what a vertical finger move means. Returns true when this
    /// callback must not consume the previous surface's coordinates as finger
    /// travel. The next touch starts fresh.
    @discardableResult
    private func reconcileScrollAction() -> Bool {
        let action = channel.engine.scrollAction
        guard action != appliedScrollAction else { return false }
        isSyncingHistoryScroll = true
        historyScroll.setContentOffset(historyScroll.contentOffset, animated: false)
        isSyncingHistoryScroll = false
        appScroll.resetGesture()
        appliedScrollAction = action
        switch action {
        case .history:
            applyEngineHistoryOffset()
        case .mouseWheel, .alternateKeys:
            prepareAppScrollSurface(forceReseed: true)
        }
        // Cancel the pan so UIScrollView cannot write the drag-began offset
        // back on the next move and have that delta consumed in the new mode.
        isSyncingHistoryScroll = true
        let pan = historyScroll.panGestureRecognizer
        pan.isEnabled = false
        pan.isEnabled = true
        isSyncingHistoryScroll = false
        return true
    }

    private func syncHistoryScrollFromEngine() {
        guard channel.engine.scrollAction == .history else { return }
        publishFollowState()
        guard !historyScroll.isDragging, !historyScroll.isDecelerating else { return }
        applyEngineHistoryOffset()
    }

    private func applyEngineHistoryOffset() {
        let height = cellSize.height
        guard height > 0, bounds.height > 0 else { return }
        let bar = channel.engine.scrollbar
        let contentHeight = SSHTerminalHistoryLayout.contentHeight(
            boundsHeight: bounds.height,
            totalRows: Int(bar.total),
            viewportRows: Int(bar.len),
            cellHeight: height
        )
        let offsetY = min(max(0, CGFloat(bar.offset) * height), max(0, contentHeight - bounds.height))
        isSyncingHistoryScroll = true
        historyScroll.contentSize = CGSize(width: bounds.width, height: contentHeight)
        if abs(historyScroll.contentOffset.y - offsetY) > 0.5 {
            historyScroll.contentOffset = CGPoint(x: 0, y: offsetY)
        }
        isSyncingHistoryScroll = false
        if metalHost.transform != .identity {
            metalHost.transform = .identity
            selectionOverlay.transform = .identity
        }
    }

    private func applyHistoryScrollOffset() {
        let height = cellSize.height
        guard height > 0 else { return }
        let maxOffset = max(0, historyScroll.contentSize.height - historyScroll.bounds.height)
        let y = historyScroll.contentOffset.y
        let bounce: CGFloat
        if y < 0 {
            bounce = -y
            channel.engine.scrollToRow(0)
        } else if y > maxOffset {
            bounce = maxOffset - y
            let bar = channel.engine.scrollbar
            let last = max(0, Int(bar.total) - Int(bar.len))
            channel.engine.scrollToRow(last)
        } else {
            bounce = 0
            channel.engine.scrollToRow(Int((y / height).rounded()))
        }
        let transform = CGAffineTransform(translationX: 0, y: bounce)
        metalHost.transform = transform
        selectionOverlay.transform = transform
        publishFollowState()
        needsPaint = true
    }

    private func consumeAppScrollOffset() {
        let tracking = historyScroll.isTracking || historyScroll.isDragging
        let wheelCell = tracking
            ? cell(at: historyScroll.panGestureRecognizer.location(in: self))
            : nil
        appScroll.consume(
            offset: historyScroll.contentOffset.y,
            cellHeight: cellSize.height,
            action: channel.engine.scrollAction,
            wheelCell: wheelCell
        )
    }

    private func prepareAppScrollSurface(forceReseed: Bool = false) {
        let height = max(bounds.height, 1)
        let contentHeight = height * 16
        let mid = max(0, (contentHeight - height) / 2)
        let dragging = historyScroll.isDragging || historyScroll.isDecelerating
        isSyncingHistoryScroll = true
        historyScroll.contentSize = CGSize(width: bounds.width, height: contentHeight)
        if forceReseed || !dragging {
            if abs(historyScroll.contentOffset.y - mid) > 1 {
                historyScroll.contentOffset = CGPoint(x: 0, y: mid)
            }
            appScroll.reseed(offset: historyScroll.contentOffset.y)
        }
        isSyncingHistoryScroll = false
        metalHost.transform = .identity
        selectionOverlay.transform = .identity
    }

    private func settleScroll() {
        flushPendingAppScroll()
        switch channel.engine.scrollAction {
        case .history:
            settleHistoryScroll()
        case .mouseWheel, .alternateKeys:
            prepareAppScrollSurface()
        }
    }

    private func flushPendingAppScroll() {
        let flush = appScroll.takeFlush(action: channel.engine.scrollAction)
        if flush.wheelSteps != 0 {
            let input: SSHTerminalEngine.MouseInput = flush.wheelSteps < 0 ? .wheelUp : .wheelDown
            let n = abs(flush.wheelSteps)
            let target = flush.wheelCell
            let bytes = SSHTerminalScrollCoalescing.encodeRepeated(n) {
                channel.engine.mouse(input, column: target.column, row: target.row)
            }
            _ = channel.send(bytes)
        }
        if flush.altRows != 0 {
            let key: GhosttyKey = flush.altRows < 0 ? GHOSTTY_KEY_ARROW_UP : GHOSTTY_KEY_ARROW_DOWN
            let n = abs(flush.altRows)
            let bytes = SSHTerminalScrollCoalescing.encodeRepeated(n) {
                channel.engine.key(key)
            }
            _ = channel.send(bytes)
        }
    }

    private func settleHistoryScroll() {
        guard channel.engine.scrollAction == .history else { return }
        publishFollowState()
        if channel.engine.following {
            channel.engine.backToLive()
        }
        syncHistoryScrollFromEngine()
        needsPaint = true
    }

    private func publishFollowState() {
        let following = !SSHTerminalFollowChrome.showsBackToLive(
            scrollAction: channel.engine.scrollAction,
            following: channel.engine.following
        )
        guard lastFollow != following else { return }
        lastFollow = following
        followChanged(following)
    }

    private func showHighlight(_ snapshot: SSHTerminalSelectionSnapshot, lingering: Bool) {
        selectionOverlay.spans = snapshot.spans.compactMap { span in
            guard span.row >= 0 else { return nil }
            let x = CGFloat(span.startColumn) * cellSize.width
            let width = CGFloat(span.endColumn - span.startColumn + 1) * cellSize.width
            return CGRect(
                x: x,
                y: CGFloat(span.row) * cellSize.height,
                width: width,
                height: cellSize.height
            )
        }
        selectionOverlay.isHidden = selectionOverlay.spans.isEmpty
        highlightClear?.cancel()
        guard lingering else { return }
        highlightGeneration &+= 1
        let generation = highlightGeneration
        highlightClear = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, self.highlightGeneration == generation else { return }
            self.clearHighlight()
        }
    }

    private func clearHighlight() {
        highlightClear?.cancel()
        highlightClear = nil
        selectionOverlay.spans = []
        selectionOverlay.isHidden = true
    }

    func setKeyActions(_ actions: [SSHTerminalKeyAction]) {
        keyActions = actions
        keyStrip?.setProgramActions(actions)
    }

    private func makeAccessoryBar() -> UIView {
        var colors = ComposerThemeColors.placeholder
        colors.fg = foreground
        colors.bg = barBackgroundColor()
        let strip = SSHTerminalKeyStripView(
            role: .accessory,
            handlers: SSHTerminalKeyStripView.Handlers(
                sendStrokes: { [weak self] strokes in self?.channel.keys(strokes) },
                sendKey: { [weak self] key in self?.accessoryKey(key) },
                sendArrow: { [weak self] key in
                    guard let self, self.isFirstResponder, self.channel.connected,
                          !self.channel.inputClosed else { return false }
                    self.accessoryKey(key)
                    return true
                },
                toggleModifier: { [weak self] modifier in
                    guard let self else { return }
                    self.channel.modifierLatch.toggle(modifier)
                    self.showModifiers()
                },
                modifierArmed: { [weak self] modifier in
                    self?.channel.modifierLatch.isArmed(modifier) ?? false
                },
                pasteTarget: self,
                useChatBar: { [weak self] in
                    guard let self else { return }
                    self.useChatBar()
                    _ = self.resignFirstResponder()
                },
                hideKeyboard: { [weak self] in _ = self?.resignFirstResponder() }
            )
        )
        strip.apply(
            profile: nil,
            userFile: nil,
            actions: keyActions,
            colors: colors,
            foreground: foreground,
            background: barBackgroundColor()
        )
        keyStrip = strip
        return strip
    }

    private func applyKeyStripTheme(background: UIColor) {
        var colors = ComposerThemeColors.placeholder
        colors.fg = foreground
        colors.bg = background
        keyStrip?.apply(
            profile: nil,
            userFile: nil,
            actions: keyActions,
            colors: colors,
            foreground: foreground,
            background: background
        )
    }

    private func barBackgroundColor() -> UIColor {
        backgroundColor ?? .systemBackground
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
            view.displayLinkTickCount &+= 1
            view.flushPendingAppScroll()
            // A hold has a one-second deadline even if no more bytes arrive.
            let changes = view.channel.engine.changeCount
            let generation = view.displayLinkGeneration
            let scrolling = view.isHistoryScrolling
            view.applyFrameRate(scrolling: scrolling)
            // Consume the gate after presentIfNeeded submits, finds nothing
            // to draw, or hits a deterministic encode miss. Transient misses
            // leave needsPaint set so the next tick retries without a new byte.
            view.updateTouchMode()
            view.syncHistoryScrollFromEngine()
            if view.needsPaint || view.paintedChangeCount != changes || view.channel.engine.renderHeld {
                if view.presentIfNeeded() {
                    view.needsPaint = false
                    view.paintedChangeCount = changes
                }
            }
            let still = SSHTerminalDisplayLinkPolicy.resolve(
                hasWindow: view.window != nil,
                sceneActive: view.sceneActive,
                needsFullPaint: view.needsFullPaint,
                pictureChanged: view.needsPaint
                    || view.paintedChangeCount != view.channel.engine.changeCount,
                renderHeld: view.channel.engine.renderHeld,
                scrolling: view.isHistoryScrolling
            )
            if still.running {
                view.applyFrameRate(scrolling: still.highFrameRate)
            } else if view.displayLinkGeneration == generation {
                view.pauseDisplayLink()
            }
            view.publishDisplayLinkDebug()
        }
    }
}

/// History scroller. Touches begin here, so a sticky long-press tap ignore
/// can clear before the next independent tap is recognized.
private final class SSHTerminalHistoryScrollView: UIScrollView {
    var touchBegan: (() -> Void)?
    var firstTouchY: CGFloat?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        firstTouchY = touches.first.map { $0.location(in: self).y }
        touchBegan?()
        super.touchesBegan(touches, with: event)
    }

    override func touchesShouldBegin(_ touches: Set<UITouch>, with event: UIEvent?, in view: UIView) -> Bool {
        firstTouchY = touches.first.map { $0.location(in: self).y }
        touchBegan?()
        return super.touchesShouldBegin(touches, with: event, in: view)
    }
}

/// Metal drawable host. Kept as a child so history rubber-band can translate
/// the grid without moving the native scroll view on top of it.
private final class SSHTerminalMetalHostView: UIView {
    let metalLayer = CAMetalLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        layer.addSublayer(metalLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalLayer.frame = bounds
    }
}

private final class SSHTerminalSelectionOverlay: UIView {
    var spans: [CGRect] = [] {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        UIColor.systemBlue.withAlphaComponent(0.28).setFill()
        for span in spans {
            UIBezierPath(rect: span).fill()
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
