import UIKit

/// Live SSH terminal: UIKit owns the screen, floating controls, grid,
/// notices, and lists. Dictation (`SSHTerminalDictation`) and attachments
/// (`SSHTerminalAttachPicker`) type straight into the shell from the bottom
/// bar. The navigation bar stays hidden while this screen is on
/// top; Back, status, Herdr or Rex, and the … menu sit in a glass bar at the bottom
/// edge, below the grid, so they never cover a terminal row.
@MainActor
final class SSHTerminalViewController: UIViewController, NavigationBarHiding {
    /// Back and the actions float over the grid instead.
    var hidesNavigationBar: Bool { true }
    private(set) var channel: SSHTerminalChannel
    private let reconnect: () -> Void
    private let editHost: () -> Void
    /// Follows the terminal shown: the switcher changes it.
    private var hostLabel: String
    private weak var session: SSHTerminalConnectSession?
    /// Screenshot preview only: a server-scoped connection for dictation. The
    /// live app uses the window's root.
    private let dictationConnection: ServerConnection?
    /// How a pane of another Rex session opens: the connect session's own way
    /// unless the owner says otherwise (a preview with no host to dial).
    private let rexPaneOpener: ((RexPaneTarget) -> Void)?
    /// Screenshot preview only. A normal launch never sets this.
    var presentsStatusDetailOnAppear = false

    private(set) var gridView: SSHTerminalGridView?
    private let overlay = SSHTerminalPassthroughView()
    /// The bottom bar's container: Back at the leading edge, the one centred
    /// pill of buttons, and a Rex session's pane switcher at the trailing one.
    /// It ends at the keyboard layout guide, so with a docked keyboard up (and a
    /// broken connection, the one case that keeps the bar) it floats just above
    /// the keyboard.
    private let bottomBar = SSHTerminalPassthroughView()
    private var bottomBarHeight: NSLayoutConstraint?
    /// A Rex session's window minimap at the grid's top right. Its pane
    /// switcher is the bar's trailing pill (`rexPill`).
    private let rexMinimap = SSHTerminalRexMinimapView()
    /// The terminal shows a Rex session: the grid swipes (past the last pane
    /// that opens a new one) and takes VoiceOver's pane actions. The Rex
    /// control (`rexPill`) shows for every such session.
    private var rexSwipes = false
    /// The pane being opened (`createPane`), while one is. One at a time.
    private var newPaneTask: Task<Void, Never>?
    private let topStack = UIStackView()
    private let backPill = SSHTerminalBackPill()
    private let connectionBanner = SSHTerminalConnectionBannerView()
    private let inputBanner = SSHTerminalTextBannerView(identifier: "sshTerminal.inputNotice")
    private let pasteBanner = SSHTerminalTextBannerView(identifier: "sshTerminal.pasteNotice")
    private let openBanner = SSHTerminalTextBannerView(identifier: "sshTerminal.openNotice")
    private let noticeCard = SSHTerminalNoticeCardView()
    private let copyNotice = SSHTerminalCopyNoticeView()
    /// A take's words not typed yet, at the grid's bottom (or top, when the
    /// cursor's row is down there).
    private let dictationTail = SSHTerminalDictationTailView()
    private var dictationTailAtBottom: NSLayoutConstraint?
    private var dictationTailAtTop: NSLayoutConstraint?
    private let backToLive = JumpToBottomButton()
    private var backToLiveThemeID: ThemeID?
    private let statusGlyph = SSHTerminalStatusGlyphButton()
    /// The bottom bar's one centred pill (Settings > Terminal > Bottom
    /// Bar), between Back and the pane switcher.
    private lazy var barPill = SSHTerminalBarPill(status: statusGlyph)
    /// A Rex pane's one Rex control, bottom trailing.
    private let rexPill = SSHTerminalRexPanesPill()
    /// The bar's buttons on the keyboard bar (`SSHTerminalKeyStripView.showBar`),
    /// and the Rex control and status symbol there, which take its leftover room.
    private let keyboardBarButtons = SSHTerminalBarButtons()
    private let keyboardBarRexPanes = SSHTerminalRexPanesButton()
    private let keyboardBarStatus = SSHTerminalStatusGlyphButton()
    private let barStore: SSHTerminalBarStore
    private lazy var barLayout = barStore.layout
    private lazy var barCustomKeys = barStore.customKeys
    private lazy var rexPanelSettings = barStore.rexPanel
    /// What the bar drew on the last pass. The … menu offers its `menu`,
    /// so the menu opened now matches the bar on screen.
    private var barPlacement = SSHTerminalBarPlacement(bar: [], menu: [])
    /// The same for the keyboard bar, whose … menu offers this one's `menu`.
    private var keyboardBarPlacement = SSHTerminalBarPlacement(bar: [], menu: [])
    private var barLayoutObserver: NSObjectProtocol?
    /// The width and side insets the pill's capacity was last worked out for.
    private var barFit = SSHTerminalBarFit()
    /// The pill's room runs to the pane switcher while it shows, else to the edge.
    private var roomEndsAtPanes: NSLayoutConstraint?
    private var roomEndsAtEdge: NSLayoutConstraint?
    private var menuTitle: String?
    private let dictation: SSHTerminalDictation
    /// The take failure last shown as a notice, so each is shown once.
    private var shownDictationFailure: VoiceCaptureFailure?
    private let attachPicker = SSHTerminalAttachPicker()
    private let gridClip = UIView()
    private var gridBottom: NSLayoutConstraint?
    /// Rows the grid leaves free for the bottom bar, from the one rule in
    /// `SSHTerminalFloatingControls`: never with a keyboard up, so reconnecting
    /// never resizes the remote shell.
    private var bottomBarReserve: CGFloat {
        SSHTerminalFloatingControls.bottomBarReserve(keyboardUp: keyboardUp)
    }

    private var pendingPaste: String?
    private var pasteNotice: String?
    private var pasteNoticeTask: Task<Void, Never>?
    private var openNotice: String?
    private var openNoticeTask: Task<Void, Never>?
    /// What the open notice's Retry button runs, while that notice offers one.
    private var openNoticeRetry: (() -> Void)?
    /// The paired server's home folder, once known: the root every owner-host
    /// file path opens inside.
    private var pairedHome: String?
    private var pairedHomeTask: Task<Void, Never>?
    /// The Open or Browse Files Here lookup in flight, so a second choice can
    /// replace it and leaving the screen cancels it.
    private var openTask: Task<Void, Never>?
    /// Which open task is the newest, so an older one finishing late cannot
    /// clear the handle of the one that replaced it.
    private var openTaskGeneration = 0
    private var copyNoticeText: String?
    private var copyNoticeTask: Task<Void, Never>?
    private var lastCopies = 0
    private var detached = false
    /// A password prompt is up on the live screen (the grid's secure entry).
    private var secureEntryActive = false
    /// The Face ID prompt and send behind a tap on Fill Password, until it ends.
    private var passwordFillTask: Task<Void, Never>?
    /// The password prompt ended while that task was waiting on the person.
    private var passwordFillPromptEnded = false
    private var herdr = HerdrMonitor()
    private var rex: RexMonitor
    private var keymap = SSHTerminalKeymapLoader()
    private var keyboardUp = false
    private var controlsVisible = true
    /// Popped, swiped back, or covered by a push: the navigation bar belongs
    /// to the incoming screen and this screen's layout no longer sizes the shell.
    private var isLeaving = false
    private var keyboardTransition = 0
    private var resizeHoldTask: Task<Void, Never>?
    private var backSwipe: SSHTerminalBackSwipe?
    private var reconnectOnReturn = false
    private var attention = SSHTerminalAttention()
    private let attentionFeedback = SSHTerminalAttentionFeedback()
    private var shownNoticeKey: SSHTerminalNotice.Key?
    /// Each multiplexer's poll, keyed by the bar action that opens its overview.
    private var overviewTasks: [SSHTerminalBarAction: Task<Void, Never>] = [:]
    /// Rex's poll: what the Rex panel shows, the Back dot's Rex count, and how
    /// the Terminal page learns Rex is on this host (`makeRexMonitor`).
    private var rexPoll: Task<Void, Never>?
    private var keymapTask: Task<Void, Never>?
    private var keymapToken: String?
    /// The host's Ghostty colors, or the app theme where it has none.
    private var colorLoader: SSHTerminalColorLoader
    private var colorChoice: SSHTerminalColorChoice
    private var colorTask: Task<Void, Never>?
    private var colorToken: String?
    private var lastTerminalColors: SSHTerminalColorTheme?
    /// The registry closed this terminal while this screen was showing.
    private var sawClosedForBackground = false
    private var isOnScreen = false
    /// False while the pane this screen sits in is covered or parked
    /// (`PaneVisibility`): its view stays in the window, but nobody sees it.
    private var paneShown = true
    /// A divider beside this screen's pane is moving: the shell gets one
    /// resize when it comes to rest (`PaneLiveResizing`).
    private var paneResizing = false
    /// On screen and, in a pane, in a pane that shows: only then does the
    /// terminal take remote clipboard writes, keep its Rex neighbours live and
    /// take its pane back from another client, and poll its host.
    private var isSeen: Bool { isOnScreen && paneShown }
    /// Leaving was asked for since the session last showed a terminal.
    private var requestedFinish = false
    private var presentingOverview = false
    private var presentingStatusDetail = false
    private var reduceMotion = UIAccessibility.isReduceMotionEnabled
    private var lastThemeID: ThemeID?
    private var defaultsObserver: NSObjectProtocol?
    /// The Rex and Herdr experiments changing while this terminal is on screen.
    private var experimentObserver: NSObjectProtocol?
    private var reduceMotionObserver: NSObjectProtocol?
    private var keyboardObserver: NSObjectProtocol?

    init(
        channel: SSHTerminalChannel,
        reconnect: @escaping () -> Void,
        editHost: @escaping () -> Void,
        hostLabel: String = "",
        session: SSHTerminalConnectSession? = nil,
        dictationConnection: ServerConnection? = nil,
        rexPaneOpener: ((RexPaneTarget) -> Void)? = nil,
        barStore: SSHTerminalBarStore = SSHTerminalBarStore(),
        dictation: SSHTerminalDictation = SSHTerminalDictation()
    ) {
        self.rexPaneOpener = rexPaneOpener
        self.dictation = dictation
        self.barStore = barStore
        self.channel = channel
        self.reconnect = reconnect
        self.editHost = editHost
        self.hostLabel = hostLabel
        self.session = session
        self.dictationConnection = dictationConnection
        rex = Self.makeRexMonitor(for: session?.connectedProfile, hosts: session?.rexHosts)
        let profileID = session?.connectedProfile?.id
        let choice = profileID.map { SSHTerminalColorStore().choice(for: $0) } ?? .host
        colorChoice = choice
        colorLoader = SSHTerminalColorLoader(
            profileID: profileID, choice: choice,
            dark: ThemeRuntimeState.currentThemeID().preferredColorScheme != .light
        )
        super.init(nibName: nil, bundle: nil)
        attention.glyphFrame.rect = .zero
        statusGlyph.glyphFrame.rect = .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        barLayoutObserver = NotificationCenter.default.addObserver(
            forName: SSHTerminalBarStore.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadBarSettings() }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.colorChoiceChanged()
            }
        }
        reduceMotionObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reduceMotionChanged()
            }
        }
        experimentObserver = NotificationCenter.default.addObserver(
            forName: AppPreferences.Experiments.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.experimentChanged() }
        }
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
            let curve = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
            let end = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .zero
            let screen = notification.object as? UIScreen
            MainActor.assumeIsolated {
                self?.keyboardWillChange(endFrame: end, screen: screen, duration: duration, curve: curve)
            }
        }
        setNeedsUpdateProperties()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isOnScreen = true
        isLeaving = false
        gridView?.releaseResize()
        applyControlsVisibility(animation: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isOnScreen = true
        // Back from a screen the keyboard bar opened: its keyboard returns.
        setNeedsUpdateProperties()
        backSwipe?.uninstall()
        backSwipe = SSHTerminalBackSwipe(navigation: navigationController)
        // Remote clipboard writes apply only while this screen is in front.
        channel.isViewed = paneShown && AppScenePhase.shared.phase == .active
        // The panes beside the shown one stream while the screen shows them, so
        // a swipe slides in a pane that is already live.
        channel.rex?.isWarming = paneShown
        attentionFeedback.prepare()
        if presentsStatusDetailOnAppear, !presentingStatusDetail, programRollup != nil {
            presentsStatusDetailOnAppear = false
            showStatusDetail()
        }
        setNeedsUpdateProperties()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // A rotation, a resized iPad window, or a notch moving sides changes
        // how many middle buttons fit.
        if SSHTerminalBarFit(view) != barFit { setNeedsUpdateProperties() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        backSwipe?.uninstall()
        backSwipe = nil
        // A pop (Back or swipe) or a push has already changed the top screen.
        // Do not read isMovingFromParent here: while this screen presents a
        // sheet, reading it now leaves it false in viewDidDisappear.
        let leavingTop = navigationController.map { $0.topViewController !== self } ?? false
        guard leavingTop || isBeingDismissed else { return }
        isLeaving = true
        // The keyboard going down and the pop move this screen's layout
        // through sizes the shell must not get. Return sends the real size.
        resizeHoldTask?.cancel()
        gridView?.holdResize()
        channel.cancelPendingResize()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let leaving = isMovingFromParent || isBeingDismissed
        let coveredByPush = navigationController != nil && navigationController?.topViewController !== self
        // Herdr, status detail, and paste alerts cover this screen; stay viewed.
        // Swipe-back or a push over this screen still clears the clipboard gate
        // even if a modal is up: OSC 52 must not land after the user left.
        if presentedViewController != nil, !leaving, !coveredByPush { return }
        isOnScreen = false
        channel.isViewed = false
        // Off screen the terminal keeps its shown pane only: the neighbours'
        // streams go back to the host.
        channel.rex?.isWarming = false
        passwordFillTask?.cancel()
        pasteNoticeTask?.cancel()
        copyNoticeTask?.cancel()
        openNoticeTask?.cancel()
        pairedHomeTask?.cancel()
        pairedHomeTask = nil
        openTask?.cancel()
        openTask = nil
        stopOverviewPolls()
        keymapTask?.cancel()
        keymapTask = nil
        keymapToken = nil
        colorTask?.cancel()
        colorTask = nil
        colorToken = nil
        attentionFeedback.cancel()
        // Leaving the screen does not close the terminal: `SSHTerminalRegistry`
        // owns the channel, and Disconnect or the host's lifecycle ends it.
        guard leaving else { return }
        dictation.release()
        session?.showsTerminal = false
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
        if let reduceMotionObserver {
            NotificationCenter.default.removeObserver(reduceMotionObserver)
            self.reduceMotionObserver = nil
        }
        if let keyboardObserver {
            NotificationCenter.default.removeObserver(keyboardObserver)
            self.keyboardObserver = nil
        }
        if let barLayoutObserver {
            NotificationCenter.default.removeObserver(barLayoutObserver)
            self.barLayoutObserver = nil
        }
        if let experimentObserver {
            NotificationCenter.default.removeObserver(experimentObserver)
            self.experimentObserver = nil
        }
    }

    override func updateProperties() {
        super.updateProperties()
        if let session, let next = session.channel, next !== channel {
            if let profile = session.connectedProfile {
                hostLabel = profile.terminalLabel(folder: session.folder, rexPane: session.rexPane)
            }
            replaceChannel(next)
        }
        // A Rex terminal is named for the pane it shows now.
        if let shown = channel.rex?.shownTarget, let profile = session?.connectedProfile {
            hostLabel = profile.terminalLabel(folder: nil, rexPane: shown)
        }
        let connected = channel.connected
        let connecting = channel.connecting
        let networkChanged = channel.networkChanged
        // A Rex terminal whose connection dropped stays up while it opens again.
        let rexReconnecting = channel.connected && channel.rex?.state.reconnecting == true
        _ = channel.reason
        _ = channel.inputNotice
        _ = channel.title
        _ = channel.copies
        _ = channel.lastCopyLength
        _ = channel.command
        _ = channel.closedForBackground
        _ = channel.programStatus.records
        _ = channel.programStatus.root
        _ = channel.progress.report
        _ = channel.workingDirectory
        _ = channel.alerts.notification
        _ = channel.alerts.bell
        for action in SSHTerminalBarAction.overviews {
            _ = overview(action)?.available
            _ = overview(action)?.needsAttention
        }
        _ = rexWaiting
        _ = keymap.actions
        _ = keymap.profile
        _ = keymap.userFile
        _ = colorLoader.resolution
        let dictationShown = dictation.presentation
        noticeDictationFailure(dictation.captureFailure)
        let locked = AppLockService.shared.isLocked
        let phase = AppScenePhase.shared.phase
        let themeID = AppRootEnvironment.near(self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        _ = AppRootEnvironment.near(self)?.themeStore.appTheme

        let terminalColors = colorLoader.theme
        // One palette for everything drawn over the grid: Oppi's theme when
        // it is on the terminal's light/dark side, else the built-in that is.
        let chromeID = SSHTerminalColorTheme.chromeTheme(themeID, colors: terminalColors)
        if lastThemeID != themeID || lastTerminalColors != terminalColors {
            lastThemeID = themeID
            lastTerminalColors = terminalColors
            applyTheme(chromeID, colors: terminalColors)
        }
        if channel.copies != lastCopies {
            lastCopies = channel.copies
            if lastCopies > 0 { showCopyNotice() }
        }
        // A remote clipboard write is applied only while this screen is in front.
        channel.isViewed = isSeen && phase == .active
        if channel.closedForBackground, isOnScreen, !sawClosedForBackground {
            reconnectOnReturn = true
        }
        sawClosedForBackground = channel.closedForBackground
        // A notice asking for Retry cannot be retried on a connection that went
        // away, so it leaves with it.
        if !connected, openNoticeRetry != nil {
            openNotice = nil
            openNoticeRetry = nil
            openNoticeTask?.cancel()
            openNoticeTask = nil
        }
        if phase == .active { reconnectAfterReturn() }
        if !locked { reconnectAfterReturn() }
        // This pass re-runs on every update; leave once per showing. A session
        // that shows a terminal again re-arms the request.
        if let session {
            if session.showsTerminal {
                requestedFinish = false
            } else if isOnScreen, !isMovingFromParent, !requestedFinish {
                requestedFinish = true
                Router.finish(self)
            }
        }

        navigationItem.title = channel.title.isEmpty ? "Terminal" : channel.title
        updatePolling()
        refreshPairedHome()
        updateFloatingControls(themeID: chromeID)
        updateBanners(
            connecting: connecting || rexReconnecting, connected: connected, networkChanged: networkChanged, themeID: chromeID
        )
        updateNotice(themeID: chromeID)
        updateCopyAndLive(themeID: chromeID)
        updateDictationTail(themeID: chromeID)
        for buttons in [barPill.buttons, keyboardBarButtons] {
            buttons.dictate.apply(
                presentation: dictationShown,
                colors: ComposerThemeColors(palette: chromeID.palette, terminal: terminalColors)
            )
        }
        takeTerminalKeyboard()
        updatePasswordFill(connected: connected)
        if let gridView {
            gridView.setKeyActions(keymap.actions)
            gridView.showModifiers()
            gridView.applyTheme(chromeID, colors: terminalColors)
            gridView.needsPaint = true
        }
        attentionFeedback.apply(
            notice: visibleNotice,
            bell: channel.alerts.bell
        ) { [weak self] key in
            self?.attention.dismiss(key)
            self?.setNeedsUpdateProperties()
        }
    }

    // MARK: - Layout

    private func buildLayout() {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        topStack.axis = .vertical
        topStack.alignment = .center
        topStack.spacing = 8
        topStack.translatesAutoresizingMaskIntoConstraints = false

        backPill.button.addAction(UIAction { [weak self] _ in self?.goBack() }, for: .touchUpInside)
        barPill.buttons.perform = { [weak self] slot in self?.perform(slot) }
        keyboardBarButtons.perform = { [weak self] slot in self?.perform(slot) }
        barPill.deliverPaste = { [weak self] items in self?.gridView?.paste(itemProviders: items) }
        dictation.type = { [weak self] text in self?.gridView?.typeDictation(text) }
        dictation.startFailed = { [weak self] message in
            self?.errorAlerts.show(title: "Couldn't Start Dictation", message: message)
        }
        attachPicker.presenter = self
        attachPicker.draftStore = { [weak self] in self.flatMap { AppRootEnvironment.near($0)?.composerDraftStore } }
        attachPicker.deliver = { [weak self] attachments in self?.attach(attachments) }
        attachPicker.failed = { [weak self] message in self?.presentPasteFailure(message) }
        attachPicker.willPresent = { [weak self] in self?.leaveKeyboardForSheet() }
        attachPicker.closed = { [weak self] in self?.sheetClosed() }
        barPill.buttons.attach.menu = attachPicker.menu()
        keyboardBarButtons.attach.menu = barPill.buttons.attach.menu
        connectionBanner.onReconnect = { [weak self] in self?.reconnect() }
        noticeCard.onDismiss = { [weak self] key in
            self?.attention.dismiss(key)
            self?.setNeedsUpdateProperties()
        }
        noticeCard.onFrameChange = { [weak self] in self?.attention.cardFrame = $0 }
        backToLive.accessibilityIdentifier = "sshTerminal.backToLive"
        backToLive.accessibilityLabel = "Back to Live"
        backToLive.onTap = { [weak self] in self?.gridView?.backToLive() }
        statusGlyph.onOpen = { [weak self] in self?.showStatusDetail() }
        keyboardBarStatus.onOpen = { [weak self] in self?.showStatusDetail() }

        connectionBanner.isHidden = true
        inputBanner.isHidden = true
        pasteBanner.isHidden = true
        openBanner.isHidden = true
        noticeCard.isHidden = true
        copyNotice.isHidden = true
        topStack.addArrangedSubview(connectionBanner)
        topStack.addArrangedSubview(inputBanner)
        topStack.addArrangedSubview(pasteBanner)
        topStack.addArrangedSubview(openBanner)
        topStack.addArrangedSubview(noticeCard)
        connectionBanner.translatesAutoresizingMaskIntoConstraints = false
        noticeCard.translatesAutoresizingMaskIntoConstraints = false
        inputBanner.translatesAutoresizingMaskIntoConstraints = false
        pasteBanner.translatesAutoresizingMaskIntoConstraints = false
        openBanner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            connectionBanner.widthAnchor.constraint(equalTo: topStack.widthAnchor),
            inputBanner.widthAnchor.constraint(equalTo: topStack.widthAnchor),
            pasteBanner.widthAnchor.constraint(equalTo: topStack.widthAnchor),
            openBanner.widthAnchor.constraint(equalTo: topStack.widthAnchor),
            noticeCard.widthAnchor.constraint(equalTo: topStack.widthAnchor),
        ])

        // Under the banners and the notice card: a notice can cover the
        // minimap for the moment it shows.
        overlay.addSubview(rexMinimap)
        overlay.addSubview(topStack)
        overlay.addSubview(copyNotice)
        overlay.addSubview(dictationTail)
        overlay.addSubview(backToLive)
        copyNotice.translatesAutoresizingMaskIntoConstraints = false
        backToLive.translatesAutoresizingMaskIntoConstraints = false
        dictationTail.isHidden = true
        let tailAtBottom = dictationTail.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -8)
        dictationTailAtBottom = tailAtBottom
        dictationTailAtTop = dictationTail.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 8)
        NSLayoutConstraint.activate([
            dictationTail.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            // Clear of Back to Live at the bottom trailing corner, on both sides.
            dictationTail.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, constant: -120),
            dictationTail.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            tailAtBottom,
        ])
        NSLayoutConstraint.activate([
            // Notices float at the grid's top edge and keep the bar's place
            // out of the way: they never change the grid's size.
            rexMinimap.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 8),
            topStack.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 8),
            topStack.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            topStack.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            copyNotice.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            copyNotice.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -8),
            backToLive.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -8),
            backToLive.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -8),
        ])

        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(backPill)
        bottomBar.addSubview(barPill)
        bottomBar.addSubview(rexPill)
        // The pill centers on the screen, so it grows the same distance each
        // way, and moves off center only when it would come closer than 8 pt
        // to Back or to what is at the trailing end (the pane switcher's pill
        // while it shows, else the screen's edge): its edges must stay in the
        // room between them, which wins over the centering
        // (`SSHTerminalBottomBar.pillMinX` is the same rule as a function).
        let room = UILayoutGuide()
        bottomBar.addLayoutGuide(room)
        let centered = barPill.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor)
        centered.priority = .defaultHigh
        // Below required: the capacity keeps the pill inside the room, and a
        // bar too narrow for "…" alone should crowd, not break constraints.
        let notBeforeRoom = barPill.leadingAnchor.constraint(greaterThanOrEqualTo: room.leadingAnchor)
        notBeforeRoom.priority = .required - 1
        let notPastRoom = barPill.trailingAnchor.constraint(lessThanOrEqualTo: room.trailingAnchor)
        notPastRoom.priority = .required - 1
        let endsAtPanes = room.trailingAnchor.constraint(equalTo: rexPill.leadingAnchor, constant: -SSHTerminalBottomBar.pillGap)
        let endsAtEdge = room.trailingAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -SSHTerminalBottomBar.sideInset
        )
        roomEndsAtPanes = endsAtPanes
        roomEndsAtEdge = endsAtEdge
        NSLayoutConstraint.activate([
            room.leadingAnchor.constraint(equalTo: backPill.trailingAnchor, constant: SSHTerminalBottomBar.pillGap),
            centered,
            notBeforeRoom,
            notPastRoom,
            barPill.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: SSHTerminalBottomBar.topInset),
        ])

        // Hidden until a switch shows it (`SSHTerminalRexMinimapView`).
        // The minimap's cells, the switcher's menu, and the swipe all show a
        // pane through `showPane`.
        rexMinimap.select = { [weak self] block in self?.showPane(block) }
        for button in [rexPill.button, keyboardBarRexPanes] {
            button.addAction(UIAction { [weak self] _ in self?.showRexPanel() }, for: .touchUpInside)
            button.installMenu(
                state: { [weak self] in self?.channel.rex?.state },
                select: { [weak self] block in self?.showPane(block) },
                newPane: { [weak self] in self?.gridView?.createPane() }
            )
        }
        gridClip.translatesAutoresizingMaskIntoConstraints = false
        gridClip.clipsToBounds = true
        view.addSubview(gridClip)
        view.addSubview(overlay)
        view.addSubview(bottomBar)
        let controlsInset = SSHTerminalBottomBar.sideInset
        // The room runs to the screen's edge until the pane switcher shows; this
        // one needs the bar in the view, for the safe area it names.
        endsAtEdge.isActive = true
        let barHeight = bottomBar.heightAnchor.constraint(equalToConstant: SSHTerminalBottomBar.shownHeight)
        bottomBarHeight = barHeight
        NSLayoutConstraint.activate([
            // Clear of a landscape notch: the grid runs edge to edge, the
            // controls stay inside the safe area.
            backPill.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: controlsInset),
            backPill.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: SSHTerminalBottomBar.topInset),
            rexPill.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -controlsInset),
            rexPill.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: SSHTerminalBottomBar.topInset),
            // Clear of a landscape notch, like the bar's pills.
            rexMinimap.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // The guide rests on the bottom safe area and rides the keyboard.
            bottomBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            barHeight,
            gridClip.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            gridClip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gridClip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gridClip.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        installGrid(makeGrid())
    }

    /// The grid ends above the bottom bar. The clip hides what a pane slide
    /// moves past the grid's edges.
    private func installGrid(_ grid: SSHTerminalGridView) {
        gridView = grid
        gridClip.addSubview(grid)
        let bottom = grid.bottomAnchor.constraint(
            equalTo: view.keyboardLayoutGuide.topAnchor,
            constant: -bottomBarReserve
        )
        gridBottom = bottom
        let overlayBottom = overlay.bottomAnchor.constraint(equalTo: grid.bottomAnchor)
        overlayBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: gridClip.topAnchor),
            grid.leadingAnchor.constraint(equalTo: gridClip.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: gridClip.trailingAnchor),
            bottom,
            overlay.topAnchor.constraint(equalTo: grid.topAnchor),
            overlayBottom,
            overlay.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
        ])
    }

    private func makeGrid() -> SSHTerminalGridView {
        let grid = SSHTerminalGridView(
            channel: channel,
            paste: { [weak self] in self?.requestPaste($0) },
            followChanged: { [weak self] following in
                self?.detached = !following
                self?.setNeedsUpdateProperties()
            }
        )
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.keyboardDismissed = { [weak self] in self?.keyboardWasHidden() }
        grid.keyboardOwnershipChanged = { [weak self] in self?.keyboardOwnershipChanged() }
        grid.goBack = { [weak self] in self?.goBack() }
        grid.secureInputChanged = { [weak self] in self?.secureInputChanged($0) }
        grid.fillPassword = { [weak self] in self?.fillPassword() }
        grid.pasteImage = { [weak self] in self?.pasteImage($0) }
        grid.openTargetForHeldCell = { [weak self] held in self?.heldOpenTarget(held) }
        grid.open = { [weak self] target, placement in self?.open(target, placement: placement) }
        grid.requestsKeyboard = { [weak self] in self?.showTerminalKeyboard() }
        grid.paneStepping = paneStepping
        grid.paneTransition.onSwitching = { [weak self] in self?.rexMinimap.setSwitching($0) }
        return grid
    }

    private func replaceChannel(_ next: SSHTerminalChannel) {
        // A terminal switched away from stays open in the registry; it is no
        // longer in front, so its remote clipboard writes are dropped.
        channel.isViewed = false
        channel.rex?.isWarming = false
        channel.cancelPendingResize()
        stopOverviewPolls()
        keymapTask?.cancel()
        colorTask?.cancel()
        keymapTask = nil
        keymapToken = nil
        colorTask = nil
        colorToken = nil
        // The switcher can show another host's terminal: its colors, choice
        // and cache are that host's, not the one this screen opened with.
        let hostID = session?.connectedProfile?.id
        if hostID != colorLoader.profileID {
            colorChoice = hostID.map { SSHTerminalColorStore().choice(for: $0) } ?? .host
            colorLoader = SSHTerminalColorLoader(profileID: hostID, choice: colorChoice, dark: appIsDark)
        }
        herdr = HerdrMonitor()
        rex = Self.makeRexMonitor(for: session?.connectedProfile, hosts: session?.rexHosts)
        keymap = SSHTerminalKeymapLoader()
        attention = SSHTerminalAttention()
        shownNoticeKey = nil
        pasteNotice = nil
        copyNoticeText = nil
        openNotice = nil
        openNoticeRetry = nil
        pairedHome = nil
        pairedHomeTask?.cancel()
        pairedHomeTask = nil
        openTask?.cancel()
        openTask = nil
        detached = false
        passwordFillTask?.cancel()
        passwordFillTask = nil
        secureEntryActive = false
        sawClosedForBackground = false
        reconnectOnReturn = false
        channel = next
        channel.isViewed = isSeen && AppScenePhase.shared.phase == .active
        // Not this terminal's copies: a swap shows no notice for the last one's.
        lastCopies = next.copies
        // The glyph's hold, ring, and last root belong to the terminal left.
        statusGlyph.reset()
        // Another terminal's switcher and swipe are not this one's; the next
        // pass shows this one's.
        rexSwipes = false
        newPaneTask?.cancel()
        newPaneTask = nil
        rexMinimap.reset()
        // A take belongs to the terminal it started in.
        dictation.release()
        gridView?.removeFromSuperview()
        installGrid(makeGrid())
    }

    /// The clock and battery read against the terminal's background, which can
    /// be on the other side of light/dark from the app's theme. The default is
    /// today's: follow the app's appearance until the first theme is applied.
    private var terminalStatusBarStyle = UIStatusBarStyle.default
    override var preferredStatusBarStyle: UIStatusBarStyle { terminalStatusBarStyle }

    /// The terminal's own background when the host's theme sets one, so the
    /// screen, its bars and its pills read as one surface with the grid.
    private func applyTheme(_ themeID: ThemeID, colors: SSHTerminalColorTheme?) {
        let theme = themeID.appTheme
        view.backgroundColor = colors?.background.map(UIColor.init) ?? theme.bg.primary
        let dark = SSHTerminalColorTheme.isDark(background: colors?.background, fallback: themeID.preferredColorScheme != .light)
        overrideUserInterfaceStyle = dark ? .dark : .light
        let style: UIStatusBarStyle = dark ? .lightContent : .darkContent
        if terminalStatusBarStyle != style {
            terminalStatusBarStyle = style
            setNeedsStatusBarAppearanceUpdate()
        }
    }

    /// Oppi's own appearance, which picks the side of a `light:`/`dark:` pair.
    private var appIsDark: Bool {
        (lastThemeID ?? ThemeRuntimeState.currentThemeID()).preferredColorScheme != .light
    }

    /// The theme for chrome over the grid; see `updateProperties`.
    private var chromeTheme: ThemeID {
        SSHTerminalColorTheme.chromeTheme(lastThemeID ?? ThemeRuntimeState.currentThemeID(), colors: lastTerminalColors)
    }

    private func colorChoiceChanged() {
        guard let id = session?.connectedProfile?.id else { return }
        let choice = SSHTerminalColorStore().choice(for: id)
        guard choice != colorChoice else { return }
        colorChoice = choice
        colorLoader.use(choice, dark: appIsDark)
        setNeedsUpdateProperties()
    }

    // MARK: - Floating controls

    /// The … menu's header names the screen: the shell's title when it
    /// set one, else the host, followed by the shell's folder when it reported
    /// one (OSC 7). The navigation bar that showed it is hidden.
    private func installMenu(title: String, folder: String) {
        let header = SSHTerminalMenuHeader.text(title: title, folder: folder)
        guard header != menuTitle else { return }
        menuTitle = header
        barPill.more.menu = UIMenu(
            title: header,
            children: [UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else { return completion([]) }
                completion(self.overflowElements(offering: self.barPlacement.menu))
            }]
        )
        keyboardBarButtons.more.menu = UIMenu(
            title: header,
            children: [UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else { return completion([]) }
                completion(self.overflowElements(offering: self.keyboardBarPlacement.menu))
            }]
        )
    }

    /// The switcher's menu is built when it opens, so it lists the terminals
    /// open then, with the one on screen checked. Installed once.
    private func installSwitcherMenu() {
        guard barPill.buttons.switcher.menu == nil else { return }
        barPill.buttons.switcher.menu = UIMenu(children: [switcherElements()])
        keyboardBarButtons.switcher.menu = barPill.buttons.switcher.menu
    }

    /// The open terminals, resolved when the menu opens. The switcher button and
    /// the … menu's Switch Terminal (when that button is hidden) both show it.
    private func switcherElements() -> UIMenuElement {
        UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self, let session = self.session else { return completion([]) }
            let terminals = session.openTerminals()
            let items = SSHTerminalSwitcher.items(terminals: terminals, current: self.channel)
            completion(SSHTerminalSwitcher.menuElements(
                items: items,
                themeID: self.lastThemeID ?? ThemeRuntimeState.currentThemeID()
            ) { [weak self] index in
                guard terminals.indices.contains(index) else { return }
                self?.session?.show(terminals[index])
            })
        }
    }

    /// The … menu: the bar's actions that have no button now (turned off, or
    /// no room) on the surface it serves (`offering`, that placement's
    /// `menu`), in the layout's order, then the host's commands, then
    /// Customize Bar. Inline groups draw the separators.
    private func overflowElements(offering: [SSHTerminalBarSlot]) -> [UIMenuElement] {
        var groups: [UIMenuElement] = []
        let hidden = offering.map(menuElement(for:))
        if !hidden.isEmpty { groups.append(UIMenu(options: .displayInline, children: hidden)) }
        var items: [UIMenuElement] = []
        if channel.connected, let route = channel.rex?.route {
            // How this Rex terminal reaches Rex; information, not an action.
            let info = UIAction(title: route.label, image: UIImage(systemName: "network"), attributes: .disabled) { _ in }
            info.accessibilityIdentifier = "sshTerminal.menu.rexRoute"
            items.append(info)
        }
        // A Rex reached over Tailscale alone has no saved host to edit.
        if session?.currentProfile?.rexTailnet == nil {
            items.append(UIAction(title: "Edit Host", image: UIImage(systemName: "pencil")) { [weak self] _ in
                self?.editHost()
            })
        }
        if channel.connected {
            items.append(UIAction(
                title: "Disconnect",
                image: UIImage(systemName: "xmark"),
                attributes: .destructive
            ) { [weak self] _ in
                self?.channel.close(reason: "Closed by you.")
            })
        } else if !channel.connecting {
            items.append(UIAction(title: "Reconnect", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.reconnect()
            })
        }
        groups.append(UIMenu(options: .displayInline, children: items))
        let customize = UIAction(
            title: String(localized: "Customize Bar…"),
            image: UIImage(systemName: "slider.horizontal.3")
        ) { [weak self] _ in self?.customizeBar() }
        customize.accessibilityIdentifier = "sshTerminal.menu.customize"
        groups.append(customize)
        return groups
    }

    private func menuElement(for slot: SSHTerminalBarSlot) -> UIMenuElement {
        let image: UIImage? = switch (slot.agentRole, slot.content) {
        case (.send, _): UIImage(systemName: ComposerPrimaryActionLook.sendSymbol)
        case (.stop, _): UIImage(systemName: ComposerPrimaryActionLook.stopSymbol)
        case (nil, .action(let action)): action.image()
        case (nil, .customKey), (nil, .shortcut): UIImage(systemName: "keyboard")
        }
        if case .action(.switcher) = slot.content {
            let menu = UIMenu(title: slot.title, image: image, children: [switcherElements()])
            menu.accessibilityIdentifier = slot.menuIdentifier
            return menu
        }
        if case .action(.attach) = slot.content {
            let menu = UIMenu(title: slot.title, image: image, children: attachPicker.menu().children)
            menu.accessibilityIdentifier = slot.menuIdentifier
            return menu
        }
        // A shortcut's menu title carries its key, as its bar button's cap does.
        var title = slot.title
        if case .shortcut(let shortcut) = slot.content { title += " (\(shortcut.keyLabel))" }
        let item = UIAction(
            title: title,
            image: image,
            attributes: slot.sendsKeys && !canSendKeys ? .disabled : []
        ) { [weak self] _ in self?.perform(slot) }
        item.accessibilityIdentifier = slot.menuIdentifier
        return item
    }

    /// What the bar offers this terminal now (`SSHTerminalBarOffer`): the one
    /// owner the bar, the … menu, and VoiceOver read, from the multiplexer, the
    /// hosts this screen reaches, the program in front, its custom keys and its
    /// shortcuts. One that could only fail is neither drawn nor in the menu.
    private func barOffer(openTerminals: Int) -> SSHTerminalBarOffer {
        SSHTerminalBarOffer(
            context: barContext,
            overviews: Set(SSHTerminalBarAction.overviews.filter { overview($0)?.available == true }),
            openTerminals: openTerminals,
            // The Files browser over this terminal's folder needs the host to
            // report one and to be a paired Oppi server.
            canBrowseFiles: !channel.workingDirectory.isEmpty && pairedServer != nil,
            // Dictation needs the paired server (its engine setting and
            // dictionary) and the microphone, which a Live Voice call holds.
            canDictate: SSHTerminalBarOffer.canDictate(
                available: serverConnection() != nil
                    && ComposerShared.dictation(dictation.manager, near: viewIfLoaded) != nil,
                secureInput: secureEntryActive,
                dictating: dictating
            ),
            // Attachments are saved on the host over SSH, which a Rex reached
            // over Tailscale alone does not have.
            canAttach: channel.sideCommandsUnavailable == nil,
            program: keymapProgram,
            customKeys: barCustomKeys,
            shortcuts: keymap.actions,
            agentKeys: SSHTerminalAgentKeys(
                root: channel.programStatus.liveRoot, app: channel.programStatus.app(of: ""), interrupt: keymap.interrupt
            )
        )
    }

    /// Which multiplexer this terminal belongs to: the owner of what the bar,
    /// the … menu, and Customize Bar leave out.
    private var barContext: SSHTerminalBarContext {
        SSHTerminalBarContext(isRexPane: channel.rex != nil, command: channel.command)
    }

    private var canSendKeys: Bool { channel.connected && !channel.inputClosed }

    /// This terminal's take is starting, listening, or finishing: Dictate is
    /// pinned to the bar that shows, so the take always has a visible stop.
    private var dictating: Bool {
        let shown = dictation.presentation
        return shown.isRecording || shown.isPreparing || shown.isProcessing
    }

    /// The keyboard bar is on screen: above a docked keyboard (the grid is the
    /// screen's only text input), or at the bottom edge under a floating one,
    /// which `keyboardUp` does not count, while the grid holds the keyboard.
    private var accessoryShown: Bool { keyboardUp || gridView?.isFirstResponder == true }

    private var keyboardBarCarriesBar: Bool {
        SSHTerminalKeyboardBar.carriesBar(accessoryShown: accessoryShown, connected: channel.connected)
    }

    private func serverConnection() -> ServerConnection? {
        dictationConnection ?? AppRootEnvironment.near(self)?.windowConnectionOrStandIn
    }

    /// One owner for a bar button, whether it came from its button, VoiceOver,
    /// or the … menu.
    private func perform(_ slot: SSHTerminalBarSlot) {
        switch slot.content {
        case .action(let action):
            switch action {
            case .keyboard: showTerminalKeyboard()
            case .dictate:
                let connection = serverConnection()
                Task { [weak self] in await self?.dictation.toggle(connection: connection) }
            case .attach: break // A menu, not an action.
            case .escape, .interrupt, .tab, .up, .down, .enter:
                channel.keys(slot.strokes)
            case .paste: break // The system paste control delivers through barPill.deliverPaste.
            case .browseFiles: browseFilesHere()
            case .herdr: showOverview(action)
            case .switcher: break // A menu, not an action.
            }
        case .customKey, .shortcut:
            channel.keys(slot.strokes)
        }
    }

    /// The saved layout, custom keys, and Rex panel choices, read again when
    /// Bottom Bar changes any of them.
    private func reloadBarSettings() {
        barLayout = barStore.layout
        barCustomKeys = barStore.customKeys
        rexPanelSettings = barStore.rexPanel
        setNeedsUpdateProperties()
    }

    /// What the Rex pane switcher's icon says (`SSHTerminalRexPillStatus`): the
    /// shown pane's program status and OSC 9;4 progress, and how many other
    /// panes need you; none of it when the person turned it off.
    private func rexPillStatus(headline: SessionStatusKind?, progress: SSHTerminalProgressReport?) -> SSHTerminalRexPillStatus {
        guard rexPanelSettings.showsStatusOnIcon else { return .none }
        let state = channel.rex?.state
        return SSHTerminalRexPillStatus(
            // The terminal's own OSC 7501 reports, else what Rex reports for the pane.
            headline: headline ?? state?.panes.first { $0.blockID == state?.shown }?.status,
            progress: progress,
            needsYou: rex.failure == nil
                ? SSHTerminalRexPanelContent.needsYou(state: state, snapshot: rex.snapshot, sessionID: channel.rex?.sessionID) : 0
        )
    }

    /// Customize for the bottom bar (Settings > Terminal > Bottom Bar), as a
    /// sheet over the terminal.
    private func customizeBar() {
        leaveKeyboardForSheet()
        SSHTerminalBarSettingsViewController(context: barContext).presentSheet(
            from: self, detents: [.large()], onDismiss: { [weak self] in self?.sheetClosed() }
        )
    }

    private func updateFloatingControls(themeID: ThemeID) {
        let rollup = programRollup
        let headline = rollup?.headline
        let progress = channel.progress.report
        // A Rex pane draws its program's status on the pane switcher's icon, not
        // as a symbol of its own in the bar's pill.
        let showsStatus = (headline != nil || progress != nil) && barContext.showsProgramStatus
        if showsStatus {
            statusGlyph.apply(
                status: headline,
                summary: rollup?.summaryText ?? "",
                themeID: themeID,
                reduceMotion: reduceMotion,
                root: channel.programStatus.root.map { .init(state: $0.state, revision: $0.revision) },
                progress: progress
            )
            attention.glyphFrame.rect = statusGlyph.glyphFrame.rect
        }
        let foreground = lastTerminalColors?.foreground.map(UIColor.init)
        let tint = foreground ?? themeID.palette.ui.fg
        let openTerminals = session?.openTerminals().count ?? 0
        barFit = SSHTerminalBarFit(view)
        // The Rex pane switcher's pill holds the room at the trailing end only
        // while it shows; the pill is centred in what is left.
        let rexPanesShown = channel.rex != nil
        let animates = !reduceMotion && isOnScreen && view.window != nil
        if roomEndsAtPanes?.isActive != rexPanesShown {
            roomEndsAtEdge?.isActive = !rexPanesShown
            roomEndsAtPanes?.isActive = rexPanesShown
            if animates {
                UIView.animate(withDuration: SSHTerminalBarPill.changeDuration, delay: 0, options: [.beginFromCurrentState]) {
                    self.bottomBar.layoutIfNeeded()
                }
            }
        }
        let offer = barOffer(openTerminals: openTerminals)
        let background = lastTerminalColors?.background.map(UIColor.init) ?? themeID.palette.ui.bg
        barPlacement = offer.placement(
            layout: barLayout,
            capacity: SSHTerminalBottomBar.capacity(
                width: view.bounds.width,
                safeInsets: view.safeAreaInsets,
                rexPanesShown: rexPanesShown,
                // The status symbol, when a program has reported, and ….
                fixedItems: (showsStatus ? 1 : 0) + 1
            ),
            dictating: dictating
        )
        barPill.apply(
            themeID: themeID,
            waiting: overviewsWaiting,
            openTerminals: openTerminals,
            tint: tint,
            background: background,
            keysEnabled: canSendKeys
        )
        barPill.show(barPlacement.bar, showsStatus: showsStatus, animated: animates)
        installSwitcherMenu()
        rexPill.apply(
            state: channel.rex?.state, tint: tint, status: rexPillStatus(headline: headline, progress: progress),
            themeID: themeID, reduceMotion: reduceMotion
        )
        if rexPanesShown, headline != nil || progress != nil { attention.glyphFrame.rect = rexPill.button.glyphFrame.rect }
        backPill.apply(themeID: themeID, attentionPending: attentionPending(), foreground: lastTerminalColors?.foreground.map(UIColor.init))
        updateKeyboardBar(
            offer: offer, themeID: themeID, tint: tint, background: background, openTerminals: openTerminals,
            showsStatus: showsStatus, rexStatus: rexPillStatus(headline: headline, progress: progress)
        )
        updateRexPanes(themeID: themeID)
        installMenu(
            title: SSHTerminalMenuHeader.name(
                shellTitle: channel.title, hostLabel: hostLabel,
                hostName: session?.connectedProfile?.endpointLabel, shellFolder: channel.workingDirectory
            ),
            folder: channel.workingDirectory
        )
        applyControlsVisibility(animation: .init(duration: 0.2, options: [.curveEaseInOut, .beginFromCurrentState]))
    }

    /// The keyboard bar's share of the pass: while it carries the bar, the
    /// same offer and layout placed at its capacity, without what the keyboard
    /// already has; then the Rex control and the status symbol in what room is
    /// left (they never displace a chosen button). Otherwise it is keys only.
    private func updateKeyboardBar(
        offer: SSHTerminalBarOffer,
        themeID: ThemeID,
        tint: UIColor,
        background: UIColor,
        openTerminals: Int,
        showsStatus: Bool,
        rexStatus: SSHTerminalRexPillStatus
    ) {
        guard let gridView else { return }
        guard keyboardBarCarriesBar else {
            keyboardBarPlacement = SSHTerminalBarPlacement(bar: [], menu: [])
            gridView.showKeyboardBar(.init(), buttons: keyboardBarButtons)
            return
        }
        // Back has a dock of its own on regular width; on compact the edge
        // swipe and VoiceOver's scrub go back, and its dot moves to ….
        let showsBack = AdaptiveWidth.isWide(traitCollection)
        let capacity = SSHTerminalKeyboardBar.capacity(
            width: view.bounds.width, safeInsets: view.safeAreaInsets, showsBack: showsBack
        )
        keyboardBarPlacement = offer.placement(
            layout: barLayout, capacity: capacity, surface: .keyboardBar, dictating: dictating
        )
        keyboardBarButtons.apply(
            themeID: themeID, waiting: overviewsWaiting, openTerminals: openTerminals, tint: tint,
            background: background, keysEnabled: canSendKeys, traits: traitCollection
        )
        var room = capacity - keyboardBarPlacement.bar.count
        var extras: [UIView] = []
        if let state = channel.rex?.state, room > 0 {
            keyboardBarRexPanes.apply(state: state, tint: tint, status: rexStatus, themeID: themeID, reduceMotion: reduceMotion)
            extras.append(keyboardBarRexPanes)
            room -= 1
            if rexStatus.headline != nil || rexStatus.progress != nil {
                attention.glyphFrame.rect = keyboardBarRexPanes.glyphFrame.rect
            }
        }
        if showsStatus, room > 0 {
            let rollup = programRollup
            keyboardBarStatus.apply(
                status: rollup?.headline,
                summary: rollup?.summaryText ?? "",
                themeID: themeID,
                reduceMotion: reduceMotion,
                root: channel.programStatus.root.map { .init(state: $0.state, revision: $0.revision) },
                progress: channel.progress.report
            )
            extras.append(keyboardBarStatus)
            attention.glyphFrame.rect = keyboardBarStatus.glyphFrame.rect
        }
        gridView.showKeyboardBar(
            .init(
                slots: keyboardBarPlacement.bar,
                extras: extras,
                showsMore: true,
                showsBack: showsBack,
                attentionPending: attentionPending(),
                attentionColor: themeID.palette.ui.orange
            ),
            buttons: keyboardBarButtons
        )
    }

    /// Puts the pane the session shows on the grid, unless a slide is running
    /// (it presents its own end). Idempotent.
    private func reconcileShownPane() {
        guard gridView?.paneTransition.phase == .idle else { return }
        gridView?.presentShownPane()
    }

    /// A Rex terminal's minimap and swipe. The swipe works for every session
    /// (past the last pane it opens a new one); the minimap is available only
    /// for a window with more than one pane, and shows only while a switch runs.
    private func updateRexPanes(themeID: ThemeID) {
        let rex = channel.rex?.state
        let swipes = channel.rex != nil
        // A session that arrives (or reconnects) while this screen is up warms
        // its neighbours too; idempotent, so every pass may ask.
        channel.rex?.isWarming = isSeen && AppScenePhase.shared.phase == .active
        // One owner of "the pane on screen is the pane typing reaches": a switch
        // with no slide of its own (a pane closed in Rex, a refusal recovered, a
        // new pane) lands here. A slide owns the pixels until it ends.
        channel.rex?.onShown = { [weak self] _ in self?.reconcileShownPane() }
        reconcileShownPane()
        if let rex {
            let background = lastTerminalColors?.background.map(UIColor.init) ?? themeID.palette.ui.bg
            rexMinimap.apply(
                state: rex, shownTint: themeID.palette.ui.blue,
                otherTint: themeID.palette.ui.fgDim.withAlphaComponent(0.5),
                backdropColor: background.withAlphaComponent(0.75)
            )
        }
        rexMinimap.isAvailable = rex?.showsMinimap == true
        if swipes != rexSwipes {
            rexSwipes = swipes
            gridView?.paneStepping = paneStepping
        }
    }

    /// The grid's swipe and VoiceOver actions, for a Rex session.
    private var paneStepping: SSHTerminalPaneStepping? {
        guard rexSwipes else { return nil }
        return SSHTerminalPaneStepping(
            neighbour: { [weak self] delta in self?.channel.rex?.latest.neighbour(offsetBy: delta)?.name },
            step: { [weak self] delta in self?.channel.rex?.step(delta) ?? false },
            shown: { [weak self] in self?.channel.rex?.latest.shown },
            newPane: { [weak self] in self?.openNewPane() ?? false },
            canCreatePane: { [weak self] in self?.newPaneTask == nil },
            target: { [weak self] delta in self?.channel.rex?.latest.pane(offsetBy: delta) },
            takeAhead: { [weak self] block in self?.channel.rex?.takeAhead(block) }
        )
    }

    /// Starts opening a new pane after the shown one, unless one is already
    /// opening. The grid's cover (`SSHTerminalPaneTransition`) waits for the
    /// answer: the new pane is shown through the session like any switch, or
    /// the cover slides away to the pane the terminal was on and a notice says
    /// why. Nothing is ever left stuck: a request that never answers ends at
    /// Rex's request timeout, and the cover's own creation timeout covers the rest.
    private func openNewPane() -> Bool {
        guard let rex = channel.rex, newPaneTask == nil else { return false }
        newPaneTask = Task { [weak self] in
            let created: Result<String, any Error>
            do { created = .success(try await rex.newPane()) } catch { created = .failure(error) }
            // A terminal swapped out meanwhile cancelled this; its cover is gone.
            guard let self, !Task.isCancelled else { return }
            newPaneTask = nil
            switch created {
            case .success(let name):
                gridView?.paneTransition.paneCreated(named: name)
            case .failure(let error):
                gridView?.paneTransition.creationFailed()
                showOpenNotice("Could not open a new pane. \(error.localizedDescription)")
            }
        }
        return true
    }

    /// Shows `blockID` for the switcher's menu and the minimap's cells: the
    /// session takes the request, and the grid slides in the direction of
    /// travel. The pane icon and the minimap's highlight follow the session's
    /// state, as they do for a swipe.
    private func showPane(_ blockID: String) {
        guard let rex = channel.rex, gridView?.paneTransition.isAwaitingCreation != true else { return }
        let before = rex.latest
        guard let from = before.shownIndex, let to = before.panes.firstIndex(where: { $0.blockID == blockID }) else { return }
        // The slide goes first, naming the pane it heads for: the session's move
        // then lands at the slide's end, not under it.
        gridView?.paneTransition.slide(toward: to > from ? 1 : -1, neighbour: before.panes[to].name, target: blockID)
        guard rex.show(blockID) else { return }
    }

    /// Fades the bar with the keyboard. A hidden bar takes no touches, leaves
    /// the accessibility tree, and gives its rows back to the grid; edge-swipe
    /// back still works.
    private func applyControlsVisibility(animation: SSHTerminalKeyboard.Animation?) {
        let visible = !keyboardBarCarriesBar
        // Geometry is idempotent and must apply even when the bar's visibility
        // does not change: the keyboard alone moves the reserve.
        applyBottomBarGeometry(visible: visible)
        guard visible != controlsVisible || animation == nil else { return }
        controlsVisible = visible
        for pill in [backPill, barPill, rexPill] as [UIView] {
            pill.isUserInteractionEnabled = visible
            pill.accessibilityElementsHidden = !visible
        }
        let apply = {
            self.backPill.alpha = visible ? 1 : 0
            self.barPill.alpha = visible ? 1 : 0
            self.rexPill.alpha = visible ? 1 : 0
        }
        if let animation, isOnScreen, view.window != nil {
            UIView.animate(withDuration: animation.duration, delay: 0, options: animation.options, animations: apply)
        } else {
            apply()
        }
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    /// The bar's height and the rows the grid leaves for it. Two inputs: the
    /// bar shows or it does not, and the keyboard is up or it is not (with a
    /// docked keyboard up the grid never gives the bar rows; a broken
    /// connection then floats the bar over them instead).
    private func applyBottomBarGeometry(visible: Bool) {
        let height = visible ? SSHTerminalBottomBar.shownHeight : 0
        if abs((bottomBarHeight?.constant ?? 0) - height) > 0.5 {
            bottomBarHeight?.constant = height
        }
        updateBottomRows()
    }

    private func goBack() {
        Router.finish(self)
    }

    /// VoiceOver's two-finger scrub goes back, as it would with a bar.
    override func accessibilityPerformEscape() -> Bool {
        guard navigationController.map({ $0.viewControllers.count > 1 }) ?? false else { return false }
        goBack()
        return true
    }

    private func attentionPending() -> Bool {
        SSHTerminalFloatingControls.attentionPending(
            multiplexersWaiting: overviewsWaiting.values.reduce(0, +) + rexWaiting,
            blockedProgram: SSHTerminalProgramStatusPresentation.blockedNotice(
                store: channel.programStatus,
                isStopped: programIsStopped
            ) != nil
        )
    }

    /// One resize per keyboard transition. Layout-driven resizes are held,
    /// the end state is laid out inside the keyboard's animation, and the grid
    /// size the keyboard settles at is sent once. Layout passes in between
    /// (the bottom bar and the keyboard guide move in separate passes) are ignored until the transition ends; the release
    /// sends the real size only if the prediction missed. The bottom bar and
    /// the floating controls change the grid's free rows, but inside that same
    /// transition, so they never add a resize of their own.
    private func keyboardWillChange(endFrame: CGRect, screen: UIScreen?, duration: TimeInterval, curve: UInt) {
        guard let viewScreen = view.window?.windowScene?.screen,
              let end = SSHTerminalKeyboard.endFrame(
                endFrame,
                keyboardScreen: screen,
                viewScreen: viewScreen,
                screenSpace: viewScreen.coordinateSpace,
                in: view
              )
        else { return }
        keyboardUp = SSHTerminalKeyboard.isUp(endFrameInView: end, viewBounds: view.bounds)
        // The reserve depends on the keyboard, and the bar's visibility may not
        // change with it (a broken connection keeps the bar), so size the grid
        // here too: it lands in the one resize this change already sends.
        applyBottomBarGeometry(visible: !keyboardBarCarriesBar)
        applyControlsVisibility(animation: SSHTerminalKeyboard.animation(duration: max(duration, 0.2), curve: curve))
        guard isOnScreen, !isLeaving, let gridView else { return }
        keyboardTransition &+= 1
        let transition = keyboardTransition
        gridView.holdResize()
        resizeHoldTask?.cancel()
        resizeHoldTask = Task { [weak self, weak gridView] in
            // Lay out and measure on the next turn, once this notification's
            // own layout has happened, still inside the keyboard's animation.
            await Task.yield()
            guard let self, let gridView, transition == self.keyboardTransition, !self.isLeaving else { return }
            self.settleKeyboardTransition(end: end, grid: gridView, duration: duration, curve: curve)
            do { try await Task.sleep(for: .seconds(max(duration, 0.25) + 0.15)) } catch { return }
            // A divider still moving keeps the hold; its end sends the size.
            guard transition == self.keyboardTransition, !self.isLeaving, !self.paneResizing else { return }
            gridView.releaseResize()
        }
    }

    private func settleKeyboardTransition(
        end: CGRect,
        grid gridView: SSHTerminalGridView,
        duration: TimeInterval,
        curve: UInt
    ) {
        let animation = SSHTerminalKeyboard.animation(duration: duration, curve: curve)
        UIView.animate(withDuration: animation.duration, delay: 0, options: animation.options) {
            self.view.layoutIfNeeded()
        }
        let settled = SSHTerminalKeyboard.settledGridSize(
            current: gridView.bounds.size,
            guideTop: view.keyboardLayoutGuide.layoutFrame.minY,
            settledGuideTop: SSHTerminalKeyboard.settledGuideTop(
                endFrameInView: end,
                viewBounds: view.bounds,
                bottomSafeArea: view.safeAreaInsets.bottom
            )
        )
        if let geometry = gridView.geometry(for: settled) { channel.resize(geometry) }
    }

    // MARK: - Overlays

    private func updateBanners(connecting: Bool, connected: Bool, networkChanged: Bool, themeID: ThemeID) {
        let showStatus = connecting || !connected || networkChanged
        connectionBanner.isHidden = !showStatus
        if showStatus {
            connectionBanner.apply(
                text: statusText,
                showsProgress: connecting || networkChanged,
                showsReconnect: !connected && !connecting,
                themeID: themeID
            )
        }
        let input = channel.inputNotice
        inputBanner.isHidden = input.isEmpty
        if !input.isEmpty {
            inputBanner.apply(text: input, color: themeID.palette.ui.orange)
        }
        pasteBanner.isHidden = pasteNotice == nil
        if let pasteNotice {
            pasteBanner.apply(text: pasteNotice, color: themeID.palette.ui.orange)
        }
        openBanner.isHidden = openNotice == nil
        if let openNotice {
            openBanner.apply(
                text: openNotice,
                color: themeID.palette.ui.fg,
                action: openNoticeRetry.map { handler in
                    SSHTerminalTextBannerView.Action(title: String(localized: "Retry"), handler: handler)
                }
            )
        }
    }

    private func updateNotice(themeID: ThemeID) {
        let notice = visibleNotice
        if notice?.key == shownNoticeKey {
            if let notice {
                noticeCard.isHidden = false
                noticeCard.apply(notice: notice, hostCaption: hostLabel, themeID: themeID, reduceMotion: reduceMotion)
            }
            return
        }
        let previousKey = shownNoticeKey
        shownNoticeKey = notice?.key
        let duration: TimeInterval = reduceMotion ? 0.2 : 0.35
        if previousKey != nil {
            let transform = reduceMotion
                ? CGAffineTransform.identity
                : SSHTerminalNoticeCardView.collapseTransform(card: attention.cardFrame, glyph: attention.glyphFrame.rect)
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
                if self.reduceMotion {
                    self.noticeCard.alpha = 0
                } else {
                    self.noticeCard.transform = transform
                    self.noticeCard.alpha = 0
                }
            } completion: { _ in
                self.noticeCard.transform = .identity
                self.noticeCard.alpha = 1
                if let notice {
                    self.noticeCard.isHidden = false
                    self.noticeCard.apply(notice: notice, hostCaption: self.hostLabel, themeID: themeID, reduceMotion: self.reduceMotion)
                    self.animateNoticeIn(duration: duration)
                } else {
                    self.noticeCard.isHidden = true
                }
            }
        } else if let notice {
            noticeCard.isHidden = false
            noticeCard.apply(notice: notice, hostCaption: hostLabel, themeID: themeID, reduceMotion: reduceMotion)
            animateNoticeIn(duration: duration)
        } else {
            noticeCard.isHidden = true
        }
    }

    private func animateNoticeIn(duration: TimeInterval) {
        if reduceMotion {
            noticeCard.alpha = 0
            UIView.animate(withDuration: duration) { self.noticeCard.alpha = 1 }
        } else {
            noticeCard.alpha = 0
            noticeCard.transform = CGAffineTransform(translationX: 0, y: -24)
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut]) {
                self.noticeCard.alpha = 1
                self.noticeCard.transform = .identity
            }
        }
    }

    /// Shows the take's untyped words above the bar while there are any. When
    /// the live cursor's row would sit under them, they move to the grid's top,
    /// so the words being typed stay in sight.
    private func updateDictationTail(themeID: ThemeID) {
        let text = dictation.provisional
        dictationTail.isHidden = text.isEmpty
        guard !text.isEmpty else { return }
        dictationTail.apply(text: text, themeID: themeID)
        let covered = max(dictationTail.bounds.height, 44) + 16
        // The cursor's row, in the grid's points, while the grid shows live output.
        let cursorRowBottom = gridView.flatMap { grid in
            channel.engine.following ? CGFloat(channel.engine.cursorCell.row + 1) * grid.cellSize.height : nil
        }
        let atTop = cursorRowBottom.map { $0 > overlay.bounds.height - covered } ?? false
        dictationTailAtBottom?.isActive = !atTop
        dictationTailAtTop?.isActive = atTop
    }

    private func updateCopyAndLive(themeID: ThemeID) {
        copyNotice.isHidden = copyNoticeText == nil
        if let copyNoticeText {
            copyNotice.apply(text: copyNoticeText, themeID: themeID)
        }
        if backToLiveThemeID != themeID {
            backToLiveThemeID = themeID
            // The terminal never shows the button busy; the tint is unused.
            backToLive.apply(palette: themeID.palette, busyTint: themeID.palette.ui.blue)
        }
        backToLive.setVisible(detached)
    }

    // MARK: - Bottom rows

    /// The bottom rows the grid leaves free for the bottom bar. Keeping this in
    /// one place is what makes a keyboard change one resize.
    private func updateBottomRows() {
        let constant = -bottomBarReserve
        guard abs((gridBottom?.constant ?? 0) - constant) > 0.5 else { return }
        gridBottom?.constant = constant
    }

    // MARK: - Mode

    private var keymapProgram: String {
        SSHTerminalAgentDetection.keymapProgram(root: channel.programStatus.liveRoot, app: channel.programStatus.app(of: ""))
    }

    private var programIsStopped: Bool { !channel.connected && !channel.connecting }
    private var programRollup: SessionStatusRollup? {
        SSHTerminalProgramStatusPresentation.rollup(
            store: channel.programStatus,
            isStopped: programIsStopped
        )
    }
    private var visibleNotice: SSHTerminalNotice? {
        attention.notice(from: SSHTerminalAttention.candidates(
            programStatus: channel.programStatus, alerts: channel.alerts, isStopped: programIsStopped
        ))
    }
    private var programStatusRows: [SSHTerminalStatusRow] {
        SSHTerminalProgramStatusPresentation.detailRows(
            store: channel.programStatus,
            isStopped: programIsStopped
        )
    }
    private var statusText: String {
        if channel.connected, channel.rex?.state.reconnecting == true { return "Connection lost \u{2014} reconnecting to Rex\u{2026}" }
        if channel.networkChanged { return "Network changed \u{2014} checking the connection\u{2026}" }
        return channel.connecting ? channel.reason : "Disconnected \u{00b7} \(channel.reason)"
    }

    private func showTerminalKeyboard() {
        askForTerminalKeyboard()
    }

    /// Type in Terminal was asked for, but the grid has not taken the keyboard
    /// yet: UIKit can refuse an ask that lands while another responder is still
    /// resigning, and a dropped ask leaves nothing focused. The screen asks
    /// again on its next pass until the grid holds it. Cleared when the person
    /// sends the keyboard away.
    private var wantsTerminalKeyboard = false

    private func askForTerminalKeyboard() {
        wantsTerminalKeyboard = true
        // Ask now too: a key strip tap should not wait a pass.
        DispatchQueue.main.async { [weak self] in self?.takeTerminalKeyboard() }
        setNeedsUpdateProperties()
    }

    private func takeTerminalKeyboard() {
        if keyboardReturnsWhenUncovered, isUncovered {
            keyboardReturnsWhenUncovered = false
            wantsTerminalKeyboard = true
        }
        guard wantsTerminalKeyboard, let grid = gridView, grid.window != nil else { return }
        if !grid.isFirstResponder { _ = grid.becomeFirstResponder() }
        if grid.isFirstResponder { wantsTerminalKeyboard = false }
    }

    private func keyboardWasHidden() {
        wantsTerminalKeyboard = false
    }

    /// The grid took or gave up the keyboard: the bar moves to the surface
    /// that shows now, in the next pass.
    private func keyboardOwnershipChanged() {
        applyControlsVisibility(animation: .init(duration: 0.2, options: [.curveEaseInOut, .beginFromCurrentState]))
        setNeedsUpdateProperties()
    }

    /// A sheet or screen opened from the keyboard bar covers the terminal:
    /// the keyboard goes down so it does not sit over the sheet, and comes
    /// back once nothing covers the terminal (`takeTerminalKeyboard`). UIKit
    /// does not bring back a responder the screen resigned itself.
    private var keyboardReturnsWhenUncovered = false

    private func leaveKeyboardForSheet() {
        guard let grid = gridView, grid.isFirstResponder else { return }
        keyboardReturnsWhenUncovered = true
        _ = grid.resignFirstResponder()
    }

    /// Nothing presented over the terminal and nothing pushed above it.
    private var isUncovered: Bool {
        isOnScreen && presentedViewController == nil && navigationController.map { $0.topViewController === self } ?? true
    }

    /// A sheet opened from the bar closed. Asks again once its dismissal has
    /// finished, since a picker reports before it has gone.
    private func sheetClosed() {
        if let coordinator = presentedViewController?.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.setNeedsUpdateProperties() }
        } else {
            DispatchQueue.main.async { [weak self] in self?.setNeedsUpdateProperties() }
        }
    }

    /// A password prompt appeared or ended: Fill Password follows it.
    private func secureInputChanged(_ secure: Bool) {
        secureEntryActive = secure
        if !secure, passwordFillTask != nil {
            passwordFillPromptEnded = true
            passwordFillTask?.cancel()
        }
        setNeedsUpdateProperties()
    }

    // MARK: - Dictation and attachments

    /// A take that failed while it ran shows once, as a notice; Dictate starts
    /// another.
    private func noticeDictationFailure(_ failure: VoiceCaptureFailure?) {
        guard failure != shownDictationFailure else { return }
        shownDictationFailure = failure
        guard let failure else { return }
        showOpenNotice(String(localized: "Dictation stopped. \(failure.message)"))
    }

    /// Saves each pick on the host, then types the paths, space-separated and
    /// without Return, as a pasted image's path is typed. Coding agents read an
    /// image or file by its path.
    private func attach(_ attachments: [PendingAttachment]) {
        guard !attachments.isEmpty else { return }
        let store = AppRootEnvironment.near(self)?.composerDraftStore
        guard channel.connected else {
            PhotoLibraryMediaImporter.discardImportedFiles(attachments, store: store)
            presentPasteFailure("Not connected.")
            return
        }
        let channel = channel
        showPasteNotice(attachments.count == 1
            ? "Saving the file on the host\u{2026}"
            : "Saving \(attachments.count) files on the host\u{2026}")
        Task { [weak self] in
            defer { PhotoLibraryMediaImporter.discardImportedFiles(attachments, store: store) }
            do {
                var paths: [String] = []
                for attachment in attachments {
                    let (data, ext) = try await SSHTerminalAttachPicker.fileContents(attachment)
                    paths.append(try await channel.upload(data, fileExtension: ext))
                }
                try channel.paste(paths.joined(separator: " "))
                self?.showPasteNotice(paths.count == 1 ? "Pasted the file's path." : "Pasted the files' paths.")
            } catch {
                self?.presentPasteFailure("The attachment was not sent. \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Fill Password

    /// The saved host the channel being typed into belongs to, which says
    /// whether there is a password to fill. Read from that channel, not from
    /// the session: while the screen swaps to another terminal the session can
    /// already stand for the next one.
    private var passwordFillProfile: SSHTerminalProfile? { session?.profile(of: channel) ?? previewFillProfile }

    /// The screenshot preview has no connect session; it names the host here.
    var previewFillProfile: SSHTerminalProfile?

    private func isPasswordFillOffered(connected: Bool? = nil) -> Bool {
        SSHTerminalPasswordFill.isOffered(
            profile: passwordFillProfile,
            secureEntry: secureEntryActive,
            inHistory: detached,
            connected: connected ?? channel.connected
        )
    }

    private func updatePasswordFill(connected: Bool) {
        let host = isPasswordFillOffered(connected: connected) ? passwordFillProfile?.endpointLabel : nil
        gridView?.setPasswordFill(host: host)
    }

    /// Asks for Face ID, then types the saved password at the prompt without
    /// pressing Return. Nothing is typed when the person cancels, the check
    /// fails, or the prompt is gone by the time it passes. Right before the
    /// send the live screen decides, not the secure-entry latch: that moves
    /// with painted frames, which stop under Face ID.
    private func fillPassword() {
        guard passwordFillTask == nil, isPasswordFillOffered(), let profile = passwordFillProfile,
              let grid = gridView, let prompt = grid.passwordFillPrompt() else { return }
        let channel = channel
        passwordFillPromptEnded = false
        passwordFillTask = Task { [weak self, weak grid] in
            let outcome = await SSHTerminalPasswordFill.fill(
                profile: profile,
                promptIsLive: { [weak self, weak grid] in
                    guard let self, let grid else { return false }
                    return self.channel === channel && self.isOnScreen && grid.passwordPromptIsLive(matching: prompt)
                },
                send: { channel.send($0) }
            )
            guard let self, self.channel === channel else { return }
            self.passwordFillTask = nil
            switch outcome {
            case .filled: self.showPasteNotice("Filled password")
            case .cancelled:
                // The prompt ending dismissed the check itself.
                if self.passwordFillPromptEnded { self.showPasteNotice("Password not filled. The prompt ended.") }
            case .promptEnded: self.showPasteNotice("Password not filled. The prompt ended.")
            case .failed(let message): self.showPasteNotice("Password not filled. \(message)")
            }
        }
    }

    // MARK: - Presentations

    /// The multiplexer a trailing bar action opens the overview of.
    private func overview(_ action: SSHTerminalBarAction) -> (any SSHTerminalOverviewSource)? {
        // An overview the bar hides (Herdr in a Rex pane, or with its
        // experiment off) has nothing to read: no button, no poll, no dot.
        guard !barContext.hidden.contains(action) else { return nil }
        return switch action {
        // Herdr is read with side commands, which a terminal without SSH has none of.
        case .herdr: channel.sideCommandsUnavailable == nil && !channel.sideCommandsSignInPending ? herdr : nil
        default: nil
        }
    }

    /// Rex panes that need you, for the Back dot. A Herdr terminal leaves Rex out.
    private var rexWaiting: Int {
        guard SSHTerminalExperimentAccess.current.rex, barContext != .herdr, rex.available else { return 0 }
        return rex.needsAttention
    }

    /// Panes that need you, per multiplexer that has answered.
    private var overviewsWaiting: [SSHTerminalBarAction: Int] {
        var waiting: [SSHTerminalBarAction: Int] = [:]
        for action in SSHTerminalBarAction.overviews {
            if let source = overview(action), source.available { waiting[action] = source.needsAttention }
        }
        return waiting
    }

    private func showOverview(_ action: SSHTerminalBarAction) {
        guard !presentingOverview, let source = overview(action) else { return }
        presentingOverview = true
        leaveKeyboardForSheet()
        source.watching = true
        let channel = channel
        Router.present(
            SSHTerminalOverviewViewController(
                content: source,
                isSheet: true,
                refresh: { await source.refresh(on: channel) },
                activate: { await source.activate($0, on: channel) }
            ),
            presentation: .sheet.detents([.medium(), .large()]).inNavigation(),
            from: self,
            onDismiss: { [weak self] in
                self?.presentingOverview = false
                source.watching = false
                self?.sheetClosed()
            }
        )
    }

    /// The Rex panel: this pane's status, the session's panes, and the other
    /// sessions, in one sheet (`SSHTerminalRexPanelContent`). Switching a pane
    /// and a new pane go through the owners a swipe uses; another session's pane
    /// opens on this device (`openRexPane`).
    private func showRexPanel() {
        guard !presentingOverview, let model = channel.rex else { return }
        presentingOverview = true
        leaveKeyboardForSheet()
        let sessionID = model.sessionID
        let monitor = rex
        monitor.watching = true
        monitor.openPane = { [weak self] pane in self?.openRexPane(pane) }
        let content = SSHTerminalRexPanelContent(
            monitor: monitor,
            settings: rexPanelSettings,
            sessionID: sessionID,
            sessionState: { [weak model] in model?.state },
            statusRows: { [weak self, weak model] in
                guard let self else { return [] }
                let own = programStatusRows
                if !own.isEmpty { return own }
                let state = model?.state
                return SSHTerminalRexPanelContent.statusRows(from: state?.panes.first { $0.blockID == state?.shown }?.records ?? [])
            }
        )
        Router.present(
            SSHTerminalOverviewViewController(
                content: content,
                isSheet: true,
                refresh: { await monitor.resync() },
                activate: { [weak self] focus in self?.activateRexPanel(focus, sessionID: sessionID) ?? false }
            ),
            presentation: .sheet.detents([.medium(), .large()]).inNavigation(),
            from: self,
            onDismiss: { [weak self] in
                self?.presentingOverview = false
                monitor.watching = false
                self?.sheetClosed()
            }
        )
    }

    /// A tapped row of the Rex panel: a pane of this session is shown, New Pane
    /// opens one, and a pane of another session opens on this device.
    private func activateRexPanel(_ focus: SSHTerminalOverviewFocus, sessionID: String) -> Bool {
        if focus == SSHTerminalRexPanelContent.newPaneFocus { return gridView?.createPane() ?? false }
        if focus.scope == sessionID || focus.scope == nil {
            showPane(focus.id)
            return true
        }
        return rex.open(focus)
    }

    private func openRexPane(_ pane: RexPaneTarget) {
        if let rexPaneOpener { rexPaneOpener(pane) } else { session?.openRexPane(pane) }
    }

    private func showStatusDetail() {
        guard !presentingStatusDetail else { return }
        presentingStatusDetail = true
        Router.present(
            SSHTerminalStatusDetailController(
                hostLabel: hostLabel,
                rows: programStatusRows,
                themeID: chromeTheme
            ),
            presentation: .popover.keepsPopoverInCompactWidth(),
            from: self,
            sourceView: keyboardBarCarriesBar ? keyboardBarStatus : statusGlyph,
            onDismiss: { [weak self] in self?.presentingStatusDetail = false }
        )
    }

    // MARK: - Opening links and paths

    /// The SSH host, as the saved profile names it. Nothing opens paths on a
    /// host this terminal was not told about.
    private var sshHost: String {
        (session?.connectedProfile?.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The paired Oppi server that is this same machine, if any. Only then can
    /// a path open in Oppi's own file routes.
    private var pairedServer: PairedServer? {
        guard let root = AppRootEnvironment.near(self), !sshHost.isEmpty else { return nil }
        let servers = root.coordinator.serverStore.servers
        let paired = servers.map { (id: $0.id, host: $0.host) }
        guard let id = SSHTerminalServerMatch.serverId(forHost: sshHost, paired: paired) else { return nil }
        return servers.first { $0.id == id }
    }

    /// Open and Copy for a held link, URL, or path. A path needs a paired
    /// server, and a path outside that server's home is not offered at all:
    /// owner-host files are rooted at the user's home there.
    private func heldOpenTarget(_ held: SSHTerminalHeldCell) -> SSHTerminalOpenTarget? {
        let folder = channel.workingDirectory.isEmpty ? nil : channel.workingDirectory
        guard let target = SSHTerminalOpenResolution.target(
            text: held.text, hyperlink: held.hyperlink, folder: folder,
            shellHost: channel.engine.workingDirectoryHost, sshHost: sshHost
        ) else { return nil }
        return SSHTerminalHostPathPolicy.offers(target, isPairedServer: pairedServer != nil, home: pairedHome) ? target : nil
    }

    /// Opens a held or tapped target. With no `placement` it goes where a
    /// tapped chat link's would (`SSHTerminalOpenRoute`); the hold menu's
    /// pane items name one (`PaneOpenMenu`).
    private func open(_ target: SSHTerminalOpenTarget, placement: PaneOpenPlacement?) {
        switch target {
        case .web(let url, _):
            guard let opener = AppRootEnvironment.near(self)?.opener else { return }
            guard let placement, placement != .here, let grid = gridView else {
                // The app's one open owner applies the link browser preference
                // and puts the page beside the terminal on a wide window.
                opener.open(.webLink(url))
                return
            }
            PaneOpenMenu.open(placement, from: grid) { await opener.paneContent(for: .webLink(url)) }
        case .path(let path, let line):
            openHostPath(path, line: line, placement: placement)
        }
    }

    private func openHostPath(_ path: String, line: SourceLineAnchor?, placement: PaneOpenPlacement?) {
        guard let server = pairedServer, let root = AppRootEnvironment.near(self),
              let api = root.coordinator.apiClient(for: server.id) else {
            showOpenNotice("This host is not a paired Oppi server, so its files can only be copied.")
            return
        }
        showOpenNotice("Opening \(path.split(separator: "/").last.map(String.init) ?? path)…")
        startOpenTask { [weak self] in
            guard let self else { return }
            do {
                let home = try await Self.hostHome(api: api)
                guard !Task.isCancelled else { return }
                self.pairedHome = home
                guard let target = SSHTerminalHostPathPolicy.absolute(path, home: home) else {
                    self.showOpenNotice("That path cannot be resolved on the host.")
                    return
                }
                let status = try await api.getHostPathStatus(path: target)
                guard !Task.isCancelled else { return }
                switch SSHTerminalHostPathPolicy.plan(status: status, home: home) {
                case .file(let file):
                    self.showHostFile(serverId: server.id, path: file, line: line, root: root, placement: placement)
                case .folder(let folder):
                    self.showHostFolder(serverId: server.id, folder: folder, home: home, root: root, placement: placement)
                case .refused(let reason):
                    self.showOpenNotice(reason)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.showOpenNotice("That path could not be opened on the host.")
            }
        }
    }

    /// The folder the shell reported: the Files browser at it, on its server.
    private func browseFilesHere() {
        guard let server = pairedServer, let root = AppRootEnvironment.near(self),
              let api = root.coordinator.apiClient(for: server.id) else { return }
        let folder = channel.workingDirectory
        startOpenTask { [weak self] in
            guard let self else { return }
            do {
                let home = try await Self.hostHome(api: api)
                guard !Task.isCancelled else { return }
                self.pairedHome = home
                guard SSHTerminalHostPathPolicy.isInside(home: home, path: folder) else {
                    self.showOpenNotice("Files open inside the server's home folder.")
                    return
                }
                self.showHostFolder(serverId: server.id, folder: folder, home: home, root: root, placement: nil)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.showOpenNotice("The server's home folder could not be read.")
            }
        }
    }

    /// One Open or Browse at a time, and never after the screen was left: a
    /// second choice replaces the first, and Back before the lookup finishes
    /// does not push onto the screen below.
    private func startOpenTask(_ work: @escaping @MainActor () async -> Void) {
        openTask?.cancel()
        openTaskGeneration &+= 1
        let generation = openTaskGeneration
        openTask = Task { [weak self] in
            await work()
            guard let self, self.openTaskGeneration == generation else { return }
            self.openTask = nil
        }
    }

    private static func hostHome(api: APIClient) async throws -> String {
        let status = try await api.getHostPathStatus(path: "~")
        guard status.resolvedPath.hasPrefix("/") else { throw SSHTerminalHostFilesError.homePathInvalid }
        return status.resolvedPath
    }

    /// The viewer opens a file through its own server, at the link's line.
    private func showHostFile(
        serverId: String, path: String, line: SourceLineAnchor?, root: AppRootEnvironment, placement: PaneOpenPlacement?
    ) {
        let target = WorkspaceLinkedFileNavTarget.hostFile(serverId: serverId, workspaceId: "", path: path, lineAnchor: line)
        show(PaneOpenContent(file: target), kind: .file, placement: placement) {
            WorkspaceLinkedFileViewController(target: target, placement: .pushed, root: root)
        }
    }

    /// The Files browser lists host folders home-relative, so the folder is
    /// passed the way its own navigation builds it: no home prefix, a trailing
    /// slash, and empty for the home folder itself.
    private func showHostFolder(
        serverId: String, folder: String, home: String, root: AppRootEnvironment, placement: PaneOpenPlacement?
    ) {
        let trimmedHome = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        var relative = folder == trimmedHome ? "" : String(folder.dropFirst(trimmedHome.count + 1))
        if !relative.isEmpty, !relative.hasSuffix("/") { relative += "/" }
        let target = FileBrowserNavTarget.hostHome(serverId: serverId, path: relative)
        show(PaneOpenContent(folder: target), kind: .folder, placement: placement) { [weak self] in
            self?.leaveKeyboardForSheet()
            return FileBrowserViewController(root: root, target: target, showsSidebarToggle: false)
        }
    }

    /// A resolved file or folder: beside the terminal where `PanePlacement`
    /// puts it, Open Here over the terminal in its own navigation, or the
    /// pane the hold menu named.
    private func show(
        _ content: PaneOpenContent, kind: PaneContentKind, placement: PaneOpenPlacement?,
        makeScreen: () -> UIViewController
    ) {
        switch placement {
        case nil:
            SSHTerminalOpenRoute.open(content, kind: kind, from: self, makeScreen: makeScreen)
        case .here?:
            SSHTerminalOpenRoute.push(from: self, makeScreen: makeScreen)
        case let placement?:
            guard let grid = gridView else { return }
            PaneOpenMenu.open(placement, from: grid) { content }
        }
    }

    /// The server's home folder, fetched once per terminal so the hold menu
    /// can tell an owner-host path from one the file routes cannot reach.
    private func refreshPairedHome() {
        guard pairedHome == nil, pairedHomeTask == nil, let server = pairedServer,
              let api = AppRootEnvironment.near(self)?.coordinator.apiClient(for: server.id) else { return }
        pairedHomeTask = Task { [weak self] in
            let home = try? await Self.hostHome(api: api)
            guard let self else { return }
            self.pairedHomeTask = nil
            guard let home else { return }
            self.pairedHome = home
            self.setNeedsUpdateProperties()
        }
    }

    private func showOpenNotice(_ text: String, retry: (() -> Void)? = nil) {
        openNotice = text
        openNoticeRetry = retry
        openNoticeTask?.cancel()
        // A notice that offers a retry waits for it: the person may have to start
        // the program by hand first, and the reason is still worth reading then.
        // It leaves on Retry, on success, or when the connection goes.
        openNoticeTask = nil
        if retry == nil {
            openNoticeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.openNotice = nil
                self?.openNoticeRetry = nil
                self?.setNeedsUpdateProperties()
            }
        }
        setNeedsUpdateProperties()
    }

    // MARK: - Paste

    private var pasteLineCount: Int { SSHTerminalEngine.pasteLineCount(pendingPaste ?? "") }

    private func requestPaste(_ text: String?) {
        guard channel.connected else { channel.send(Data()); return }
        guard let text else {
            showPasteNotice("Nothing pasted \u{2014} the clipboard has no text, or paste access was not allowed.")
            return
        }
        guard text.utf8.count <= SSHTerminalEngine.maximumPasteBytes else {
            presentPasteFailure("Pastes are limited to 64 KiB.")
            return
        }
        if SSHTerminalEngine.pasteNeedsConfirmation(text) {
            pendingPaste = text
            Confirmation(
                title: "Paste \(pasteLineCount) \(pasteLineCount == 1 ? "line" : "lines")?",
                message: "This text contains a newline or terminal control sequence and may run commands. Paste only text you trust.",
                actionTitle: "Paste",
                style: .alert,
                isDestructive: false
            ).present(from: self, anchor: nil) { [weak self] in
                guard let self, let text = self.pendingPaste else { return }
                self.pendingPaste = nil
                do { try self.channel.paste(text, confirmed: true) } catch {
                    self.presentPasteFailure("Paste was not sent. \(error.localizedDescription)")
                }
            } onCancel: { [weak self] in
                self?.pendingPaste = nil
            }
        } else {
            do { try channel.paste(text) } catch {
                presentPasteFailure("Paste was not sent. \(error.localizedDescription)")
            }
        }
    }

    /// Saves the image on the host like an attachment, then pastes
    /// its path. Claude Code and pi read a pasted image path as the image.
    private func pasteImage(_ image: SSHTerminalPastedImage) {
        guard channel.connected else { channel.send(Data()); return }
        if let reason = channel.sideCommandsUnavailable {
            presentPasteFailure("The image was not pasted. \(reason)")
            return
        }
        let channel = channel
        showPasteNotice("Saving the image on the host\u{2026}")
        Task { [weak self] in
            do {
                let path = try await channel.upload(image.data, fileExtension: image.fileExtension)
                try channel.paste(path)
                self?.showPasteNotice("Pasted the image's path.")
            } catch {
                self?.presentPasteFailure("The image was not pasted. \(error.localizedDescription)")
            }
        }
    }

    private func presentPasteFailure(_ message: String) {
        errorAlerts.show(title: "Paste Not Sent", message: message)
    }

    private func showPasteNotice(_ text: String) {
        pasteNotice = text
        pasteNoticeTask?.cancel()
        pasteNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.pasteNotice = nil
            self?.setNeedsUpdateProperties()
        }
        setNeedsUpdateProperties()
    }

    private func showCopyNotice() {
        let count = channel.lastCopyLength
        copyNoticeText = "Copied \(count) \(count == 1 ? "character" : "characters")"
        copyNoticeTask?.cancel()
        copyNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.copyNoticeText = nil
            self?.setNeedsUpdateProperties()
        }
        setNeedsUpdateProperties()
    }

    // MARK: - Lifecycle

    /// "Open Terminal here" on a host whose Run on Connect command starts a
    /// multiplexer that opens folders inside its own terminal (Herdr): the
    /// folder is focused, or created, on this already-connected terminal, over
    /// its side exec channel. Nothing is typed into the program.
    ///
    /// One attempt per connection, and a failed one offers Retry: a Herdr that
    /// was not running yet can be started by hand in the terminal underneath and
    /// then opened without leaving it.
    private func openMultiplexerFolderIfNeeded() {
        guard let session, let target = session.multiplexerFolder, channel.connected,
              let kind = SSHTerminalMultiplexerKind.detected(in: session.connectedProfile?.commandOnConnect()),
              case .inHostTerminal(let run)? = kind.multiplexer.opening(target) else { return }
        session.multiplexerFolder = nil
        openFolderInMultiplexer(target, multiplexer: kind.multiplexer, run: run)
    }

    /// Runs, or re-runs from Retry, the multiplexer's folder open on this
    /// connection. A refusal shows over the terminal, which is where the person
    /// stays either way; the notice keeps its Retry until that is used, the open
    /// succeeds, or the connection goes away.
    private func openFolderInMultiplexer(
        _ target: SSHTerminalFolderTarget,
        multiplexer: any SSHTerminalMultiplexer,
        run: @escaping (SSHTerminalChannel) async throws -> Void
    ) {
        // Whatever this notice said is answered by this attempt, which reports
        // its own result when it finishes.
        openNotice = nil
        openNoticeRetry = nil
        openNoticeTask?.cancel()
        setNeedsUpdateProperties()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await run(channel)
                showOpenNotice("Opened \(target.folderLabel) in \(multiplexer.name).")
                await herdr.refresh(on: channel)
            } catch {
                // The reason leads, and the folder is its last name: a phone
                // notice has room for one line of each.
                showOpenNotice(
                    Self.failureNotice(target: target, multiplexer: multiplexer, error: error),
                    retry: { [weak self] in
                        guard let self, channel.connected else { return }
                        openFolderInMultiplexer(target, multiplexer: multiplexer, run: run)
                    }
                )
            }
        }
    }

    /// "Herdr is not running. oppi did not open in Herdr." — the reason first,
    /// then the folder by its own name and the program that refused it.
    private static func failureNotice(
        target: SSHTerminalFolderTarget,
        multiplexer: any SSHTerminalMultiplexer,
        error: any Error
    ) -> String {
        var reason = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reason.isEmpty, !".!?".contains(reason.last ?? ".") { reason += "." }
        return "\(reason) \(target.folderName) did not open in \(multiplexer.name)."
    }

    /// The Experiments switch changed: the bar's Herdr button, the Rex and
    /// Herdr polls, and Customize Bar follow it now. A Rex terminal is a pane
    /// of a session Oppi may no longer read, and the registry ends it where it
    /// was the one that turned off.
    private func experimentChanged() {
        if !AppPreferenceStore.Experiments.rexEnabled {
            rexPoll?.cancel()
            rexPoll = nil
        }
        if !AppPreferenceStore.Experiments.herdrEnabled { stopOverview(.herdr) }
        setNeedsUpdateProperties()
    }

    /// Stops one multiplexer's overview poll (its read), leaving the other alone.
    private func stopOverview(_ action: SSHTerminalBarAction) {
        overviewTasks.removeValue(forKey: action)?.cancel()
    }

    /// A terminal's Rex monitor tells the Terminal tab what it found on the
    /// host (`SSHTerminalRexHostStore`): a host Rex was read on gets a live Rex
    /// section there, and one with no `rex` loses it. It reaches the host's
    /// Rex over Tailscale when it can (`RexRoutePlan`).
    /// A Rex reached over Tailscale alone is no saved host: it is followed
    /// straight over Tailscale and nothing is recorded for it.
    static func makeRexMonitor(for profile: SSHTerminalProfile?, hosts: SSHTerminalRexHostStore?) -> RexMonitor {
        if profile?.rexTailnet != nil { return RexMonitor.forTerminal(of: profile) }
        let monitor = RexMonitor(directHost: profile.map(RexDirectHost.init))
        if let profile, let hosts {
            monitor.onFinding = { hosts.record($0, on: profile) }
        }
        return monitor
    }

    private func stopOverviewPolls() {
        overviewTasks.values.forEach { $0.cancel() }
        overviewTasks = [:]
        rexPoll?.cancel()
        rexPoll = nil
    }

    private func updatePolling() {
        // Herdr, Rex, and keymaps load again when you return; they do not run off
        // screen, or in a pane that is covered or parked.
        guard isSeen else {
            stopOverviewPolls()
            keymapTask?.cancel()
            keymapTask = nil
            keymapToken = nil
            colorTask?.cancel()
            colorTask = nil
            colorToken = nil
            return
        }
        if channel.connected {
            openMultiplexerFolderIfNeeded()
            for action in SSHTerminalBarAction.overviews where overviewTasks[action] == nil {
                guard let source = overview(action) else { continue }
                let channel = channel
                overviewTasks[action] = Task { await source.run(on: channel) }
            }
            if rexPoll == nil, SSHTerminalExperimentAccess.current.rex {
                let channel = channel
                let rex = rex
                rexPoll = Task { await rex.run(on: channel) }
            }
        } else {
            stopOverviewPolls()
        }
        let dark = appIsDark
        // The host's Ghostty colors are read with side commands; a terminal
        // without them keeps the colors it has (Oppi's theme, or the last read),
        // and a Rex over Tailscale reads them only once something else signed
        // in to SSH: a read on its own never asks for Face ID.
        let readsColors = channel.connected && colorChoice != .oppi && channel.sideCommandsUnavailable == nil
            && !channel.sideCommandsSignInPending
        let colorKey = readsColors ? "\(colorChoice)|\(dark)" : nil
        if colorToken != colorKey {
            colorToken = colorKey
            colorTask?.cancel()
            colorTask = nil
            if colorKey != nil {
                let channel = channel
                let choice = colorChoice
                colorTask = Task { [weak self] in
                    await self?.colorLoader.load(choice: choice, dark: dark) { try await channel.run($0) }
                }
            }
        }
        let token = channel.connected && !channel.sideCommandsSignInPending ? keymapProgram : nil
        if keymapToken != token {
            keymapToken = token
            keymapTask?.cancel()
            keymapTask = Task { [weak self] in
                guard let self else { return }
                await self.keymap.load(program: token, on: self.channel)
            }
        }
    }

    /// A fresh sign-in, with the same approval as Reconnect: no prompt when the
    /// person approved within the last few minutes. The flag stays set until
    /// App Lock no longer covers Oppi. A terminal you had already left is not
    /// reconnected: only a close that happened while this screen was showing.
    private func reconnectAfterReturn() {
        guard reconnectOnReturn, AppScenePhase.shared.phase == .active, !AppLockService.shared.requiresUnlock() else { return }
        reconnectOnReturn = false
        reconnect()
    }

    private func reduceMotionChanged() {
        reduceMotion = UIAccessibility.isReduceMotionEnabled
        setNeedsUpdateProperties()
    }
}

/// A terminal in a pane (a Rex pane, a folder terminal, the chat's Terminal)
/// goes quiet while the pane is covered or parked, as it does off screen: no
/// Rex neighbours stream, a pane another client took (the Mac app) stays
/// theirs, and nothing polls. A divider beside it sends one resize, at rest.
extension SSHTerminalViewController: PaneVisibilityObserving, PaneLiveResizing {
    func paneVisibilityDidChange(_ visibility: PaneVisibility) {
        paneShown = if case .visible = visibility { true } else { false }
        // A covered pane's screen may not run its pass until it shows again.
        let active = isSeen && AppScenePhase.shared.phase == .active
        channel.isViewed = active
        channel.rex?.isWarming = active
        updatePolling()
        setNeedsUpdateProperties()
    }

    func paneWillBeginLiveResize() {
        paneResizing = true
        gridView?.holdResize()
    }

    func paneSettleLiveResize(to size: CGSize, final: Bool) {
        guard final else { return }
        paneResizing = false
        // Leaving holds until the screen returns, which sends the real size.
        guard !isLeaving else { return }
        gridView?.releaseResize()
    }
}

/// Back swipe with the bar hidden. The navigation controller's own delegate
/// filters touches through a private event check that refuses every touch
/// while the bar is hidden, and this screen always hides it. While the
/// terminal is on top, this delegate answers with
/// the navigation controller's public decisions only: same edge, same Back
/// button exclusion, same begin rule.
private final class SSHTerminalBackSwipe: NSObject, UIGestureRecognizerDelegate {
    private weak var navigation: UINavigationController?
    private weak var original: (any UIGestureRecognizerDelegate)?

    init?(navigation: UINavigationController?) {
        guard let navigation, let gesture = navigation.interactivePopGestureRecognizer else { return nil }
        self.navigation = navigation
        original = gesture.delegate
        super.init()
        gesture.delegate = self
    }

    func uninstall() {
        guard let gesture = navigation?.interactivePopGestureRecognizer, gesture.delegate === self else { return }
        gesture.delegate = original
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        original?.gestureRecognizer?(gesture, shouldReceive: touch) ?? true
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let navigation, navigation.viewControllers.count > 1 else { return false }
        return original?.gestureRecognizerShouldBegin?(gesture) ?? true
    }

    func gestureRecognizer(
        _ gesture: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        original?.gestureRecognizer?(gesture, shouldRecognizeSimultaneouslyWith: other) ?? false
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        original?.gestureRecognizer?(gesture, shouldRequireFailureOf: other) ?? false
    }
}
