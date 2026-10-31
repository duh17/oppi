import UIKit

/// One MCP server's OAuth sign-in as a sheet: where it stands, the sign-in
/// link, the callback URL to paste, the host's errors, and Cancel Sign-In
/// (Done once it settles). `McpSignInOwner` owns the attempt: closing the
/// sheet never cancels it.
///
/// A `ListScreenController`: the base owns the list, the section headings, and
/// the rows redrawn only when their inputs change, so typing keeps the callback
/// field's selection.
@MainActor
final class McpSignInViewController: ListScreenController<McpSignInViewController.Section, McpSignInViewController.Item> {
    enum Section: Hashable, Sendable {
        case summary, finishing, signIn, preparing, notices, finish
    }

    enum Item: Hashable, Sendable {
        case host, status
        case finishing
        case openLink, callback, submit
        case preparing
        case flowError, actionError, refreshError, gone
        case finish
    }

    let attempt: ProviderAuthFlowAttempt
    private let owner: McpSignInOwner
    private let root: AppRootEnvironment
    /// Above the keyboard while the callback field has it.
    private lazy var keyboardBar: UIToolbar = {
        let bar = UIToolbar()
        bar.sizeToFit()
        keyboardSubmit.title = "Submit Callback"
        keyboardSubmit.primaryAction = UIAction(title: "Submit Callback") { [weak self] _ in self?.submit() }
        keyboardSubmit.accessibilityIdentifier = "mcp.auth.submit.keyboard"
        bar.items = [UIBarButtonItem(systemItem: .flexibleSpace), keyboardSubmit]
        return bar
    }()
    private let keyboardSubmit = UIBarButtonItem()

    init(attempt: ProviderAuthFlowAttempt, owner: McpSignInOwner, root: AppRootEnvironment) {
        self.attempt = attempt
        self.owner = owner
        self.root = root
        super.init(
            title: "Sign In", listIdentifier: "mcp.auth.list",
            headers: true, footers: true, endsAtKeyboard: true, dismissesKeyboardOnDrag: true
        )
        traitOverrides.appRootEnvironment = root
        let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction(title: "Close") { [weak owner] _ in
            owner?.showingSheet = false
        })
        close.accessibilityLabel = "Close"
        close.accessibilityIdentifier = "mcp.auth.close"
        navigationItem.leftBarButtonItem = close
    }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }

    override func updateProperties() {
        super.updateProperties()
        // A cancel in flight must finish before the sheet can go.
        isModalInPresentation = attempt.isCancelling
        keyboardSubmit.isEnabled = owner.canSubmitCallback
    }

    /// The sheet's rows change as the flow settles; they should not slide.
    override var animatesUpdates: Bool { false }

    // MARK: - List

    override func sections() -> [ListSection<Section, Item>] {
        let flow = attempt.flow
        var sections: [ListSection<Section, Item>] = [
            ListSection(.summary, header: attempt.providerName, items: [.host, .status])
        ]
        if !attempt.isSettled {
            if owner.callbackAccepted || attempt.isSubmitting {
                sections.append(ListSection(.finishing, items: [.finishing]))
            } else if let auth = flow.auth {
                var items: [Item] = []
                if ProviderAuthFlowPresentation.signInURL(auth.url) != nil { items.append(.openLink) }
                items += [.callback, .submit]
                sections.append(ListSection(
                    .signIn,
                    header: "Sign In",
                    footer: "After approval, the browser may fail to load 127.0.0.1. Copy its full callback URL and paste it below. You can also complete sign-in using a browser on the host.",
                    items: items
                ))
            } else {
                sections.append(ListSection(.preparing, items: [.preparing]))
            }
        }
        var notices: [Item] = []
        if flow.error != nil { notices.append(.flowError) }
        if attempt.actionError != nil { notices.append(.actionError) }
        if attempt.refreshError != nil { notices.append(.refreshError) }
        if attempt.isGone { notices.append(.gone) }
        if !notices.isEmpty {
            sections.append(ListSection(.notices, items: notices))
        }
        sections.append(ListSection(.finish, items: [.finish]))
        return sections
    }

    /// The provider's name and the sign-in group carry a heading; the rest do
    /// not.
    override func showsHeader(for section: Section) -> Bool {
        section == .summary || section == .signIn
    }

    /// Only the Submit row changes while typing, so the field keeps its
    /// selection and the keyboard.
    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .host: AnyHashable([attempt.serverName])
        case .status: AnyHashable([attempt.flow.status.rawValue])
        case .openLink: AnyHashable([attempt.flow.auth?.url])
        case .submit: AnyHashable([owner.canSubmitCallback])
        case .flowError: AnyHashable([attempt.flow.error])
        case .actionError: AnyHashable([attempt.actionError])
        case .refreshError: AnyHashable([attempt.refreshError])
        case .finish: AnyHashable([attempt.isSettled, attempt.isCancelling])
        case .finishing, .callback, .preparing, .gone: AnyHashable(0)
        }
    }

    // MARK: - Rows

    private lazy var field = UICollectionView.CellRegistration<SSHTerminalTextFieldCell, Item> { [weak self] cell, _, _ in
        self?.configureCallback(cell)
    }

    // A registration must exist before the first row is dequeued.
    override func prepareRegistrations() {
        _ = field
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        item == .callback
            ? collectionView.dequeueConfiguredReusableCell(using: field, for: indexPath, item: item)
            : cardCell(for: item, at: indexPath)
    }

    private func configureCallback(_ cell: SSHTerminalTextFieldCell) {
        let attempt = attempt
        cell.configure(
            text: attempt.input,
            placeholder: "Paste full callback URL",
            identifier: "mcp.auth.callback",
            keyboard: .URL,
            textColor: UIColor(palette.fg),
            returnKey: .go,
            onReturn: { [weak self] in self?.submit() },
            onChange: { attempt.input = $0 }
        )
        cell.textField.inputAccessoryView = keyboardBar
    }

    override func configureCard(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        switch item {
        case .host:
            ListScreen.staticRow(cell)
            cell.contentConfiguration = McpRowContent.value("Host", attempt.serverName)
        case .status:
            ListScreen.staticRow(cell)
            cell.contentConfiguration = McpRowContent.value(
                "Status", ProviderAuthFlowPresentation.statusText(attempt.flow.status)
            )
        case .finishing:
            ListScreen.stateRow(
                cell, .loading(String(localized: "Finishing sign-in on the host…")), palette: palette
            )
        case .preparing:
            ListScreen.stateRow(cell, .loading(String(localized: "Preparing sign-in…")), palette: palette)
        case .openLink:
            ListScreen.buttonRow(cell, identifier: "mcp.auth.open", label: "Open Sign-In Page") { [weak self] in
                self?.openSignInPage()
            }
            cell.contentConfiguration = Self.actionContent("Open Sign-In Page", color: UIColor(palette.blue))
        case .callback:
            break
        case .submit:
            let enabled = owner.canSubmitCallback
            ListScreen.buttonRow(
                cell, identifier: "mcp.auth.submit", label: "Submit Callback", enabled: enabled
            ) { [weak self] in
                self?.submit()
            }
            cell.contentConfiguration = Self.actionContent(
                "Submit Callback", color: UIColor(enabled ? palette.blue : palette.comment)
            )
        case .flowError:
            notice(cell, attempt.flow.error, style: .body, color: UIColor(palette.red))
        case .actionError:
            notice(cell, attempt.actionError, style: .body, color: UIColor(palette.red))
        case .refreshError:
            notice(cell, attempt.refreshError, style: .body, color: UIColor(palette.orange))
        case .gone:
            notice(cell, "The host no longer has this flow. Start a new sign-in.", style: .body, color: UIColor(palette.fg))
        case .finish:
            if attempt.isSettled {
                ListScreen.buttonRow(cell, identifier: "mcp.auth.sheet.done", label: "Done") { [weak self] in
                    self?.owner.showingSheet = false
                }
                cell.contentConfiguration = Self.actionContent("Done", color: UIColor(palette.blue))
            } else {
                let cancelling = attempt.isCancelling
                ListScreen.buttonRow(
                    cell, identifier: "mcp.auth.sheet.cancel", label: "Cancel Sign-In", enabled: !cancelling
                ) { [weak self] in
                    guard let owner = self?.owner else { return }
                    Task { await owner.cancel() }
                }
                cell.contentConfiguration = Self.actionContent(
                    "Cancel Sign-In", color: UIColor(cancelling ? palette.comment : palette.red)
                )
            }
        }
    }

    private func notice(_ cell: SidebarListCell, _ text: String?, style: UIFont.TextStyle, color: UIColor) {
        ListScreen.staticRow(cell)
        cell.contentConfiguration = ControlViewContent {
            ControlRowViews.selectableText(text ?? "", style: style, color: color)
        }
    }

    private static func actionContent(_ title: String, color: UIColor) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.cell()
        content.text = title
        content.textProperties.color = color
        return content
    }

    // MARK: - Actions

    private func submit() {
        guard owner.canSubmitCallback else { return }
        view.endEditing(true)
        let owner = owner
        Task { await owner.submitCallback() }
    }

    private func openSignInPage() {
        guard let auth = attempt.flow.auth, let url = ProviderAuthFlowPresentation.signInURL(auth.url) else { return }
        root.opener.open(.webLink(url))
    }
}

/// Presents the sign-in sheet for `McpSignInOwner`'s attempt from whichever
/// MCP screen is on top: the list holds the attempt, but a sign-in starts on a
/// server's detail, which covers the list. Each screen owns one presenter and
/// calls `sync` from `updateProperties()`; only a screen in the window
/// presents, and one sheet is up at a time.
@MainActor
final class McpSignInPresenter {
    private weak var sheet: McpSignInViewController?
    private var isScheduled = false

    func sync(owner: McpSignInOwner, root: AppRootEnvironment, from screen: UIViewController) {
        guard owner.showingSheet, let wanted = owner.attempt else {
            if let sheet, !sheet.isBeingDismissed { Router.finish(sheet) }
            return
        }
        if let sheet {
            // A different attempt replaces the open sheet: the old one closes
            // (it no longer owns the owner's state), and its dismissal
            // presents the new one.
            if sheet.attempt !== wanted, !sheet.isBeingDismissed { Router.finish(sheet) }
            return
        }
        guard !isScheduled, screen.viewIfLoaded?.window != nil else { return }
        // A presentation needs a settled view tree, not the layout pass that asked for it.
        isScheduled = true
        Task { @MainActor [weak self, weak owner, weak screen] in
            guard let self else { return }
            isScheduled = false
            guard let owner, let screen, owner.showingSheet, let attempt = owner.attempt,
                  sheet == nil, screen.viewIfLoaded?.window != nil, !Self.isShowing(from: screen) else { return }
            let sheet = McpSignInViewController(attempt: attempt, owner: owner, root: root)
            self.sheet = sheet
            Router.present(sheet, presentation: .sheet.inNavigation(), from: screen) { [weak self, weak owner, weak screen] in
                guard let self else { return }
                self.sheet = nil
                guard let owner else { return }
                if owner.attempt === attempt {
                    owner.sheetDismissed()
                } else if let screen {
                    // Replaced by another attempt: show that one.
                    sync(owner: owner, root: root, from: screen)
                }
            }
        }
    }

    /// A sheet from another MCP screen is already up.
    private static func isShowing(from screen: UIViewController) -> Bool {
        let top = Router.topPresenter(from: screen)
        return (top as? UINavigationController)?.viewControllers.first is McpSignInViewController
    }
}
