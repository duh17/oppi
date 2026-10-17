import SwiftUI
import UIKit

/// Live SSH terminal: UIKit owns the screen, bar, grid, notices, and lists.
/// The chat bar is still SwiftUI `SSHTerminalComposer`, hosted through
/// `HostFactory.content` until slice D replaces it.
@MainActor
final class SSHTerminalViewController: UIViewController {
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
    private let handle = SSHTerminalTopBarHandleView()
    private let connectionBanner = SSHTerminalConnectionBannerView()
    private let inputBanner = SSHTerminalTextBannerView(identifier: "sshTerminal.inputNotice")
    private let pasteBanner = SSHTerminalTextBannerView(identifier: "sshTerminal.pasteNotice")
    private let noticeCard = SSHTerminalNoticeCardView()
    private let copyNotice = SSHTerminalCopyNoticeView()
    private let backToLive = SSHTerminalBackToLiveButton()
    private let statusGlyph = SSHTerminalStatusGlyphButton()
    private var composerHost: HostedContentController?
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
    private var topBarHidden = false
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
        installOverflowMenu()
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
        setNeedsUpdateProperties()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isOnScreen = true
        // Remote clipboard writes apply only while this screen is in front.
        channel.isViewed = AppScenePhase.shared.phase == .active
        attentionFeedback.prepare()
        if presentsStatusDetailOnAppear, !presentingStatusDetail, programRollup != nil {
            presentsStatusDetailOnAppear = false
            showStatusDetail()
        }
        setNeedsUpdateProperties()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Herdr, status detail, and paste alerts cover this screen; stay viewed.
        guard presentedViewController == nil else { return }
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
        guard isMovingFromParent || isBeingDismissed else { return }
        session?.showsTerminal = false
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
        if let reduceMotionObserver {
            NotificationCenter.default.removeObserver(reduceMotionObserver)
            self.reduceMotionObserver = nil
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
        updateBarItems(themeID: themeID)
        updateTopBarHidden(connected: connected)
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
        handle.isHidden = !(topBarHidden && connected)
        handle.apply(themeID: themeID)
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
        topStack.isLayoutMarginsRelativeArrangement = true
        topStack.layoutMargins = UIEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)

        handle.onShow = { [weak self] in self?.setTopBarHidden(false) }
        connectionBanner.onReconnect = { [weak self] in self?.reconnect() }
        noticeCard.onDismiss = { [weak self] in
            guard let self, let key = self.visibleNotice?.key else { return }
            self.attention.dismiss(key)
            self.setNeedsUpdateProperties()
        }
        noticeCard.onFrameChange = { [weak self] in self?.attention.cardFrame = $0 }
        backToLive.addAction(UIAction { [weak self] _ in
            self?.channel.engine.backToLive()
            self?.detached = false
            self?.setNeedsUpdateProperties()
        }, for: .touchUpInside)
        statusGlyph.onOpen = { [weak self] in self?.showStatusDetail() }

        handle.isHidden = true
        connectionBanner.isHidden = true
        inputBanner.isHidden = true
        pasteBanner.isHidden = true
        noticeCard.isHidden = true
        copyNotice.isHidden = true
        backToLive.isHidden = true
        topStack.addArrangedSubview(handle)
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
        copyNotice.translatesAutoresizingMaskIntoConstraints = false
        backToLive.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topStack.topAnchor.constraint(equalTo: overlay.topAnchor),
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
        topBarHidden = false
        sawClosedForBackground = false
        reconnectOnReturn = false
        channel = next
        channel.isViewed = isOnScreen && AppScenePhase.shared.phase == .active
        unembedComposer()
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
        let palette = themeID.palette
        view.backgroundColor = UIColor(palette.bg)
        overrideUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
    }

    // MARK: - Bar

    private func installOverflowMenu() {
        navigationItem.additionalOverflowItems = UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.overflowElements() ?? [])
        }
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
            items.append(UIAction(title: "Hide Bar", image: UIImage(systemName: "chevron.up")) { [weak self] _ in
                self?.setTopBarHidden(true)
            })
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

    private func updateBarItems(themeID: ThemeID) {
        var items: [UIBarButtonItem] = []
        if let rollup = programRollup, let headline = rollup.headline {
            statusGlyph.apply(
                status: headline,
                summary: rollup.summaryText,
                themeID: themeID,
                reduceMotion: reduceMotion,
                root: channel.programStatus.root.map { .init(state: $0.state, revision: $0.revision) }
            )
            attention.glyphFrame.rect = statusGlyph.glyphFrame.rect
            let item = UIBarButtonItem(customView: statusGlyph)
            item.accessibilityIdentifier = "sshTerminal.programStatus"
            configureRail(item)
            items.append(item)
        }
        if herdr.available {
            let count = herdr.snapshot?.needsAttention ?? 0
            let title = count > 0 ? "Herdr agents (\(count))" : "Herdr agents"
            let action = UIAction(title: title, image: UIImage(systemName: "square.grid.2x2")) { [weak self] _ in
                self?.showHerdr()
            }
            let item = UIBarButtonItem(primaryAction: action)
            item.accessibilityIdentifier = "sshTerminal.herdr"
            item.accessibilityLabel = "Herdr agents"
            item.accessibilityValue = herdr.snapshot.map { "\($0.needsAttention) need you" } ?? ""
            if count > 0 { item.tintColor = UIColor(themeID.palette.orange) }
            configureRail(item)
            items.append(item)
        }
        navigationItem.rightBarButtonItems = items.reversed()
    }

    private func configureRail(_ item: UIBarButtonItem) {
        if #available(iOS 27.0, *) {
            item.visibilityPriority = .high
        }
        if #available(iOS 27.1, *) {
            item.axisBehavior = .verticalPreferred
        }
    }

    private func updateTopBarHidden(connected: Bool) {
        let hide = topBarHidden && connected
        guard navigationController?.isNavigationBarHidden != hide else { return }
        navigationController?.setNavigationBarHidden(hide, animated: true)
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
        } else {
            unembedComposer()
        }
    }

    private func embedComposer() {
        let root = HostFactory.root(near: self)
        let content = composerView()
        if let host = composerHost {
            host.setContent(content)
            return
        }
        guard let root else { return }
        let host = HostFactory.content(content, root: root)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        host.sizingOptions = .intrinsicContentSize
        host.safeAreaRegions = []
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        composerHost = host
        gridBottomToKeyboard?.isActive = false
        guard let gridView else { return }
        let bottom = gridView.bottomAnchor.constraint(equalTo: host.view.topAnchor)
        gridBottomToComposer = bottom
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            bottom,
        ])
    }

    private func unembedComposer() {
        guard let host = composerHost else { return }
        gridBottomToComposer?.isActive = false
        gridBottomToComposer = nil
        gridBottomToKeyboard?.isActive = true
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        composerHost = nil
    }

    private func composerView() -> AnyView {
        var composer = AnyView(
            SSHTerminalComposer(
                channel: channel,
                focusRequest: composerFocusRequest,
                profile: keymap.profile,
                userFile: keymap.userFile,
                showRawKeyboard: { [weak self] in self?.showTerminalKeyboard() }
            )
        )
        if let composerConnection {
            composer = AnyView(composer.environment(composerConnection))
        }
        return composer
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

    private func setTopBarHidden(_ hidden: Bool) {
        guard hidden != topBarHidden else { return }
        topBarHidden = hidden
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
