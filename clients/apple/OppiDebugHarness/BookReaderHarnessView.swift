#if DEBUG
import UIKit

/// Launch-argument dispatch for the book reader harness: a shelf with one
/// synthetic book, so a UI test can open it, leave, and come back to the same
/// paragraph without a server.
enum BookReaderHarnessConfig {
    static var isEnabled: Bool {
#if targetEnvironment(simulator)
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("--book-reader-harness")
            || processInfo.environment["PI_BOOK_READER_HARNESS"] == "1"
#else
        return false
#endif
    }
}

/// A shelf: "Open book" presents the reader for a synthetic three-chapter book.
/// Leaving and opening again is the journey the saved position is for. The paged
/// reader needs a chapter that runs over several pages, so a second, longer book
/// sits next to the short one.
final class BookReaderHarnessViewController: UIViewController {
    private static let quietBookPath = "books/a-quiet-book.epub"
    private static let longBookPath = "books/a-long-book.epub"

    private static func positionKey(for path: String) -> String {
        EPUBReadingPositionStore.key(serverId: "harness", origin: "workspace:harness", path: path)
    }

    private let readyLabel = UILabel()
    private let openButton = UIButton(type: .system)
    private let openLongBookButton = UIButton(type: .system)

    private lazy var book: EPUBBook? = try? EPUBBook.open(data: EPUBFixture.epub3(
        title: "A Quiet Book",
        chapterTitles: ["One", "Two", "Three"]
    ))
    private lazy var longBook: EPUBBook? = try? EPUBBook.open(data: EPUBFixture.epub3(
        title: "A Quiet Book",
        chapterTitles: ["One", "Two", "Three"],
        paragraphsPerChapter: 90
    ))

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ThemeID.dark.palette.ui.bgDark
        // Every launch starts a new book, read as pages: a mode another run
        // chose is not this run's.
        for path in [Self.quietBookPath, Self.longBookPath] {
            EPUBReadingPositionStore().clear(Self.positionKey(for: path))
        }
        var modeStore = BookReaderPageModeStore()
        modeStore.defaults.removeObject(forKey: BookReaderPageModeStore.preferenceKey)

        readyLabel.text = "harness.ready"
        readyLabel.accessibilityIdentifier = "harness.ready"
        readyLabel.textColor = ThemeID.dark.palette.ui.fgDim
        readyLabel.font = .scaled(.footnote)

        var configuration = UIButton.Configuration.borderedProminent()
        configuration.title = "Open book"
        openButton.configuration = configuration
        openButton.accessibilityIdentifier = "harness.book.open"
        openButton.addTarget(self, action: #selector(openBook), for: .touchUpInside)

        var longConfiguration = UIButton.Configuration.bordered()
        longConfiguration.title = "Open paged book"
        openLongBookButton.configuration = longConfiguration
        openLongBookButton.accessibilityIdentifier = "harness.book.paged.open"
        openLongBookButton.addTarget(self, action: #selector(openLongBook), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [readyLabel, openButton, openLongBookButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            openButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            openButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            openLongBookButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            openLongBookButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @objc private func openBook() {
        presentReader(book, at: Self.quietBookPath)
    }

    @objc private func openLongBook() {
        presentReader(longBook, at: Self.longBookPath)
    }

    private func presentReader(_ book: EPUBBook?, at path: String) {
        guard let book else { return }
        let document = EPUBReaderDocument(
            book: book,
            positionKey: Self.positionKey(for: path),
            filePath: path,
            title: book.title
        )
        let reader = FullScreenCodeViewController(
            content: .book(document),
            presentationMode: .sheet
        )
        present(reader, animated: true)
    }
}
#endif
