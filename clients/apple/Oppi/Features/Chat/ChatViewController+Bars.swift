import UIKit

/// The chat's navigation bar: Back leading, the session title in the middle,
/// and trailing the buttons the user chose — Files, Outline, the context ring,
/// and Terminal, in their order — with a … menu holding the ones they hid. On
/// a vertical toolbar rail (the iPhone Duo) the same controls join the rail one
/// per position and the session slot carries the title's menu.
///
/// The choice is Settings → Chat → Top Bar (`ChatTopBarLayout`): one device-wide
/// setting, the same for every chat, not a per-chat decision. An action this
/// session cannot offer (Files and Terminal without a workspace, Outline on an
/// empty timeline, Terminal while the experiment is off) leaves no control at
/// all, and no menu item either: what the user chose is what the bar shows, and
/// the … menu never offers a button that could only fail.
///
/// Items are built once and refreshed in the chat's `updateProperties()`.
/// Each control's touch and accessibility activation run the same action.
@MainActor
final class ChatBarItems {
    weak var chat: ChatViewController?
    /// Leading items the screen around the chat adds first (the split detail
    /// root's sidebar toggle, `ChatRouteViewController`).
    var leadingPrefix: [UIBarButtonItem] = []

    /// A per-screen state change (a panel opened, a value the bar reads) and a
    /// menu action now build their menus and stay on the same instance. Rail
    /// items follow `ChatTopBarLayout.order`, and a hidden action is left out
    /// rather than left blank. The context ring is not one of these: it is its
    /// own control, placed in the order like the rest.
    private struct ActionControls {
        /// One rail item (the Duo rail); a hidden action has none.
        let rail: UIBarButtonItem
        /// The horizontal bar's plain control inside the trailing glass group.
        let button: UIButton
    }

    private let railRing = ContextUsageRingButton()
    private lazy var contextItem = UIBarButtonItem(customView: railRing)
    private let ringButton = ContextUsageRingButton()
    private lazy var railSessionItem = makeRailSessionItem()
    private lazy var moreItem = makeMoreItem()
    private lazy var moreButton: UIButton = {
        let button = Self.barButton(
            symbol: "ellipsis", textStyle: .subheadline, weight: .regular,
            identifier: "chat.toolbar.more", label: "More actions"
        ) {}
        button.showsMenuAsPrimaryAction = true
        button.menu = makeTopBarMenu()
        return button
    }()
    private lazy var backItem = makeBackItem()
    private lazy var backButton = Self.barButton(
        symbol: "chevron.left", textStyle: .headline, weight: .semibold,
        identifier: "chat.toolbar.back", label: "Back"
    ) { [weak self] in self?.chat?.navigateBackFromChat() }

    private lazy var files = ActionControls(rail: makeFilesItem(), button: makeActionButton(.files))
    private lazy var terminal = ActionControls(rail: makeTerminalItem(), button: makeActionButton(.terminal))
    private lazy var outline = ActionControls(rail: makeOutlineItem(), button: makeActionButton(.outline))

    /// Back alone on the left; the chosen buttons and … on the right.
    private lazy var leadingStack = Self.group([backButton], spacing: 10)
    private lazy var trailingStack = Self.group([], spacing: 2)
    private lazy var leadingGroup = UIBarButtonItem(customView: leadingStack)
    private lazy var trailingGroup = UIBarButtonItem(customView: trailingStack)
    let titleControl = ChatTitleControl()
    /// What the trailing glass group currently holds, so a pass that changes
    /// nothing leaves an open menu attached to its owner. Nil until the first
    /// pass builds the group: nothing drawn is still a group holding only ….
    private var appliedBar: [ChatTopBarAction]?

    /// Rail order, top to bottom: Back, session, then the shown buttons in the
    /// user's order, then … . Overflow empties the rail from the bottom; on a
    /// short rail (the Duo cover display in landscape) Back, the session menu,
    /// and Context stay, and the rest go to the system overflow.
    /// Set while the chat leaves its stack (`clear()`); the chat lifts it when
    /// it appears again (a cancelled back swipe).
    var isSuspended = false

    func update() {
        guard let chat, !isSuspended else { return }
        let navigationItem = chat.screen.navigationItem
        let joinsRail = SystemVerticalBar.traitIsActive(chat.traitCollection)
        let usesCustomBack = chat.usesCustomChatBackButton
        let usesColumn = chat.usesTrailingSidePanel
        let palette = HostFactory.root(near: chat)?.themeStore.activeThemeID.palette
            ?? ThemeRuntimeState.currentPalette()
        let colors = ComposerThemeColors(palette: palette)

        let available = currentAvailability(of: chat)
        let layout = AppPreferences.ChatTopBar.layout
        let drawn = layout.bar(available: available)

        // A shown action draws its own control; a hidden one is only in the …
        // menu. Nothing refills a place another action could not fill.
        let drawnSet = Set(drawn)
        for (action, controls) in [
            (ChatTopBarAction.files, files), (.terminal, terminal), (.outline, outline),
        ] {
            controls.rail.isHidden = !drawnSet.contains(action)
            controls.button.isHidden = !drawnSet.contains(action)
        }
        contextItem.isHidden = !drawnSet.contains(.context)
        for item in [backItem, railSessionItem, moreItem] where item.isHidden {
            item.isHidden = false
        }
        moreButton.isHidden = false
        ringButton.isHidden = false
        leadingStack.isHidden = false
        trailingStack.isHidden = false
        titleControl.isHidden = false

        // On the side rail the system draws the title as its own strip above
        // the timeline. The rail session menu carries the name.
        navigationItem.title = joinsRail ? "" : chat.sessionDisplayName
        navigationItem.titleView = joinsRail ? nil : titleControl
        navigationItem.hidesBackButton = usesCustomBack
        navigationItem.largeTitleDisplayMode = .never

        let filesOpen = chat.model.isFilePanelVisible
        files.rail.image = UIImage(systemName: filesOpen ? "folder.fill" : "folder")
        files.rail.tintColor = filesOpen ? colors.blue : colors.fg
        files.rail.accessibilityLabel = filesOpen ? "Close chat files" : ChatTopBarAction.files.accessibilityLabel
        files.button.configuration?.image = UIImage(systemName: filesOpen ? "folder.fill" : "folder")
        files.button.tintColor = filesOpen ? colors.blue : colors.fg
        files.button.accessibilityLabel = filesOpen ? "Close chat files" : ChatTopBarAction.files.accessibilityLabel
        // The folder lookup can take a round trip; the control says so and takes
        // no second tap until it finishes.
        let openingTerminal = chat.model.isOpeningTerminal
        terminal.rail.isEnabled = !openingTerminal
        terminal.button.isEnabled = !openingTerminal
        terminal.rail.tintColor = openingTerminal ? colors.comment : colors.fg
        terminal.button.tintColor = openingTerminal ? colors.comment : colors.fg
        terminal.rail.accessibilityValue = openingTerminal ? String(localized: "Opening…") : nil
        terminal.button.accessibilityValue = terminal.rail.accessibilityValue

        // A rail button tints while its panel is open in the trailing
        // column. A compact-width sheet covers the chat, so it needs no tint.
        let outlineTint = usesColumn && chat.model.showOutline ? colors.blue : colors.fg
        outline.rail.tintColor = outlineTint
        outline.button.tintColor = outlineTint
        backItem.tintColor = colors.fg
        backButton.tintColor = colors.fg
        moreItem.tintColor = colors.fg
        moreButton.tintColor = colors.fg
        for ring in [railRing, ringButton] {
            ring.apply(usage: chat.contextUsageSnapshot, colors: colors)
            ring.onTap = { [weak chat] in chat?.toggleContextPanel() }
        }

        if joinsRail {
            railSessionItem.menu = makeSessionMenu(title: chat.sessionDisplayName, includesRename: true)
            railSessionItem.image = chat.railSessionImage(palette: palette)
            railSessionItem.accessibilityValue = chat.sessionDisplayName
            var rail: [UIBarButtonItem] = []
            if usesCustomBack { rail.append(keepsVisible(backItem)) }
            rail.append(railSessionItem)
            for action in drawn {
                if action == .context {
                    rail.append(keepsVisible(contextItem))
                } else if let controls = controls(for: action) {
                    rail.append(controls.rail)
                }
            }
            rail.append(moreItem)
            for item in rail { joinsVerticalRail(item) }
            // Trailing items run from the trailing edge in; the rail reads
            // them in declaration order from the top.
            setItems(left: leadingPrefix, right: rail.reversed(), on: navigationItem)
        } else {
            backButton.isHidden = !usesCustomBack
            applyTrailingGroup(drawn: drawn)
            var leading = leadingPrefix
            if usesCustomBack { leading.append(leadingGroup) }
            setItems(left: leading, right: [trailingGroup], on: navigationItem)
        }

        titleControl.onTap = { [weak chat] in chat?.presentRenameAlert() }
        titleControl.menuProvider = { [weak self, weak chat] in
            guard let self, let chat else { return nil }
            return self.makeSessionMenu(title: nil, includesRename: false, chat: chat)
        }
        titleControl.accessibilityLabel = "Rename session"
        titleControl.accessibilityValue = chat.assistantIdentityPresentation == .globalAvatar
            ? chat.sessionDisplayName
            : "\(chat.sessionDisplayName), launched with a saved Agent"
    }

    /// Which actions this chat can offer right now. One owner for the bar and
    /// for the … menu, so a button that leaves the bar appears in the menu on
    /// the same pass.
    private func currentAvailability(of chat: ChatViewController) -> Set<ChatTopBarAction> {
        Self.availableActions(
            hasWorkspace: chat.session?.workspaceId != nil,
            showsOutline: chat.outlineAvailability.isAvailable,
            terminalEnabled: AppPreferences.Experiments.sshTerminalEnabled && chat.hasUsableTerminalFolder
        )
    }

    /// Which actions this chat can offer right now: the ring is always there,
    /// Files and Terminal need a workspace, Outline needs a timeline, and
    /// Terminal also needs a workspace folder a shell can start in, so a sandbox
    /// workspace or a relative host mount offers no Terminal.
    static func availableActions(
        hasWorkspace: Bool,
        showsOutline: Bool,
        terminalEnabled: Bool
    ) -> Set<ChatTopBarAction> {
        var available: Set<ChatTopBarAction> = [.outline, .context]
        if hasWorkspace {
            available.insert(.files)
            if terminalEnabled { available.insert(.terminal) }
        }
        if !showsOutline { available.remove(.outline) }
        return available
    }

    /// Hides the chat's bar controls while it leaves its stack. UIKit keeps
    /// the outgoing items on screen while the bar animates, where they still
    /// took taps and accessibility queries meant for the screen below.
    /// `update()` shows them again.
    func clear() {
        isSuspended = true
        for item in [backItem, files.rail, terminal.rail, outline.rail, contextItem, railSessionItem, moreItem] {
            item.isHidden = true
        }
        files.button.isHidden = true
        terminal.button.isHidden = true
        outline.button.isHidden = true
        moreButton.isHidden = true
        ringButton.isHidden = true
        leadingStack.isHidden = true
        trailingStack.isHidden = true
        titleControl.isHidden = true
    }

    /// The action's own rail item and bar button. The ring is not one of these:
    /// `.context` draws `contextItem` on the rail and `ringButton` in the bar,
    /// so it answers nil here and the callers place the ring themselves.
    private func controls(for action: ChatTopBarAction) -> ActionControls? {
        switch action {
        case .files: files
        case .terminal: terminal
        case .outline: outline
        case .context: nil
        }
    }

    /// The trailing glass group: the shown buttons in the user's order, with …
    /// last. The ring takes the place `.context` has in that order.
    private func applyTrailingGroup(drawn: [ChatTopBarAction]) {
        guard appliedBar != drawn else { return }
        appliedBar = drawn
        for view in trailingStack.arrangedSubviews {
            trailingStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for action in drawn {
            if action == .context {
                trailingStack.addArrangedSubview(ringButton)
            } else if let controls = controls(for: action) {
                controls.button.isHidden = false
                trailingStack.addArrangedSubview(controls.button)
            }
        }
        trailingStack.addArrangedSubview(moreButton)
    }

    /// The … menu, built once: the hidden actions are resolved when the menu
    /// opens, so a pass that changes the bar never has to rebuild and re-attach
    /// the menu its owner is holding.
    private func makeTopBarMenu() -> UIMenu {
        let hidden = UIDeferredMenuElement.uncached { [weak self] completion in
            // The menu asks on the main thread; `assumeIsolated` keeps the call
            // to the bar's state a main-actor one either way.
            MainActor.assumeIsolated { completion(self?.hiddenTopBarItems() ?? []) }
        }
        let customize = UIAction(
            title: String(localized: "Customize Top Bar…"),
            image: UIImage(systemName: "slider.horizontal.3")
        ) { [weak self] _ in self?.chat?.customizeTopBar() }
        customize.accessibilityIdentifier = "chat.toolbar.menu.customize"
        return UIMenu(children: [hidden, customize])
    }

    /// The actions without a button, in the user's order, for the … menu. An
    /// inline submenu is what draws the separator above Customize; with nothing
    /// hidden the menu holds Customize alone. Terminal while the experiment is
    /// off is not in here either: it cannot be drawn, so it belongs to the
    /// setting, not to a chat's menu.
    private func hiddenTopBarItems() -> [UIMenuElement] {
        guard let chat else { return [] }
        let available = currentAvailability(of: chat)
        let filesOpen = chat.model.isFilePanelVisible
        let items = AppPreferences.ChatTopBar.layout.menu(available: available).map { action in
            let item = UIAction(
                title: action.menuTitle(filesOpen: filesOpen),
                image: UIImage(systemName: action.symbolName)
            ) { [weak self] _ in self?.chat?.runTopBarAction(action) }
            item.accessibilityIdentifier = action.menuIdentifier
            // The ring's number is the reason to open the panel; the menu keeps
            // it visible without a bar position.
            if action == .context {
                item.subtitle = chat.contextUsageSnapshot.percentText
            }
            return item
        }
        return items.isEmpty ? [] : [UIMenu(options: .displayInline, children: items)]
    }

    private static func barButton(
        symbol: String,
        textStyle: UIFont.TextStyle,
        weight: UIImage.SymbolWeight,
        identifier: String,
        label: String,
        action: @escaping () -> Void
    ) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: textStyle)
            .applying(UIImage.SymbolConfiguration(weight: weight))
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 36),
            button.heightAnchor.constraint(equalToConstant: 36),
        ])
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = label
        return button
    }

    private static func group(_ views: [UIView], spacing: CGFloat) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = spacing
        return stack
    }

    private func setItems(left: [UIBarButtonItem], right: [UIBarButtonItem], on navigationItem: UINavigationItem) {
        if navigationItem.leftBarButtonItems?.elementsEqual(left, by: ===) != true {
            navigationItem.leftBarButtonItems = left
        }
        if navigationItem.rightBarButtonItems?.elementsEqual(right, by: ===) != true {
            navigationItem.rightBarButtonItems = right
        }
    }

    private func keepsVisible(_ item: UIBarButtonItem) -> UIBarButtonItem {
        if #available(iOS 27.0, *) {
            item.visibilityPriority = .high
        }
        return item
    }

    private func joinsVerticalRail(_ item: UIBarButtonItem) {
        if #available(iOS 27.1, *) {
            item.axisBehavior = .verticalPreferred
        }
    }

    private func makeBackItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"),
            primaryAction: UIAction(title: "Back") { [weak self] _ in self?.chat?.navigateBackFromChat() }
        )
        item.accessibilityLabel = "Back"
        item.accessibilityIdentifier = "chat.toolbar.back"
        return item
    }

    private func makeFilesItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "folder"),
            primaryAction: UIAction(title: "Files") { [weak self] _ in self?.chat?.runTopBarAction(.files) }
        )
        item.accessibilityLabel = ChatTopBarAction.files.accessibilityLabel
        item.accessibilityIdentifier = ChatTopBarAction.files.accessibilityIdentifier
        return item
    }

    private func makeTerminalItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "terminal"),
            primaryAction: UIAction(title: "Terminal") { [weak self] _ in self?.chat?.runTopBarAction(.terminal) }
        )
        item.accessibilityLabel = ChatTopBarAction.terminal.accessibilityLabel
        item.accessibilityIdentifier = ChatTopBarAction.terminal.accessibilityIdentifier
        return item
    }

    private func makeOutlineItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "list.bullet"),
            primaryAction: UIAction(title: "Outline") { [weak self] _ in self?.chat?.runTopBarAction(.outline) }
        )
        item.accessibilityLabel = ChatTopBarAction.outline.accessibilityLabel
        item.accessibilityIdentifier = ChatTopBarAction.outline.accessibilityIdentifier
        return item
    }

    private func makeMoreItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), primaryAction: nil, menu: makeTopBarMenu())
        item.accessibilityLabel = "More actions"
        item.accessibilityIdentifier = "chat.toolbar.more"
        return item
    }

    private func makeActionButton(_ action: ChatTopBarAction) -> UIButton {
        Self.barButton(
            symbol: action.symbolName, textStyle: .subheadline, weight: .regular,
            identifier: action.accessibilityIdentifier, label: action.accessibilityLabel
        ) { [weak self] in self?.chat?.runTopBarAction(action) }
    }

    private func makeRailSessionItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(title: "Session", image: nil, primaryAction: nil, menu: nil)
        item.accessibilityLabel = "Session"
        item.accessibilityIdentifier = "chat.rail.session"
        return item
    }

    private func makeSessionMenu(title: String?, includesRename: Bool, chat: ChatViewController? = nil) -> UIMenu {
        guard let chat = chat ?? self.chat else { return UIMenu() }
        var actions: [UIMenuElement] = []
        if includesRename {
            actions.append(UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { [weak chat] _ in
                chat?.presentRenameAlert()
            })
        }
        actions.append(UIAction(title: "Copy Session ID", image: UIImage(systemName: "doc.on.doc")) { [weak chat] _ in
            chat?.copySessionID()
        })
        let share = UIAction(title: "Share Session", image: UIImage(systemName: "square.and.arrow.up")) { [weak chat] _ in
            chat?.shareSessionFromTitleMenu()
        }
        if !chat.hasShareSlashCommand { share.attributes = .disabled }
        actions.append(share)
        guard let title else { return UIMenu(children: actions) }
        return UIMenu(children: [UIMenu(title: title, options: .displayInline, children: actions)])
    }
}


/// The session title in the bar: `ChatTitleView` (avatar, name, cost,
/// mirror and durable marks, Conversation subtitle). A tap renames; a long
/// press offers Copy Session ID and Share Session. One element for
/// accessibility, whose activation is the same rename.
@MainActor
final class ChatTitleControl: UIControl {
    var onTap: (() -> Void)?
    var menuProvider: (() -> UIMenu?)?
    private(set) var titleView: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        isContextMenuInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Installs the title view once; its content follows the session itself.
    func install(_ view: UIView) {
        guard titleView == nil else { return }
        titleView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func accessibilityActivate() -> Bool {
        onTap?()
        return true
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let menu = menuProvider?() else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }
}

/// The context ring in the bar: how full the session's context window is.
/// Opens the Context panel; touch and accessibility activation run the same
/// action.
@MainActor
final class ContextUsageRingButton: UIControl {
    var onTap: (() -> Void)?
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = ChatTopBarAction.context.accessibilityIdentifier
        accessibilityLabel = "Open context inspector"
        for layer in [track, fill] {
            layer.fillColor = UIColor.clear.cgColor
            self.layer.addSublayer(layer)
        }
        track.lineWidth = 2
        fill.lineWidth = 2.2
        fill.lineCap = .round
        label.font = UIFont.systemFont(ofSize: 7, weight: .semibold).rounded()
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.isAccessibilityElement = false
        addSubview(label)
        addAction(UIAction { [weak self] _ in
            AppHaptics.toolbarExpansion()
            self?.onTap?()
        }, for: .touchUpInside)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 44),
            heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize { CGSize(width: 44, height: 44) }

    func apply(usage: ContextUsageSnapshot, colors: ComposerThemeColors) {
        track.strokeColor = colors.comment.withAlphaComponent(0.35).cgColor
        let progress = usage.progress
        let stroke: UIColor = if let progress {
            progress > 0.9 ? colors.red : progress > 0.7 ? colors.orange : colors.green
        } else {
            colors.comment
        }
        fill.strokeColor = stroke.cgColor
        fill.isHidden = progress == nil
        fill.strokeEnd = CGFloat(progress ?? 0)
        label.text = progress.map { String(Int(($0 * 100).rounded())) } ?? "0"
        label.textColor = colors.fg
        accessibilityValue = usage.accessibilityLabel
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let ring = CGRect(x: bounds.midX - 12, y: bounds.midY - 12, width: 24, height: 24)
        // Starts at 12 o'clock, like the rotated SwiftUI circle.
        let path = UIBezierPath(
            arcCenter: CGPoint(x: ring.midX, y: ring.midY),
            radius: 11,
            startAngle: -.pi / 2,
            endAngle: 3 * .pi / 2,
            clockwise: true
        ).cgPath
        track.path = path
        fill.path = path
        label.frame = ring.insetBy(dx: 3, dy: 3)
    }

    override func accessibilityActivate() -> Bool {
        sendActions(for: .touchUpInside)
        return true
    }
}

private extension UIFont {
    func rounded() -> UIFont {
        guard let descriptor = fontDescriptor.withDesign(.rounded) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

extension ChatViewController {
    var usesTrailingSidePanel: Bool {
        TrailingSidePanelPolicy.usesTrailingColumn(horizontalSizeClass: traitCollection.horizontalSizeClass)
    }

    func toggleChatFilePanel(source: String) {
        AppHaptics.toolbarExpansion()
        let willShow = !model.isFilePanelVisible
        model.isFilePanelVisible = willShow
        ClientLog.info("FileBrowser", "Chat files toggle tapped", metadata: [
            "sessionId": sessionId,
            "workspaceId": session?.workspaceId ?? "none",
            "isFilePanelVisible": String(model.isFilePanelVisible),
            "selectedTab": model.selectedFilePanelTab.rawValue,
            "source": source,
        ])
        if model.isFilePanelVisible {
            model.showOutline = false
            model.showContextInspector = false
        }
    }

    /// Rail and bar buttons stay visible beside an open panel in the column,
    /// so there they switch panels; a sheet covers the chat.
    func toggleOutlinePanel() {
        if usesTrailingSidePanel {
            showSidePanel(model.showOutline ? nil : .outline)
        } else {
            model.showOutline = true
        }
    }

    func toggleContextPanel() {
        if usesTrailingSidePanel {
            showSidePanel(model.showContextInspector ? nil : .context)
        } else {
            model.showContextInspector = true
        }
    }

    /// At most one side panel at a time; the newest request wins.
    func showSidePanel(_ panel: ChatSidePanel?) {
        model.isFilePanelVisible = panel == .files
        model.showOutline = panel == .outline
        model.showContextInspector = panel == .context
    }

    func presentRenameAlert() {
        let alert = UIAlertController(title: "Rename Session", message: nil, preferredStyle: .alert)
        // The theme's accent, as SwiftUI alerts get from the app root's `.tint(.themeBlue)`.
        let palette = root?.themeStore.activeThemeID.palette ?? ThemeRuntimeState.currentPalette()
        alert.view.tintColor = ComposerThemeColors(palette: palette).blue
        let currentName = session?.name ?? ""
        alert.addTextField { field in
            field.placeholder = "Session name"
            field.text = currentName
        }
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert] _ in
            self?.rename(to: alert?.textFields?.first?.text ?? "")
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        Router.topPresenter(from: self).present(alert, animated: true)
    }

    /// The session slot's avatar on the rail.
    func railSessionImage(palette: ThemePalette) -> UIImage {
        switch assistantIdentityPresentation {
        case .agent:
            AgentIconRenderer.render(value: session?.launch?.agentIcon, size: AgentIconSizingPolicy.titleTextMinimum)
                .withRenderingMode(.alwaysOriginal)
        case .globalAvatar:
            PiAvatarRenderer.render(size: 22, themeID: HostFactory.root(near: self)?.themeStore.activeThemeID)
                .withRenderingMode(.alwaysOriginal)
        }
    }
}

/// The chat's side panels. A new panel replaces the column's screen.
enum ChatSidePanel: Hashable {
    case files, outline, context
}

extension ChatViewController {
    /// Runs a top bar action, from its button or from the … menu. One owner for
    /// both, so a rail item, a bar button, a menu item, and accessibility
    /// activation all do the same thing.
    func runTopBarAction(_ action: ChatTopBarAction) {
        switch action {
        case .files: toggleChatFilePanel(source: "top_trailing_pill")
        case .outline: toggleOutlinePanel()
        case .context: toggleContextPanel()
        case .terminal: openTerminalHere()
        }
    }

    /// Settings → Chat → Top Bar, pushed over the chat so the bar being
    /// customized stays one Back away.
    func customizeTopBar() {
        Router.push(SettingsChatTopBarViewController(), from: self)
    }

    /// Whether this chat has a folder a folder terminal can start in: the
    /// session's worktree, else its workspace root. A sandbox workspace runs
    /// inside its sandbox, and a relative host mount resolves on the server, so
    /// neither offers a terminal here.
    var hasUsableTerminalFolder: Bool {
        guard let workspaceId = session?.workspaceId,
              let workspace = connection.workspaceStore.workspaces.first(where: { $0.id == workspaceId })
        else { return false }
        return SSHTerminalFolderTarget.workspace(workspace) != nil
    }

    /// "Open Terminal here" from the chat bar: a login shell on the saved SSH
    /// host that serves this session's server, starting in the session's
    /// worktree folder when it has one, else in its workspace's root.
    func openTerminalHere() {
        guard AppPreferences.Experiments.sshTerminalEnabled,
              !model.isOpeningTerminal,
              let workspaceId = session?.workspaceId else { return }
        let worktreeId = session?.worktreeId
        let apiClient = connection.apiClient
        let host = connection.credentials?.host ?? ""
        let workspaceStore = connection.workspaceStore
        model.isOpeningTerminal = true
        Task { [weak self] in
            defer { self?.model.isOpeningTerminal = false }
            guard let self else { return }
            guard let workspace = workspaceStore.workspaces.first(where: { $0.id == workspaceId }) else {
                SSHTerminalFolderEntry.open(
                    SSHTerminalFolderTarget(serverHost: host, folder: ""),
                    from: self,
                    missingReason: .unknownWorkspace
                )
                return
            }
            // A worktree's own folder is one API call away and resolves to the
            // workspace root only when the session has no worktree or the server
            // does not have the route.
            let target = SSHTerminalFolderTarget(serverHost: host, folder: workspace.hostMount ?? "")
            switch await SSHTerminalFolderResolve.folder(
                workspace: workspace, worktreeId: worktreeId, apiClient: apiClient
            ) {
            case .folder(let folder):
                SSHTerminalFolderEntry.open(
                    SSHTerminalFolderTarget(serverHost: host, folder: folder), from: self
                )
            case .noFolder:
                SSHTerminalFolderEntry.open(target, from: self, missingReason: .noFolder)
            case .failure(let message):
                SSHTerminalFolderEntry.open(target, from: self, missingReason: .lookupFailed(message))
            }
        }
    }
}
