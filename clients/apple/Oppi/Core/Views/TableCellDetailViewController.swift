import UIKit

/// The whole text of one table cell, for a cell the grid had to clip to one line.
/// A sheet over the full-screen table viewer: selectable text, a Copy button, Done.
final class TableCellDetailViewController: UIViewController {
    private let cellText: String
    private let palette: ThemePalette
    private let textView = UITextView()

    static func makeNavigationController(
        title: String,
        text: String,
        palette: ThemePalette
    ) -> UINavigationController {
        let controller = TableCellDetailViewController(title: title, text: text, palette: palette)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.overrideUserInterfaceStyle = ThemeRuntimeState.currentThemeID().preferredColorScheme == .light
            ? .light : .dark
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        return navigation
    }

    private init(title: String, text: String, palette: ThemePalette) {
        cellText = text
        self.palette = palette
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = palette.ui.bgDark
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textColor = palette.ui.fg
        textView.font = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular))
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.text = cellText
        textView.accessibilityIdentifier = "table.cell.detail.text"
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        let copy = UIBarButtonItem(
            image: UIImage(systemName: "doc.on.doc"),
            primaryAction: UIAction { [cellText] _ in UIPasteboard.general.string = cellText }
        )
        copy.accessibilityLabel = String(localized: "Copy cell")
        copy.accessibilityIdentifier = "table.cell.detail.copy"
        navigationItem.rightBarButtonItem = copy
    }
}
