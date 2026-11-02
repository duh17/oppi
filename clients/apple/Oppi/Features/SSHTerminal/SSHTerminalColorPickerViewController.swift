import UIKit

/// Chooses where a host's terminal takes its colors from: the host's own Ghostty
/// theme, the app's theme, or one theme by name. The names come from the host
/// over a live terminal's side channel when the screen opens, so a host with no
/// open terminal offers the first two and the one already chosen.
///
/// A `ListScreenController`: the base paints the rows, runs the page's one read
/// (`readThemes`), and draws what the read found in the themes section — its
/// loading row, and a failure with one Retry.
final class SSHTerminalColorPickerViewController: ListScreenController<
    SSHTerminalColorPickerViewController.Section, SSHTerminalColorPickerViewController.Item
> {
    enum Section: Hashable, Sendable { case choices, themes }

    enum Item: Hashable, Sendable {
        case host, oppi
        case theme(String)
    }

    private let selected: SSHTerminalColorChoice
    private let hostSummary: String
    /// Reads the theme names over a live terminal; nil when this host has none
    /// open, which the section's footer says.
    private let readThemes: (@MainActor () async -> [String]?)?
    private let onSelect: (SSHTerminalColorChoice) -> Void
    private let search = ScreenSearchController(prompt: String(localized: "Search themes"))
    /// The names the host offered, once they came back.
    private var names: [String]? {
        didSet { setNeedsUpdateProperties() }
    }
    private var query = "" {
        didSet { setNeedsUpdateProperties() }
    }

    /// `readThemes` is a connected terminal of this host, or nil when there is none.
    init(
        selected: SSHTerminalColorChoice,
        hostSummary: String,
        readThemes: (@MainActor () async -> [String]?)?,
        onSelect: @escaping (SSHTerminalColorChoice) -> Void
    ) {
        self.selected = selected
        self.hostSummary = hostSummary
        self.readThemes = readThemes
        self.onSelect = onSelect
        super.init(
            title: "Terminal Colors",
            listIdentifier: "sshTerminal.colors.list",
            headers: false,
            footers: true,
            largeTitle: false
        )
        navigationItem.largeTitleDisplayMode = .never
        search.install(on: self, alwaysVisible: true)
        search.searchController.searchBar.accessibilityIdentifier = "sshTerminal.colors.search"
        // Theme names are file names: no sentence capital, no "correcting" them.
        search.searchController.searchBar.autocapitalizationType = .none
        search.onTextChange = { [weak self] text in
            guard let self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard trimmed != query else { return }
            query = trimmed
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        search.hostDidAppear(self)
    }

    // MARK: - Load

    /// The names are the same until the terminal is another one, and a read that
    /// failed is tried again when the page appears: an offline host offers no
    /// read at all.
    override var loadPolicy: LoadPolicy { readThemes == nil ? .none : .onceUntilSubjectChanges }

    override func load() async throws {
        guard let readThemes else { return }
        guard let offered = await readThemes() else {
            throw LoadFailure(String(localized: "Couldn’t read the host’s themes"))
        }
        guard !Task.isCancelled else { return }
        names = offered
    }

    // MARK: - Rows

    override func sections() -> [ListSection<Section, Item>] {
        [
            ListSection(.choices, footer: choicesFooter, items: [.host, .oppi]),
            ListSection(.themes, footer: themesFooter, items: shownThemes.map(Item.theme)),
        ]
    }

    /// The themes the section shows: the host's, narrowed by the search field,
    /// or the saved one alone when there is no terminal to list its folders.
    private var shownThemes: [String] {
        guard let names else {
            if case let .named(name) = selected { return [name] }
            return []
        }
        guard !query.isEmpty else { return names }
        return names.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var choicesFooter: String {
        String(localized: "The host’s theme is read from its Ghostty config each time you connect. Oppi uses its own theme where the host has none.")
    }

    private var themesFooter: String? {
        guard readThemes != nil else {
            return String(localized: "Connect to this host to choose from the themes it has.")
        }
        // Nothing to add while the read is on its way, or after it failed: the
        // section's own state row says what happened.
        guard let names else { return nil }
        return names.isEmpty ? String(localized: "This host has no Ghostty themes.") : nil
    }

    /// The list's own state row sits in the themes section, where the names go.
    override func stateSection() -> Section? { .themes }

    override func hasContent() -> Bool { !(names ?? []).isEmpty }

    override func loadingCaption() -> String? { String(localized: "Reading the host’s themes…") }

    /// A row is keyed by whether it is the chosen one: choosing another moves the
    /// check and leaves every other row as it was.
    override func inputs(of item: Item) -> AnyHashable {
        guard let value = choice(for: item) else { return AnyHashable(0) }
        return AnyHashable(value == selected)
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        let style = SettingsStyle.current
        var content = content(.info)
        switch item {
        case .host:
            content.text = SSHTerminalColorChoice.host.title
            content.secondaryText = hostSummary
            cell.accessibilityIdentifier = "sshTerminal.colors.option.host"
        case .oppi:
            content.text = SSHTerminalColorChoice.oppi.title
            cell.accessibilityIdentifier = "sshTerminal.colors.option.oppi"
        case let .theme(name):
            content.text = name
            cell.accessibilityIdentifier = "sshTerminal.colors.theme.\(name)"
        }
        if let value = choice(for: item) {
            let isSelected = value == selected
            cell.accessories = isSelected ? [.checkmark(options: .init(tintColor: style.accent))] : []
            cell.accessibilityTraits.insert(.button)
            if isSelected { cell.accessibilityTraits.insert(.selected) } else { cell.accessibilityTraits.remove(.selected) }
        }
        cell.contentConfiguration = content
    }

    override func isSelectable(_ item: Item) -> Bool { choice(for: item) != nil }

    override func select(_ item: Item) {
        guard let value = choice(for: item) else { return }
        onSelect(value)
        Router.finish(self)
    }

    private func choice(for item: Item) -> SSHTerminalColorChoice? {
        switch item {
        case .host: .host
        case .oppi: .oppi
        case let .theme(name): .named(name)
        }
    }
}
