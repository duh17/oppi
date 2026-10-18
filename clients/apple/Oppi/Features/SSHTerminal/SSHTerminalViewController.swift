import UIKit

/// Live SSH terminal: UIKit owns the screen, floating controls, grid,
/// notices, lists, and chat bar (`ComposerBarController` in a terminal
/// configuration). The navigation bar stays hidden while this screen is on
/// top; Back, status, Herdr, and the … menu float over the grid.
@MainActor
final class SSHTerminalViewController: UIViewController, RouterHidesNavigationBar {
    private(set) var channel: SSHTerminalChannel
    private let reconnect: () -> Void
    private let editHost: () -> Void
    private let hostLabel: String
    private weak var session: SSHTerminalConnectSession?
    /// Screenshot preview only: a server-scoped connection so the hosted
    /// composer can claim dictation. The live app uses the window's root.
    private let composerConnection: ServerConnection?
    /// Screenshot preview only. A normal launch never sets this.
    var presentsStatusDetailOnAppear = false

    private(set) var gridView: SSHTerminalGridView?
    private let overlay = SSHTerminalPassthroughView()
    private let topStack = UIStackView()
    private let backPill = SSHTerminalBackPill()
    private let connectionBanner = SSHTerminalConnectionBannerView()
    private let inputBanner = SSHTerminalTextBannerView(identifier: "sshTerminal.inputNotice")
    private let pasteBanner = SSHTerminalTextBannerView(identifier: "sshTerminal.pasteNotice")
    private let noticeCard = SSHTerminalNoticeCardView()
    private let copyNotice = SSHTerminalCopyNoticeView()
    private let backToLive = SSHTerminalBackToLiveButton()
    private let statusGlyph = SSHTerminalStatusGlyphButton()
    private lazy var morePill = SSHTerminalMorePill(status: statusGlyph)
    private var menuTitle: String?
    private var composerBar: ComposerBarController?
    private var composerSession: SSHTerminalComposerHost?
    private var composerKeyStrip: SSHTerminalKeyStripView?
    private var composerContainer: UIView?
    private var sendFailureLabel: UILabel?
    private var dictationFailureView: ComposerDictationFailureView?
    private var composerHeightConstraint: NSLayoutConstraint?
    private var lastAppliedComposerFocus = 0
    private var voicePrepareTask: Task<Void, Never>?
    private var gridBottomToKeyboard: NSLayoutConstraint?
    private var gridBottomToComposer: NSLayoutConstraint?

    private var pendingPaste: String?
    private var pasteNotice: String?
    private var pasteNoticeTask: Task<Void, Never>?
    private var copyNoticeText: String?
    private var copyNoticeTask: Task<Void, Never>?
    private var lastCopies = 0
    private var detached = false
    private var rawKeyboard = false
    private var herdr = HerdrMonitor()
    private var keymap = SSHTerminalKeymapLoader()
    private var modeOverride: SSHTerminalInputMode?
    private var lastDetectedMode: SSHTerminalInputMode?
    private var focusComposerAfterRaw = false
    private var composerFocusRequest = 0
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
    private var herdrTask: Task<Void, Never>?
    private var keymapTask: Task<Void, Never>?
    private var keymapToken: String?
    /// The registry closed this terminal while this screen was showing.
    private var sawClosedForBackground = false
    private var isOnScreen = false
    private var presentingHerdr = false
    private var presentingStatusDetail = false
    private var reduceMotion = UIAccessibility.isReduceMotionEnabled
    private var lastThemeID: ThemeID?
    private var defaultsObserver: NSObjectProtocol?
    private var reduceMotionObserver: NSObjectProtocol?
    private var keyboardObserver: NSObjectProtocol?

    init(
        channel: SSHTerminalChannel,
        reconnect: @escaping () -> Void,
        editHost: @escaping () -> Void,
        hostLabel: String = "",
        session: SSHTerminalConnectSession? = nil,
        composerConnection: ServerConnection? = nil
    ) {
        self.channel = channel
        self.reconnect = reconnect
        self.editHost = editHost
        self.hostLabel = hostLabel
        self.session = session
        self.composerConnection = composerConnection
        super.init(nibName: nil, bundle: nil)
        attention.glyphFrame.rect = .zero
        statusGlyph.glyphFrame.rect = .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .inline
        buildLayout()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.experimentChanged()
        }
        reduceMotionObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reduceMotionChanged()
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
        // Back and the actions float over the grid instead.
        navigationController?.setNavigationBarHidden(true, animated: animated)
        applyControlsVisibility(animation: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isOnScreen = true
        backSwipe?.uninstall()
        backSwipe = SSHTerminalBackSwipe(navigation: navigationController)
        // Remote clipboard writes apply only while this screen is in front.
        channel.isViewed = AppScenePhase.shared.phase == .active
        attentionFeedback.prepare()
        if presentsStatusDetailOnAppear, !presentingStatusDetail, programRollup != nil {
            presentsStatusDetailOnAppear = false
            showStatusDetail()
        }
        setNeedsUpdateProperties()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateComposerHeight()
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
        // The incoming screen needs its Back and title.
        navigationController?.setNavigationBarHidden(false, animated: animated)
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
        pasteNoticeTask?.cancel()
        copyNoticeTask?.cancel()
        herdrTask?.cancel()
        herdrTask = nil
        keymapTask?.cancel()
        keymapTask = nil
        keymapToken = nil
        attentionFeedback.cancel()
        // Leaving the screen does not close the terminal: `SSHTerminalRegistry`
        // owns the channel, and Disconnect or the host's lifecycle ends it.
        guard leaving else { return }
        composerSession?.releaseVoice()
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
    }

    override func updateProperties() {
        super.updateProperties()
        if let session, let next = session.channel, next !== channel {
            replaceChannel(next)
        }
        let connected = channel.connected
        let connecting = channel.connecting
        let networkChanged = channel.networkChanged
        _ = channel.reason
        _ = channel.inputNotice
        _ = channel.title
        _ = channel.copies
        _ = channel.lastCopyLength
        _ = channel.command
        _ = channel.closedForBackground
        _ = channel.programStatus.records
        _ = channel.programStatus.root
        _ = channel.alerts.notification
        _ = channel.alerts.bell
        _ = herdr.snapshot
        _ = herdr.failure
        _ = herdr.available
        _ = keymap.actions
        _ = keymap.profile
        _ = keymap.userFile
        if let manager = composerSession?.voiceManager {
            _ = manager.transcriptPresentationRevision
            _ = manager.currentTranscript
            _ = manager.state
            _ = manager.currentComposerCaptureFailure
            composerSession?.applyOwnedVoiceObservation()
            applyDictationFailure()
        }
        let locked = AppLockService.shared.isLocked
        let phase = AppScenePhase.shared.phase
        let themeID = HostFactory.root(near: self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        _ = HostFactory.root(near: self)?.themeStore.appTheme

        if lastThemeID != themeID {
            lastThemeID = themeID
            applyTheme(themeID)
        }
        if channel.copies != lastCopies {
            lastCopies = channel.copies
            if lastCopies > 0 { showCopyNotice() }
        }
        // A remote clipboard write is applied only while this screen is in front.
        channel.isViewed = isOnScreen && phase == .active
        if channel.closedForBackground, isOnScreen, !sawClosedForBackground {
            reconnectOnReturn = true
        }
        sawClosedForBackground = channel.closedForBackground
        if phase == .active { reconnectAfterReturn() }
        if !locked { reconnectAfterReturn() }
        if let session, !session.showsTerminal, isOnScreen, !isMovingFromParent {
            Router.finish(self)
        }

        let detected = detectedMode
        if detected != lastDetectedMode {
            lastDetectedMode = detected
            modeOverride = nil
            if detected == .chat && rawKeyboard {
                focusComposerAfterRaw = true
                _ = gridView?.resignFirstResponder()
            }
        }

        navigationItem.title = channel.title.isEmpty ? "SSH Terminal" : channel.title
        updatePolling()
        updateFloatingControls(themeID: themeID)
        updateBanners(connecting: connecting, connected: connected, networkChanged: networkChanged, themeID: themeID)
        updateNotice(themeID: themeID)
        updateCopyAndLive(themeID: themeID)
        updateComposer()
        if let gridView {
            gridView.tapTypesInTerminal = inputMode == .terminal
            gridView.setKeyActions(keymap.actions)
            gridView.showModifiers()
            gridView.applyTheme(themeID)
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
        morePill.herdr.addAction(UIAction { [weak self] _ in self?.showHerdr() }, for: .touchUpInside)
        connectionBanner.onReconnect = { [weak self] in self?.reconnect() }
        noticeCard.onDismiss = { [weak self] key in
            self?.attention.dismiss(key)
            self?.setNeedsUpdateProperties()
        }
        noticeCard.onFrameChange = { [weak self] in self?.attention.cardFrame = $0 }
        backToLive.addAction(UIAction { [weak self] _ in
            self?.gridView?.backToLive()
        }, for: .touchUpInside)
        statusGlyph.onOpen = { [weak self] in self?.showStatusDetail() }

        connectionBanner.isHidden = true
        inputBanner.isHidden = true
        pasteBanner.isHidden = true
        noticeCard.isHidden = true
        copyNotice.isHidden = true
        backToLive.isHidden = true
        topStack.addArrangedSubview(connectionBanner)
        topStack.addArrangedSubview(inputBanner)
        topStack.addArrangedSubview(pasteBanner)
        topStack.addArrangedSubview(noticeCard)
        connectionBanner.translatesAutoresizingMaskIntoConstraints = false
        noticeCard.translatesAutoresizingMaskIntoConstraints = false
        inputBanner.translatesAutoresizingMaskIntoConstraints = false
        pasteBanner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            connectionBanner.widthAnchor.constraint(equalTo: topStack.widthAnchor),
            inputBanner.widthAnchor.constraint(equalTo: topStack.widthAnchor),
            pasteBanner.widthAnchor.constraint(equalTo: topStack.widthAnchor),
            noticeCard.widthAnchor.constraint(equalTo: topStack.widthAnchor),
        ])

        overlay.addSubview(topStack)
        overlay.addSubview(copyNotice)
        overlay.addSubview(backToLive)
        overlay.addSubview(backPill)
        overlay.addSubview(morePill)
        copyNotice.translatesAutoresizingMaskIntoConstraints = false
        backToLive.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            backPill.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 4),
            morePill.topAnchor.constraint(equalTo: backPill.topAnchor),
            topStack.topAnchor.constraint(equalTo: backPill.bottomAnchor, constant: 8),
            topStack.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            topStack.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            copyNotice.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            copyNotice.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -8),
            backToLive.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -8),
            backToLive.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -8),
        ])

        let grid = makeGrid()
        gridView = grid
        view.addSubview(grid)
        view.addSubview(overlay)
        let keyboardBottom = grid.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        gridBottomToKeyboard = keyboardBottom
        let controlsInset: CGFloat = 12
        NSLayoutConstraint.activate([
            // Clear of a landscape notch: the grid runs edge to edge, the
            // controls stay inside the safe area.
            backPill.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: controlsInset),
            morePill.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -controlsInset),
            grid.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardBottom,
            overlay.topAnchor.constraint(equalTo: grid.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: grid.bottomAnchor),
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
        grid.rawKeyboardChanged = { [weak self] raw in
            guard let self else { return }
            self.rawKeyboard = raw
            if !raw, self.focusComposerAfterRaw {
                self.focusComposerAfterRaw = false
                if self.inputMode == .chat { self.composerFocusRequest += 1 }
            }
            self.setNeedsUpdateProperties()
        }
        grid.focusComposer = { [weak self] in
            self?.composerFocusRequest += 1
            self?.setNeedsUpdateProperties()
        }
        grid.useChatBar = { [weak self] in self?.showChatBar() }
        return grid
    }

    private func replaceChannel(_ next: SSHTerminalChannel) {
        herdrTask?.cancel()
        keymapTask?.cancel()
        herdrTask = nil
        keymapTask = nil
        keymapToken = nil
        herdr = HerdrMonitor()
        keymap = SSHTerminalKeymapLoader()
        modeOverride = nil
        lastDetectedMode = nil
        attention = SSHTerminalAttention()
        shownNoticeKey = nil
        pasteNotice = nil
        copyNoticeText = nil
        detached = false
        rawKeyboard = false
        sawClosedForBackground = false
        reconnectOnReturn = false
        channel = next
        channel.isViewed = isOnScreen && AppScenePhase.shared.phase == .active
        destroyComposer()
        gridView?.removeFromSuperview()
        let grid = makeGrid()
        gridView = grid
        view.insertSubview(grid, belowSubview: overlay)
        let keyboardBottom = grid.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        gridBottomToKeyboard = keyboardBottom
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardBottom,
            overlay.topAnchor.constraint(equalTo: grid.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: grid.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
        ])
    }

    private func applyTheme(_ themeID: ThemeID) {
        let theme = themeID.appTheme
        view.backgroundColor = UIColor(theme.bg.primary)
        overrideUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
    }

    // MARK: - Floating controls

    /// The … menu's header names the screen: the shell's title when it
    /// set one, else the host. The navigation bar that showed it is hidden.
    private func installMenu(title: String) {
        guard title != menuTitle else { return }
        menuTitle = title
        morePill.more.menu = UIMenu(
            title: title,
            children: [UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.overflowElements() ?? [])
            }]
        )
    }

    private func overflowElements() -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        if inputMode == .chat {
            items.append(UIAction(title: "Type in Terminal", image: UIImage(systemName: "keyboard")) { [weak self] _ in
                self?.showTerminalKeyboard()
            })
        } else {
            items.append(UIAction(title: "Use Chat Bar", image: UIImage(systemName: "text.bubble")) { [weak self] _ in
                self?.showChatBar()
            })
        }
        items.append(UIAction(title: "Edit Host", image: UIImage(systemName: "pencil")) { [weak self] _ in
            self?.editHost()
        })
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
        return items
    }

    private func updateFloatingControls(themeID: ThemeID) {
        let rollup = programRollup
        if let rollup, let headline = rollup.headline {
            statusGlyph.apply(
                status: headline,
                summary: rollup.summaryText,
                themeID: themeID,
                reduceMotion: reduceMotion,
                root: channel.programStatus.root.map { .init(state: $0.state, revision: $0.revision) }
            )
            attention.glyphFrame.rect = statusGlyph.glyphFrame.rect
        }
        morePill.apply(
            themeID: themeID,
            herdrAvailable: herdr.available,
            herdrWaiting: herdr.snapshot?.needsAttention,
            showsStatus: rollup?.headline != nil
        )
        backPill.apply(themeID: themeID, attentionPending: attentionPending())
        let shellTitle = channel.title.trimmingCharacters(in: .whitespacesAndNewlines)
        installMenu(title: shellTitle.isEmpty ? (hostLabel.isEmpty ? "SSH Terminal" : hostLabel) : shellTitle)
        applyControlsVisibility(animation: .init(duration: 0.2, options: [.curveEaseInOut, .beginFromCurrentState]))
    }

    /// Fades the pills with the keyboard. Hidden pills take no touches and
    /// leave the accessibility tree; edge-swipe back still works.
    private func applyControlsVisibility(animation: SSHTerminalKeyboard.Animation?) {
        let visible = SSHTerminalFloatingControls.visible(keyboardUp: keyboardUp, connected: channel.connected)
        guard visible != controlsVisible || animation == nil else { return }
        controlsVisible = visible
        for pill in [backPill, morePill] as [UIView] {
            pill.isUserInteractionEnabled = visible
            pill.accessibilityElementsHidden = !visible
        }
        let apply = {
            self.backPill.alpha = visible ? 1 : 0
            self.morePill.alpha = visible ? 1 : 0
        }
        if let animation, isOnScreen, view.window != nil {
            UIView.animate(withDuration: animation.duration, delay: 0, options: animation.options, animations: apply)
        } else {
            apply()
        }
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
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
            herdrWaiting: herdr.snapshot?.needsAttention ?? 0,
            blockedProgram: SSHTerminalProgramStatusPresentation.blockedNotice(
                store: channel.programStatus,
                isStopped: programIsStopped,
                seenAt: SSHTerminalProgramStatusPresentation.seenAt
            ) != nil
        )
    }

    /// One resize per keyboard transition. Layout-driven resizes are held,
    /// the chat bar's end state is laid out inside the keyboard's animation,
    /// and the grid size the keyboard settles at is sent once. Layout passes
    /// in between (the chat bar and the keyboard guide move in separate
    /// passes) are ignored until the transition ends; the release sends the
    /// real size only if the prediction missed. The floating controls fade in
    /// the same motion and never change the grid.
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
        applyControlsVisibility(animation: SSHTerminalKeyboard.animation(duration: max(duration, 0.2), curve: curve))
        guard isOnScreen, !isLeaving, let gridView else { return }
        keyboardTransition &+= 1
        let transition = keyboardTransition
        gridView.holdResize()
        resizeHoldTask?.cancel()
        resizeHoldTask = Task { [weak self, weak gridView] in
            // The chat bar's text view finishes editing after this
            // notification and drops its key strip. Lay out and measure once
            // that has happened, still inside the keyboard's animation.
            await Task.yield()
            guard let self, let gridView, transition == self.keyboardTransition, !self.isLeaving else { return }
            self.settleKeyboardTransition(end: end, grid: gridView, duration: duration, curve: curve)
            do { try await Task.sleep(for: .seconds(max(duration, 0.25) + 0.15)) } catch { return }
            guard transition == self.keyboardTransition, !self.isLeaving else { return }
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
            self.updateComposerHeight()
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
            inputBanner.apply(text: input, color: UIColor(themeID.palette.orange))
        }
        pasteBanner.isHidden = pasteNotice == nil
        if let pasteNotice {
            pasteBanner.apply(text: pasteNotice, color: UIColor(themeID.palette.orange))
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

    private func updateCopyAndLive(themeID: ThemeID) {
        copyNotice.isHidden = copyNoticeText == nil
        if let copyNoticeText {
            copyNotice.apply(text: copyNoticeText, themeID: themeID)
        }
        backToLive.isHidden = !detached
    }

    // MARK: - Composer

    private func updateComposer() {
        let show = inputMode == .chat && !rawKeyboard
        if show {
            embedComposer()
            refreshComposerChrome()
            if composerFocusRequest != lastAppliedComposerFocus {
                lastAppliedComposerFocus = composerFocusRequest
                composerSession?.requestFocus()
            }
        } else {
            unembedComposer()
        }
    }

    private func serverConnection() -> ServerConnection? {
        composerConnection ?? HostFactory.root(near: self)?.coordinator.activeConnection
    }

    private func makeComposer() {
        let themeID = lastThemeID ?? ThemeRuntimeState.currentThemeID()
        let session = SSHTerminalComposerHost(
            channel: channel,
            connection: serverConnection(),
            draftStore: HostFactory.root(near: self)?.composerDraftStore,
            themeID: themeID,
            showRawKeyboard: { [weak self] in self?.showTerminalKeyboard() }
        )
        session.onNeedsLayout = { [weak self] in self?.updateComposerHeight() }
        session.onFailureChange = { [weak self] message in self?.applySendFailure(message) }

        let bar = ComposerBarController()
        session.attach(bar)
        _ = bar.view

        let strip = SSHTerminalKeyStripView(
            role: .composer,
            handlers: SSHTerminalKeyStripView.Handlers(
                sendStrokes: { [weak self] strokes in self?.channel.keys(strokes) },
                sendKey: { [weak self] key in _ = self?.channel.key(key) },
                sendArrow: { [weak self] key in self?.channel.key(key) ?? false },
                showRawKeyboard: { [weak self] in self?.showTerminalKeyboard() }
            )
        )
        bar.installKeyStrip(strip)

        let container = UIStackView()
        container.axis = .vertical
        container.alignment = .fill
        container.spacing = 4
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = .clear
        container.isLayoutMarginsRelativeArrangement = true
        container.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let dictation = ComposerDictationFailureView()
        dictation.isHidden = true
        dictation.onRetry = { [weak session] in session?.retryVoice() }

        let failure = UILabel()
        failure.font = UIFont.preferredFont(forTextStyle: .caption1)
        failure.numberOfLines = 0
        failure.accessibilityIdentifier = "sshTerminal.composer.failure"
        failure.isHidden = true

        bar.view.translatesAutoresizingMaskIntoConstraints = false
        bar.view.backgroundColor = .clear
        let dictationWrap = UIView()
        dictation.translatesAutoresizingMaskIntoConstraints = false
        dictationWrap.addSubview(dictation)
        NSLayoutConstraint.activate([
            dictation.leadingAnchor.constraint(equalTo: dictationWrap.leadingAnchor, constant: 16),
            dictation.trailingAnchor.constraint(equalTo: dictationWrap.trailingAnchor, constant: -16),
            dictation.topAnchor.constraint(equalTo: dictationWrap.topAnchor),
            dictation.bottomAnchor.constraint(equalTo: dictationWrap.bottomAnchor),
        ])
        let failureWrap = UIView()
        failure.translatesAutoresizingMaskIntoConstraints = false
        failureWrap.addSubview(failure)
        NSLayoutConstraint.activate([
            failure.leadingAnchor.constraint(equalTo: failureWrap.leadingAnchor, constant: 16),
            failure.trailingAnchor.constraint(equalTo: failureWrap.trailingAnchor, constant: -16),
            failure.topAnchor.constraint(equalTo: failureWrap.topAnchor),
            failure.bottomAnchor.constraint(equalTo: failureWrap.bottomAnchor),
        ])
        dictationWrap.isHidden = true
        failureWrap.isHidden = true
        container.addArrangedSubview(dictationWrap)
        container.addArrangedSubview(failureWrap)
        container.addArrangedSubview(bar.view)

        composerSession = session
        composerBar = bar
        composerKeyStrip = strip
        composerContainer = container
        dictationFailureView = dictation
        sendFailureLabel = failure
    }

    private func embedComposer() {
        if composerBar == nil { makeComposer() }
        guard let bar = composerBar, let container = composerContainer, bar.parent !== self else {
            return
        }
        addChild(bar)
        view.addSubview(container)
        bar.didMove(toParent: self)
        gridBottomToKeyboard?.isActive = false
        guard let gridView else { return }
        let bottom = gridView.bottomAnchor.constraint(equalTo: container.topAnchor)
        gridBottomToComposer = bottom
        let height = container.heightAnchor.constraint(equalToConstant: 60)
        composerHeightConstraint = height
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            bottom,
            height,
        ])
        voicePrepareTask?.cancel()
        voicePrepareTask = Task { [weak self] in
            await self?.composerSession?.prepareVoice()
            guard !Task.isCancelled else { return }
            self?.setNeedsUpdateProperties()
        }
        updateComposerHeight()
    }

    private func unembedComposer() {
        guard let bar = composerBar, bar.parent === self else { return }
        voicePrepareTask?.cancel()
        voicePrepareTask = nil
        composerKeyStrip?.stopRepeating()
        composerSession?.releaseVoice()
        bar.view.endEditing(true)
        gridBottomToComposer?.isActive = false
        gridBottomToComposer = nil
        composerHeightConstraint?.isActive = false
        composerHeightConstraint = nil
        gridBottomToKeyboard?.isActive = true
        bar.willMove(toParent: nil)
        composerContainer?.removeFromSuperview()
        bar.removeFromParent()
    }

    private func destroyComposer() {
        voicePrepareTask?.cancel()
        voicePrepareTask = nil
        unembedComposer()
        composerBar = nil
        composerSession = nil
        composerKeyStrip = nil
        composerContainer = nil
        sendFailureLabel = nil
        dictationFailureView = nil
        lastAppliedComposerFocus = 0
    }

    private func refreshComposerChrome() {
        let themeID = lastThemeID ?? ThemeRuntimeState.currentThemeID()
        composerSession?.connection = serverConnection()
        composerSession?.draftStore = HostFactory.root(near: self)?.composerDraftStore
        composerSession?.refreshChrome(
            themeID: themeID,
            reduceMotion: reduceMotion,
            connected: channel.connected
        )
        let colors = ComposerThemeColors(palette: themeID.palette)
        composerKeyStrip?.handlers.sendStrokes = { [weak self] strokes in self?.channel.keys(strokes) }
        composerKeyStrip?.handlers.sendKey = { [weak self] key in _ = self?.channel.key(key) }
        composerKeyStrip?.handlers.sendArrow = { [weak self] key in self?.channel.key(key) ?? false }
        composerKeyStrip?.handlers.showRawKeyboard = { [weak self] in self?.showTerminalKeyboard() }
        composerKeyStrip?.apply(
            profile: keymap.profile,
            userFile: keymap.userFile,
            colors: colors,
            foreground: colors.fg,
            background: colors.bg
        )
        applySendFailure(composerSession?.sendFailure)
        applyDictationFailure()
        composerBar?.apply()
        updateComposerHeight()
    }

    private func applySendFailure(_ message: String?) {
        guard let label = sendFailureLabel else { return }
        let themeID = lastThemeID ?? ThemeRuntimeState.currentThemeID()
        let colors = ComposerThemeColors(palette: themeID.palette)
        label.text = message
        label.textColor = colors.red
        let hidden = message == nil || message?.isEmpty == true
        label.isHidden = hidden
        label.superview?.isHidden = hidden
        updateComposerHeight()
    }

    private func applyDictationFailure() {
        guard let banner = dictationFailureView else { return }
        let themeID = lastThemeID ?? ThemeRuntimeState.currentThemeID()
        let colors = ComposerThemeColors(palette: themeID.palette)
        if let failure = ComposerShared.captureFailure(composerSession?.voiceManager, owner: .inlineComposer) {
            banner.apply(message: failure.message, colors: colors)
            banner.isHidden = false
            banner.superview?.isHidden = false
        } else {
            banner.isHidden = true
            banner.superview?.isHidden = true
        }
        updateComposerHeight()
    }

    private func updateComposerHeight() {
        guard let bar = composerBar, let container = composerContainer,
              container.superview != nil else { return }
        let width = max(view.bounds.width, 1)
        let barHeight = bar.sizeThatFits(width: width).height
        let dictation: CGFloat = dictationFailureView?.isHidden == false
            ? (dictationFailureView?.systemLayoutSizeFitting(
                CGSize(width: max(width - 32, 1), height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height ?? 0) + 4
            : 0
        let failure: CGFloat = sendFailureLabel?.isHidden == false
            ? (sendFailureLabel?.sizeThatFits(CGSize(width: max(width - 32, 1), height: .greatestFiniteMagnitude)).height ?? 0)
            : 0
        let height = max(barHeight + dictation + failure, 1)
        if abs((composerHeightConstraint?.constant ?? 0) - height) > 0.5 {
            composerHeightConstraint?.constant = height
        }
    }

    // MARK: - Mode

    private var herdrAttached: Bool { SSHTerminalAgentDetection.isHerdrCommand(channel.command) }
    private var detectedMode: SSHTerminalInputMode? {
        SSHTerminalAgentDetection.mode(
            root: channel.programStatus.liveRoot, app: channel.programStatus.app(of: ""),
            herdrAttached: herdrAttached, herdr: herdr.snapshot
        )
    }
    private var inputMode: SSHTerminalInputMode { modeOverride ?? detectedMode ?? .terminal }
    private var keymapProgram: String {
        SSHTerminalAgentDetection.keymapProgram(
            root: channel.programStatus.liveRoot, app: channel.programStatus.app(of: ""),
            herdrAttached: herdrAttached, herdr: herdr.snapshot
        )
    }

    private var programIsStopped: Bool { !channel.connected && !channel.connecting }
    private var programRollup: SessionStatusRollup? {
        SSHTerminalProgramStatusPresentation.rollup(
            store: channel.programStatus,
            isStopped: programIsStopped,
            seenAt: SSHTerminalProgramStatusPresentation.seenAt
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
            isStopped: programIsStopped,
            seenAt: SSHTerminalProgramStatusPresentation.seenAt
        )
    }
    private var statusText: String {
        if channel.networkChanged { return "Network changed \u{2014} checking the connection\u{2026}" }
        return channel.connecting ? channel.reason : "Disconnected \u{00b7} \(channel.reason)"
    }

    private func showTerminalKeyboard() {
        modeOverride = .terminal
        DispatchQueue.main.async { [weak self] in
            _ = self?.gridView?.becomeFirstResponder()
        }
        setNeedsUpdateProperties()
    }

    private func showChatBar() {
        modeOverride = detectedMode == .chat ? nil : .chat
        focusComposerAfterRaw = true
        _ = gridView?.resignFirstResponder()
        setNeedsUpdateProperties()
    }

    // MARK: - Presentations

    private func showHerdr() {
        guard !presentingHerdr else { return }
        presentingHerdr = true
        herdr.watching = true
        Router.present(
            HerdrAgentsViewController(monitor: herdr, channel: channel),
            presentation: .sheet.detents([.medium(), .large()]).inNavigation(),
            from: self,
            theme: HostFactory.root(near: self)?.themeStore,
            onDismiss: { [weak self] in
                self?.presentingHerdr = false
                self?.herdr.watching = false
            }
        )
    }

    private func showStatusDetail() {
        guard !presentingStatusDetail else { return }
        presentingStatusDetail = true
        Router.present(
            SSHTerminalStatusDetailController(
                hostLabel: hostLabel,
                rows: programStatusRows,
                themeID: lastThemeID ?? ThemeRuntimeState.currentThemeID()
            ),
            presentation: .popover.keepsPopoverInCompactWidth(),
            from: self,
            sourceView: statusGlyph,
            theme: HostFactory.root(near: self)?.themeStore,
            onDismiss: { [weak self] in self?.presentingStatusDetail = false }
        )
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
            let alert = UIAlertController(
                title: "Paste \(pasteLineCount) \(pasteLineCount == 1 ? "line" : "lines")?",
                message: "This text contains a newline or terminal control sequence and may run commands. Paste only text you trust.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                self?.pendingPaste = nil
            })
            alert.addAction(UIAlertAction(title: "Paste", style: .default) { [weak self] _ in
                guard let self, let text = self.pendingPaste else { return }
                self.pendingPaste = nil
                do { try self.channel.paste(text, confirmed: true) }
                catch { self.presentPasteFailure("Paste was not sent. \(error.localizedDescription)") }
            })
            present(alert, animated: true)
        } else {
            do { try channel.paste(text) }
            catch { presentPasteFailure("Paste was not sent. \(error.localizedDescription)") }
        }
    }

    private func presentPasteFailure(_ message: String) {
        let alert = UIAlertController(title: "Paste Not Sent", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
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

    private func updatePolling() {
        // Herdr and keymaps load again when you return; they do not run off screen.
        guard isOnScreen else {
            herdrTask?.cancel()
            herdrTask = nil
            keymapTask?.cancel()
            keymapTask = nil
            keymapToken = nil
            return
        }
        if channel.connected {
            if herdrTask == nil {
                herdr.attached = herdrAttached
                herdrTask = Task { [weak self] in
                    guard let self else { return }
                    await self.herdr.run(on: self.channel)
                }
            }
        } else {
            herdrTask?.cancel()
            herdrTask = nil
        }
        let token = channel.connected ? keymapProgram : nil
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

    private func experimentChanged() {
        guard let session, !AppPreferences.Experiments.sshTerminalEnabled else { return }
        session.handleExperimentDisabled()
    }

    private func reduceMotionChanged() {
        reduceMotion = UIAccessibility.isReduceMotionEnabled
        setNeedsUpdateProperties()
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
