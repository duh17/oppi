import UIKit

/// The book's table of contents in a sheet: one row per entry that names a
/// chapter in the reading order, indented by how deeply the book nests it, with
/// the chapter on screen marked and scrolled into view.
@MainActor
final class BookTableOfContentsViewController: UIViewController {
    struct Row: Equatable {
        let title: String
        /// Nesting depth from the book's own table of contents.
        let level: Int
        /// Index in the book's reading order.
        let chapter: Int
    }

    private let bookTitle: String
    private let rows: [Row]
    private let currentChapter: Int
    private let palette: ThemePalette
    private let onSelect: (Int) -> Void

    private let titleLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .plain)

    init(
        bookTitle: String,
        rows: [Row],
        currentChapter: Int,
        palette: ThemePalette,
        onSelect: @escaping (Int) -> Void
    ) {
        self.bookTitle = bookTitle
        self.rows = rows
        self.currentChapter = currentChapter
        self.palette = palette
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = palette.ui.bgDark
        view.accessibilityIdentifier = "fullScreen.book.tocSheet"

        titleLabel.text = bookTitle
        titleLabel.font = .scaled(.headline)
        titleLabel.textColor = palette.ui.fg
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2
        titleLabel.accessibilityIdentifier = "fullScreen.book.tocSheet.title"

        doneButton.setTitle(String(localized: "Done"), for: .normal)
        doneButton.titleLabel?.font = .scaled(.body, .semibold)
        doneButton.tintColor = palette.ui.blue
        doneButton.addTarget(self, action: #selector(done), for: .touchUpInside)
        doneButton.accessibilityIdentifier = "fullScreen.book.tocSheet.done"

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = palette.ui.bgDark
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "toc")
        tableView.accessibilityIdentifier = "fullScreen.book.tocSheet.list"

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
        content.text = row.title
        content.textProperties.font = .scaled(row.level == 0 ? .body : .subheadline)
        content.textProperties.color = row.chapter == currentChapter ? palette.ui.blue : palette.ui.fg
        content.textProperties.numberOfLines = 2
        content.directionalLayoutMargins.leading = 20 + CGFloat(min(row.level, 5)) * 16
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        cell.accessoryType = row.chapter == currentChapter ? .checkmark : .none
        cell.tintColor = palette.ui.blue
        cell.accessibilityIdentifier = "fullScreen.book.tocSheet.row"
        // One stop per row: the title, and whether it is the chapter on screen.
        cell.accessibilityLabel = row.chapter == currentChapter
            ? String(localized: "\(row.title), current chapter")
            : row.title
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
