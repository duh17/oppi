import UIKit

/// The chat's navigation bar: Back and Files leading, the session title in
/// the middle, Outline and the context ring trailing. On a vertical toolbar
/// rail (the iPhone Duo) the same controls join the rail one per slot and the
/// session slot carries the title's menu.
///
/// Items are built once and refreshed in the chat's `updateProperties()`.
/// Each control's touch and accessibility activation run the same action.
@MainActor
final class ChatBarItems {
    weak var chat: ChatViewController?
    /// Leading items the screen around the chat adds first (the split detail
    /// root's sidebar toggle, `ChatRouteViewController`).
    var leadingPrefix: [UIBarButtonItem] = []

    // Rail items, one control per slot.
    private lazy var backItem = makeBackItem()
    private lazy var filesItem = makeFilesItem()
    private lazy var outlineItem = makeOutlineItem()
    private let railRing = ContextUsageRingButton()
    private lazy var contextItem = UIBarButtonItem(customView: railRing)
    private lazy var railSessionItem = makeRailSessionItem()
    // Horizontal bar: Back and Files share one leading item, Outline and the
    // ring one trailing item, each a group of plain controls in one glass
    // capsule.
    private lazy var backButton = Self.barButton(
        symbol: "chevron.left", textStyle: .headline, weight: .semibold,
        identifier: "chat.toolbar.back", label: "Back"
    ) { [weak self] in self?.chat?.navigateBackFromChat() }
    private lazy var filesButton = Self.barButton(
        symbol: "folder", textStyle: .subheadline, weight: .regular,
        identifier: "chat.toolbar.files", label: "Open chat files"
    ) { [weak self] in self?.chat?.toggleChatFilePanel(source: "top_leading_pill") }
    private lazy var outlineButton = Self.barButton(
        symbol: "list.bullet", textStyle: .subheadline, weight: .regular,
        identifier: "chat.toolbar.outline", label: "Open session outline"
    ) { [weak self] in self?.chat?.toggleOutlinePanel() }
    private let ringButton = ContextUsageRingButton()
    private lazy var leadingStack = Self.group([backButton, filesButton], spacing: 10)
    private lazy var trailingStack = Self.group([outlineButton, ringButton], spacing: 2)
    private lazy var leadingGroup = UIBarButtonItem(customView: leadingStack)
    private lazy var trailingGroup = UIBarButtonItem(customView: trailingStack)
    let titleControl = ChatTitleControl()

    /// Rail order, top to bottom: Back, session, Files, Outline, Context.
    /// Overflow empties the rail from the bottom; on a short rail (the Duo
    /// cover display in landscape) Back, Files, and Context stay, and the
    /// session menu and Outline go to the overflow menu first.
    /// Set while the chat leaves its stack (`clear()`); the chat lifts it when
    /// it appears again (a cancelled back swipe).
    var isSuspended = false

    func update() {
        guard let chat, !isSuspended else { return }
        let navigationItem = chat.screen.navigationItem
        let joinsRail = SystemVerticalBar.traitIsActive(chat.traitCollection)
        let usesCustomBack = chat.usesCustomChatBackButton
        let hasWorkspace = chat.session?.workspaceId != nil
        let showsOutline = chat.outlineAvailability.isAvailable
        let usesColumn = chat.usesTrailingSidePanel
        let palette = HostFactory.root(near: chat)?.themeStore.activeThemeID.palette
            ?? ThemeRuntimeState.currentPalette()
        let colors = ComposerThemeColors(palette: palette)
        for item in [backItem, filesItem, outlineItem, contextItem, railSessionItem] where item.isHidden {
            item.isHidden = false
        }
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
        let filesSymbol = filesOpen ? "folder.fill" : "folder"
        let filesLabel = filesOpen ? "Close chat files" : "Open chat files"
        filesItem.image = UIImage(systemName: filesSymbol)
        filesItem.tintColor = filesOpen ? colors.blue : colors.fg
        filesItem.accessibilityLabel = filesLabel
        filesButton.configuration?.image = UIImage(systemName: filesSymbol)
        filesButton.tintColor = filesOpen ? colors.blue : colors.fg
        filesButton.accessibilityLabel = filesLabel

        // A rail button tints while its panel is open in the trailing
        // column. A compact-width sheet covers the chat, so it needs no tint.
        let outlineTint = usesColumn && chat.model.showOutline ? colors.blue : colors.fg
        outlineItem.tintColor = outlineTint
        outlineButton.tintColor = outlineTint
        backItem.tintColor = colors.fg
        backButton.tintColor = colors.fg
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
            if hasWorkspace { rail.append(keepsVisible(filesItem)) }
            if showsOutline { rail.append(outlineItem) }
            rail.append(keepsVisible(contextItem))
            for item in rail { joinsVerticalRail(item) }
            // Trailing items run from the trailing edge in; the rail reads
            // them in declaration order from the top.
            setItems(left: leadingPrefix, right: rail.reversed(), on: navigationItem)
        } else {
            backButton.isHidden = !usesCustomBack
            filesButton.isHidden = !hasWorkspace
            outlineButton.isHidden = !showsOutline
            var leading = leadingPrefix
            if usesCustomBack || hasWorkspace { leading.append(leadingGroup) }
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

    /// Hides the chat's bar controls while it leaves its stack. UIKit keeps
    /// the outgoing items on screen while the bar animates, where they still
    /// took taps and accessibility queries meant for the screen below.
    /// `update()` shows them again.
    func clear() {
        isSuspended = true
        for item in [backItem, filesItem, outlineItem, contextItem, railSessionItem] {
            item.isHidden = true
        }
        leadingStack.isHidden = true
        trailingStack.isHidden = true
        titleControl.isHidden = true
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
            primaryAction: UIAction(title: "Files") { [weak self] _ in
                self?.chat?.toggleChatFilePanel(source: "top_leading_pill")
            }
        )
        item.accessibilityIdentifier = "chat.toolbar.files"
        return item
    }

    private func makeOutlineItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "list.bullet"),
            primaryAction: UIAction(title: "Outline") { [weak self] _ in self?.chat?.toggleOutlinePanel() }
        )
        item.accessibilityLabel = "Open session outline"
        item.accessibilityIdentifier = "chat.toolbar.outline"
        return item
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

/// The session title in the bar: the hosted title view (avatar, name, cost,
/// mirror and durable marks, Conversation subtitle). A tap renames; a long
/// press offers Copy Session ID and Share Session. One element for
/// accessibility, whose activation is the same rename.
@MainActor
final class ChatTitleControl: UIControl {
    var onTap: (() -> Void)?
    var menuProvider: (() -> UIMenu?)?
    private(set) var hostedView: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        isContextMenuInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Installs the hosted title once; its content follows the session itself.
    func install(_ view: UIView) {
        guard hostedView == nil else { return }
        hostedView = view
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
        accessibilityIdentifier = "chat.toolbar.context"
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
