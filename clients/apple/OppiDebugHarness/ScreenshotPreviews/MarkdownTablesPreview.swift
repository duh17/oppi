#if DEBUG
import UIKit

// MARK: - Markdown Tables Preview

/// `SCREENSHOT_SCREEN=markdown-tables`: one assistant message with the table
/// shapes chat meets, drawn by the live markdown renderer at the window's width:
/// a prose table that fits by wrapping, a wide table that scrolls sideways at any
/// device width, phone to 13-inch iPad (the "N more columns" cue; the planner wraps
/// prose but never breaks a word, so its long header words force the scroll), a 30-row table
/// folded behind "Show all 30 rows", and cells with inline code and bold.
final class MarkdownTablesPreviewController: PreviewRootController {
    init(root: AppRootEnvironment) {
        super.init(root: root, themeStore: root.themeStore, content: MarkdownTablesContentController())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

private final class MarkdownTablesContentController: UIViewController {
    private let scrollView = UIScrollView()
    private let markdown = AssistantMarkdownContentView()
    private var appliedWidth: CGFloat = 0

    private static let margin: CGFloat = 16

    private static var message: String {
        let longRows = (1 ... 30).map { "| item-\($0) | value \($0) | \($0 % 3 == 0 ? "done" : "open") |" }
        return """
        Here is how the three options compare.

        | Work | Commit | Qualification |
        | --- | --- | --- |
        | Timeline fold | 3f9c2a1 | Folds tables past twenty rows behind a bar that opens the full table. |
        | Fit to width | 8d41e7b | Wraps the long column into the room that is left instead of cutting it off. |
        | Overflow cue | c20b5f6 | Fades the edge and counts the columns that are still off screen. |

        And the wide one, which cannot fit a phone or an iPad:

        | Endpoint | httpMethodVerbName | latencyMedianMillis | latencyNinetyFiveMillis | errorBudgetRemaining | owningTeamDirectory | deploymentRegionName | rolloutWindowStartTime | oncallRotationHandle | lastIncidentTimestamp | runbookDocumentationPath |
        | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        | /sessions | GET | 12 ms | 48 ms | 99.95% | Platform | us-west-2 | Tue 09:00 | primary | 2026-09-14 | sessions |
        | /sessions/:id | PATCH | 18 ms | 71 ms | 99.90% | Platform | eu-central-1 | Thu 14:00 | primary | 2026-10-02 | session-id |
        | /extensions | GET | 9 ms | 33 ms | 99.99% | Extensions | us-east-1 | Fri 10:30 | secondary | 2026-08-21 | extensions |

        A long one:

        | Item | Value | State |
        | --- | --- | --- |
        \(longRows.joined(separator: "\n"))

        Inline formatting in cells:

        | Call | Meaning |
        | --- | --- |
        | `fold(rows:)` | **Required** for long tables |
        | `plan(width:)` | *Chooses* clip, grid, or ~~scroll~~ fit |
        """
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ThemeRuntimeState.currentPalette().ui.bgDark
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.accessibilityIdentifier = "markdownTables.scroll"
        markdown.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(markdown)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            markdown.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 64),
            markdown.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            markdown.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: Self.margin),
            markdown.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -2 * Self.margin),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width - 2 * Self.margin
        guard width > 0, abs(width - appliedWidth) > 0.5 else { return }
        appliedWidth = width
        markdown.hostLayoutWidth = width
        markdown.apply(configuration: .make(
            content: Self.message,
            isStreaming: false,
            themeID: ThemeRuntimeState.currentThemeID()
        ))
    }
}
#endif
