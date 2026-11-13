import UIKit

/// A table of contents in a sheet: one row per entry, indented by how deeply
/// the document nests it, with the entry on screen marked and scrolled into
/// view. A book lists its chapters; a file reader lists its headings
/// (`ReaderOutline`), under its own identifier prefix.
@MainActor
final class BookTableOfContentsViewController: UIViewController {
    struct Row: Equatable {
        let title: String
        /// Nesting depth from the document's own table of contents.
        let level: Int
        /// Index in the book's reading order, or the heading's ordinal.
        let chapter: Int
        /// An Org task state that leads the title, and whether it is a done one.
        var keyword: String?
        var isDone = false
        /// Names this row for automation; rows share one identifier without it.
        var identifier: String?
    }

    private let identifierPrefix: String
    private let bookTitle: String
    private let rows: [Row]
    private let currentChapter: Int
    private let palette: ThemePalette
    /// The page's own paper, ink and link colour: the sheet is opened over a book
    /// and belongs to it, not to the app's chrome.
    private let appearance: BookReaderAppearance
    private let onSelect: (Int) -> Void

    private let titleLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .plain)

    init(
        bookTitle: String,
        rows: [Row],
        currentChapter: Int,
        palette: ThemePalette,
        appearance: BookReaderAppearance = BookReaderAppearance(),
        identifierPrefix: String = "fullScreen.book.tocSheet",
        onSelect: @escaping (Int) -> Void
    ) {
        self.identifierPrefix = identifierPrefix
        self.bookTitle = bookTitle
        self.rows = rows
        self.currentChapter = currentChapter
        self.palette = palette
        self.appearance = appearance
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        let paper = appearance.backgroundColor(in: palette)
        view.backgroundColor = paper
        // The sheet's own labels are system colours; on a light page they must be
        // the light-appearance ones.
        overrideUserInterfaceStyle = ReaderPaper.isLight(paper) ? .light : .dark
        view.accessibilityIdentifier = identifierPrefix

        titleLabel.text = bookTitle
        titleLabel.font = .scaled(.headline)
        titleLabel.textColor = appearance.textColor(in: palette)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2
        titleLabel.accessibilityIdentifier = "\(identifierPrefix).title"

        doneButton.setTitle(String(localized: "Done"), for: .normal)
        doneButton.titleLabel?.font = .scaled(.body, .semibold)
        doneButton.tintColor = appearance.linkColor(in: palette)
        doneButton.addTarget(self, action: #selector(done), for: .touchUpInside)
        doneButton.accessibilityIdentifier = "\(identifierPrefix).done"

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = paper
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "toc")
        tableView.accessibilityIdentifier = "\(identifierPrefix).list"

        for view in [titleLabel, doneButton, tableView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor, constant: -12),

            doneButton.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            doneButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),

            tableView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A popover closes by a tap outside or on a row; only a sheet needs Done.
        doneButton.isHidden = presentationController is UIPopoverPresentationController
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scrollToCurrentChapter()
    }

    private func scrollToCurrentChapter() {
        guard let row = rows.firstIndex(where: { $0.chapter == currentChapter }) else { return }
        tableView.layoutIfNeeded()
        tableView.scrollToRow(at: IndexPath(row: row, section: 0), at: .middle, animated: false)
    }

    @objc private func done() {
        dismiss(animated: true)
    }
}

extension BookTableOfContentsViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "toc", for: indexPath)
        let row = rows[indexPath.row]
        var content = UIListContentConfiguration.cell()
        let font = UIFont.scaled(row.level == 0 ? .body : .subheadline)
        let ink = row.chapter == currentChapter ? appearance.linkColor(in: palette) : appearance.textColor(in: palette)
        if let keyword = row.keyword {
            // The state leads the title, quieter once it is done.
            let text = NSMutableAttributedString(
                string: keyword + " ",
                attributes: [
                    .font: UIFont.scaled(.caption1, .semibold),
                    .foregroundColor: row.isDone ? palette.ui.fgDim : palette.ui.blue,
                ]
            )
            text.append(NSAttributedString(string: row.title, attributes: [.font: font, .foregroundColor: ink]))
            content.attributedText = text
        } else {
            content.text = row.title
            content.textProperties.font = font
            content.textProperties.color = ink
        }
        content.textProperties.numberOfLines = 2
        content.directionalLayoutMargins.leading = 20 + CGFloat(min(row.level, 5)) * 16
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        cell.accessoryType = row.chapter == currentChapter ? .checkmark : .none
        cell.tintColor = appearance.linkColor(in: palette)
        cell.accessibilityIdentifier = row.identifier ?? "\(identifierPrefix).row"
        // One stop per row: the state and title, and whether it is the chapter on screen.
        let spoken = row.keyword.map { "\($0), \(row.title)" } ?? row.title
        cell.accessibilityLabel = row.chapter == currentChapter
            ? String(localized: "\(spoken), current chapter")
            : spoken
        cell.accessibilityTraits = row.chapter == currentChapter ? [.button, .selected] : .button
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        let chapter = rows[indexPath.row].chapter
        dismiss(animated: true) { [onSelect] in
            onSelect(chapter)
        }
    }
}
