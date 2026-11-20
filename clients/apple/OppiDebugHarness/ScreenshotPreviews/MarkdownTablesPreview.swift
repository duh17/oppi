#if DEBUG
import UIKit

// MARK: - Markdown Tables Preview

/// `SCREENSHOT_SCREEN=markdown-tables`: one assistant message with the table
/// shapes chat meets, drawn by the live markdown renderer at the window's width.
/// It opens with four overflow shapes: a 5-column plan whose columns run past
/// the edge, a small table that fits, a 25-row two-column table folded at 20,
/// and a test report both too wide and too long. Then a short benchmark table (4 columns, 3 rows) that is just too wide for a phone
/// in portrait, a prose table that fits by wrapping, an 8-column table of numbers
/// with right-aligned delimiters, a wide table that scrolls sideways at any device
/// width, phone to 13-inch iPad (the planner wraps prose but never breaks a word,
/// so its long header words force the scroll), a 40-row table folded behind
/// "Show 20 more rows", and cells with inline code and bold.
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
        let longRows = (1 ... 40).map { "| item-\($0) | value \($0) | \($0 % 3 == 0 ? "done" : "open") |" }
        let settings = [
            "Auto-Save", "Read Aloud voice", "Message Text Size", "Code font", "Wrap long lines", "Show thinking",
            "Haptics", "Keep screen awake", "Sound on finish", "Default model", "Thinking level", "Live Activity",
            "Notifications", "App Lock", "Lock after", "Incognito by default", "Spell check", "Smart quotes",
            "Send with Return", "Dictation language", "Theme", "App icon", "Pane width", "New pane side", "Experiments",
        ]
        let defaults = [
            "On", "Ava", "Default", "SF Mono", "Off", "Collapsed", "On", "Off", "On", "Server default", "Medium",
            "On", "Mentions only", "Off", "5 minutes", "Off", "On", "Off", "Off", "English (US)", "Night", "Default",
            "Half", "Right", "None",
        ]
        let settingRows = zip(settings, defaults).map { "| \($0) | \($1) |" }
        let suites = [
            "MarkdownTableColumnLayoutTests", "MarkdownTableStreamingGateTests", "MarkdownTableGridTests",
            "AssistantMarkdownSegmentTests", "ChatTimelineScrollTests", "ComposerPolicyTests", "PaneHostControllerTests",
            "ScenePanesTreeTests", "RouterPresentationTests", "SessionListEntriesTests", "GitStatusStoreTests",
            "ServerRouteControllerTests", "FocusedSessionStreamBinderTests", "ReaderTraceTests", "BookReaderBodyTests",
            "DocumentEditOwnerTests", "TaskSourceEditTests", "SSHTerminalRegistryTests", "RexSessionConnectionTests",
            "LiveVoiceCallCenterTests", "AISharingConsentTests", "ThemeContrastTests", "EntityIconTests",
            "LoadStateContentTests", "ListScreenControllerTests", "ScheduleListTests", "QuickSessionModelTests",
            "FileSuggestionRankerTests",
        ]
        let suiteRows = suites.enumerated().map { index, suite in
            let tests = 12 + (index * 7) % 41
            let failed = index % 9 == 4 ? 1 : 0
            let skipped = index % 5 == 2 ? 2 : 0
            let median = 0.4 + Double((index * 13) % 37) / 10
            return "| \(suite) | \(tests) | \(tests - failed - skipped) | \(failed) | \(skipped) | \(String(format: "%.1f s", median)) | \(String(format: "%.1f s", median * 2.3)) | iPhone 17 Pro | shard-\(index % 4 + 1) |"
        }
        return """
        The plan, in landing order:

        | # | Slice | What changes | Risk | Depends on |
        | --- | --- | --- | --- | --- |
        | N1 | All Sessions row in the sidebar | One row above the workspaces opens every session across servers | Low | — |
        | N2 | Sidebar button belongs to the main pane | The button moves from the window bar into the primary pane's bar, so a split never shows two | Medium | — |
        | N3 | Back means back (needs N2) | Back pops the stack it was pushed on instead of replacing the root | High: 97 navigation tests pin the old behaviour | N2 |
        | N4 | One `open` function (needs N3) | Every entry point routes through one function that picks the pane | High | N3 |
        | N5 | Side content through the same function | Files, Git, and the browser open beside the chat through it | Medium | N4 |
        | N6 (later) | Terminal becomes a routed screen | The terminal gets a route and stops presenting itself | Medium | N4 |
        | N7 (later) | Every pane's stack in one tree | Restore and rotation rebuild panes from one tree | High | N6 |

        The defaults:

        | Mode | Shortcut |
        | --- | --- |
        | Plan | ⌘1 |
        | Build | ⌘2 |
        | Review | ⌘3 |

        Every setting and its default:

        | Setting | Default |
        | --- | --- |
        \(settingRows.joined(separator: "\n"))

        Last night's unit run, by suite:

        | Suite | Tests | Passed | Failed | Skipped | Median duration | p95 duration | Simulator | Shard |
        | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
        \(suiteRows.joined(separator: "\n"))

        Parse times, median of 50 runs:

        | Input | comrak, parse only | Oppi tonight, full pipeline | swift-cmark alone |
        | --- | --- | --- | --- |
        | 6 KB message | 0.03 ms | 0.08 ms | — |
        | 67 KB report | 0.35 ms | 1.5 ms | — |
        | 273 KB session | 1.1 ms | 4.1 ms | about 2.0 ms |

        Here is how the three options compare.

        | Work | Commit | Qualification |
        | --- | --- | --- |
        | Timeline fold | 3f9c2a1 | Folds tables past twenty rows behind a bar that opens the full table. |
        | Fit to width | 8d41e7b | Wraps the long column into the room that is left instead of cutting it off. |
        | Overflow cue | c20b5f6 | Fades the edge and counts the columns that are still off screen. |

        Launch and scroll on each test device:

        | Device | OS | Cold launch | Warm launch | Scroll p50 | Scroll p95 | Peak memory | Battery per hour |
        | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
        | iPhone 16 Pro | iOS 27.1 | 412 ms | 118 ms | 8.1 ms | 14.6 ms | 182 MB | 4.2% |
        | iPhone 13 mini | iOS 26.4 | 655 ms | 171 ms | 9.8 ms | 21.3 ms | 164 MB | 6.0% |
        | iPad mini (A17 Pro) | iPadOS 27.1 | 398 ms | 104 ms | 7.9 ms | 13.2 ms | 211 MB | 3.1% |
        | iPhone SE (3rd generation) | iOS 26.4 | 1,702 ms | 190 ms | 11.4 ms | 26.8 ms | 151 MB | 7.4% |

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
