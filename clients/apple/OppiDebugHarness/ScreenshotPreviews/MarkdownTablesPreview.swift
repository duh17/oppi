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
        super.init(
            root: root,
            themeStore: root.themeStore,
            content: MarkdownMessageContentController(message: Self.message, scrollIdentifier: "markdownTables.scroll")
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

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
}

// MARK: - Markdown Math Preview

/// `SCREENSHOT_SCREEN=markdown-math`: one assistant answer with inline and
/// display math in a heading, prose, a table, a quote and a nested list,
/// beside the dollar amounts and shell variables that must stay text.
/// `SCREENSHOT_MATH_PAGE=costs` is a long cost report: formulas above a
/// table with more than a thousand dollar signs. `SCREENSHOT_MATH_PAGE=stream`
/// streams a long math-heavy answer 48 bytes every 50 ms, following its tail,
/// then names the scroll view `markdownMath.streamDone`.
/// `SCREENSHOT_MATH_PAGE=parity` holds the wiki-link and embed shapes the
/// parser glue repairs (emphasis and reference definitions inside `[[…]]`,
/// embed sizes, embeds in table cells and quotes) and an Org paragraph with
/// dollars and stars; workspace images come from a local stand-in fetcher.
final class MarkdownMathPreviewController: PreviewRootController {
    init(root: AppRootEnvironment) {
        super.init(
            root: root,
            themeStore: root.themeStore,
            content: Self.content(page: ProcessInfo.processInfo.environment["SCREENSHOT_MATH_PAGE"])
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private static let message = #"""
    ## The $a*b*c$ rule for $O(n^2)$

    Between $5 and $10, or $USD/$EUR at $PATH:$HOME, stays text; $\alpha = 0.43$ and \(a_n = 2^n\) are math, as is $$\sum_{i=1}^{n} i$$ in a sentence.

    | Case | Formula | Cost |
    | --- | --- | --- |
    | Circle | $\pi r^2$ | $7.76 |
    | Norm | $\sqrt{x^2 + y^2}$ | **$49.56** |

    > A quoted display:
    > $$
    > a*b*c + d_1*e_1*f
    > $$

    1. A step
        - with a nested display:

            $$
            T(n) = \alpha*n*\beta
            $$

        - and a closing item.
    """#

    private static func content(page: String?) -> UIViewController {
        switch page {
        case "costs":
            MarkdownMessageContentController(message: costReport, scrollIdentifier: "markdownMath.scroll")
        case "stream":
            MarkdownMessageContentController(message: streamedAnswer, scrollIdentifier: "markdownMath.scroll", streams: true)
        case "parity":
            MarkdownMessageContentController(
                message: parityAnswer,
                scrollIdentifier: "markdownMath.scroll",
                resourceAccess: previewWorkspaceAccess
            )
        default:
            MarkdownMessageContentController(message: message, scrollIdentifier: "markdownMath.scroll")
        }
    }

    private static let streamedAnswer: String = (0 ..< 12).map { step in
        #"""
        ### Step \#(step): the $\alpha_{\#(step)}$ term

        With $\alpha_{\#(step)} = 0.\#(step)$ and $\beta = \frac{1}{\#(step + 2)}$, the term $x_{\#(step)}^2 + y_{\#(step)}^2$ grows while $5 and $10 stay prices.

        $$
        T_{\#(step)}(n) = \sum_{i=1}^{n} \alpha_i n^{\#(step % 3 + 1)} + \beta
        $$

        | Case | Formula | Cost |
        | --- | --- | --- |
        | A\#(step) | $\pi r^{\#(step)}$ | $\#(step).50 |

        - The bound \(a_n \le 2^{\#(step)}\) holds.

        """#
    }.joined(separator: "\n")

    private static let parityAnswer: String = {
        let org = "Costs $5*2 or (2*$3) total and $x_1$ math."
        let orgMarkdown = MarkdownBlockSerializer.serialize(
            OrgToMarkdownConverter.convert(located: OrgParser().parseLocated(org))
        )
        let markdown = #"""
        See [[*draft*]] beside [[my_notes_file]], and [[foo]] here.

        Labels: [[docs/a.md|A | B]] and [[docs/c.md|[c]]].

        ![[img/wide.png|160]]

        | Clip | Pic | Sized |
        | --- | --- | --- |
        | ![[clips/a.mp4]] | ![alt](img/p.png) | ![[img/pic.png|300]] |

        > Quoted: ![[img/y.png]]

        """#
        return markdown + "Org: " + orgMarkdown + "\n\n[foo]: https://example.com\n"
    }()

    /// Workspace `ws` on a placeholder server, serving one generated picture for every path.
    private static var previewWorkspaceAccess: MarkdownResourceAccess {
        MarkdownResourceAccess(
            identity: .init(serverID: "preview", workspaceID: "ws", serverBaseURL: URL(string: "https://oppi.invalid")),
            fetchWorkspaceFile: { _, path in previewPicture(label: path) }
        )
    }

    private static func previewPicture(label: String) -> Data {
        let size = CGSize(width: 1_200, height: 800)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
            (label as NSString).draw(
                at: CGPoint(x: 60, y: 340),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 96), .foregroundColor: UIColor.white]
            )
        }
    }

    private static let costReport: String = {
        let rows = (1 ... 600).map { "| run-\($0) | $\($0 % 9).\($0 % 7)5 | $\($0 % 13).2\($0 % 10) |" }
        return """
        ## Cost report

        The fit is $c(t) = a*t*b + d$ with $a = 0.42$; the night run went from $7.76 to $49.56 (+$41.80), and \\$5 was the cap.

        | Run | Input | Output |
        | --- | --- | --- |
        \(rows.joined(separator: "\n"))
        """
    }()
}

/// One assistant message drawn by the live markdown renderer at the window's width.
private final class MarkdownMessageContentController: UIViewController {
    private let scrollView = UIScrollView()
    private let markdown = AssistantMarkdownContentView()
    private let message: String
    private let scrollIdentifier: String
    private let streams: Bool
    private let resourceAccess: MarkdownResourceAccess
    private var appliedWidth: CGFloat = 0
    private var streamedByteCount = 0
    private var streamTimer: Timer?

    private static let margin: CGFloat = 16

    init(
        message: String,
        scrollIdentifier: String,
        streams: Bool = false,
        resourceAccess: MarkdownResourceAccess = .empty
    ) {
        self.message = message
        self.scrollIdentifier = scrollIdentifier
        self.streams = streams
        self.resourceAccess = resourceAccess
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ThemeRuntimeState.currentPalette().ui.bgDark
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.accessibilityIdentifier = scrollIdentifier
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
        guard streams else {
            markdown.apply(configuration: .make(
                content: message,
                isStreaming: false,
                themeID: ThemeRuntimeState.currentThemeID(),
                resourceAccess: resourceAccess
            ))
            return
        }
        guard streamTimer == nil else { return }
        streamTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.streamNextChunk() }
        }
    }

    private func streamNextChunk() {
        let bytes = Array(message.utf8)
        var end = min(bytes.count, streamedByteCount + 48)
        while end < bytes.count, bytes[end] & 0xC0 == 0x80 { end += 1 }
        streamedByteCount = end
        let isDone = end == bytes.count
        markdown.apply(configuration: .make(
            content: String(decoding: bytes[..<end], as: UTF8.self),
            isStreaming: !isDone,
            themeID: ThemeRuntimeState.currentThemeID()
        ))
        view.layoutIfNeeded()
        let bottom = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        scrollView.contentOffset.y = max(-scrollView.adjustedContentInset.top, bottom)
        if isDone {
            streamTimer?.invalidate()
            streamTimer = nil
            scrollView.accessibilityIdentifier = "markdownMath.streamDone"
        }
    }
}
#endif
