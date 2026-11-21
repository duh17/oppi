import UIKit

/// The chat's navigation bar: Back leading, the session title in the middle,
/// and trailing the buttons the user chose — Files, Git, Outline, the context
/// ring, and Terminal, in their order — with a … menu holding the ones they hid. On
/// a vertical toolbar rail (the iPhone Duo) the same controls join the rail one
/// per position and the session slot carries the title's menu.
///
/// The choice is Settings → Chat → Top Bar (`ChatTopBarLayout`): one device-wide
/// setting, the same for every chat, not a per-chat decision. An action this
/// session cannot offer (Files, Git, and Terminal without a workspace, Outline on an
/// empty timeline, Terminal without a folder a shell can start in) leaves no control at
/// all, and no menu item either: what the user chose is what the bar shows, and
/// the … menu never offers a button that could only fail. A bar too narrow
/// for every chosen button keeps the first ones in the user's order and moves
/// the rest into the … menu (`capacity`), so the title keeps its room.
///
/// Items are built once and refreshed in the chat's `updateProperties()`.
/// Each control's touch and accessibility activation run the same action.
@MainActor
final class ChatBarItems {
    weak var chat: ChatViewController?

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
            image: UIImage(systemName: "ellipsis"), textStyle: .subheadline, weight: .regular,
            identifier: "chat.toolbar.more", label: "More actions"
        ) {}
        button.showsMenuAsPrimaryAction = true
        button.menu = makeTopBarMenu()
        return button
    }()
    private lazy var backItem = makeBackItem()
    private lazy var backButton = Self.barButton(
        image: UIImage(systemName: "chevron.left"), textStyle: .headline, weight: .semibold,
        identifier: "chat.toolbar.back", label: "Back",
        size: CGSize(width: Self.backButtonSide, height: Self.backButtonSide)
    ) { [weak self] in self?.chat?.navigateBackFromChat() }

    private lazy var files = ActionControls(rail: makeRailItem(.files), button: makeActionButton(.files))
    /// The horizontal bar's Git button carries the changed-file count. The
    /// rail item has no room for one; its accessibility value carries it.
    private lazy var gitButton: GitBarButton = {
        let button = GitBarButton(textStyle: .subheadline) { [weak self] in self?.chat?.runTopBarAction(.git) }
        button.accessibilityIdentifier = ChatTopBarAction.git.accessibilityIdentifier
        button.accessibilityLabel = ChatTopBarAction.git.accessibilityLabel
        button.toolTip = ChatTopBarAction.git.accessibilityLabel
        return button
    }()
    private lazy var git = ActionControls(rail: makeRailItem(.git), button: gitButton)
    /// Every trailing control's slot, the ring's included: one pitch with no
    /// spacing between slots, so the icons sit evenly apart however many are
    /// shown and whatever Git's count says (`GitBarButton`), each 44 pt tall.
    private static let barButtonSize = CGSize(width: GitBarButton.side, height: GitBarButton.height)
    /// Back alone in its own glass circle.
    private static let backButtonSide: CGFloat = 36
    /// The selected platter: a 36 pt circle centered in the slot, the ring's
    /// size (`ContextUsageRingButton`).
    private static let platterSide: CGFloat = 36
    private lazy var terminal = ActionControls(rail: makeRailItem(.terminal), button: makeActionButton(.terminal))
    private lazy var outline = ActionControls(rail: makeRailItem(.outline), button: makeActionButton(.outline))

    /// Back alone on the left; the chosen buttons and … on the right.
    private lazy var leadingStack = Self.group([backButton], spacing: 10)
    private lazy var trailingStack = Self.group([], spacing: 0)
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
        let usesColumn = chat.opensPanelsBeside
        let palette = AppRootEnvironment.near(chat)?.themeStore.activeThemeID.palette
            ?? ThemeRuntimeState.currentPalette()
        let colors = ComposerThemeColors(palette: palette)

        let drawn = placement(of: chat).bar

        // A shown action draws its own control; a hidden one is only in the …
        // menu. Nothing refills a place another action could not fill.
        let drawnSet = Set(drawn)
        let filesOpen = chat.model.panel == .files
        let open: Set<ChatTopBarAction> = filesOpen ? [.files] : []
        for (action, controls) in [
            (ChatTopBarAction.files, files), (.git, git), (.terminal, terminal), (.outline, outline),
        ] {
            controls.rail.isHidden = !drawnSet.contains(action)
            controls.button.isHidden = !drawnSet.contains(action)
            // Every pass, so a text size change reaches the Git logo, which
            // is drawn for one size, as it reaches the symbols.
            controls.rail.image = action.image(textStyle: .body, isActive: open.contains(action))
            controls.button.configuration?.image = action.image(textStyle: .subheadline, isActive: open.contains(action))
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
        navigationItem.hidesBackButton = true
        navigationItem.largeTitleDisplayMode = .never

        files.rail.accessibilityLabel = filesOpen ? "Close chat files" : ChatTopBarAction.files.accessibilityLabel
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

        // A button shows as selected while its panel is open in the trailing
        // column beside it. A compact-width sheet covers the chat, so it needs
        // no state. The bar's glass draws the content of its controls in one
        // color, so a tint never showed and none is set: the state is a
        // platter behind the icon (which glass keeps), the selected trait,
        // and on the rail the bar item's own selected state. Files keeps its
        // filled folder while its panel is open, sheet or column.
        let openInColumn: ChatTopBarAction? = switch chat.model.panel {
        case .files? where usesColumn: .files
        case .outline? where usesColumn: .outline
        case .git? where usesColumn: .git
        case .context? where usesColumn: .context
        default: nil
        }
        for (action, controls) in [(ChatTopBarAction.files, files), (.outline, outline), (.git, git)] {
            Self.showOpen(openInColumn == action, controls: controls, colors: colors)
            controls.rail.tintColor = colors.fg
            controls.button.tintColor = colors.fg
        }
        for ring in [railRing, ringButton] {
            ring.isSelected = openInColumn == .context
        }
        // The strip that used to sit over the timeline showed the branch and
        // the change count at a glance; the button says both.
        let gitSummary = chat.gitBarSummary
        let gitValue = gitSummary.map(Self.gitAccessibilityValue)
        git.rail.accessibilityValue = gitValue
        git.button.accessibilityValue = gitValue
        gitButton.apply(changedFiles: gitSummary?.changedFiles ?? 0, color: colors.fg)
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
            railSessionItem.image = chat.railSessionImage()
            railSessionItem.accessibilityValue = chat.sessionDisplayName
            var rail: [UIBarButtonItem] = []
            rail.append(keepsVisible(backItem))
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
            setItems(back: nil, right: rail.reversed(), on: navigationItem)
        } else {
            applyTrailingGroup(drawn: drawn)
            setItems(back: leadingGroup, right: [trailingGroup], on: navigationItem)
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
            gitAvailable: chat.mayHaveGit,
            showsOutline: chat.outlineAvailability.isAvailable,
            hasTerminalFolder: chat.hasUsableTerminalFolder,
            offersTerminal: chat.connection.offers(.terminal)
        )
    }

    /// The bar and the … menu for this chat now: one owner for both, so a
    /// button crowded out of the bar is in the menu on the same pass. The
    /// horizontal bar draws what fits its width (`capacity`); the Duo rail
    /// draws every shown button and the system overflows it.
    func placement(of chat: ChatViewController) -> BarPlacement<ChatTopBarAction> {
        let capacity = SystemVerticalBar.traitIsActive(chat.traitCollection)
            ? Int.max
            : Self.capacity(barWidth: chat.timelineWidth, leadingItems: leadingItemCount(of: chat))
        return AppPreferences.ChatTopBar.layout.placement(
            available: currentAvailability(of: chat), capacity: capacity, slots: { [$0] }
        )
    }

    /// The glass circles before the title: Back, and the main pane's sidebar
    /// button (`MainPaneSidebarItem`).
    private func leadingItemCount(of chat: ChatViewController) -> Int {
        1 + (chat.screen.navigationItem.mainPaneSidebarItem == nil ? 0 : 1)
    }

    /// What the bar keeps besides its buttons: the side margins, each leading
    /// glass circle with the gap after it, the gaps on both sides of the
    /// title, the title's minimum, and … with its group's padding.
    private static let barMargins: CGFloat = 2 * 16
    private static let leadingItemWidth: CGFloat = 44 + 8
    private static let titleGaps: CGFloat = 2 * 8
    static let titleMinimumWidth: CGFloat = 96
    private static let moreWidth: CGFloat = 44 + 2 * 4

    /// How many buttons the horizontal bar has room for beside Back, the
    /// title, and …, in a bar `barWidth` wide. The chat passes its timeline's
    /// width, which a pane holds while its divider moves, so the bar settles
    /// with the timeline instead of dropping buttons under the finger. Before
    /// the first layout (no width yet) nothing is crowded out.
    static func capacity(barWidth: CGFloat, leadingItems: Int) -> Int {
        guard barWidth > 0 else { return .max }
        let fixed = barMargins + CGFloat(leadingItems) * leadingItemWidth + titleGaps + titleMinimumWidth + moreWidth
        return BarCapacity.slots(width: barWidth, fixed: fixed, slotWidth: barButtonSize.width)
    }

    /// Whether the chat offers `action` now, in the bar or the … menu. The
    /// keyboard commands ask the same question the controls do.
    func isAvailable(_ action: ChatTopBarAction) -> Bool {
        guard let chat else { return false }
        return currentAvailability(of: chat).contains(action)
    }

    /// "main, 3 changed files": the Git button's value, from the count the
    /// panel opens with.
    static func gitAccessibilityValue(_ summary: (branch: String?, changedFiles: Int)) -> String {
        let count = summary.changedFiles == 1
            ? String(localized: "1 changed file")
            : String(localized: "\(summary.changedFiles) changed files")
        guard let branch = summary.branch, !branch.isEmpty else { return count }
        return "\(branch), \(count)"
    }

    /// Git is a button that could only fail in a workspace with Git status
    /// turned off, or once its loaded status says it is no repository. While
    /// the status is unknown (not loaded yet) the button stays, rather than
    /// appearing late and shifting the bar.
    static func mayOfferGit(gitStatusEnabled: Bool?, loadedStatus: GitStatus?) -> Bool {
        if gitStatusEnabled == false { return false }
        return loadedStatus?.isGitRepo ?? true
    }

    /// Which actions this chat can offer right now: the ring is always there,
    /// Files, Git, and Terminal need a workspace, Outline needs a timeline, Git
    /// needs a workspace that may be a Git repository (`gitAvailable`), and
    /// Terminal needs a workspace folder a shell can start in, so a sandbox
    /// workspace or a relative host mount offers no Terminal, and a server
    /// that offers it (`offersTerminal`, its Terminal switch).
    static func availableActions(
        hasWorkspace: Bool,
        gitAvailable: Bool,
        showsOutline: Bool,
        hasTerminalFolder: Bool,
        offersTerminal: Bool
    ) -> Set<ChatTopBarAction> {
        var available: Set<ChatTopBarAction> = [.outline, .context]
        if hasWorkspace {
            available.insert(.files)
            if gitAvailable { available.insert(.git) }
            if hasTerminalFolder, offersTerminal { available.insert(.terminal) }
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
        for item in [backItem, files.rail, git.rail, terminal.rail, outline.rail, contextItem, railSessionItem, moreItem] {
            item.isHidden = true
        }
        files.button.isHidden = true
        git.button.isHidden = true
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
        case .git: git
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
            MainActor.assumeIsolated {
                // Opening the menu is finding the tools the hint points at.
                FeatureEducationTips.markTopBarMoreToolsFound()
                completion(self?.hiddenTopBarItems() ?? [])
            }
        }
        let customize = UIAction(
            title: String(localized: "Customize Top Bar…"),
            image: UIImage(systemName: "slider.horizontal.3")
        ) { [weak self] _ in self?.chat?.customizeTopBar() }
        customize.accessibilityIdentifier = "chat.toolbar.menu.customize"
        // Split Right and Split Down on a wide window: with one pane there is
        // no grip yet, so this is where touch makes the first split. Undo and,
        // while a pane fills the window, Restore Panes.
        let panes = UIDeferredMenuElement.uncached { [weak self] completion in
            MainActor.assumeIsolated {
                guard let chat = self?.chat, let host = PaneHostController.containing(chat) else { return completion([]) }
                let items = host.screenMenuItems(for: chat).map(\.element)
                completion(items.isEmpty ? [] : [UIMenu(options: .displayInline, children: items)])
            }
        }
        // Pin Session or Unpin Session, read when the menu opens.
        let pin = UIDeferredMenuElement.uncached { [weak self] completion in
            MainActor.assumeIsolated {
                guard let chat = self?.chat else { return completion([]) }
                let connection = chat.connection
                guard connection.pinsAvailable, let api = connection.apiClient else { return completion([]) }
                let toggle = PinMenu.toggle(
                    route: .session(chat.sessionId),
                    titles: (String(localized: "Pin Session"), String(localized: "Unpin Session")),
                    identifiers: ("chat.toolbar.menu.pin", "chat.toolbar.menu.unpin"),
                    pins: connection.pins, api: api, view: chat.view
                )
                completion([UIMenu(options: .displayInline, children: [toggle.action])])
            }
        }
        return UIMenu(children: [hidden, pin, panes, customize])
    }

    /// The actions without a button (turned off, or crowded out of a narrow
    /// bar), in the user's order, for the … menu. An
    /// inline submenu is what draws the separator above Customize; with nothing
    /// hidden the menu holds Customize alone. Terminal while the experiment is
    /// off is not in here either: it cannot be drawn, so it belongs to the
    /// setting, not to a chat's menu.
    private func hiddenTopBarItems() -> [UIMenuElement] {
        guard let chat else { return [] }
        let filesOpen = chat.model.panel == .files
        let items = placement(of: chat).menu.map { action in
            let item = UIAction(
                title: Self.menuTitle(action.menuTitle(filesOpen: filesOpen), detail: menuDetail(for: action, chat: chat)),
                // The menu sizes unconfigured symbols itself; `nil` gives it
                // those, and the Git logo at the size it draws them.
                image: action.image(textStyle: nil)
            ) { [weak self] _ in self?.chat?.runTopBarAction(action) }
            item.accessibilityIdentifier = action.menuIdentifier
            return item
        }
        return items.isEmpty ? [] : [UIMenu(options: .displayInline, children: items)]
    }

    /// What a hidden action's button would have shown at a glance, for the
    /// menu: the ring's usage, and Git's changes and upstream counts.
    private func menuDetail(for action: ChatTopBarAction, chat: ChatViewController) -> String? {
        switch action {
        case .context:
            chat.contextUsageSnapshot.progress == nil ? nil : chat.contextUsageSnapshot.percentText
        case .git:
            chat.gitMenuDetail
        case .files, .outline, .terminal:
            nil
        }
    }

    /// A menu item's one line: the label, then its details after it. A
    /// subtitle would put them on a second line, and the menu then centers
    /// the icon between the two lines instead of beside the label.
    static func menuTitle(_ label: String, detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return label }
        return "\(label)  \(detail)"
    }

    /// The lines the changed files added and removed (or, for changes with no
    /// line counts, how many files changed), then the commits ahead of and
    /// behind the upstream (arrows, as in the panel's header), each left out
    /// when it is zero or unknown. Nil when all are. Short on purpose: an
    /// iPhone menu wraps a title past about 18 characters, and a wrapped title
    /// leaves the icon between its lines instead of beside the label.
    static func gitMenuDetail(changedFiles: Int, added: Int, removed: Int, ahead: Int?, behind: Int?) -> String? {
        var parts: [String] = []
        let lines = [
            added > 0 ? "+\(SessionFormatting.compactCount(added))" : nil,
            removed > 0 ? "\u{2212}\(SessionFormatting.compactCount(removed))" : nil,
        ].compactMap { $0 }
        if !lines.isEmpty {
            parts.append(lines.joined(separator: " "))
        } else if changedFiles > 0 {
            parts.append(String(localized: "\(SessionFormatting.compactCount(changedFiles)) changed"))
        }
        let upstream = [
            (ahead ?? 0) > 0 ? "\u{2191}\(SessionFormatting.compactCount(ahead ?? 0))" : nil,
            (behind ?? 0) > 0 ? "\u{2193}\(SessionFormatting.compactCount(behind ?? 0))" : nil,
        ].compactMap { $0 }
        if !upstream.isEmpty { parts.append(upstream.joined(separator: " ")) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    private static func barButton(
        image: UIImage?,
        textStyle: UIFont.TextStyle,
        weight: UIImage.SymbolWeight,
        identifier: String,
        label: String,
        size: CGSize = barButtonSize,
        action: @escaping () -> Void
    ) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = image
        // A symbol configuration also scales a plain image (the Git logo) to
        // the text size, which shrank the logo below its neighbours; such an
        // image arrives at its size already (`ChatTopBarAction.image`).
        if image?.isSymbolImage != false {
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: textStyle)
                .applying(UIImage.SymbolConfiguration(weight: weight))
        }
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: size.width),
            button.heightAnchor.constraint(equalToConstant: size.height),
        ])
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = label
        // An icon names itself under a pointer.
        button.toolTip = label
        button.isPointerInteractionEnabled = true
        return button
    }

    private static func group(_ views: [UIView], spacing: CGFloat) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = spacing
        return stack
    }

    private func setItems(back: UIBarButtonItem?, right: [UIBarButtonItem], on navigationItem: UINavigationItem) {
        navigationItem.setLeadingItems([], back: back)
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
        SystemVerticalBar.prefersRail(item)
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

    /// An action's item on the Duo's vertical rail.
    private func makeRailItem(_ action: ChatTopBarAction) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: action.image(textStyle: .body),
            primaryAction: UIAction(title: action.label) { [weak self] _ in self?.chat?.runTopBarAction(action) }
        )
        item.accessibilityLabel = action.accessibilityLabel
        item.accessibilityIdentifier = action.accessibilityIdentifier
        return item
    }

    /// A panel button's open state: the selected platter behind its icon on
    /// the horizontal bar and the selected trait for VoiceOver, and the bar
    /// item's selected state on the rail.
    private static func showOpen(_ isOpen: Bool, controls: ActionControls, colors: ComposerThemeColors) {
        controls.rail.isSelected = isOpen
        controls.button.configuration?.background.backgroundColor = isOpen
            ? colors.fg.withAlphaComponent(0.14)
            : .clear
        let horizontal = (barButtonSize.width - platterSide) / 2
        let vertical = (barButtonSize.height - platterSide) / 2
        controls.button.configuration?.background.backgroundInsets = NSDirectionalEdgeInsets(
            top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal
        )
        controls.button.configuration?.background.cornerRadius = platterSide / 2
        controls.button.accessibilityTraits = isOpen ? [.button, .selected] : .button
    }

    private func makeMoreItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), primaryAction: nil, menu: makeTopBarMenu())
        item.accessibilityLabel = "More actions"
        item.accessibilityIdentifier = "chat.toolbar.more"
        return item
    }

    private func makeActionButton(_ action: ChatTopBarAction) -> UIButton {
        Self.barButton(
            image: action.image(textStyle: .subheadline), textStyle: .subheadline, weight: .regular,
            identifier: action.accessibilityIdentifier, label: action.accessibilityLabel
        ) { [weak self] in self?.chat?.runTopBarAction(action) }
    }

    /// The rail avatar alone, for artwork that arrived after the bar was built:
    /// redrawing it must not rerun the chat's whole update pass.
    func refreshRailSessionImage() {
        guard let chat, !isSuspended else { return }
        guard SystemVerticalBar.traitIsActive(chat.traitCollection) else { return }
        railSessionItem.image = chat.railSessionImage()
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
    /// The selected platter behind the ring while the Context panel is open
    /// beside the chat, as the other panel buttons show it.
    private let platter = CALayer()

    override var isSelected: Bool {
        didSet {
            platter.isHidden = !isSelected
            accessibilityTraits = isSelected ? [.button, .selected] : .button
        }
    }

    override init(frame: CGRect) {
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = ChatTopBarAction.context.accessibilityIdentifier
        accessibilityLabel = "Open context inspector"
        platter.isHidden = true
        self.layer.addSublayer(platter)
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
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// A bar control's slot, so the ring sits on the bar's pitch.
    private static let size = CGSize(width: GitBarButton.side, height: GitBarButton.height)

    override var intrinsicContentSize: CGSize { Self.size }

    func apply(usage: ContextUsageSnapshot, colors: ComposerThemeColors) {
        track.strokeColor = colors.comment.withAlphaComponent(0.35).cgColor
        platter.backgroundColor = colors.fg.withAlphaComponent(0.14).cgColor
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
        // The same 36 pt circle as a selected bar button.
        platter.frame = CGRect(x: bounds.midX - 18, y: bounds.midY - 18, width: 36, height: 36)
        platter.cornerRadius = 18
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
    /// Panels open beside the chat in its pane host's companion (regular
    /// width), and as sheets elsewhere.
    var opensPanelsBeside: Bool {
        attachedLeaf.opensBeside
    }

    func toggleChatFilePanel(source: String) {
        AppHaptics.toolbarExpansion()
        showPanel(model.panel == .files ? nil : .files)
        ClientLog.info("FileBrowser", "Chat files toggle tapped", metadata: [
            "sessionId": sessionId,
            "workspaceId": session?.workspaceId ?? "none",
            "isFilePanelVisible": String(model.panel == .files),
            "source": source,
        ])
    }

    /// Rail and bar buttons stay visible beside an open panel in the column,
    /// so there they switch panels; a sheet covers the chat.
    func toggleOutlinePanel() {
        showPanel(opensPanelsBeside && model.panel == .outline ? nil : .outline)
    }

    func toggleContextPanel() {
        showPanel(opensPanelsBeside && model.panel == .context ? nil : .context)
    }

    func toggleGitPanel() {
        showPanel(opensPanelsBeside && model.panel == .git ? nil : .git)
    }

    /// At most one panel at a time; the newest request wins. Share's
    /// preflight stops once Share is not the panel, so another panel opening
    /// never leaves it running, and a reader's stored payload goes with it
    /// unless another reader replaces it.
    func showPanel(_ panel: ChatPanel?) {
        let previous = model.panel
        guard previous != panel else { return }
        model.panel = panel
        switch previous {
        case .share?:
            cancelSharePreflight()
        case .reader(let target)?:
            if case .reader = panel { break }
            root?.chatReaderPayloadStore.remove(target)
        default:
            break
        }
    }

    /// Closes `panel` if it is still the one open: a sheet's swipe-down, or
    /// the panel's own Close, never closes a newer panel.
    func closePanel(_ panel: ChatPanel) {
        if model.panel == panel { showPanel(nil) }
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
    func railSessionImage() -> UIImage {
        switch assistantIdentityPresentation {
        case .agent:
            EntityIcon.image(.agent(session?.launch?.agentIcon), size: 22, assets: connection.iconAssetCache)
        case .globalAvatar:
            EntityIcon.image(.pi, size: 22)
        }
    }
}

/// The chat's panels (`ChatScreenModel.panel`), shown in its attached leaf
/// on a wide window. A new panel replaces the leaf's screen. The reader
/// carries its own target, so two different reader opens are two different
/// panels even while both are "the reader". Share is reached from the
/// title's menu, not a top-bar button, but it is the same container: a
/// regular-width window used to show it full screen over everything else,
/// which the divider's full-window drag now covers instead.
enum ChatPanel: Hashable {
    case files, outline, git, context, share
    case reader(ChatReaderNavTarget)
    case timeline(ChatTimelinePanelTarget)
    /// A file this chat's text links to.
    case linkedFile(WorkspaceLinkedFileNavTarget)
    /// An extension surface's panel pane, by surface id (`PaneRoute.panel`).
    case panel(String)
    /// One of the session's internal URLs in the viewer (`PaneRoute.read`).
    case read(String)
}

extension ChatViewController {
    /// Runs a top bar action, from its button or from the … menu. One owner for
    /// both, so a rail item, a bar button, a menu item, and accessibility
    /// activation all do the same thing.
    func runTopBarAction(_ action: ChatTopBarAction) {
        switch action {
        case .files: toggleChatFilePanel(source: "top_trailing_pill")
        case .git: toggleGitPanel()
        case .outline: toggleOutlinePanel()
        case .context: toggleContextPanel()
        case .terminal: openTerminalHere()
        }
    }

    /// Customize for the top bar, as a sheet over the chat so the bar being
    /// customized stays in view and redraws as it changes.
    func customizeTopBar() {
        BarCustomizeViewController<ChatTopBarAction, Never>(surface: .chatTopBar()).presentSheet(from: self)
    }

    /// The one-time "Chat tools are in the menu" hint shows under the bar of a chat on screen
    /// that is on the default bar (only the ring) and has a workspace, so the
    /// tools it names are there to find. A bar someone customized does not
    /// need it. The coordinator decides whether it is this hint's turn among
    /// the chat's tips, and shows each tip once.
    func updateTopBarTip() {
        let eligible = hasAppeared
            && viewIfLoaded?.window != nil
            && session?.workspaceId != nil
            && AppPreferences.ChatTopBar.layout.isDefault
        if eligible {
            topBarTip.start()
        } else {
            topBarTip.stop()
        }
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

    /// "Open Terminal here" from the chat bar: the session's worktree folder,
    /// else its workspace's root, opened on the saved SSH host that serves this
    /// session's server — inside the host's multiplexer when its Run on Connect
    /// command starts one. A window wide enough to split opens it in a pane
    /// beside the chat, where `PanePlacement.sideContent` puts a terminal (below unless
    /// New Panes says otherwise); otherwise it pushes over the chat.
    func openTerminalHere() {
        guard !model.isOpeningTerminal,
              let workspaceId = session?.workspaceId else { return }
        let worktreeId = session?.worktreeId
        let apiClient = connection.apiClient
        let host = connection.credentials?.host ?? ""
        let workspaceStore = connection.workspaceStore
        let serverOffers = SSHTerminalMultiplexerAccess.offered(by: connection)
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
            let target = SSHTerminalFolderTarget(
                serverHost: host, folder: workspace.hostMount ?? "", label: workspace.name
            )
            switch await SSHTerminalFolderResolve.folder(
                workspace: workspace, worktreeId: worktreeId, apiClient: apiClient
            ) {
            case .folder(path: let folder, label: let label, isWorktree: let isWorktree):
                let folderTarget = SSHTerminalFolderTarget(
                    serverHost: host, folder: folder, label: label, isWorktree: isWorktree, serverOffers: serverOffers
                )
                openTerminal(folderTarget, workspaceId: workspaceId)
            case .noFolder:
                SSHTerminalFolderEntry.open(target, from: self, missingReason: .noFolder)
            case .failure(let message):
                SSHTerminalFolderEntry.open(target, from: self, missingReason: .lookupFailed(message))
            }
        }
    }

    /// The folder terminal in a pane beside the chat, focused, else pushed
    /// over the chat.
    private func openTerminal(_ target: SSHTerminalFolderTarget, workspaceId: String) {
        guard let serverId = connection.currentServerId ?? serverIdHint,
              let terminal = SSHTerminalFolderEntry.terminal(for: target, workspaceId: workspaceId) else {
            SSHTerminalFolderEntry.open(target, from: self)
            return
        }
        let content = PaneOpenContent(terminal: terminal, serverId: serverId)
        PaneHostController.openBeside(content, kind: .terminal, from: self)
    }
}
