import UIKit

/// Settings > Text: the code font, the code and message text sizes, and
/// whether messages use the code font, over a live preview set in the fonts the
/// app draws with. Everything here is saved on this device, and a change
/// applies at once to chats, code, and terminals (`FontPreferences` rebuilds
/// `AppFont` before the page redraws).
@MainActor
final class SettingsTextViewController: ListScreenController<SettingsTextViewController.Section, SettingsTextViewController.Item> {
    enum Section: Hashable, Sendable { case codeFont, codeSize, messages, preview }
    enum Item: Hashable, Sendable { case codeFont, codeSize, messageSize, monospacedMessages, preview }

    /// The size sliders move in whole percents of five.
    static let step: Float = 0.05

    init() {
        super.init(
            title: String(localized: "Text"),
            listIdentifier: "settings.text.list",
            scope: .device,
            footers: true
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // `AppFont` is rebuilt after the preference notification, so the preview
        // reads the new fonts from this one.
        NotificationCenter.default.addObserver(
            self, selector: #selector(fontsDidRebuild), name: AppFont.didRebuildNotification, object: nil
        )
    }

    @objc private func fontsDidRebuild() { setNeedsUpdateProperties() }

    override func sections() -> [ListSection<Section, Item>] {
        [
            ListSection(
                .codeFont,
                footer: String(localized: "Nerd Font icons add prompt and file icons in the terminal and tool output, with any code font."),
                items: [.codeFont]
            ),
            ListSection(
                .codeSize,
                footer: String(localized: "Code blocks, diffs, terminals, and tool output."),
                items: [.codeSize]
            ),
            ListSection(
                .messages,
                footer: String(localized: "Assistant and user chat messages. Monospaced Messages sets them in your code font."),
                items: [.messageSize, .monospacedMessages]
            ),
            ListSection(.preview, items: [.preview]),
        ]
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .codeFont: AnyHashable(FontPreferences.codeFont)
        case .codeSize: AnyHashable(FontPreferences.codeTextScale)
        case .messageSize: AnyHashable(FontPreferences.messageTextScale)
        case .monospacedMessages: AnyHashable(FontPreferences.useMonoForMessages)
        // Every font change rebuilds `AppFont`, and a text-size change rebuilds it too.
        case .preview: AnyHashable(AppFont.revision)
        }
    }

    // MARK: - Cells

    private lazy var menuRow = UICollectionView.CellRegistration<SettingsMenuRowCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(
            title: String(localized: "Code Font"),
            identifier: "settings.text.codeFont",
            value: FontPreferences.codeFont.displayName,
            menu: {
                FontPreferences.CodeFontFamily.allCases.map { family in
                    SettingsMenuOption(title: family.displayName, selected: family == FontPreferences.codeFont) { [weak self] in
                        self?.setCodeFont(family)
                    }
                }
            }
        )
    }

    private lazy var sliderRow = UICollectionView.CellRegistration<SettingsSliderRowCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        switch item {
        case .codeSize:
            configure(
                cell, title: String(localized: "Code Text Size"), identifier: "settings.text.codeSize",
                scale: FontPreferences.codeTextScale,
                range: FontPreferences.minimumCodeTextScale...FontPreferences.maximumCodeTextScale,
                set: { FontPreferences.setCodeTextScale($0) }
            )
        default:
            configure(
                cell, title: String(localized: "Message Text Size"), identifier: "settings.text.messageSize",
                scale: FontPreferences.messageTextScale,
                range: FontPreferences.minimumMessageTextScale...FontPreferences.maximumMessageTextScale,
                set: { FontPreferences.setMessageTextScale($0) }
            )
        }
    }

    private lazy var previewRow = UICollectionView.CellRegistration<SettingsWorkPreviewCell, Item> { cell, _, _ in
        cell.configurePreview(
            SettingsTypographyPreviewView(),
            caption: String(localized: "Preview"),
            symbol: "text.magnifyingglass",
            labelColor: SettingsStyle.current.value
        )
    }

    override func prepareRegistrations() {
        _ = (menuRow, sliderRow, previewRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .codeFont: collectionView.dequeueConfiguredReusableCell(using: menuRow, for: indexPath, item: item)
        case .codeSize, .messageSize: collectionView.dequeueConfiguredReusableCell(using: sliderRow, for: indexPath, item: item)
        case .preview: collectionView.dequeueConfiguredReusableCell(using: previewRow, for: indexPath, item: item)
        case .monospacedMessages: super.dequeue(item, at: indexPath)
        }
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        guard item == .monospacedMessages else { return }
        toggleRow(
            cell,
            title: String(localized: "Monospaced Messages"),
            isOn: FontPreferences.useMonoForMessages,
            identifier: "settings.text.monospacedMessages"
        ) { [weak self] in
            FontPreferences.setUseMonoForMessages($0)
            self?.setNeedsUpdateProperties()
        }
    }

    private func configure(
        _ cell: SettingsSliderRowCell,
        title: String,
        identifier: String,
        scale: CGFloat,
        range: ClosedRange<CGFloat>,
        set: @escaping @MainActor (CGFloat) -> Void
    ) {
        let percent = Self.percent(scale)
        cell.configure(
            title: title,
            valueText: "\(percent)%",
            spokenValue: String(localized: "\(percent) percent"),
            value: Float(scale),
            range: Float(range.lowerBound)...Float(range.upperBound),
            step: Self.step,
            identifier: identifier
        ) { [weak self] value in
            // Whole hundredths: the slider's `Float` steps carry binary noise.
            set(CGFloat((Double(value) * 100).rounded() / 100))
            self?.setNeedsUpdateProperties()
        }
    }

    private func setCodeFont(_ family: FontPreferences.CodeFontFamily) {
        FontPreferences.setCodeFont(family)
        setNeedsUpdateProperties()
    }

    static func percent(_ scale: CGFloat) -> Int { Int((scale * 100).rounded()) }
}
