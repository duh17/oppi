import UIKit

/// The screen's chrome: the progress panel over the list, the rail and
/// compact bars (with the Git button that opens the Git panel), and the
/// worktree title and menu.
extension WorkspaceDetailViewController {
    /// The creating / resuming progress panel.
    func syncProgressPanel() {
        if state.isCreating || state.isImportingLocal {
            progressPanel.text = state.isImportingLocal
                ? String(localized: "Resuming session...")
                : String(localized: "Creating session...")
            progressPanel.isHidden = false
            view.bringSubviewToFront(progressPanel)
        } else {
            progressPanel.isHidden = true
        }
    }

    // MARK: Bars

    /// Rail and compact bars. Items rebuild when their set changes; the
    /// SwiftUI controls inside them update in place.
    func syncBars(_ detail: DetailState) {
        let joinsRail = SessionListBarItems.joinsRail(traitCollection)
        let palette = root.themeStore.activeThemeID.palette
        let showsDictation = SessionInboxComposeChrome.showsDictationShortcut(hasActivePlayback: detail.hasActivePlayback)
        let showsBottomItems = !detail.isNavigatingDeeper

        navigationItem.title = detail.workspace.name
        navigationItem.backBarButtonItem?.accessibilityLabel = detail.workspace.name

        let worktrees = visibleWorktrees(detail.workspace)
        let selectedName = state.worktrees.first { $0.id == state.selectedWorktreeId }?.displayName ?? "Main"
        let title = TitleState(
            name: detail.workspace.name,
            worktreeName: selectedName,
            worktrees: worktrees,
            selectedWorktreeId: state.selectedWorktreeId,
            canSwitch: !state.isLoadingWorktrees && worktrees.count > 1,
            lockBadge: detail.lockBadge,
            themeID: root.themeStore.activeThemeID
        )

        if !joinsRail, showsBottomItems {
            bottomBar.update(
                showsDictation: showsDictation,
                hasActivePlayback: detail.hasActivePlayback,
                toolbar: detail.toolbar,
                player: detail.connection.audioPlayer,
                columnWidth: columnWidth
            )
            // Disabled while a session is being created.
            bottomBar.composeHost?.view.isUserInteractionEnabled = !state.isCreating
            bottomBar.composeHost?.view.alpha = state.isCreating ? 0.55 : 1
        }

        let bars = BarState(
            joinsRail: joinsRail,
            showsSidebarToggle: showsSidebarToggle,
            isSplit: detail.isSplit,
            showsBottomItems: showsBottomItems,
            showsNowPlaying: detail.toolbar.showsNowPlayingPill,
            parksNowPlayingNextToCompose: detail.toolbar.parksNowPlayingNextToCompose,
            isCreating: state.isCreating,
            showsDictation: showsDictation,
            showsUnlockedBadge: detail.lockBadge == .unlocked,
            configurationLabel: Self.configurationAccessibilityLabel(detail.workspace),
            // Offered only where it can actually open: the workspace has a host
            // folder a shell can start in.
            showsGit: ChatBarItems.mayOfferGit(
                gitStatusEnabled: detail.workspace.gitStatusEnabled,
                loadedStatus: detail.gitStatus
            ),
            showsTerminal: SSHTerminalFolderTarget.workspace(detail.workspace) != nil,
            title: title
        )
        if bars != barState {
            barState = bars
            installBarItems(bars, palette: palette)
        }
        syncGit(detail, palette: palette)
        if title != titleState {
            titleState = title
            configureTitleButton(title, palette: palette)
        }
        if let sidebarToggle {
            WorkspaceSplitSidebarToggle.sync(sidebarToggle, root: root)
        }
    }

    /// The Git button's count and value follow the status every pass, without
    /// rebuilding the bar: the selected worktree's changed files, as the
    /// chat's button counts a worktree session's.
    private func syncGit(_ detail: DetailState, palette: ThemePalette) {
        let gitStatus = detail.gitStatus.flatMap { $0.isGitRepo ? $0 : nil }
        let changedFiles = gitStatus?.uncommittedCount ?? 0
        let value = gitStatus.map { ChatBarItems.gitAccessibilityValue(($0.branch, changedFiles)) }
        gitButton.apply(changedFiles: changedFiles, color: UIColor(palette.fg))
        gitButton.tintColor = UIColor(palette.fg)
        gitButton.accessibilityValue = value
        gitRailItem?.accessibilityValue = value
    }

    private static func configurationAccessibilityLabel(_ workspace: Workspace) -> String {
        workspace.runtime == .sandbox
            ? String(localized: "Edit sandbox workspace")
            : String(localized: "Edit workspace")
    }

    private func installBarItems(_ bars: BarState, palette: ThemePalette) {
        let tint = UIColor(palette.fg)
        let railTint = SessionListBarItems.railTint(palette)
        sidebarToggle = bars.showsSidebarToggle ? WorkspaceSplitSidebarToggle.makeItem(root: root) : nil
        var leading: [UIBarButtonItem] = sidebarToggle.map { [$0] } ?? []
        var trailing: [UIBarButtonItem] = []
        var bottom: [UIBarButtonItem] = []
        let showWorkspaces = UIAction { [weak self] _ in self?.navigation.showWorkspaceListInSplitSidebar() }
        let openConfiguration = UIAction { [weak self] _ in self?.openWorkspaceConfiguration() }
        let openFiles: () -> Void = { [weak self] in self?.openWorkspaceFiles() }
        let openTerminal: () -> Void = { [weak self] in self?.openWorkspaceTerminal() }

        if bars.joinsRail {
            // The principal title is a wide custom view; the rail keeps the
            // system title and a labeled worktree symbol with the same menu.
            navigationItem.titleView = nil
            if bars.isSplit {
                // Split detail has no system Back.
                let item = UIBarButtonItem(
                    title: String(localized: "Workspaces"),
                    image: UIImage(systemName: "sidebar.leading"),
                    primaryAction: showWorkspaces
                )
                item.tintColor = railTint
                item.accessibilityLabel = String(localized: "Show workspaces")
                item.accessibilityIdentifier = "workspace.sidebar.showWorkspaces"
                trailing.append(SessionListBarItems.railItem(item, priority: .navigation))
            }
            if bars.showsBottomItems {
                let compose = bottomBar.railCompose(showsDictation: bars.showsDictation, tint: railTint)
                compose.isEnabled = !bars.isCreating
                trailing.append(compose)
            }
            if bars.showsUnlockedBadge {
                let badge = UIBarButtonItem(
                    title: String(localized: "Unlocked"),
                    image: UIImage(systemName: "lock.open.fill"),
                    primaryAction: nil
                )
                badge.tintColor = tint
                badge.accessibilityLabel = String(localized: "Unlocked")
                badge.accessibilityIdentifier = "lockBadge.unlocked"
                trailing.append(SessionListBarItems.railItem(badge, priority: .keep))
            }
            trailing.append(SessionListBarItems.railItem(worktreeRailItem(bars.title, tint: tint), priority: .keep))
            // Git, Terminal, then Config: the same order in both bar shapes.
            if bars.showsGit {
                let git = UIBarButtonItem(
                    title: String(localized: "Git"),
                    image: GitLogoImage.image(textStyle: .body),
                    primaryAction: UIAction { [weak self] _ in self?.openWorkspaceGit() }
                )
                git.tintColor = railTint
                git.accessibilityLabel = gitButton.accessibilityLabel
                git.accessibilityIdentifier = gitButton.accessibilityIdentifier
                gitRailItem = git
                trailing.append(SessionListBarItems.railItem(git, priority: .keep))
            } else {
                gitRailItem = nil
            }
            if bars.showsTerminal {
                trailing.append(SessionListBarItems.railItem(terminalBarItem(tint: railTint, title: true, action: openTerminal), priority: .keep))
            }
            let configuration = UIBarButtonItem(
                title: String(localized: "Config"),
                image: UIImage(systemName: "slider.horizontal.3"),
                primaryAction: openConfiguration
            )
            configuration.tintColor = railTint
            configuration.accessibilityLabel = bars.configurationLabel
            configuration.accessibilityIdentifier = "workspace.edit.open"
            trailing.append(SessionListBarItems.railItem(configuration, priority: .keep))
            if bars.showsBottomItems {
                if bars.showsNowPlaying {
                    trailing.append(bottomBar.railNowPlaying(tint: railTint))
                }
                // Bottom-anchored: spacers cannot push a rail item down.
                bottom.append(SessionListBarItems.files(
                    isEnabled: true,
                    accessibilityLabel: String(localized: "Open workspace files"),
                    railTitle: String(localized: "Files"),
                    palette: palette,
                    action: openFiles
                ))
            }
        } else {
            navigationItem.titleView = titleButton
            if bars.isSplit {
                let item = UIBarButtonItem(image: UIImage(systemName: "chevron.left"), primaryAction: showWorkspaces)
                item.tintColor = tint
                item.accessibilityLabel = String(localized: "Show workspaces")
                item.accessibilityIdentifier = "workspace.sidebar.showWorkspaces"
                leading.append(SessionListBarItems.horizontalOnly(item))
            }
            let configuration = UIBarButtonItem(
                image: UIImage(systemName: "slider.horizontal.3"),
                primaryAction: openConfiguration
            )
            configuration.tintColor = tint
            configuration.accessibilityLabel = bars.configurationLabel
            configuration.accessibilityIdentifier = "workspace.edit.open"
            gitRailItem = nil
            if bars.showsGit {
                trailing.append(UIBarButtonItem(customView: gitButton))
            }
            if bars.showsTerminal {
                trailing.append(terminalBarItem(tint: tint, title: false, action: openTerminal))
            }
            trailing.append(configuration)
            if bars.showsBottomItems {
                bottom = bottomBar.items(
                    showsNowPlaying: bars.showsNowPlaying,
                    parksNowPlayingNextToCompose: bars.parksNowPlayingNextToCompose,
                    files: SessionListBarItems.files(
                        isEnabled: true,
                        accessibilityLabel: String(localized: "Open workspace files"),
                        railTitle: nil,
                        palette: palette,
                        action: openFiles
                    )
                )
            }
        }

        navigationItem.leadingItemGroups = leading.isEmpty
            ? [] : [UIBarButtonItemGroup(barButtonItems: leading, representativeItem: nil)]
        navigationItem.trailingItemGroups = trailing.isEmpty
            ? [] : [UIBarButtonItemGroup(barButtonItems: trailing, representativeItem: nil)]
        setToolbarItems(bottom, animated: false)
        if navigationController?.topViewController === self {
            navigationController?.setToolbarHidden(bottom.isEmpty, animated: false)
        }
    }

    // MARK: Title and worktree menu

    /// "Open Terminal here": a login shell on the saved SSH host for this
    /// server, starting in the workspace's root folder.
    private func terminalBarItem(tint: UIColor, title: Bool, action: @escaping () -> Void) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            title: title ? String(localized: "Terminal") : nil,
            image: UIImage(systemName: "terminal"),
            primaryAction: UIAction { _ in action() }
        )
        item.tintColor = tint
        item.accessibilityLabel = String(localized: "Open terminal here")
        item.accessibilityIdentifier = "workspace.terminal.open"
        return item
    }

    private func worktreeMenu(_ title: TitleState) -> UIMenu {
        let actions = title.worktrees.map { worktree in
            var label = WorkspaceWorktreeMenuFormatting.title(for: worktree)
            if let count = WorkspaceWorktreeMenuFormatting.sessionCountText(for: worktree) {
                label += " · \(count)"
            }
            let symbol = title.selectedWorktreeId == worktree.id
                ? "checkmark"
                : worktree.isMain ? "house" : "point.3.connected.trianglepath.dotted"
            let action = UIAction(title: label, image: UIImage(systemName: symbol)) { [weak self] _ in
                self?.selectWorktree(worktree)
            }
            action.accessibilityIdentifier = "workspace.worktree.\(worktree.id)"
            return action
        }
        return UIMenu(children: [
            UIMenu(title: String(localized: "Worktree"), options: .displayInline, children: actions),
        ])
    }

    private func worktreeAccessibilityLabel(_ title: TitleState) -> String {
        title.canSwitch
            ? String(localized: "Switch worktree, current worktree \(title.worktreeName)")
            : String(localized: "Current worktree \(title.worktreeName)")
    }

    /// The rail's worktree control: the title's menu on a labeled branch symbol.
    private func worktreeRailItem(_ title: TitleState, tint: UIColor) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            title: String(localized: "Worktree"),
            image: UIImage(systemName: "arrow.triangle.branch"),
            primaryAction: nil,
            menu: title.canSwitch ? worktreeMenu(title) : nil
        )
        item.tintColor = tint
        item.accessibilityLabel = worktreeAccessibilityLabel(title)
        item.accessibilityIdentifier = title.canSwitch ? "workspace.worktree.menu" : "workspace.worktree.title"
        return item
    }

    /// The principal title: the workspace name with its lock badge over the
    /// worktree name, and the worktree menu when there is more than one.
    private func configureTitleButton(_ title: TitleState, palette: ThemePalette) {
        titleButton.configure(
            name: title.name,
            worktreeName: title.worktreeName,
            lockSymbol: title.lockBadge.symbolName,
            showsChevron: title.canSwitch,
            palette: palette
        )
        titleButton.menu = title.canSwitch ? worktreeMenu(title) : nil
        titleButton.isUserInteractionEnabled = title.canSwitch
        titleButton.accessibilityLabel = worktreeAccessibilityLabel(title)
        titleButton.accessibilityIdentifier = title.canSwitch ? "workspace.worktree.menu" : "workspace.worktree.title"
        titleButton.accessibilityTraits = title.canSwitch ? .button : .staticText
    }
}

/// The principal title: the workspace name and lock badge over the worktree
/// name, with a chevron when it opens the worktree menu. One accessibility
/// element; the screen sets its label.
final class WorkspaceTitleButton: UIButton {
    private let nameLabel = UILabel()
    private let lockImage = UIImageView()
    private let worktreeLabel = UILabel()
    private let chevron = UIImageView()
    private let row = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsMenuAsPrimaryAction = true
        isAccessibilityElement = true

        nameLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .headline).pointSize, weight: .semibold)
        )
        nameLabel.adjustsFontForContentSizeCategory = true
        worktreeLabel.font = .preferredFont(forTextStyle: .caption2)
        worktreeLabel.adjustsFontForContentSizeCategory = true
        let symbol = UIImage.SymbolConfiguration(textStyle: .caption2)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        lockImage.preferredSymbolConfiguration = symbol
        chevron.preferredSymbolConfiguration = symbol
        chevron.image = UIImage(systemName: "chevron.down")
        for view in [lockImage, chevron] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        worktreeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let nameRow = UIStackView(arrangedSubviews: [nameLabel, lockImage])
        nameRow.spacing = 4
        nameRow.alignment = .center
        let titles = UIStackView(arrangedSubviews: [nameRow, worktreeLabel])
        titles.axis = .vertical
        titles.alignment = .center
        titles.spacing = 1
        row.addArrangedSubview(titles)
        row.addArrangedSubview(chevron)
        row.spacing = 5
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The bar sizes a title view by its intrinsic size; a button's own
    /// would be its (empty) system title's.
    override var intrinsicContentSize: CGSize {
        row.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    }

    func configure(name: String, worktreeName: String, lockSymbol: String?, showsChevron: Bool, palette: ThemePalette) {
        let comment = UIColor(palette.comment)
        nameLabel.text = name
        nameLabel.textColor = UIColor(palette.fg)
        lockImage.image = lockSymbol.flatMap { UIImage(systemName: $0) }
        lockImage.isHidden = lockSymbol == nil
        lockImage.tintColor = comment
        worktreeLabel.text = worktreeName
        worktreeLabel.textColor = comment
        chevron.isHidden = !showsChevron
        chevron.tintColor = comment
        invalidateIntrinsicContentSize()
    }
}

private extension ScopedLockState {
    var symbolName: String? {
        switch self {
        case .none: nil
        case .locked: "lock.fill"
        case .unlocked: "lock.open.fill"
        }
    }
}
