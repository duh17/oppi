import UIKit

/// One page of a server plugin's sidebar entry, drawn from the page the server watches for it
/// (`PluginScreenStream`, `protocol/screens.json`). The page is data in a closed vocabulary:
/// sections of seven row kinds, the page's own state, up to two bar buttons, and an optional
/// submit that makes it a form. Every row is the list kit's own (`ListScreenController`), so a
/// plugin page looks and reads like a native one, and nothing here knows which plugin it draws.
///
/// The page watches while it is on screen: appearing watches again and takes the current value,
/// leaving unwatches and keeps the last rows. A form keeps a local draft of its toggles,
/// choices and fields, so typing never goes to the server until Submit. A tap's row shows as
/// pending until its result; a failure shows under the row's section. Navigation comes only
/// from the person's taps: an item's `push`, a bar button's `present`, or an action's result.
@MainActor
final class PluginScreenViewController: ListScreenController<String, String> {
    let entry: String
    let page: String
    var showsSidebarToggle: Bool {
        didSet { setNeedsUpdateProperties() }
    }

    private let root: AppRootEnvironment
    private let fallbackTitle: String
    private var stream: PluginScreenStream?
    private var watchId: String?
    private var replica = PluginScreenReplica()
    private var content: PluginScreenPage? { didSet { setNeedsUpdateProperties() } }
    /// Why the page stopped: the server refused a value, or ended the watch.
    private var problem: String? { didSet { setNeedsUpdateProperties() } }
    /// A form's values by row id, kept here until Submit.
    private var draft: [String: JSONValue] = [:]
    /// Rows (or the bar or the submit) whose action is in flight.
    private var pending: Set<String> = [] { didSet { setNeedsUpdateProperties() } }
    /// The last failed action's words, by the section of the row that asked.
    private var failures: [String: String] = [:] { didSet { setNeedsUpdateProperties() } }
    private var sidebarToggle: UIBarButtonItem?
    private var barButtons: [String: UIBarButtonItem] = [:]
    private lazy var submitItem = UIBarButtonItem()

    private static let stateSection = "\u{1}state"
    private static let failureSection = "\u{1}failure"
    private static let failureRow = "\u{1}failure"

    init(entry: String, page: String, title: String, root: AppRootEnvironment, showsSidebarToggle: Bool = false) {
        self.entry = entry
        self.page = page
        self.root = root
        self.fallbackTitle = title
        self.showsSidebarToggle = showsSidebarToggle
        super.init(
            title: title, listIdentifier: "screen.\(entry).\(page).list",
            headers: true, footers: true, endsAtKeyboard: true, dismissesKeyboardOnDrag: true
        )
        traitOverrides.appRootEnvironment = root
    }

    private var palette: ThemePalette { ThemeRuntimeState.currentPalette() }
    private var isForm: Bool { content?.submit != nil }

    // MARK: - Watch

    /// Appearing watches the page again (the server answers with its current value); a pull to
    /// refresh asks the plugin to read its source again.
    override var loadPolicy: LoadPolicy { .eachAppearance }

    override func load() async throws {
        guard watchId != nil, loadTrigger == .ask else { return startWatching() }
        await perform("refresh", row: nil, section: nil)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if let watchId { stream?.unwatch(watchId) }
        watchId = nil
    }

    private func startWatching() {
        guard watchId == nil else { return }
        if stream == nil, let connection = root.windowConnection { stream = PluginScreenStream.shared(for: connection) }
        guard let stream else {
            problem = String(localized: "Connect to a paired server to open this page.")
            return
        }
        problem = nil
        watchId = stream.watch(entry: entry, page: page) { [weak self] message in self?.receive(message) }
    }

    func receive(_ message: PluginScreenServerMessage) {
        switch message {
        case .value, .ops:
            do {
                content = try replica.apply(message)
                problem = nil
            } catch {
                // An unfaithful copy: start over with a fresh value.
                replica = PluginScreenReplica()
                if let watchId { stream?.unwatch(watchId) }
                watchId = nil
                startWatching()
            }
        case .failed(_, let message):
            problem = message
        case .ended(_, let reason):
            watchId = nil
            if reason == "gone" {
                Router.finish(self)
            } else {
                problem = String(localized: "Update Oppi to open this page.")
            }
        case .result, .authRenewResult, .unknown:
            break
        }
    }

    /// Sends `action` for `row` and applies its result: a failure under `section`, or the
    /// navigation it asks for.
    private func act(_ action: String, row: String?, section: String?, values: [PluginScreenValue]? = nil) {
        Task { [weak self] in await self?.perform(action, row: row, section: section, values: values) }
    }

    private func perform(_ action: String, row: String?, section: String?, values: [PluginScreenValue]? = nil) async {
        let key = row ?? action
        guard let stream, let watchId, !pending.contains(key) else { return }
        pending.insert(key)
        if let section { failures[section] = nil }
        let result = await stream.act(watch: watchId, action: action, row: row, values: values)
        pending.remove(key)
        if !result.ok {
            failures[section ?? Self.failureSection] = result.message ?? String(localized: "That didn't work.")
        }
        if let nav = result.nav { navigate(nav) }
    }

    private func navigate(_ nav: PluginScreenNav) {
        switch nav.kind {
        case "pop": Router.finish(self)
        case "push": nav.page.map(open(page:))
        case "present": nav.page.map(present(page:))
        default: break
        }
    }

    private func open(page: String) {
        Router.push(PluginScreenViewController(entry: entry, page: page, title: "", root: root), from: self)
    }

    private func present(page: String) {
        let screen = PluginScreenViewController(entry: entry, page: page, title: "", root: root)
        Router.present(screen, presentation: .sheet.inNavigation(), from: self)
    }

    private func openURL(_ text: String) {
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme) else { return }
        root.opener.open(.webLink(url))
    }

    // MARK: - Bars

    override func viewDidLoad() {
        super.viewDidLoad()
        submitItem.style = .prominent
        submitItem.primaryAction = UIAction { [weak self] _ in self?.submit() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func updateProperties() {
        let content = content
        title = content.map { $0.title.isEmpty ? fallbackTitle : $0.title } ?? fallbackTitle
        super.updateProperties()
        if let submit = content?.submit {
            submitItem.title = submit.title
            submitItem.accessibilityIdentifier = "screen.\(entry).\(page).submit"
            submitItem.isEnabled = !pending.contains(submit.action)
            isModalInPresentation = pending.contains(submit.action)
            let cancel = barButtons["\u{1}cancel"] ?? UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                Router.finish(self)
            })
            barButtons["\u{1}cancel"] = cancel
            ListScreen.setBarItems(trailing: [submitItem], leading: [cancel], on: navigationItem)
            return
        }
        let items = (content?.bar ?? []).reversed().map(barButton)
        let leading = presentingViewController != nil && navigationController?.viewControllers.first === self
            ? [closeButton()] : sidebarItems()
        ListScreen.setBarItems(trailing: items, leading: leading, on: navigationItem)
    }

    /// One bar button per id, kept across passes so an open menu or a highlight survives.
    private func barButton(_ item: PluginScreenPage.BarItem) -> UIBarButtonItem {
        let button = barButtons[item.id] ?? UIBarButtonItem()
        barButtons[item.id] = button
        button.title = item.title
        button.image = item.symbol.flatMap { UIImage(systemName: $0) }
        button.accessibilityLabel = item.title
        button.accessibilityIdentifier = "screen.\(entry).\(page).bar.\(item.id)"
        button.isEnabled = item.disabled != true && !pending.contains(item.id) && content?.state == nil
        button.primaryAction = UIAction(title: item.title, image: button.image) { [weak self] _ in
            if let page = item.present { self?.present(page: page) }
            if let page = item.push { self?.open(page: page) }
            if let action = item.action { self?.act(action, row: item.id, section: nil) }
        }
        return button
    }

    private func closeButton() -> UIBarButtonItem {
        let close = barButtons["\u{1}close"] ?? UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            Router.finish(self)
        })
        barButtons["\u{1}close"] = close
        return close
    }

    private func sidebarItems() -> [UIBarButtonItem] {
        guard showsSidebarToggle else { return [] }
        let toggle = sidebarToggle ?? WorkspaceSplitSidebarToggle.makeItem(root: root)
        sidebarToggle = toggle
        WorkspaceSplitSidebarToggle.sync(toggle, root: root)
        return [toggle]
    }

    private func submit() {
        guard let submit = content?.submit else { return }
        view.endEditing(true)
        let values = draft.keys.sorted().compactMap { key in draft[key].map { PluginScreenValue(field: key, value: $0) } }
        act(submit.action, row: nil, section: nil, values: values)
    }

    // MARK: - List

    /// A form's rows keep their text: the page's sections come in place, never animated.
    override var animatesUpdates: Bool { false }

    override func sections() -> [ListSection<String, String>] {
        guard let content else {
            let state: LoadState = problem.map { .failed(title: $0, message: nil, retry: nil) } ?? .loading(nil)
            return [ListSection(Self.stateSection, items: [], state: ListStateRow(state: state, identifier: stateRowIdentifier))]
        }
        if let state = content.state {
            return [ListSection(Self.stateSection, items: [], state: ListStateRow(state: loadState(state), identifier: stateRowIdentifier))]
        }
        seedDraft(content)
        var sections: [ListSection<String, String>] = []
        if let problem {
            sections.append(ListSection(Self.stateSection, items: [], state: ListStateRow(
                state: .failed(title: problem, message: nil, retry: nil), identifier: stateRowIdentifier
            )))
        }
        for section in content.sections where shows(section) {
            var items = section.rows.map(\.id)
            if failures[section.id] != nil { items.append(Self.failureRow + section.id) }
            sections.append(ListSection(section.id, header: section.header, footer: section.footer, items: items))
        }
        if failures[Self.failureSection] != nil {
            sections.append(ListSection(Self.failureSection, items: [Self.failureRow]))
        }
        return sections
    }

    override func showsHeader(for section: String) -> Bool {
        content?.sections.first { $0.id == section }?.header != nil
    }

    private func shows(_ section: PluginScreenPage.Section) -> Bool {
        guard let when = section.when else { return true }
        return draft[when.field] == .string(when.is)
    }

    /// A form starts from the values its rows carry; the person's edits win from then on.
    private func seedDraft(_ page: PluginScreenPage) {
        guard page.submit != nil else { return }
        for row in page.sections.flatMap(\.rows) where draft[row.id] == nil {
            switch row.kind {
            case "toggle", "choice", "field": draft[row.id] = row.value ?? (row.kind == "field" ? .string("") : nil)
            default: break
            }
        }
    }

    private func loadState(_ state: PluginScreenPage.State) -> LoadState {
        switch state.kind {
        case "empty":
            return .empty(title: state.title ?? "", systemImage: "tray", message: state.message)
        case "failed":
            return .failed(
                title: state.title ?? String(localized: "Couldn't Load"),
                message: state.message,
                retry: RetryAction { [weak self] in self?.act("refresh", row: nil, section: nil) }
            )
        default:
            return .loading(state.message)
        }
    }

    /// The row with `id` on the page now, and its section's id.
    func locate(_ id: String) -> (row: PluginScreenRow, section: String)? {
        for section in content?.sections ?? [] {
            if let row = section.rows.first(where: { $0.id == id }) { return (row, section.id) }
        }
        return nil
    }

    /// A row redraws when what it draws changes. A field never redraws from the draft, so typing
    /// keeps its keyboard and selection.
    override func inputs(of item: String) -> AnyHashable {
        if item.hasPrefix(Self.failureRow) {
            let section = String(item.dropFirst(Self.failureRow.count))
            return AnyHashable(failures[section.isEmpty ? Self.failureSection : section])
        }
        guard let (row, _) = locate(item) else { return AnyHashable(0) }
        let draftValue: JSONValue? = row.kind == "field" ? nil : draft[item]
        return AnyHashable([AnyHashable(row), AnyHashable(draftValue), AnyHashable(pending.contains(item))])
    }

    // MARK: - Rows

    private lazy var fieldCell = UICollectionView.CellRegistration<SSHTerminalTextFieldCell, String> { [weak self] cell, _, id in
        self?.configureField(cell, id: id)
    }

    private lazy var editorCell = UICollectionView.CellRegistration<SettingsTextViewRowCell, String> { [weak self] cell, _, id in
        self?.configureEditor(cell, id: id)
    }

    private lazy var menuCell = UICollectionView.CellRegistration<SettingsMenuRowCell, String> { [weak self] cell, _, id in
        self?.configureMenu(cell, id: id)
    }

    private lazy var segmentedCell = UICollectionView.CellRegistration<AgentNativeEditSegmentedCell, String> { [weak self] cell, _, id in
        self?.configureSegmented(cell, id: id)
    }

    override func prepareRegistrations() {
        _ = (fieldCell, editorCell, menuCell, segmentedCell)
    }

    override func dequeue(_ item: String, at indexPath: IndexPath) -> UICollectionViewCell {
        guard let (row, _) = locate(item) else { return cardCell(for: item, at: indexPath) }
        switch row.kind {
        case "field" where row.input == "multiline":
            return collectionView.dequeueConfiguredReusableCell(using: editorCell, for: indexPath, item: item)
        case "field":
            return collectionView.dequeueConfiguredReusableCell(using: fieldCell, for: indexPath, item: item)
        case "choice" where (row.options?.count ?? 0) <= 3:
            return collectionView.dequeueConfiguredReusableCell(using: segmentedCell, for: indexPath, item: item)
        case "choice":
            return collectionView.dequeueConfiguredReusableCell(using: menuCell, for: indexPath, item: item)
        case "item", "button":
            return cardCell(for: item, at: indexPath)
        default:
            return super.dequeue(item, at: indexPath)
        }
    }

    /// `screen.<entry>.<page>.<section>.<row>`, from the page's own ids.
    private func identifier(_ row: String, in section: String) -> String { "screen.\(entry).\(page).\(section).\(row)" }

    /// `value`, `text`, `toggle`, and a kind this app does not know.
    override func configure(_ cell: UICollectionViewListCell, item: String) {
        let palette = palette
        // A read-only row is one element that says all it shows (`app.cells[id]`); a toggle row's
        // element is its switch. Reuse clears both.
        cell.isAccessibilityElement = false
        cell.accessibilityLabel = nil
        cell.accessibilityValue = nil
        if item.hasPrefix(Self.failureRow) {
            let section = String(item.dropFirst(Self.failureRow.count))
            let message = failures[section.isEmpty ? Self.failureSection : section]
            cell.accessibilityIdentifier = "screen.\(entry).\(page).failure"
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = message
            cell.contentConfiguration = ControlViewContent { ControlRowViews.label(message, style: .body, color: palette.ui.red) }
            return
        }
        guard let (row, section) = locate(item) else { return }
        let id = identifier(row.id, in: section)
        switch row.kind {
        case "value":
            var content = UIListContentConfiguration.valueCell()
            content.text = row.label
            content.secondaryText = row.stringValue
            if row.mono == true { content.secondaryTextProperties.font = .scaledMonospaced(.body) }
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = id
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = row.label
            cell.accessibilityValue = row.stringValue
        case "text":
            let text = row.text ?? ""
            let style: UIFont.TextStyle = row.style == "footnote" ? .footnote : .body
            let color = tone(row.tone, palette: palette) ?? palette.ui.fg
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) {
                if row.selectable == true {
                    let selectable = ControlRowViews.selectableText(text, style: style, color: color)
                    if row.mono == true { selectable.font = .scaledMonospaced(style) }
                    return selectable
                }
                let label = ControlRowViews.label(text, style: style, color: color)
                if row.mono == true { label.font = .scaledMonospaced(style) }
                return label
            }
            cell.accessibilityIdentifier = id
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = text
        case "toggle":
            let isOn = draft[row.id].map { $0 == .bool(true) } ?? row.boolValue
            toggleRow(
                cell, title: row.label ?? "", isOn: isOn, identifier: id,
                isEnabled: row.disabled != true && !pending.contains(row.id)
            ) { [weak self] value in self?.change(row.id, to: .bool(value)) }
        default:
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "Update Oppi to see this row.")
            content.textProperties.color = palette.ui.comment
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = id
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = content.text
        }
    }

    /// `item` and `button`: one button each, the row's one accessibility element.
    override func configureCard(_ cell: SidebarListCell, item: String) {
        let palette = palette
        guard let (row, section) = locate(item) else {
            ListScreen.staticRow(cell)
            return
        }
        let id = identifier(row.id, in: section)
        let enabled = row.disabled != true && !pending.contains(row.id)
        if row.kind == "item" {
            let status = row.status
            ListScreen.buttonRow(
                cell, identifier: id, label: row.title,
                value: [row.subtitle, status?.text].compactMap { $0 }.joined(separator: ", "),
                enabled: enabled
            ) { [weak self] in
                if let page = row.push { self?.open(page: page) } else if let url = row.url { self?.openURL(url) }
            }
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 4, leading: 0, bottom: 4, trailing: 0)) {
                var views: [UIView] = [ControlRowViews.label(row.title, style: .headline, color: palette.ui.fg)]
                if let subtitle = row.subtitle {
                    views.append(ControlRowViews.label(subtitle, style: .subheadline, color: palette.ui.comment))
                }
                if let status {
                    views.append(ControlRowViews.symbolLabel(
                        status.text, systemImage: status.symbol ?? "circle", style: .caption1,
                        color: self.tone(status.tone, palette: palette) ?? palette.ui.comment
                    ))
                }
                return ControlRowViews.stack(views, spacing: 4)
            }
            cell.accessories = row.push != nil ? [.disclosureIndicator()] : []
            return
        }
        let title = row.title ?? ""
        ListScreen.buttonRow(cell, identifier: id, label: title, enabled: enabled) { [weak self] in
            self?.tapButton(row, section: section)
        }
        var content = UIListContentConfiguration.cell()
        content.text = title
        content.textProperties.color = !enabled ? palette.comment : row.role == "destructive" ? palette.red : palette.blue
        cell.contentConfiguration = content
    }

    private func tapButton(_ row: PluginScreenRow, section: String) {
        if let url = row.url { return openURL(url) }
        guard let action = row.action else { return }
        guard let confirm = row.confirm else { return act(action, row: row.id, section: section) }
        let anchor = indexPath(for: row.id).flatMap(collectionView.cellForItem(at:))
        Confirmation(
            title: confirm.title, message: confirm.message, actionTitle: confirm.button,
            isDestructive: row.role == "destructive",
            actionIdentifier: "\(identifier(row.id, in: section)).confirm"
        ).present(from: self, anchor: anchor) { [weak self] in
            self?.act(action, row: row.id, section: section)
        }
    }

    private func configureField(_ cell: SSHTerminalTextFieldCell, id: String) {
        guard let (row, section) = locate(id) else { return }
        cell.configure(
            text: draft[id].flatMap { if case .string(let text) = $0 { text } else { nil } } ?? "",
            placeholder: row.placeholder ?? row.label ?? "",
            identifier: identifier(row.id, in: section),
            label: row.label,
            isSecure: row.input == "secret",
            keyboard: row.input == "number" ? .numberPad : row.input == "url" ? .URL : .default,
            textColor: palette.ui.fg,
            enabled: pending.isEmpty
        ) { [weak self] text in self?.draft[id] = .string(text) }
    }

    private func configureEditor(_ cell: SettingsTextViewRowCell, id: String) {
        guard let (row, section) = locate(id) else { return }
        let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        let placeholder = row.placeholder ?? row.label ?? ""
        cell.configure(
            text: draft[id].flatMap { if case .string(let text) = $0 { text } else { nil } } ?? "",
            placeholder: placeholder,
            identifier: identifier(row.id, in: section),
            accessibilityLabel: placeholder,
            minHeight: lineHeight * 3 + SettingsTextViewRowCell.verticalInsets,
            maxHeight: lineHeight * 8 + SettingsTextViewRowCell.verticalInsets,
            onChange: { [weak self] text in self?.draft[id] = .string(text) },
            onCaretMove: { [weak self] textView in
                guard let self, let range = textView.selectedTextRange else { return }
                let caret = textView.convert(textView.caretRect(for: range.end), to: collectionView)
                collectionView.scrollRectToVisible(caret.insetBy(dx: 0, dy: -12), animated: false)
            }
        )
        cell.textView.textColor = palette.ui.fg
        cell.textView.autocapitalizationType = .none
        cell.textView.autocorrectionType = .no
    }

    private func configureMenu(_ cell: SettingsMenuRowCell, id: String) {
        guard let (row, section) = locate(id) else { return }
        let options = row.options ?? []
        let current = choice(of: row)
        cell.configure(
            title: row.label ?? "",
            identifier: identifier(row.id, in: section),
            isEnabled: row.disabled != true && !pending.contains(row.id),
            value: options.first { $0.value == current }?.title ?? current
        ) { [weak self] in
            options.map { option in
                SettingsMenuOption(title: option.title, selected: option.value == current) {
                    self?.change(row.id, to: .string(option.value))
                }
            }
        }
    }

    private func configureSegmented(_ cell: AgentNativeEditSegmentedCell, id: String) {
        guard let (row, section) = locate(id) else { return }
        let options = row.options ?? []
        let current = choice(of: row)
        cell.configure(
            titles: options.map(\.title),
            selectedIndex: options.firstIndex { $0.value == current } ?? 0,
            identifier: identifier(row.id, in: section)
        ) { [weak self] index in
            guard options.indices.contains(index) else { return }
            self?.change(row.id, to: .string(options[index].value))
        }
    }

    private func choice(of row: PluginScreenRow) -> String {
        if case .string(let value) = draft[row.id] { return value }
        return row.stringValue ?? ""
    }

    /// A toggle or choice changed: a form keeps it in its draft, any other page acts on it.
    private func change(_ id: String, to value: JSONValue) {
        if isForm {
            draft[id] = value
            setNeedsUpdateProperties()
            return
        }
        guard let (row, section) = locate(id), let action = row.action else { return }
        act(action, row: id, section: section, values: [PluginScreenValue(field: id, value: value)])
    }

    private func tone(_ tone: String?, palette: ThemePalette) -> UIColor? {
        switch tone {
        case "secondary": palette.ui.comment
        case "accent": palette.ui.blue
        case "success": palette.ui.green
        case "warning": palette.ui.orange
        case "danger": palette.ui.red
        default: nil
        }
    }
}
