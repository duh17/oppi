import UIKit

/// Settings > Voice & Dictation: how voice replies play, which engine
/// dictates, the dictation animation (with a live preview of the composer's mic),
/// and the Dictation Dictionary. The first three are saved on this device. The
/// dictionary is the active server's, so its row says which server, and is
/// disabled with the reason while no server is paired.
@MainActor
final class SettingsVoiceViewController: SettingsListViewController<SettingsVoiceViewController.Section, SettingsVoiceViewController.Item> {
    enum Section: Hashable, Sendable { case replies, dictation, dictionary }
    enum Item: Hashable, Sendable { case replies, engine, animation, micPreview, dictionary }

    private let root: AppRootEnvironment

    init(root: AppRootEnvironment) {
        self.root = root
        super.init(
            title: String(localized: "Voice & Dictation"),
            listIdentifier: "settings.voice.list",
            scope: .device,
            footers: true
        )
    }

    /// The server whose Dictation Dictionary the row opens: the active one.
    private var dictionaryServer: PairedServer? {
        root.coordinator.activeServerId.flatMap { root.coordinator.serverStore.server(for: $0) }
    }

    override func sections() -> [SettingsSectionModel<Section, Item>] {
        let replyMode = AppPreferences.Voice.replyMode
        let server = dictionaryServer
        return [
            SettingsSectionModel(
                .replies,
                footer: String(localized: "\(replyMode.detail) Session-specific changes still happen in chat."),
                items: [.replies]
            ),
            // One footer for the engine, the animation, and its preview.
            SettingsSectionModel(
                .dictation,
                footer: Self.dictationFooter(engine: AppPreferences.Voice.engineMode),
                items: [.engine, .animation, .micPreview]
            ),
            SettingsSectionModel(
                .dictionary,
                footer: Self.dictionaryFooter(serverName: server?.name),
                scope: server.map { .server($0.name) },
                items: [.dictionary]
            ),
        ]
    }

    static func dictationFooter(engine: AppPreferences.Voice.EngineMode) -> String {
        let engineText = switch engine {
        case .remote:
            String(localized: "Server dictation sends audio to the speech-to-text service configured on your paired server.")
        case .onDevice:
            String(localized: "On-device dictation uses Apple's local dictation.")
        }
        return engineText + " " + String(localized: "The preview shows the animation only; it does not use the microphone.")
    }

    static func dictionaryFooter(serverName: String?) -> String {
        let purpose = String(localized: "Names and terms that help dictation recognize what you say.")
        guard serverName != nil else {
            return purpose + " " + String(localized: "Pair a server to edit its dictionary.")
        }
        return purpose
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .replies: AnyHashable(AppPreferences.Voice.replyMode)
        case .engine: AnyHashable(AppPreferences.Voice.engineMode)
        case .animation: AnyHashable(AppPreferences.Appearance.dictationIndicatorStyle)
        case .micPreview: AnyHashable(AppPreferences.Appearance.dictationIndicatorStyle)
        case .dictionary: AnyHashable(dictionaryServer?.id ?? "")
        }
    }

    // MARK: - Cells

    private lazy var menuRow = UICollectionView.CellRegistration<SettingsMenuRowCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        switch item {
        case .replies:
            cell.configure(
                title: String(localized: "Voice Replies"),
                identifier: "settings.voice.replies",
                options: AppPreferences.Voice.ReplyMode.allCases.map { mode in
                    (mode.label, mode == AppPreferences.Voice.replyMode, { [weak self] in
                        AppPreferences.Voice.setReplyMode(mode)
                        self?.setNeedsUpdateProperties()
                    })
                }
            )
        case .engine:
            cell.configure(
                title: String(localized: "Dictation Engine"),
                identifier: "settings.voice.engine",
                options: AppPreferences.Voice.supportedModes.map { mode in
                    (mode.label, mode == AppPreferences.Voice.engineMode, { [weak self] in
                        AppPreferences.Voice.setEngineMode(mode)
                        self?.setNeedsUpdateProperties()
                    })
                }
            )
        default:
            cell.configure(
                title: String(localized: "Dictation Animation"),
                identifier: "settings.dictationIndicatorStyle",
                options: DictationIndicatorStyle.allCases.map { style in
                    (style.displayName, style == AppPreferences.Appearance.dictationIndicatorStyle, { [weak self] in
                        AppPreferences.Appearance.setDictationIndicatorStyle(style)
                        self?.setNeedsUpdateProperties()
                    })
                }
            )
        }
    }

    private lazy var previewRow = UICollectionView.CellRegistration<SettingsWorkPreviewCell, Item> { cell, _, _ in
        cell.configureMic(labelColor: SettingsStyle.current.value)
    }

    private lazy var dictionaryRow = UICollectionView.CellRegistration<SettingsIndexRowCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        let server = dictionaryServer
        cell.configure(
            title: String(localized: "Dictation Dictionary"),
            systemImage: nil,
            value: server == nil ? String(localized: "No server paired") : nil,
            identifier: "settings.dictationDictionary",
            isEnabled: server != nil
        ) { [weak self] in self?.openDictionary() }
    }

    override func prepareRegistrations() {
        _ = (menuRow, previewRow, dictionaryRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .replies, .engine, .animation: collectionView.dequeueConfiguredReusableCell(using: menuRow, for: indexPath, item: item)
        case .micPreview: collectionView.dequeueConfiguredReusableCell(using: previewRow, for: indexPath, item: item)
        case .dictionary: collectionView.dequeueConfiguredReusableCell(using: dictionaryRow, for: indexPath, item: item)
        }
    }

    private func openDictionary() {
        let navigator = ScreenNavigator.forUIKitScreen(self, root: root)
        navigator.push { DictationDictionaryView(workspaceId: nil) }
    }
}
