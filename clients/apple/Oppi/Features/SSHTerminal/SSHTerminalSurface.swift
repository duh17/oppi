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
final class SSHTerminalGridView: UIView, UITextInput, UIScrollViewDelegate, UIGestureRecognizerDelegate,
    UIEditMenuInteractionDelegate {
    let channel: SSHTerminalChannel
    let requestPaste: (String?) -> Void
    let followChanged: (Bool) -> Void
    var needsPaint = true
    var keyboardRequest = 0
    var resignRequest = 0
    var tapTypesInTerminal = false
    var rawKeyboardChanged: (Bool) -> Void = { _ in }
    /// A password prompt appeared (true) or ended (false) on the live screen.
    var secureInputChanged: (Bool) -> Void = { _ in }
    /// The user sent the keyboard away with its hide key or a tap: a manual
    /// choice, so an automatic switch back after a password prompt stands down.
    var keyboardDismissed: () -> Void = {}
    var focusComposer: () -> Void = {}
    var useChatBar: () -> Void = {}
    /// Runs on every display-link tick, after that tick's frame is encoded:
    /// output, resize, and scroll are applied, and a move of the grid made
    /// here commits in the same frame as the picture. Sub-row history moves
    /// paint without `onPictureChange`; this still sees them.
    var didDrawFrame: () -> Void = {}
    var paintedChangeCount = -1
    /// Rebuilt when `AppFont` rebuilds (Code Font or Code Text Size change);
    /// a new cell size resizes the remote terminal on the next layout.
    private var metrics = SSHTerminalCellMetrics.codeFont()
    var cellSize: CGSize { metrics.cellSize }
    private var renderer: SSHTerminalMetalRenderer?
    /// Theme, font, or bounds changed: encode the whole grid even if libghostty
    /// reported no dirty rows.
    private var needsFullPaint = true
    private var paintedSize = CGSize.zero
    private var sceneActive = true
    private var appliedTheme: ThemeID?
    private var lastGeometry: SSHTerminalGeometry?
    /// A keyboard transition or leaving the screen: layout inside that motion
    /// does not resize the terminal. The screen sends the settled size itself.
    private var resizeHeld = false
    private var reportGeometryOnLayout = false
    private var keyStrip: SSHTerminalKeyStripView?
    /// The value reported for `isSecureTextEntry`, changed only by
    /// `updateSecureEntry`.
    private var secureEntry = false
    /// The prompt secure entry latched to: the cursor row it appeared on and
    /// its text. A prompt that echoes one mark per key (`pwfeedback`) stops
    /// matching as soon as the secret is typed, so the latch, not a fresh
    /// match, keeps the keyboard secure until that row is left behind.
    private struct SecurePrompt: Equatable {
        var row: Int
        var text: String
    }
    private var securePrompt: SecurePrompt?
    /// The change count of the first check that no longer saw the prompt. The
    /// latch and the input switch back only when a check on a later picture
    /// agrees, so one half-drawn frame (a repaint in a neighbouring Herdr pane
    /// that moves the cursor away and back) cannot drop secure entry and pull
    /// the chat bar up under the rest of the secret.
    private var secureOffChanges: Int?
    /// The change count and cursor row of the last completed check, so an
    /// idle frame costs two reads and no string.
    private var secureCheckedChanges = -1
    private var secureCheckedRow = -1
    /// A hardware key is sent from pressesBegan only. While one is down,
    /// insertText/deleteBackward and the edit-menu paste are echoes of the
    /// same press and must not send again. Ended or cancelled presses are
    /// ignored so a stale UIPress cannot swallow software ⌫ repeats.
    private var hardwarePresses = Set<UIPress>()
    /// The keyboard's document, kept equal to what it typed into the shell.
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
    var trackpadArrows = SSHTerminalTrackpadArrows()
    private var deleteAcceleration = SSHTerminalDeleteAcceleration()
    /// The highlighted selection, while a drag or its copy highlight shows.
    private var shownSelection: SSHTerminalSelectionSnapshot?
    private lazy var shortcutCommands: [UIKeyCommand] = SSHTerminalHardwareShortcut.allCases.map { shortcut in
        let command = UIKeyCommand(
            title: shortcut.title,
            action: #selector(performHardwareShortcut(_:)),
            input: shortcut.input,
            modifierFlags: .command,
            propertyList: shortcut.rawValue
        )
        command.wantsPriorityOverSystemBehavior = true
        return command
    }
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
    /// Where a recognized hold started. It becomes a selection or mouse drag
    /// only once the finger moves; a hold lifted in place opens the edit menu.
    private var holdStart: CGPoint?
    /// What the held cell offers: Open and Copy join Paste when it is a link,
    /// a URL, or a path. Cleared when the menu closes.
    private var heldCell: SSHTerminalHeldCell?
    private var heldOpenTarget: SSHTerminalOpenTarget?
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    /// An image from Paste or the paste control, for the host to save.
    var pasteImage: (SSHTerminalPastedImage) -> Void = { _ in }
    /// The Open choice for a held cell, if this terminal can open one. The
    /// owner knows the host's folder and whether it is a paired server.
    var openTargetForHeldCell: (SSHTerminalHeldCell) -> SSHTerminalOpenTarget? = { _ in nil }
    /// Runs the Open choice picked from the hold menu.
    var open: (SSHTerminalOpenTarget) -> Void = { _ in }
    private var highlightClear: Task<Void, Never>?
    private var highlightGeneration = 0
    private var isSyncingHistoryScroll = false
    /// Whole pixels the grid is drawn above its top history row, so a history
    /// scroll glides between rows. Zero in app scroll modes. A move within a
    /// row changes only this and sets `needsPaint`; the engine's picture is
    /// unchanged, so `onPictureChange` does not fire for it.
    private var historyShiftPixels = 0
    private var paintedShiftPixels = 0
    /// Kitty graphics generation last drawn: an image arriving, being replaced,
    /// or being deleted repaints even when no text row moved.
    private var paintedKittyGeneration: UInt64 = 0
    /// Finger travel shown before UIScrollView's pan starts; see
    /// `SSHTerminalHistoryFingerLead`. `leadStartedFollowing` is set while
    /// that lead is shown and says whether the live screen was followed when
    /// it started, so a tap puts Back to Live state back as it was. Until it
    /// clears, the finger owns the picture: follow state is not published and
    /// the engine does not move the scroll view.
    private var historyLead: CGFloat = 0
    private var leadStartedFollowing: Bool?
    /// contentOffset when a history pan began with a lead shown, until
    /// `commitHistoryLead` hands the lead to the scroll view.
    private var historyDragStart: CGFloat?
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
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.plainText.identifier, UTType.image.identifier])
        accessibilityIdentifier = "sshTerminal.grid"
        accessibilityLabel = "SSH terminal. Tap to type or hide the keyboard. Double-tap a word to copy it. Drag to scroll. Touch and hold for Open, Copy, and Paste, or hold then drag to select."
        addInteraction(editMenu)
        installGestures()
        bar = makeAccessoryBar()
        applyTheme(ThemeRuntimeState.currentThemeID())
        channel.engine.onPictureChange = { [weak self] in
            guard let self else { return }
            self.needsPaint = true
            self.requestDisplayLink()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(fontPreferencesChanged),
                                               name: AppFont.didRebuildNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Posted on the main thread after `AppFont` rebuilds.
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
    /// Secure entry is on only while the live screen's cursor sits after a
    /// password prompt; see `updateSecureEntry`. Third-party keyboards,
    /// dictation, and keyboard learning do not see what is typed then.
    var isSecureTextEntry: Bool { get { secureEntry } set { _ = newValue } }
    var textContentType: UITextContentType? { get { nil } set { _ = newValue } }
    /// Writing Tools rewrites through `replace`, which would type its result.
    var writingToolsBehavior: UIWritingToolsBehavior { get { .none } set { _ = newValue } }
    var keyboardType: UIKeyboardType { get { .asciiCapable } set { _ = newValue } }
    override var inputAccessoryView: UIView? { bar }
    override var keyCommands: [UIKeyCommand]? { shortcutCommands }

    /// A grid moved up past a clipping parent (the chat bar's cursor shift)
    /// is outlined only where it shows.
    override var accessibilityFrame: CGRect {
        get {
            guard let superview, superview.clipsToBounds else { return super.accessibilityFrame }
            let shown = bounds.intersection(superview.convert(superview.bounds, to: self))
            return UIAccessibility.convertToScreenCoordinates(shown.isNull ? .zero : shown, in: self)
        }
        set { super.accessibilityFrame = newValue }
    }

    @objc private func performHardwareShortcut(_ command: UIKeyCommand) {
        guard let raw = command.propertyList as? Int,
              let shortcut = SSHTerminalHardwareShortcut(rawValue: raw) else { return }
        switch shortcut {
        case .copy:
            // Same copy and note as a long-press selection; nothing without one.
            guard let selection = shownSelection else { return }
            channel.copyLocalSelection(selection.text)
            showHighlight(selection, lingering: true)
        case .clearScreen:
            resetTextInput()
            clearHighlight()
            channel.clearScreen()
            syncHistoryScrollFromEngine()
        }
        needsPaint = true
        requestDisplayLink()
    }

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

    /// A finger is on local history, or it is still coasting.
    var isHistoryScrolling: Bool {
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
        if !resizeHeld, let geometry = geometry(for: bounds.size),
           geometry != lastGeometry || reportGeometryOnLayout {
            lastGeometry = geometry
            reportGeometryOnLayout = false
            channel.resize(geometry)
            needsPaint = true
        }
        syncHistoryScrollFromEngine()
        updateTouchMode()
    }

    /// The terminal grid that fits `size` with the current cell metrics.
    func geometry(for size: CGSize) -> SSHTerminalGeometry? {
        let scale = traitCollection.displayScale
        guard size.width > 0, size.height > 0, scale > 0 else { return nil }
        return SSHTerminalGeometry(
            columns: min(500, max(1, Int(size.width / cellSize.width))),
            rows: min(300, max(1, Int(size.height / cellSize.height))),
            cellWidth: Int(cellSize.width * scale), cellHeight: Int(cellSize.height * scale))
    }

    func holdResize() {
        resizeHeld = true
    }

    /// The next layout reports the current size even if it matches the last
    /// one; the channel drops a same-size repeat.
    func releaseResize() {
        guard resizeHeld else { return }
        resizeHeld = false
        reportGeometryOnLayout = true
        setNeedsLayout()
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
        // Never shift toward a side with no captured rows (the live bottom).
        let shift = frame.rowsBelowViewport > 0 ? historyShiftPixels : 0
        let shouldDraw = needsFullPaint || !frame.rebuiltRows.isEmpty || shift != paintedShiftPixels
            || frame.kittyGeneration != paintedKittyGeneration
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
            frame: frame, cursorColor: cursor, drawable: drawable, fullRebuild: needsFullPaint,
            shiftPixels: shift
        )
        if cost.submitted {
            needsFullPaint = false
            paintedShiftPixels = shift
            paintedKittyGeneration = frame.kittyGeneration
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

    /// Writes what the keyboard's document produced. Whenever the shell's
    /// line stops matching the document (Return, Tab, a key a one-shot
    /// modifier changed, a word delete, text sent to paste confirmation),
    /// the document starts over.
    func applyTextInput(_ actions: [SSHTerminalTextInputStorage.Action]) {
        guard !actions.isEmpty else { return }
        defer { showModifiers() }
        for action in actions {
            switch action {
            case .insert(let text):
                deleteAcceleration.reset()
                // A lone Return is Enter; any other text that could run a
                // command takes the paste confirmation.
                if text != "\n", text != "\r", SSHTerminalEngine.pasteNeedsConfirmation(text) {
                    requestPaste(text)
                    resetTextInput()
                    return
                }
                let modified = channel.modifierLatch.modifiers != 0
                for character in text {
                    let piece = String(character)
                    let key = Self.logicalKey(piece)
                    channel.key(key, text: key == GHOSTTY_KEY_ENTER || key == GHOSTTY_KEY_TAB ? "" : piece)
                }
                if modified || text.contains(where: { $0.isNewline || $0 == "\t" }) { resetTextInput() }
            case .edit(let deleting, let text):
                deleteAcceleration.reset()
                // One write without the one-shot latch: a modifier armed for
                // the next key must not turn the first letter into Ctrl-C.
                var bytes = SSHTerminalScrollCoalescing.encodeRepeated(deleting) {
                    channel.engine.key(GHOSTTY_KEY_BACKSPACE)
                }
                // A newline anywhere in the text, even alone, asks first.
                if SSHTerminalEngine.pasteNeedsConfirmation(text) || text.contains(where: \.isNewline) {
                    if !bytes.isEmpty { channel.send(bytes) }
                    requestPaste(text)
                    resetTextInput()
                    return
                }
                for character in text {
                    let piece = String(character)
                    let key = Self.logicalKey(piece)
                    bytes.append(channel.engine.key(key, text: key == GHOSTTY_KEY_TAB ? "" : piece))
                }
                channel.send(bytes)
                if text.contains("\t") { resetTextInput() }
            case .backspace:
                let word = deleteAcceleration.softwareDeletesWord(at: CACurrentMediaTime())
                // A one-shot Alt or Ctrl makes ⌫ another key (Alt-⌫ deletes
                // a word in readline), so the document starts over.
                let modified = channel.modifierLatch.modifiers != 0
                sendBackspace(word: word)
                if word || modified { resetTextInput() }
            }
        }
    }

    /// A word delete is Ctrl-W, encoded for the app's keyboard protocol, and
    /// only on the primary screen; see `SSHTerminalDeleteAcceleration`.
    @discardableResult
    private func sendBackspace(word: Bool) -> Bool {
        if word, channel.modifierLatch.modifiers == 0, !channel.engine.alternateScreen {
            return channel.key(GHOSTTY_KEY_W, text: "w", modifiers: GhosttyMods(GHOSTTY_MODS_CTRL))
        }
        return channel.key(GHOSTTY_KEY_BACKSPACE)
    }

    /// One write for the trackpad travel since the last frame. Arrows follow
    /// the app's cursor-key mode and do not spend a Ctrl or Alt latch.
    func flushTrackpadArrows() {
        let steps = trackpadArrows.takePending()
        guard !steps.isEmpty, channel.connected, !channel.inputClosed else { return }
        var bytes = SSHTerminalScrollCoalescing.encodeRepeated(abs(steps.columns)) {
            channel.engine.key(steps.columns < 0 ? GHOSTTY_KEY_ARROW_LEFT : GHOSTTY_KEY_ARROW_RIGHT)
        }
        bytes.append(SSHTerminalScrollCoalescing.encodeRepeated(abs(steps.rows)) {
            channel.engine.key(steps.rows < 0 ? GHOSTTY_KEY_ARROW_UP : GHOSTTY_KEY_ARROW_DOWN)
        })
        channel.send(bytes)
    }

    /// Input that bypasses the keyboard's document may change the shell's
    /// line or move its cursor, so the document starts over, and the
    /// keyboard is told so it stops editing text that is gone. A
    /// composition in progress is the input method's and stays.
    func resetTextInput() {
        var restarted = textInputStorage
        restarted.restart()
        guard restarted != textInputStorage else { return }
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.textWillChange(self)
        textInputStorage = restarted
        inputDelegate?.textDidChange(self)
        inputDelegate?.selectionDidChange(self)
    }

    private func accessoryKey(_ key: GhosttyKey) {
        resetTextInput()
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
            resetTextInput()
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
            // Same as the hide key: a tap that sends the keyboard away is the
            // user's choice, not an automatic switch to undo later.
            self.keyboardDismissed()
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
        clearHistoryLead()
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

    /// The viewport cell drawn under `point`, including a history scroll that
    /// stopped between rows.
    private func cell(at point: CGPoint) -> (column: Int, row: Int) {
        let shift = CGFloat(historyShiftPixels) / max(traitCollection.displayScale, 1)
        return (Int(point.x / cellSize.width), Int((point.y + shift) / cellSize.height))
    }
    /// The edit menu's Paste. iOS grants that read without the Allow Paste alert.
    /// Text wins over an image when the clipboard holds both.
    override func paste(_ sender: Any?) {
        guard !ignoresSoftwareKeyEcho else { return }
        resetTextInput()
        let board = UIPasteboard.general
        if !board.hasStrings, let image = SSHTerminalPastedImage(pasteboard: board) {
            pasteImage(image)
            return
        }
        requestPaste(board.string)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return UIPasteboard.general.hasStrings || UIPasteboard.general.hasImages
        }
        return super.canPerformAction(action, withSender: sender)
    }

    /// The hold menu. A held link, URL, or path gets Open beside Copy and
    /// Paste; anything else keeps the system's Paste-only menu (`nil` leaves
    /// `defaultMenu` in place).
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        defaultMenu: UIMenu
    ) -> UIMenu? {
        Self.holdMenu(
            held: heldCell,
            target: heldOpenTarget,
            canPaste: canPerformAction(#selector(paste(_:)), withSender: nil),
            open: { [weak self] target in self?.open(target) },
            copy: { [weak self] in self?.copyHeldWord() },
            paste: { [weak self] in self?.paste(nil) }
        )
    }

    /// The items a hold menu shows, in order: Open when the cell can open
    /// something, Copy when there is a word or a link to copy, then Paste. A
    /// cell with nothing to open and nothing to copy keeps the system's menu.
    static func holdMenu(
        held: SSHTerminalHeldCell?,
        target: SSHTerminalOpenTarget?,
        canPaste: Bool,
        open: @escaping (SSHTerminalOpenTarget) -> Void,
        copy: @escaping () -> Void,
        paste: @escaping () -> Void
    ) -> UIMenu? {
        var items: [UIMenuElement] = []
        if let target {
            items.append(UIAction(
                title: openTitle(for: target),
                image: UIImage(systemName: "arrow.up.forward.app")
            ) { _ in open(target) })
        }
        if let held, copyText(for: held) != nil {
            items.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in copy() })
        }
        guard !items.isEmpty else { return nil }
        if canPaste {
            items.append(UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { _ in paste() })
        }
        return UIMenu(children: items)
    }

    /// The item names where Open goes: the site for a page, the file for a
    /// path, so the destination is visible before the tap.
    static func openTitle(for target: SSHTerminalOpenTarget) -> String {
        switch target {
        case .web(_, let host): return host.isEmpty ? "Open Link" : "Open \(host)"
        case .path(let path):
            let name = path.split(separator: "/").last.map(String.init) ?? ""
            return name.isEmpty ? "Open" : "Open \(name)"
        }
    }

    /// The accessory bar's UIPasteControl. Its tap is the consent, so there is
    /// no alert, and the text or image loads off the main thread.
    override func paste(itemProviders: [NSItemProvider]) {
        resetTextInput()
        if let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: String.self) }) {
            _ = provider.loadObject(ofClass: String.self) { [weak self] text, _ in
                Task { @MainActor in self?.requestPaste(text) }
            }
            return
        }
        guard let provider = itemProviders.first(where: { SSHTerminalPastedImage.imageType(in: $0) != nil }),
              let type = SSHTerminalPastedImage.imageType(in: provider) else {
            requestPaste(nil)
            return
        }
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { [weak self] data, _ in
            let image = data.map { SSHTerminalPastedImage(data: $0, type: type) }
            Task { @MainActor in
                if let image { self?.pasteImage(image) } else { self?.requestPaste(nil) }
            }
        }
    }
    override func resignFirstResponder() -> Bool {
        hardwarePresses.removeAll()
        textInputStorage.reset()
        deleteAcceleration.reset()
        trackpadArrows.end()
        _ = trackpadArrows.takePending()
        keyRepeater.stop()
        keyStrip?.stopRepeating()
        let resigned = super.resignFirstResponder()
        if resigned { Task { @MainActor [rawKeyboardChanged] in rawKeyboardChanged(false) } }
        return resigned
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        if presses.contains(where: { $0.key != nil }) { resetTextInput() }
        for press in presses {
            guard let key = press.key else { unhandled.insert(press); continue }
            hardwarePresses.insert(press)
            // Modifier keys alone (HID 0xE0...0xE7) send nothing and must not
            // spend the one-shot modifiers.
            if (0xE0...0xE7).contains(key.keyCode.rawValue) { continue }
            // ⌘C and ⌘K run as key commands (`keyCommands`), never here.
            if SSHTerminalHardwareShortcut.matching(input: key.charactersIgnoringModifiers, modifiers: key.modifierFlags) != nil {
                unhandled.insert(press)
                continue
            }
            if key.modifierFlags.contains(.command), key.charactersIgnoringModifiers.lowercased() == "v" {
                requestPaste(UIPasteboard.general.string)
                continue
            }
            // iOS hands ⌘. over as Esc: the period key, no modifiers, and
            // the Esc input string as its characters.
            let escape = key.characters == UIKeyCommand.inputEscape
            let physical = escape ? GHOSTTY_KEY_ESCAPE
                : Self.physicalKey(key.keyCode) ?? Self.logicalKey(key.charactersIgnoringModifiers)
            var mods: GhosttyMods = 0
            if key.modifierFlags.contains(.control) { mods |= GhosttyMods(GHOSTTY_MODS_CTRL) }
            if key.modifierFlags.contains(.alternate) { mods |= GhosttyMods(GHOSTTY_MODS_ALT) }
            if key.modifierFlags.contains(.shift) { mods |= GhosttyMods(GHOSTTY_MODS_SHIFT) }
            if key.modifierFlags.contains(.command) { mods |= GhosttyMods(GHOSTTY_MODS_SUPER) }
            guard let characters = Self.hardwareCharacters(key) else { continue }
            // UIKit names special keys with input strings (UIKeyInputEscape),
            // never text for the shell.
            let text = escape || characters.unicodeScalars.contains { $0.value < 32 || $0.value == 127 || (0xf700...0xf8ff).contains($0.value) }
                ? "" : characters
            // Snapshot for repeats, but only key() may consume the latch.
            let repeatMods = mods | channel.modifierLatch.modifiers
            let accepted = channel.key(physical, text: text, modifiers: mods)
            showModifiers()
            guard accepted else { continue }
            // The held key repeats with the modifiers it was pressed with
            // (including a spent one-shot Ctrl); DECCKM is read at each encode.
            // A plain ⌫ held past a second deletes words.
            repeatingPress = press
            let pressedAt = CACurrentMediaTime()
            let plainDelete = physical == GHOSTTY_KEY_BACKSPACE && repeatMods == 0
            keyRepeater.start { [weak self] in
                guard let self, self.channel.connected else { return false }
                let accepted: Bool
                if plainDelete {
                    let held = CACurrentMediaTime() - pressedAt
                    accepted = self.sendBackspace(word: SSHTerminalDeleteAcceleration.hardwareDeletesWord(heldFor: held))
                } else {
                    accepted = self.channel.key(physical, text: text, modifiers: repeatMods)
                }
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
        // A hold that drifted before it began puts the grid back first, so
        // the selection starts on the text that is shown.
        if gesture.state == .began { endHistoryLead() }
        let location = gesture.location(in: self)
        let cell = self.cell(at: location)
        let scale = max(traitCollection.displayScale, 1)
        let surface = CGPoint(x: location.x * scale, y: location.y * scale + CGFloat(historyShiftPixels))
        switch gesture.state {
        case .began:
            tapIgnore.arm()
            tapSequence.reset()
            cancelHideKeyboard()
            historyScroll.isScrollEnabled = false
            holdStart = location
            dragSnapshot = nil
        case .changed:
            if dragTarget == nil, let start = holdStart,
               hypot(location.x - start.x, location.y - start.y) >= Self.holdDragThreshold {
                beginHoldDrag(at: start)
            }
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
                if gesture.state == .ended, let start = holdStart {
                    presentHoldMenu(at: start)
                }
            }
            holdStart = nil
            dragSnapshot = nil
            let tapFailed = tapRecognizer?.state == .failed || tapRecognizer?.state == .cancelled
            tapIgnore.longPressEnded(tapFailed: tapFailed)
            updateTouchMode()
        default:
            break
        }
        needsPaint = true
    }

    /// Finger travel after the hold before it counts as a drag rather than
    /// a hold for the menu.
    private static let holdDragThreshold: CGFloat = 6

    /// A hold that lifts in place opens the edit menu at the finger. When the
    /// held cell is an OSC 8 link, a URL, or a path, the menu offers Open and
    /// Copy beside Paste; otherwise it is the usual Paste menu. Opening never
    /// writes to the host, and a tap keeps its own behaviour.
    private func presentHoldMenu(at point: CGPoint) {
        let cell = self.cell(at: point)
        let held = channel.engine.heldCell(column: cell.column, row: cell.row)
        heldCell = held
        heldOpenTarget = held.flatMap(openTargetForHeldCell)
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }
    /// Copy in the hold menu: the same local copy the double tap makes, never
    /// a remote clipboard write. A cell on an OSC 8 link copies the link, so a
    /// blank or punctuation cell under a link still copies something.
    private func copyHeldWord() {
        guard let held = heldCell, let text = Self.copyText(for: held) else { return }
        let snapshot = SSHTerminalSelectionSnapshot(text: text, spans: held.text == text ? held.spans : [])
        channel.copyLocalSelection(text)
        showHighlight(snapshot, lingering: true)
        needsPaint = true
    }

    /// What Copy puts on this device's clipboard: the link the cell carries,
    /// else its word.
    static func copyText(for held: SSHTerminalHeldCell) -> String? {
        if let hyperlink = held.hyperlink, !hyperlink.isEmpty { return hyperlink }
        return held.text.isEmpty ? nil : held.text
    }

    /// Starts the selection, or the mouse press in an app that asked for
    /// mouse input, at the cell where the hold began.
    private func beginHoldDrag(at start: CGPoint) {
        let cell = self.cell(at: start)
        let scale = max(traitCollection.displayScale, 1)
        let surface = CGPoint(x: start.x * scale, y: start.y * scale + CGFloat(historyShiftPixels))
        let target = SSHTerminalDragTarget.resolve(mouseReporting: channel.engine.mouseTracking)
        dragTarget = target
        switch target {
        case .mouse:
            resetTextInput()
            channel.mouse(.press, column: cell.column, row: cell.row)
        case .selection:
            channel.engine.beginSelection(column: cell.column, row: cell.row, surfacePoint: surface)
        }
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
            commitHistoryLead(underFinger: true)
            applyHistoryScrollOffset()
        case .mouseWheel, .alternateKeys:
            consumeAppScrollOffset()
        }
        requestDisplayLink()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === historyScroll else { return }
        // Local history sends nothing, so dictation keeps its document.
        if channel.engine.scrollAction != .history { resetTextInput() }
        appScroll.resetGesture()
        if channel.engine.scrollAction == .history {
            // The grid already follows the finger; the first drag callback
            // moves the scroll view there.
            if leadStartedFollowing != nil { historyDragStart = scrollView.contentOffset.y }
        } else {
            let pan = scrollView.panGestureRecognizer
            let slop = SSHTerminalAppScrollSlop.uncountedTravel(
                panTranslationY: pan.translation(in: scrollView).y,
                firstTouchY: historyScroll.firstTouchY,
                panLocationY: pan.location(in: self).y
            )
            appScroll.lastOffset = scrollView.contentOffset.y + slop
            appScroll.pendingWheelCell = cell(at: pan.location(in: self))
        }
        requestDisplayLink()
        applyFrameRate(scrolling: true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === historyScroll else { return }
        // A pan can end before it moved content (a short nudge, or a flick
        // whose next event is the lift), so no drag callback committed the lead.
        commitHistoryLead(underFinger: false)
        guard !decelerate else { return }
        settleScroll(nearLiveIsLive: true)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === historyScroll else { return }
        settleScroll(nearLiveIsLive: false)
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
        historyScroll.touchMoved = { [weak self] travel in self?.leadHistory(fingerTravel: travel) }
        historyScroll.touchEnded = { [weak self] in self?.endHistoryLead() }
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
        clearHistoryLead()
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
        // A lead scrolls the engine off live before the touch is known to be
        // a drag; publishing that would flash Back to Live on a tap.
        guard channel.engine.scrollAction == .history, leadStartedFollowing == nil else { return }
        publishFollowState()
        guard !historyScroll.isDragging, !historyScroll.isDecelerating else { return }
        applyEngineHistoryOffset()
    }

    private var historyMaxOffset: CGFloat {
        max(0, historyScroll.contentSize.height - historyScroll.bounds.height)
    }

    private var historyLastRow: Int {
        let bar = channel.engine.scrollbar
        return max(0, Int(bar.total) - Int(bar.len))
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
        let maxOffset = max(0, contentHeight - bounds.height)
        // A scroll that stopped between rows stays there while the engine
        // still shows that row; output, Back to Live, or a resize that moved
        // the viewport lands on a whole row.
        let rowOffset = CGFloat(bar.offset) * height
        let current = historyScroll.contentOffset.y
        let target = current >= rowOffset && current < rowOffset + height ? current : rowOffset
        let offsetY = min(max(0, target), maxOffset)
        isSyncingHistoryScroll = true
        historyScroll.contentSize = CGSize(width: bounds.width, height: contentHeight)
        if abs(current - offsetY) > 0.5 {
            historyScroll.contentOffset = CGPoint(x: 0, y: offsetY)
        }
        isSyncingHistoryScroll = false
        let position = SSHTerminalHistoryPosition.resolve(
            offset: offsetY, maxOffset: maxOffset, lastRow: historyLastRow,
            cellHeight: height, scale: traitCollection.displayScale
        )
        let shift = position.row == Int(bar.offset) ? position.shiftPixels : 0
        if shift != historyShiftPixels {
            historyShiftPixels = shift
            needsPaint = true
        }
        applyGridTransform(bounce: 0)
    }

    private func applyHistoryScrollOffset() {
        showHistory(at: historyScroll.contentOffset.y - historyLead, publishFollow: true)
    }

    /// Draws local history with its top at `offset` (scroll view points):
    /// the engine shows the top whole row and the renderer shifts the grid up
    /// by the rest, so a drag glides instead of stepping a row at a time.
    private func showHistory(at offset: CGFloat, publishFollow: Bool) {
        let height = cellSize.height
        guard height > 0 else { return }
        let lastRow = historyLastRow
        let position = SSHTerminalHistoryPosition.resolve(
            offset: offset, maxOffset: historyMaxOffset, lastRow: lastRow,
            cellHeight: height, scale: traitCollection.displayScale
        )
        // scrollToRow rebuilds every row; a move inside one row only shifts.
        if Int(channel.engine.scrollbar.offset) != position.row
            || (position.row == lastRow && !channel.engine.following) {
            channel.engine.scrollToRow(position.row)
        }
        historyShiftPixels = position.shiftPixels
        applyGridTransform(bounce: position.bounce)
        if publishFollow { publishFollowState() }
        needsPaint = true
    }

    /// The rubber band moves the drawn grid; the selection highlight also
    /// follows the sub-row shift the renderer draws.
    private func applyGridTransform(bounce: CGFloat) {
        let shift = CGFloat(historyShiftPixels) / max(traitCollection.displayScale, 1)
        let grid = CGAffineTransform(translationX: 0, y: bounce)
        let selection = CGAffineTransform(translationX: 0, y: bounce - shift)
        if metalHost.transform != grid { metalHost.transform = grid }
        if selectionOverlay.transform != selection { selectionOverlay.transform = selection }
    }

    /// Before UIScrollView's pan starts, local history follows the finger.
    /// Follow state is not published until the touch becomes a drag.
    func leadHistory(fingerTravel: CGFloat) {
        guard channel.engine.scrollAction == .history, appliedScrollAction == .history,
              dragTarget == nil, historyScroll.isScrollEnabled,
              !historyScroll.isDragging, !historyScroll.isDecelerating else { return }
        let lead = SSHTerminalHistoryFingerLead.lead(fingerTravel: fingerTravel)
        if leadStartedFollowing == nil {
            guard lead != 0 else { return }
            leadStartedFollowing = channel.engine.following
        }
        historyLead = lead
        let offset = min(max(0, historyScroll.contentOffset.y - lead), historyMaxOffset)
        showHistory(at: offset, publishFollow: false)
        requestDisplayLink()
    }

    /// A tap, a touch and hold, or a lifted finger puts the grid back where
    /// the scroll view is. The pan's own cancel of these touches is skipped:
    /// that drag keeps the grid where it is.
    func endHistoryLead() {
        let pan = historyScroll.panGestureRecognizer.state
        guard let wasFollowing = leadStartedFollowing, !historyScroll.isDragging,
              pan != .began, pan != .changed else { return }
        leadStartedFollowing = nil
        historyLead = 0
        guard channel.engine.scrollAction == .history else { return }
        if wasFollowing {
            channel.engine.backToLive()
            applyEngineHistoryOffset()
        } else {
            showHistory(at: historyScroll.contentOffset.y, publishFollow: true)
        }
        needsPaint = true
        requestDisplayLink()
    }

    /// The pan took over from the lead: the scroll view moves to where the
    /// grid already is, and from here its offset alone places the grid. On
    /// the pan's first move, `underFinger` puts content where the finger is
    /// now, so the drag continues from under it. When the pan ended without
    /// moving content, the scroll view moves to the lead last drawn.
    private func commitHistoryLead(underFinger: Bool) {
        guard let start = historyDragStart else { return }
        var lead = historyLead
        if underFinger, let firstTouchY = historyScroll.firstTouchY {
            lead = SSHTerminalHistoryFingerLead.lead(
                fingerTravel: historyScroll.panGestureRecognizer.location(in: self).y - firstTouchY
            )
        }
        clearHistoryLead()
        let current = historyScroll.contentOffset.y
        let target = SSHTerminalHistoryFingerLead.dragOffset(
            start: start, current: current, lead: lead, maxOffset: historyMaxOffset
        )
        guard abs(target - current) >= 0.5 else { return }
        isSyncingHistoryScroll = true
        historyScroll.contentOffset = CGPoint(x: 0, y: target)
        isSyncingHistoryScroll = false
    }

    private func clearHistoryLead() {
        historyLead = 0
        leadStartedFollowing = nil
        historyDragStart = nil
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
        clearHistoryLead()
        if historyShiftPixels != 0 {
            historyShiftPixels = 0
            needsPaint = true
        }
        applyGridTransform(bounce: 0)
    }

    private func settleScroll(nearLiveIsLive: Bool) {
        flushPendingAppScroll()
        switch channel.engine.scrollAction {
        case .history:
            settleHistoryScroll(nearLiveIsLive: nearLiveIsLive)
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

    /// `nearLiveIsLive`: a drag released within half a row of the bottom goes
    /// back to live, as it did when history moved in whole rows.
    private func settleHistoryScroll(nearLiveIsLive: Bool) {
        guard channel.engine.scrollAction == .history else { return }
        // Backstop: no lead outlives the gesture that started it.
        clearHistoryLead()
        let nearLive = nearLiveIsLive
            && historyScroll.contentOffset.y > historyMaxOffset - cellSize.height / 2
        if channel.engine.following || nearLive {
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
        shownSelection = snapshot
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
        shownSelection = nil
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
                sendStrokes: { [weak self] strokes in
                    guard let self else { return }
                    self.resetTextInput()
                    self.channel.keys(strokes)
                },
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
                hideKeyboard: { [weak self] in
                    guard let self else { return }
                    self.keyboardDismissed()
                    _ = self.resignFirstResponder()
                }
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

    /// Option is Meta: Option-b sends Alt with `b`, not the `∫` a Mac layout
    /// puts on that key, so readline and agent TUIs see their Alt bindings.
    /// UIKey has no Shift-only character for an Option chord, so Option-Shift
    /// works for letters only. With another key it sends nothing: guessing
    /// the unshifted key would turn Option-Shift-[ into `ESC [`, the start
    /// of a control sequence.
    private static func hardwareCharacters(_ key: UIKey) -> String? {
        guard key.modifierFlags.contains(.alternate) else { return key.characters }
        return metaCharacters(base: key.charactersIgnoringModifiers, shift: key.modifierFlags.contains(.shift))
    }

    /// With Shift, only a single ASCII letter, uppercased the same in every
    /// locale (a Turkish `i` must stay `I`, not `İ`).
    nonisolated static func metaCharacters(base: String, shift: Bool) -> String? {
        guard shift else { return base }
        guard base.unicodeScalars.count == 1, let scalar = base.unicodeScalars.first,
              scalar.isASCII, scalar.properties.isAlphabetic else { return nil }
        return base.uppercased(with: Locale(identifier: "en_US_POSIX"))
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

    /// One display-link frame: pending scroll input goes out, the engine is
    /// snapshotted and drawn if it changed, then `didDrawFrame` runs.
    func drawFrame() {
        flushPendingAppScroll()
        flushTrackpadArrows()
        // A hold has a one-second deadline even if no more bytes arrive.
        let changes = channel.engine.changeCount
        applyFrameRate(scrolling: isHistoryScrolling)
        // Consume the gate after presentIfNeeded submits, finds nothing
        // to draw, or hits a deterministic encode miss. Transient misses
        // leave needsPaint set so the next tick retries without a new byte.
        updateTouchMode()
        syncHistoryScrollFromEngine()
        if needsPaint || paintedChangeCount != changes || channel.engine.renderHeld {
            if presentIfNeeded() {
                needsPaint = false
                paintedChangeCount = changes
            }
        }
        updateSecureEntry()
        didDrawFrame()
    }

    /// Turns the keyboard's secure entry on while the live screen asks for a
    /// secret (`Password:`, `[sudo] password for duh:`). The trait is read when
    /// the keyboard is built, so a change reloads the input views once. Only a
    /// painted frame that changed the picture asks the terminal again, and a
    /// frame with no fresh snapshot leaves the state alone. The keyboard bar
    /// shows a lock meanwhile, and the screen moves typing off the chat bar.
    private func updateSecureEntry() {
        guard channel.connected else {
            securePrompt = nil
            secureOffChanges = nil
            applySecureEntry(false)
            return
        }
        let changes = channel.engine.changeCount
        let row = channel.engine.cursorCell.row
        guard changes != secureCheckedChanges || row != secureCheckedRow else { return }
        // nil is history, a hidden cursor, or a picture no frame has drawn yet,
        // not "no prompt".
        guard let line = channel.engine.cursorLineBeforeCursor else { return }
        secureCheckedChanges = changes
        secureCheckedRow = row
        let latched = securePrompt.map {
            $0.row == row && SSHTerminalPasswordPrompt.trimmingEcho(line).hasPrefix($0.text)
        } ?? false
        if !latched {
            let prompt = SSHTerminalPasswordPrompt.prompt(
                inLineBeforeCursor: line, atShellPrompt: channel.engine.cursorAtPrompt
            )
            if let prompt {
                // Turning it on is immediate: the prompt is on screen now.
                securePrompt = SecurePrompt(row: row, text: prompt)
                secureOffChanges = nil
                applySecureEntry(true)
                return
            }
        } else {
            secureOffChanges = nil
            applySecureEntry(true)
            return
        }
        // Off, on one frame: one more check on a later picture decides, so a
        // single half-drawn frame changes nothing.
        if let off = secureOffChanges, off != changes {
            secureOffChanges = nil
            securePrompt = nil
            applySecureEntry(false)
        } else {
            secureOffChanges = changes
        }
    }

    private func applySecureEntry(_ secure: Bool) {
        guard secure != secureEntry else { return }
        secureEntry = secure
        keyStrip?.setSecureInput(secure)
        reloadInputViews()
        secureInputChanged(secure)
    }

    @MainActor private final class DisplayTarget {
        weak var view: SSHTerminalGridView?
        init(_ view: SSHTerminalGridView) { self.view = view }
        @objc func tick() {
            guard let view else { return }
            view.displayLinkTickCount &+= 1
            let generation = view.displayLinkGeneration
            view.drawFrame()
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
/// can clear before the next independent tap is recognized. Until its pan
/// starts (and cancels these touches), moves report vertical finger travel.
private final class SSHTerminalHistoryScrollView: UIScrollView {
    var touchBegan: (() -> Void)?
    var touchMoved: ((CGFloat) -> Void)?
    var touchEnded: (() -> Void)?
    /// Where the first finger of this touch went down, in the grid's
    /// coordinates, which do not scroll.
    var firstTouchY: CGFloat?
    /// That finger. A second finger neither moves the lead nor resets
    /// `firstTouchY`.
    private var firstTouch: UITouch?

    private func track(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Every finger on this view is new: a fresh touch, even if a lost
        // end left an old one tracked.
        let fresh = event?.touches(for: self).map { $0.isSubset(of: touches) } ?? true
        guard firstTouch == nil || fresh, let touch = touches.first else { return }
        firstTouch = touch
        firstTouchY = touch.location(in: superview).y
    }

    /// True when the tracked finger is among `touches`, which then ends it.
    private func untrack(_ touches: Set<UITouch>) -> Bool {
        guard let firstTouch, touches.contains(firstTouch) else { return false }
        self.firstTouch = nil
        return true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        track(touches, with: event)
        touchBegan?()
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let firstTouch, touches.contains(firstTouch), let firstTouchY {
            touchMoved?(firstTouch.location(in: superview).y - firstTouchY)
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if untrack(touches) { touchEnded?() }
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if untrack(touches) { touchEnded?() }
        super.touchesCancelled(touches, with: event)
    }

    override func touchesShouldBegin(_ touches: Set<UITouch>, with event: UIEvent?, in view: UIView) -> Bool {
        track(touches, with: event)
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

/// A pasted image as the bytes the clipboard held and a file extension the
/// host file can carry, so the agent sees a PNG, JPEG, or HEIC as such.
struct SSHTerminalPastedImage: Equatable {
    let data: Data
    let fileExtension: String

    init(data: Data, type: UTType) {
        self.data = data
        fileExtension = type.preferredFilenameExtension ?? "png"
    }

    init?(pasteboard: UIPasteboard) {
        for identifier in pasteboard.types {
            guard let type = UTType(identifier), type.conforms(to: .image),
                  let data = pasteboard.data(forPasteboardType: identifier) else { continue }
            self.init(data: data, type: type)
            return
        }
        guard let data = pasteboard.image?.pngData() else { return nil }
        self.init(data: data, type: .png)
    }

    static func imageType(in provider: NSItemProvider) -> UTType? {
        provider.registeredTypeIdentifiers.lazy.compactMap { UTType($0) }.first { $0.conforms(to: .image) }
    }
}
