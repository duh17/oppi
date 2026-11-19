import UIKit

/// What an internal-URL viewer reads: one URL of one session, through the
/// session's `internal-url` routes.
@MainActor
struct InternalURLViewerSource {
    /// The URL as the link named it (`proc://bash-3`, or an id prefix).
    let url: String
    /// The view now, its output after UTF-16 offset `from` when given.
    let read: @MainActor (_ from: Int?) async throws -> InternalURLView
    let stop: @MainActor () async throws -> Void
    /// The … menu's Pin or Unpin for this view; empty where pins are off.
    let pinMenu: () -> [UIMenuElement]
}

/// One internal URL of a session (`PaneRoute.read`): beside its chat on a
/// wide window, full screen pushed on a narrow one. The header is what the
/// scheme says of it, top to bottom: the status with its time and Stop, the
/// facts, and the command; the body is the terminal reader over its output,
/// with the reader's buttons in the bar.
///
/// It reads only while it is on screen: once a second while the view is live,
/// asking only for the output after what it holds, and once more when it comes
/// back. Every field comes from `InternalURLView`, so every scheme with a
/// viewer shows the same way.
@MainActor
final class InternalURLViewController: UIViewController {
    private static let pollInterval: Duration = .seconds(1)

    private let source: InternalURLViewerSource
    /// Closes the pane; nil when the viewer is a pushed page, whose Back leaves it.
    private let onClose: (() -> Void)?

    private let header = InternalURLHeaderView()
    private let body = UIView()
    private let bar = FileViewerBar()
    private var reader: FullScreenCodeViewController?
    /// The live reader's feed; nil when it opened on finished output.
    private var trace: ReaderTrace<TerminalSnapshot>?
    private var window = InternalURLOutputWindow()
    private var shown: InternalURLView?
    private var polling: Task<Void, Never>?
    /// Which `startPolling` the running poller came from: a poller that ends clears `polling` only
    /// while it is still its own, never a newer one's.
    private var pollGeneration = 0
    private var clock: Timer?
    private var loadFailure: String?
    private var stopping = false

    init(source: InternalURLViewerSource, onClose: (() -> Void)?) {
        self.source = source
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.title = source.url
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "internalURL.view"
        if let onClose {
            let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { _ in onClose() })
            close.accessibilityIdentifier = "internalURL.close"
            navigationItem.leftBarButtonItem = close
        }
        header.onStop = { [weak self] in self?.stop() }
        header.isHidden = true
        for subview in [header, body] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: guide.topAnchor),
            header.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        updateBar()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startPolling()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        polling?.cancel()
        polling = nil
        clock?.invalidate()
        clock = nil
    }

    override func updateProperties() {
        super.updateProperties()
        let palette = (AppRootEnvironment.near(self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()).palette
        view.backgroundColor = palette.ui.bg
        header.applyPalette(palette)
        if shown != nil {
            contentUnavailableConfiguration = nil
        } else if let loadFailure {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loadState(.empty(
                title: String(localized: "Can\u{2019}t Show This"),
                systemImage: "terminal",
                message: loadFailure
            ), palette: palette, background: palette.ui.bg)
        } else {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loadState(
                .loading(String(localized: "Loading\u{2026}")), palette: palette, background: palette.ui.bg
            )
        }
    }

    // MARK: Reading

    /// Reads now, then once a second while the view is live; a finished view
    /// is read once each time the viewer shows.
    private func startPolling() {
        guard polling == nil else { return }
        pollGeneration += 1
        let generation = pollGeneration
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.readOnce()
                guard self.shown?.status.live == true else { break }
                try? await Task.sleep(for: Self.pollInterval)
            }
            if let self, self.pollGeneration == generation { self.polling = nil }
        }
    }

    private func readOnce() async {
        do {
            let next = try await source.read(shown == nil ? nil : window.end)
            // A cancelled poller's read lands after a newer poller started: only the newer one shows.
            guard !Task.isCancelled else { return }
            apply(next)
        } catch is CancellationError {
        } catch {
            // A read that fails after the first keeps what is shown; the next tick tries again.
            guard shown == nil else { return }
            loadFailure = error.localizedDescription
            setNeedsUpdateProperties()
        }
    }

    private func apply(_ next: InternalURLView) {
        window.apply(next.output)
        let first = shown == nil
        shown = next
        navigationItem.title = next.title
        navigationItem.subtitle = next.url
        header.isHidden = false
        header.apply(next, stopping: stopping)
        let snapshot = TerminalSnapshot(output: window.text, command: nil, isDone: !next.status.live)
        if first {
            mountReader(snapshot)
            setNeedsUpdateProperties()
        } else {
            trace?.update(snapshot)
        }
        tickClock()
    }

    /// The elapsed time counts on its own between reads.
    private func tickClock() {
        clock?.invalidate()
        clock = nil
        header.applyDuration(shown?.duration(at: .now))
        guard shown?.status.live == true else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.header.applyDuration(self.shown?.duration(at: .now))
            }
        }
    }

    private func mountReader(_ snapshot: TerminalSnapshot) {
        let trace = snapshot.isDone ? nil : ReaderTrace(snapshot, isNews: TerminalSnapshot.isNews)
        self.trace = trace
        let reader = FullScreenCodeViewController(
            content: .terminal(content: snapshot.output, command: nil, trace: trace),
            presentationMode: .contentOnly()
        )
        // Without a bar of its own, the reader's buttons (`barOffers`) join this one.
        reader.onBarOffersChange = { [weak self] in self?.updateBar() }
        addChild(reader)
        reader.view.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(reader.view)
        NSLayoutConstraint.activate([
            reader.view.topAnchor.constraint(equalTo: body.topAnchor),
            reader.view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            reader.view.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            reader.view.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
        reader.didMove(toParent: self)
        self.reader = reader
        updateBar()
    }

    private func updateBar() {
        bar.reader.presenter = self
        let offers = reader?.barOffers ?? [:]
        // The job view's Find keeps an identifier of its own.
        offers[.find]?.forEach { $0.accessibilityIdentifier = "internalURL.find" }
        bar.show(
            offers: offers,
            documentActions: [UIDeferredMenuElement.uncached { [weak self] completion in
                MainActor.assumeIsolated { completion(self?.source.pinMenu() ?? []) }
            }],
            editorItems: [],
            isEditing: false
        )
        bar.title = shown?.title ?? source.url
        bar.apply(to: navigationItem)
    }

    // MARK: Stop

    private func stop() {
        guard !stopping else { return }
        stopping = true
        if let shown { header.apply(shown, stopping: true) }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await source.stop()
            } catch {
                errorAlerts.show(title: String(localized: "Couldn\u{2019}t Stop"), message: error.localizedDescription)
            }
            stopping = false
            // The next read shows it stopped; a viewer off screen reads when it comes back.
            if polling == nil, viewIfLoaded?.window != nil { startPolling() }
            if let shown { header.apply(shown, stopping: false) }
        }
    }
}

/// The viewer's header: the status line (its mark, words and time, and Stop),
/// the facts, then the command, wrapped, with Copy.
@MainActor
final class InternalURLHeaderView: UIView {
    var onStop: (() -> Void)?

    private let statusIcon = UIImageView()
    private let statusLabel = UILabel()
    private let durationLabel = UILabel()
    private let stopButton = UIButton(configuration: .tinted())
    private let facts = UIStackView()
    private let commandBox = UIView()
    private let commandView = UITextView()
    private let copyButton = UIButton(configuration: .plain())
    private var commandHeight: NSLayoutConstraint?
    private var palette = ThemeRuntimeState.currentThemeID().palette
    private var tone = ExtensionSurfaceTone.neutral

    /// Lines of command shown before it scrolls inside its box.
    private static let commandMaxLines: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)
        statusIcon.accessibilityIdentifier = "internalURL.statusIcon"
        statusLabel.font = UIFont.scaled(.headline, .semibold)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.accessibilityIdentifier = "internalURL.status"
        durationLabel.font = .monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .regular
        )
        durationLabel.accessibilityIdentifier = "internalURL.duration"
        durationLabel.setContentHuggingPriority(.required, for: .horizontal)
        stopButton.configuration?.title = String(localized: "Stop")
        stopButton.configuration?.baseForegroundColor = .systemRed
        stopButton.configuration?.baseBackgroundColor = .systemRed
        stopButton.configuration?.cornerStyle = .capsule
        stopButton.accessibilityIdentifier = "internalURL.stop"
        stopButton.setContentHuggingPriority(.required, for: .horizontal)
        stopButton.addAction(UIAction { [weak self] _ in self?.onStop?() }, for: .primaryActionTriggered)
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let status = UIStackView(arrangedSubviews: [statusIcon, statusLabel, durationLabel, spacer, stopButton])
        status.spacing = 8
        status.alignment = .center
        status.isAccessibilityElement = false

        facts.axis = .vertical
        facts.spacing = 4
        facts.accessibilityIdentifier = "internalURL.facts"

        commandView.isEditable = false
        commandView.isSelectable = true
        commandView.backgroundColor = .clear
        commandView.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 40)
        commandView.textContainer.lineFragmentPadding = 0
        commandView.textContainer.lineBreakMode = .byCharWrapping
        commandView.accessibilityIdentifier = "internalURL.command"
        commandView.translatesAutoresizingMaskIntoConstraints = false
        copyButton.configuration?.image = UIImage(systemName: "doc.on.doc")
        copyButton.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote)
        copyButton.accessibilityLabel = String(localized: "Copy Command")
        copyButton.accessibilityIdentifier = "internalURL.command.copy"
        copyButton.addAction(UIAction { [weak self] _ in
            UIPasteboard.general.string = self?.commandView.text
        }, for: .primaryActionTriggered)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        commandBox.layer.cornerRadius = 10
        commandBox.addSubview(commandView)
        commandBox.addSubview(copyButton)
        let height = commandView.heightAnchor.constraint(equalToConstant: 44)
        commandHeight = height
        NSLayoutConstraint.activate([
            commandView.topAnchor.constraint(equalTo: commandBox.topAnchor),
            commandView.leadingAnchor.constraint(equalTo: commandBox.leadingAnchor),
            commandView.trailingAnchor.constraint(equalTo: commandBox.trailingAnchor),
            commandView.bottomAnchor.constraint(equalTo: commandBox.bottomAnchor),
            height,
            copyButton.topAnchor.constraint(equalTo: commandBox.topAnchor, constant: 2),
            copyButton.trailingAnchor.constraint(equalTo: commandBox.trailingAnchor, constant: -2),
        ])

        let column = UIStackView(arrangedSubviews: [status, facts, commandBox])
        column.axis = .vertical
        column.spacing = 12
        column.isLayoutMarginsRelativeArrangement = true
        column.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The command wraps to its box's width, up to six lines; a longer one scrolls in place.
        let font = commandView.font ?? Self.commandFont
        let fit = commandView.sizeThatFits(CGSize(width: commandView.bounds.width, height: .greatestFiniteMagnitude)).height
        let cap = font.lineHeight * Self.commandMaxLines + commandView.textContainerInset.top + commandView.textContainerInset.bottom
        let height = min(fit, cap)
        if commandHeight?.constant != height { commandHeight?.constant = height }
        commandView.isScrollEnabled = fit > cap
    }

    private static var commandFont: UIFont {
        .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
    }

    func applyPalette(_ palette: ThemePalette) {
        self.palette = palette
        backgroundColor = palette.ui.bg
        commandBox.backgroundColor = palette.ui.bgHighlight
        copyButton.tintColor = palette.ui.comment
        durationLabel.textColor = palette.ui.comment
        statusLabel.textColor = tone == .neutral ? palette.ui.fg : tone.color(palette)
        statusIcon.tintColor = tone.color(palette)
        for case let row as UIStackView in facts.arrangedSubviews {
            (row.arrangedSubviews.first as? UILabel)?.textColor = palette.ui.comment
            (row.arrangedSubviews.last as? UILabel)?.textColor = palette.ui.fg
        }
    }

    func apply(_ view: InternalURLView, stopping: Bool) {
        tone = ExtensionSurfaceTone(raw: view.status.tone)
        statusLabel.text = view.status.text
        statusIcon.image = UIImage(systemName: Self.symbol(for: tone, live: view.status.live))?
            .withConfiguration(UIImage.SymbolConfiguration(textStyle: .headline))
        stopButton.isHidden = !view.stoppable
        stopButton.isEnabled = !stopping
        stopButton.configuration?.title = stopping ? String(localized: "Stopping\u{2026}") : String(localized: "Stop")
        applyFacts(view.facts)
        commandBox.isHidden = view.command?.isEmpty ?? true
        if let command = view.command, commandView.text != command {
            let highlighted = NSMutableAttributedString(attributedString: ToolRowTextRenderer.bashCommandHighlighted(command))
            highlighted.addAttribute(.font, value: Self.commandFont, range: NSRange(location: 0, length: highlighted.length))
            commandView.attributedText = highlighted
            setNeedsLayout()
        }
        applyPalette(palette)
    }

    func applyDuration(_ text: String?) {
        durationLabel.text = text
        durationLabel.isHidden = text == nil
    }

    private func applyFacts(_ list: [InternalURLView.Fact]) {
        let rows = list.map { fact in (fact.label, fact.value ?? fact.time.map(Self.time) ?? "") }
        let current = facts.arrangedSubviews.compactMap { row -> (String, String)? in
            guard let row = row as? UIStackView,
                  let label = (row.arrangedSubviews.first as? UILabel)?.text,
                  let value = (row.arrangedSubviews.last as? UILabel)?.text else { return nil }
            return (label, value)
        }
        guard !rows.elementsEqual(current, by: ==) else { return }
        facts.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var firstLabel: UILabel?
        for (label, value) in rows {
            let key = UILabel()
            key.text = label
            key.font = .preferredFont(forTextStyle: .subheadline)
            key.adjustsFontForContentSizeCategory = true
            key.setContentHuggingPriority(.required, for: .horizontal)
            key.setContentCompressionResistancePriority(.required, for: .horizontal)
            let shown = UILabel()
            shown.text = value
            shown.font = .preferredFont(forTextStyle: .subheadline)
            shown.adjustsFontForContentSizeCategory = true
            shown.numberOfLines = 0
            shown.lineBreakMode = .byCharWrapping
            let row = UIStackView(arrangedSubviews: [key, shown])
            row.spacing = 12
            row.alignment = .firstBaseline
            row.isAccessibilityElement = true
            row.accessibilityLabel = label
            row.accessibilityValue = value
            row.accessibilityIdentifier = "internalURL.fact.\(label)"
            facts.addArrangedSubview(row)
            // The values line up in one column, after the widest label.
            if let firstLabel {
                key.widthAnchor.constraint(equalTo: firstLabel.widthAnchor).isActive = true
            } else {
                firstLabel = key
            }
            let fit = key.widthAnchor.constraint(greaterThanOrEqualToConstant: key.intrinsicContentSize.width)
            fit.isActive = true
        }
    }

    /// A fact's time in the device's clock: today's as a time, another day's with its date.
    private static func time(_ milliseconds: Double) -> String {
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        return Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func symbol(for tone: ExtensionSurfaceTone, live: Bool) -> String {
        if live { return WorkingMarkView.symbolName }
        return switch tone {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "xmark.circle.fill"
        case .accent, .neutral: "circle.fill"
        }
    }
}
