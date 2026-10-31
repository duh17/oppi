import UIKit

/// Dictation Dictionary: the names and terms that help dictation recognize what
/// you say, kept on the server (the same authenticated lists `oppi dictionary`
/// edits; the device caches no phrase). Opened from App Settings → Voice,
/// Server Settings, and Workspace Settings.
///
/// From a workspace the page shows two lists: All Workspaces, which every
/// workspace on the server uses, and This Workspace. Save writes whichever
/// changed, so a workspace's entry also edits the server-wide list; the
/// footers say so and name the server.
///
/// Phrases are drafts until Save in the bar writes them: a failed save keeps
/// the drafts, and Retry reloads the lists and discards them.
@MainActor
final class DictationDictionaryViewController: ListScreenController<DictationDictionaryViewController.Section, DictationDictionaryViewController.Item> {
    enum Section: Hashable, Sendable { case status, global, workspace, add, consent, delete }
    enum PhraseScope: String, Hashable, Sendable { case global, workspace }
    enum Item: Hashable, Sendable {
        case loading
        case failed
        case notice
        case empty(PhraseScope)
        /// `occurrence` keeps two equal phrases in one list distinct.
        case phrase(PhraseScope, String, occurrence: Int)
        case addPhrase, scope, field, cancel, commit
        case consent
        case delete
    }

    let model: DictationDictionaryModel
    private var saveItem: UIBarButtonItem?

    init(model: DictationDictionaryModel) {
        self.model = model
        super.init(
            title: String(localized: "Dictation Dictionary"),
            listIdentifier: "settings.dictionary.list",
            scope: .server(model.serverName),
            headers: true,
            footers: true,
            dismissesKeyboardOnDrag: true
        )
    }

    /// The page for `serverId`, over that server's connection; `workspace` adds
    /// its own list.
    static func make(
        root: AppRootEnvironment,
        serverId: String,
        workspace: (id: String, name: String)? = nil
    ) -> DictationDictionaryViewController {
        let name = root.coordinator.serverStore.server(for: serverId)?.name ?? serverId
        return DictationDictionaryViewController(model: DictationDictionaryModel(
            serverId: serverId,
            serverName: name,
            workspaceId: workspace?.id,
            workspaceName: workspace?.name,
            service: root.coordinator.apiClient(for: serverId)
        ))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let save = UIBarButtonItem(title: String(localized: "Save"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            Task { await self.model.save() }
        })
        save.style = .prominent
        save.accessibilityLabel = String(localized: "Save")
        save.accessibilityIdentifier = "settings.dictionary.save"
        navigationItem.rightBarButtonItem = save
        saveItem = save
        model.load()
    }

    override func updateProperties() {
        super.updateProperties()
        saveItem?.isEnabled = model.canSave
    }

    // MARK: - Sections

    private var provider: String? { model.global?.provider }

    override func sections() -> [ListSection<Section, Item>] {
        switch model.loadState {
        case .loading:
            return [ListSection(.status, items: [.loading])]
        case .failed:
            return [ListSection(.status, items: [.failed])]
        case .loaded:
            break
        }
        var sections: [ListSection<Section, Item>] = []
        if model.notice != nil {
            sections.append(ListSection(.status, items: [.notice]))
        }
        sections.append(ListSection(
            .global,
            header: String(localized: "All Workspaces"),
            footer: DictationDictionaryCopy.globalFooter(serverName: model.serverName, workspaceName: model.workspaceName),
            items: phraseItems(model.globalDraft, scope: .global)
        ))
        if model.workspaceId != nil {
            sections.append(ListSection(
                .workspace,
                header: String(localized: "This Workspace"),
                footer: DictationDictionaryCopy.workspaceFooter(serverName: model.serverName),
                scope: model.workspaceName.map { SettingsScope.workspace($0) },
                items: phraseItems(model.workspaceDraft, scope: .workspace)
            ))
        }
        sections.append(ListSection(
            .add,
            footer: String(localized: "Saved phrases are hints, not guaranteed transcriptions. Entries marked excluded will not be selected for the next take."),
            items: [.addPhrase] + (model.isComposing
                ? (model.workspaceId != nil ? [.scope] : []) + [.field, .cancel, .commit]
                : [])
        ))
        if let provider {
            sections.append(ListSection(
                .consent,
                footer: DictationDictionaryCopy.consentFooter(serverName: model.serverName, provider: provider),
                scope: .deviceOnServer(model.serverName),
                items: [.consent]
            ))
        }
        if model.workspaceId != nil {
            sections.append(ListSection(.delete, items: [.delete]))
        }
        return sections
    }

    private func phraseItems(_ phrases: [String], scope: PhraseScope) -> [Item] {
        guard !phrases.isEmpty else { return [.empty(scope)] }
        var seen: [String: Int] = [:]
        return phrases.map { phrase in
            let occurrence = seen[phrase, default: 0]
            seen[phrase] = occurrence + 1
            return .phrase(scope, phrase, occurrence: occurrence)
        }
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .loading, .empty, .addPhrase, .cancel:
            AnyHashable(0)
        case .failed:
            AnyHashable(String(describing: model.loadState))
        case .notice:
            AnyHashable([model.notice?.text ?? "", model.notice?.offersRetry == true ? "retry" : ""])
        case .phrase(let scope, let value, _):
            // The position is an input: the row's id carries it, and a rename or delete above moves it.
            AnyHashable([AnyHashable(value), AnyHashable(caption(of: value, scope: scope) ?? ""), AnyHashable(position(of: item) ?? -1)])
        case .scope:
            AnyHashable(model.addsToWorkspace)
        case .field:
            // Redrawn only when the editor opens for another phrase; what is
            // typed stays in the field.
            AnyHashable(model.composeGeneration)
        case .commit:
            AnyHashable([model.canAddPhrase, model.isComposing])
        case .consent:
            AnyHashable(provider.map { DictationDictionaryConsent.isEnabled(serverId: model.serverId, provider: $0) } ?? false)
        case .delete:
            AnyHashable(model.isSaving)
        }
    }

    /// Why a phrase will not be used, when it will not.
    private func caption(of value: String, scope: PhraseScope) -> String? {
        let entry = model.selection.entries.first { ($0.scope == .workspace) == (scope == .workspace) && $0.phrase == value }
        if let reason = entry?.exclusion { return DictationDictionaryCopy.exclusion(reason) }
        if provider == "xai", value.unicodeScalars.count > 50 {
            return String(localized: "Excluded from xAI Server dictation (over 50 characters)")
        }
        return nil
    }

    // MARK: - Cells

    private lazy var stateRow = UICollectionView.CellRegistration<SettingsStateRowCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        switch item {
        case .loading:
            cell.configure(.loading(String(localized: "Loading…")), identifier: "settings.dictionary.loading")
        case .failed:
            if case .failed(let reason) = model.loadState {
                cell.configure(.failure(reason, retry: { [weak self] in self?.model.load() }), identifier: "settings.dictionary.retry")
            }
        case .notice:
            let retry: (() -> Void)? = model.notice?.offersRetry == true ? { [weak self] in self?.model.load() } : nil
            cell.configure(.failure(model.notice?.text ?? "", retry: retry), identifier: "settings.dictionary.notice")
        case .empty:
            cell.configure(.message(String(localized: "No phrases yet.")), identifier: nil)
        default:
            break
        }
    }

    private lazy var entryRow = UICollectionView.CellRegistration<SettingsEntryRowCell, Item> { [weak self] cell, _, item in
        guard let self, case .phrase(let scope, let value, let occurrence) = item else { return }
        let caption = caption(of: value, scope: scope)
        cell.configure(
            title: value,
            caption: caption,
            isWarning: caption != nil,
            identifier: "settings.dictionary.phrase.\(scope.rawValue).\(position(of: item) ?? 0)"
        ) { [weak self] in
            // The row is not redrawn when a phrase above it changes, so its place is
            // found now, not when it was drawn.
            guard let self, let index = index(of: value, occurrence: occurrence, scope: scope) else { return }
            view.endEditing(true)
            model.beginEditing(workspaceScope: scope == .workspace, index: index)
            focusPhraseField()
        }
    }

    private lazy var actionRow = UICollectionView.CellRegistration<SettingsActionRowCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        switch item {
        case .addPhrase:
            cell.configure(title: String(localized: "Add Phrase"), systemImage: "plus", identifier: "settings.dictionary.addPhrase") { [weak self] in
                guard let self else { return }
                view.endEditing(true)
                model.beginAdding()
                focusPhraseField()
            }
        case .cancel:
            cell.configure(title: String(localized: "Cancel"), identifier: "settings.dictionary.cancelPhrase") { [weak self] in
                self?.view.endEditing(true)
                self?.model.cancelComposing()
            }
        case .commit:
            cell.configure(
                title: String(localized: "Add to List"),
                identifier: "settings.dictionary.commitPhrase",
                isEnabled: model.canAddPhrase
            ) { [weak self] in
                self?.view.endEditing(true)
                self?.model.addPhrase()
            }
        default:
            cell.configure(
                title: String(localized: "Delete Workspace Phrases"),
                tint: .destructive,
                identifier: "settings.dictionary.deleteWorkspace",
                isEnabled: !model.isSaving,
                confirmation: .init(
                    title: String(localized: "Delete this workspace's phrases?"),
                    message: String(localized: "This deletes this workspace's phrases on \(model.serverName). Phrases for All Workspaces stay."),
                    actionTitle: String(localized: "Delete")
                )
            ) { [weak self] in
                guard let self else { return }
                Task { await self.model.deleteWorkspacePhrases() }
            }
        }
    }

    private lazy var menuRow = UICollectionView.CellRegistration<SettingsMenuRowCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        let addsToWorkspace = model.addsToWorkspace
        cell.configure(
            title: String(localized: "Add To"),
            identifier: "settings.dictionary.scope",
            value: addsToWorkspace ? String(localized: "This Workspace") : String(localized: "All Workspaces"),
            menu: {
                [
                    SettingsMenuOption(
                        title: String(localized: "All Workspaces"),
                        selected: !addsToWorkspace
                    ) { [weak self] in
                        self?.model.addsToWorkspace = false
                    },
                    SettingsMenuOption(
                        title: String(localized: "This Workspace"),
                        selected: addsToWorkspace
                    ) { [weak self] in
                        self?.model.addsToWorkspace = true
                    },
                ]
            }
        )
    }

    private lazy var fieldRow = UICollectionView.CellRegistration<SSHTerminalTextFieldCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(
            text: model.phrase,
            placeholder: String(localized: "Phrase"),
            identifier: "settings.dictionary.phrase",
            autocapitalization: .words,
            autocorrection: .default,
            textColor: SettingsStyle.current.title,
            returnKey: .done,
            onReturn: { [weak self] in self?.model.addPhrase() },
            onChange: { [weak self] in self?.model.phrase = $0 }
        )
        // The row is redrawn for another phrase only, and then the text is the model's.
        cell.textField.text = model.phrase
    }

    override func prepareRegistrations() {
        _ = (stateRow, entryRow, actionRow, menuRow, fieldRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .loading, .failed, .notice, .empty: collectionView.dequeueConfiguredReusableCell(using: stateRow, for: indexPath, item: item)
        case .phrase: collectionView.dequeueConfiguredReusableCell(using: entryRow, for: indexPath, item: item)
        case .addPhrase, .cancel, .commit, .delete: collectionView.dequeueConfiguredReusableCell(using: actionRow, for: indexPath, item: item)
        case .scope: collectionView.dequeueConfiguredReusableCell(using: menuRow, for: indexPath, item: item)
        case .field: collectionView.dequeueConfiguredReusableCell(using: fieldRow, for: indexPath, item: item)
        case .consent: super.dequeue(item, at: indexPath)
        }
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        guard item == .consent, let provider else { return }
        toggleRow(
            cell,
            title: String(localized: "Send Selected Phrases to Server Dictation"),
            isOn: DictationDictionaryConsent.isEnabled(serverId: model.serverId, provider: provider),
            identifier: "settings.dictionary.sendToServer"
        ) { [weak self] enabled in
            guard let self else { return }
            DictationDictionaryConsent.setEnabled(enabled, serverId: model.serverId, provider: provider)
            setNeedsUpdateProperties()
        }
    }

    override func trailingSwipeActions(for item: Item) -> UISwipeActionsConfiguration? {
        guard case .phrase(let scope, let value, let occurrence) = item,
              let index = index(of: value, occurrence: occurrence, scope: scope) else { return nil }
        let delete = UIContextualAction(style: .destructive, title: String(localized: "Delete")) { [weak self] _, _, done in
            self?.model.deletePhrase(workspaceScope: scope == .workspace, index: index)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    // MARK: - Helpers

    private func position(of item: Item) -> Int? {
        guard case .phrase(let scope, let value, let occurrence) = item else { return nil }
        return index(of: value, occurrence: occurrence, scope: scope)
    }

    private func index(of value: String, occurrence: Int, scope: PhraseScope) -> Int? {
        let list = scope == .workspace ? model.workspaceDraft : model.globalDraft
        return list.indices.filter { list[$0] == value }.dropFirst(occurrence).first
    }

    /// Puts the cursor in the phrase field once the editor's rows are drawn.
    private func focusPhraseField() {
        setNeedsUpdateProperties()
        updatePropertiesIfNeeded()
        view.layoutIfNeeded()
        guard let indexPath = dataSource?.indexPath(for: .item(.field)),
              let cell = collectionView.cellForItem(at: indexPath) as? SSHTerminalTextFieldCell else { return }
        cell.textField.becomeFirstResponder()
    }
}
