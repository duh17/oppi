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
/// Leaving and opening again is the journey the saved position is for.
final class BookReaderHarnessViewController: UIViewController {
    private static let positionKey = EPUBReadingPositionStore.key(
        serverId: "harness",
        origin: "workspace:harness",
        path: "books/a-quiet-book.epub"
    )

    private let readyLabel = UILabel()
    private let openButton = UIButton(type: .system)

    private lazy var book: EPUBBook? = try? EPUBBook.open(data: EPUBFixture.epub3(
        title: "A Quiet Book",
        chapterTitles: ["One", "Two", "Three"]
    ))

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ThemeID.dark.palette.ui.bgDark
        // Every launch starts a new book.
        EPUBReadingPositionStore().clear(Self.positionKey)

        readyLabel.text = "harness.ready"
        readyLabel.accessibilityIdentifier = "harness.ready"
        readyLabel.textColor = ThemeID.dark.palette.ui.fgDim
        readyLabel.font = .scaled(.footnote)

        var configuration = UIButton.Configuration.borderedProminent()
        configuration.title = "Open book"
        openButton.configuration = configuration
        openButton.accessibilityIdentifier = "harness.book.open"
        openButton.addTarget(self, action: #selector(openBook), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [readyLabel, openButton])
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
        ])
    }

    @objc private func openBook() {
        guard let book else { return }
        let document = EPUBReaderDocument(
            book: book,
            positionKey: Self.positionKey,
            filePath: "books/a-quiet-book.epub",
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
