import UIKit

/// The notice an extension or the app raises through
/// `ServerConnection.extensionToast`: its message, one line each, titled
/// "Notice". A line with a web link shows the text before the link as its
/// label, the link (opened the way the Open Links preference says, through
/// the app root's opener), and a button that copies it. Done closes the
/// notice; so does swiping it down.
///
/// `AppRootModals` presents it and hands it each newer message through
/// `update(message:)`.
@MainActor
final class ExtensionNoticeViewController: UIViewController {
    /// One non-empty line of a notice: plain text, or a label and its link.
    struct Line: Equatable {
        let text: String
        let label: String
        let url: URL?
    }

    private let root: AppRootEnvironment
    private var message: String
    /// What the rows were last drawn from.
    private var shown: (themeID: ThemeID, message: String)?
    private let scrollView = UIScrollView()
    private let stack = UIStackView()

    init(message: String, root: AppRootEnvironment) {
        self.message = message
        self.root = root
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Notice")
        traitOverrides.appRootEnvironment = root
        navigationItem.largeTitleDisplayMode = .never
        let done = UIBarButtonItem(
            title: String(localized: "Done"),
            style: .done,
            target: self,
            action: #selector(finish)
        )
        done.accessibilityIdentifier = "extension.notice.done"
        navigationItem.rightBarButtonItem = done
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(message: String) {
        guard message != self.message else { return }
        self.message = message
        setNeedsUpdateProperties()
    }

    // MARK: Lines

    /// The message split into its non-empty lines, each with the first web
    /// link it holds.
    static func lines(of message: String) -> [Line] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return message.components(separatedBy: .newlines).compactMap { raw -> Line? in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }

            let range = NSRange(location: 0, length: trimmed.utf16.count)
            guard let match = detector?.firstMatch(in: trimmed, options: [], range: range),
                  let urlRange = Range(match.range, in: trimmed),
                  let url = URL(string: String(trimmed[urlRange])),
                  url.scheme?.hasPrefix("http") == true else {
                return Line(text: trimmed, label: trimmed, url: nil)
            }

            let prefix = String(trimmed[..<urlRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            return Line(text: trimmed, label: prefix.isEmpty ? String(localized: "Link") : prefix, url: url)
        }
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        scrollView.alwaysBounceVertical = false
        scrollView.accessibilityIdentifier = "extension.notice.list"
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 16
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
        ])
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.shown = nil
            self.setNeedsUpdateProperties()
        }
    }

    override func updateProperties() {
        super.updateProperties()
        // Read here, so a theme change runs this again.
        let themeID = root.themeStore.activeThemeID
        view.backgroundColor = UIColor(themeID.palette.bg)
        guard shown?.themeID != themeID || shown?.message != message else { return }
        shown = (themeID, message)
        rebuild(palette: themeID.palette)
    }

    private func rebuild(palette: ThemePalette) {
        for row in stack.arrangedSubviews {
            stack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        for line in Self.lines(of: message) {
            if let url = line.url {
                stack.addArrangedSubview(linkRow(label: line.label, url: url, palette: palette))
            } else {
                let text = UILabel()
                text.numberOfLines = 0
                text.font = .preferredFont(forTextStyle: .body)
                text.adjustsFontForContentSizeCategory = true
                text.textColor = UIColor(palette.fg)
                text.text = line.text
                text.accessibilityIdentifier = "extension.notice.text"
                stack.addArrangedSubview(text)
            }
        }
    }

    private func linkRow(label: String, url: URL, palette: ThemePalette) -> UIView {
        let caption = UILabel()
        caption.numberOfLines = 0
        caption.font = .preferredFont(forTextStyle: .subheadline)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = UIColor(palette.comment)
        caption.text = label

        var linkConfiguration = UIButton.Configuration.plain()
        linkConfiguration.contentInsets = .zero
        linkConfiguration.baseForegroundColor = UIColor(palette.blue)
        linkConfiguration.titleLineBreakMode = .byTruncatingTail
        linkConfiguration.attributedTitle = AttributedString(
            url.absoluteString,
            attributes: AttributeContainer([.font: UIFont.preferredFont(forTextStyle: .body)])
        )
        let link = UIButton(configuration: linkConfiguration, primaryAction: UIAction { [weak self] _ in
            self?.root.opener.open(.webLink(url))
        })
        link.contentHorizontalAlignment = .leading
        link.accessibilityIdentifier = "extension.notice.link"
        link.setContentHuggingPriority(.defaultLow, for: .horizontal)
        link.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var copyConfiguration = UIButton.Configuration.plain()
        copyConfiguration.image = UIImage(systemName: "doc.on.doc")
        copyConfiguration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(scale: .medium)
        copyConfiguration.baseForegroundColor = UIColor(palette.fgDim)
        let copy = UIButton(configuration: copyConfiguration, primaryAction: UIAction { _ in
            UIPasteboard.general.string = url.absoluteString
            AppHaptics.impact(style: .light, intensity: 0.8)
        })
        copy.accessibilityLabel = String(localized: "Copy link")
        copy.accessibilityIdentifier = "extension.notice.copy"
        copy.setContentHuggingPriority(.required, for: .horizontal)
        copy.setContentCompressionResistancePriority(.required, for: .horizontal)

        let actions = UIStackView(arrangedSubviews: [link, copy])
        actions.axis = .horizontal
        actions.spacing = 12
        actions.alignment = .center

        let column = UIStackView(arrangedSubviews: [caption, actions])
        column.axis = .vertical
        column.spacing = 4
        return column
    }

    @objc private func finish() {
        Router.finish(self)
    }
}
