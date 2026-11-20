import UIKit

/// A button a file reader's bar can show, or offer in its … menu when it is
/// turned off. The cases read in the default order, leading to trailing (top
/// to bottom on the side rail).
enum ReaderBarAction: String, CaseIterable, Identifiable, BarLayoutAction {
    case edit
    case find
    case outline
    case copy
    case share
    /// Source and rendered views of the same file (Markdown, a table, HTML).
    case sourceToggle
    /// Text size, wrapping, and spacing.
    case viewingOptions
    /// The file before and after this one in the list it was opened from.
    case previousFile
    case nextFile
    /// Floating controls that join the bar on the side rail only.
    case annotate
    case stash

    /// Every button the reader drew before the bar was customizable, so nothing
    /// disappears from it on upgrade.
    static let defaultShown = Set(allCases)
    /// A button a later version adds waits in the … menu of a layout saved
    /// before it.
    static let unseen = BarLayoutUnseenRule.appendHidden

    var id: String { rawValue }

    @MainActor var label: String {
        switch self {
        case .edit: String(localized: "Edit")
        case .find: String(localized: "Find")
        case .outline: String(localized: "Outline")
        case .copy: String(localized: "Copy")
        case .share: String(localized: "Share")
        case .sourceToggle: String(localized: "Source or Preview")
        case .viewingOptions: String(localized: "Viewing Options")
        case .previousFile: String(localized: "Previous File")
        case .nextFile: String(localized: "Next File")
        case .annotate: PaperMarkupCanvasSession.AnnotateAction.title
        case .stash: FullScreenReviewCommentStashControl.accessibilityLabel
        }
    }

    @MainActor var systemImage: String {
        switch self {
        case .edit: "pencil"
        case .find: "magnifyingglass"
        case .outline: "list.bullet.indent"
        case .copy: "doc.on.doc"
        case .share: "square.and.arrow.up"
        case .sourceToggle: "curlybraces"
        case .viewingOptions: FullScreenViewingOptionsSymbols.readerModeIconName
        case .previousFile: "chevron.left"
        case .nextFile: "chevron.right"
        case .annotate: PaperMarkupCanvasSession.AnnotateAction.systemImage
        case .stash: FullScreenReviewCommentStashControl.systemImage
        }
    }

    /// The … menu item's identifier while the button is turned off.
    var menuIdentifier: String { "fileViewer.menu.\(rawValue)" }
}

typealias ReaderBarLayout = BarLayout<ReaderBarAction>

/// What a file reader offers in its bar now, and the person's Reader Bar
/// layout over it: the one owner for a reader's trailing items and its … menu,
/// whichever bar shows them (the reader's own, or the screen that embeds the
/// viewer).
///
/// The … is the system's overflow menu (`additionalOverflowItems`), never a
/// second one of ours: it holds the turned-off buttons, the document's own
/// actions (Edit with Session), and Customize Bar…, and UIKit adds whatever a
/// narrow bar crowds out. While the editor is open its status, Preview, and
/// Done own the bar instead.
@MainActor
final class ReaderBar {
    /// Each offered action's buttons, leading to trailing. Most actions are
    /// one button; the editor's controls are several.
    private(set) var offers: [ReaderBarAction: [UIBarButtonItem]] = [:]
    /// Menu items of the document's own (Edit with Session).
    private(set) var documentActions: [UIMenuElement] = []
    /// Presents Customize Bar….
    weak var presenter: UIViewController?
    /// Runs when the person changes the layout (in Customize, here or in
    /// another window), so the owner lays its bar out again.
    var onLayoutChange: (() -> Void)?

    private let defaults: UserDefaults
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        observer = NotificationCenter.default.addObserver(
            forName: AppPreferences.ReaderBar.preference.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onLayoutChange?() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var layout: ReaderBarLayout { AppPreferences.ReaderBar.layout(in: defaults) }

    /// Replaces what the reader offers. Returns whether anything changed, so a
    /// caller reassigns its bar only then.
    @discardableResult
    func update(offers next: [ReaderBarAction: [UIBarButtonItem]], documentActions nextActions: [UIMenuElement]) -> Bool {
        let same = next.count == offers.count && next.allSatisfy { action, items in
            offers[action].map { $0.elementsEqual(items, by: ===) } ?? false
        } && nextActions.elementsEqual(documentActions, by: ===)
        guard !same else { return false }
        offers = next
        documentActions = nextActions
        return true
    }

    /// The shown actions' buttons in `rightBarButtonItems` order: the first is
    /// the trailing-most.
    ///
    /// A bar too narrow for all of them crowds the rest into the system's …
    /// from the end of the person's order: each button's visibility priority
    /// falls from standard with its place, so the first stays longest and
    /// Back or Close (high) outlasts them all on the Duo's shared rail. Every
    /// button is titled with an icon, so UIKit's crowded-out rows read like
    /// the turned-off ones (`menuElement`), and none is a text button, which
    /// would split the bar into two glass groups.
    var trailingItems: [UIBarButtonItem] {
        let items = layout.bar(available: Set(offers.keys)).flatMap { offers[$0] ?? [] }
        if #available(iOS 27.0, *) {
            let first = UIBarButtonItemVisibilityPriority.standard.rawValue
            for (place, item) in items.enumerated() {
                item.visibilityPriority = UIBarButtonItemVisibilityPriority(rawValue: first - place)
            }
        }
        return items.reversed()
    }

    /// The … menu, built once: what it lists is read when it opens, so a
    /// redraw never replaces a menu someone is holding.
    private(set) lazy var overflow = makeOverflow()

    private func makeOverflow() -> UIDeferredMenuElement {
        UIDeferredMenuElement.uncached { [weak self] completion in
            // The menu asks on the main thread.
            MainActor.assumeIsolated { completion(self?.overflowElements() ?? []) }
        }
    }

    func overflowElements() -> [UIMenuElement] {
        var sections: [UIMenuElement] = []
        let hidden = layout.menu(available: Set(offers.keys)).compactMap { action -> UIMenuElement? in
            guard let item = offers[action]?.first else { return nil }
            return Self.menuElement(for: action, item: item)
        }
        if !hidden.isEmpty { sections.append(UIMenu(options: .displayInline, children: hidden)) }
        if !documentActions.isEmpty { sections.append(UIMenu(options: .displayInline, children: documentActions)) }
        let customize = UIAction(
            title: String(localized: "Customize Bar\u{2026}"),
            image: UIImage(systemName: "slider.horizontal.3")
        ) { [weak self] _ in self?.customize() }
        customize.accessibilityIdentifier = "fileViewer.menu.customize"
        sections.append(customize)
        return sections
    }

    private func customize() {
        guard let presenter else { return }
        BarCustomizeViewController<ReaderBarAction, Never>(surface: .readerBar(defaults: defaults))
            .presentSheet(from: presenter)
    }

    /// A turned-off button as a menu item that does what the button does: the
    /// row it shows when the bar crowds it into the … (`menuRepresentation`:
    /// Share, Outline, the source toggle), else its own menu (a table's Copy)
    /// as a submenu, else its action.
    private static func menuElement(for action: ReaderBarAction, item: UIBarButtonItem) -> UIMenuElement {
        if let representation = item.menuRepresentation { return representation }
        let image = UIImage(systemName: action.systemImage)
        if item.primaryAction == nil, item.action == nil, let menu = item.menu {
            let submenu = UIMenu(title: action.label, image: image, children: menu.children)
            submenu.accessibilityIdentifier = action.menuIdentifier
            return submenu
        }
        let element = UIAction(title: action.label, image: image, attributes: item.isEnabled ? [] : .disabled) { _ in
            if let primary = item.primaryAction {
                primary.performWithSender(item, target: nil)
            } else if let selector = item.action {
                UIApplication.shared.sendAction(selector, to: item.target, from: item, for: nil)
            }
        }
        element.accessibilityIdentifier = action.menuIdentifier
        return element
    }
}

extension BarSurface where Action == ReaderBarAction {
    /// Customize for a file reader's bar: Settings → Editor → Reader Bar, and
    /// the reader's … menu.
    static func readerBar(defaults: UserDefaults = .standard) -> Self {
        BarSurface(
            title: String(localized: "Reader Bar"),
            footer: String(localized: "A button turned off moves into the \u{2026} menu. A button shows only where the file offers it: Outline for a file with headings, Source or Preview for a file with both, Previous File and Next File for a file opened from a list. Annotate and Staged Comments join the bar on a side toolbar; elsewhere they float over the page. While you edit, the editor's controls take the bar."),
            identifierPrefix: "settings.reader.bar",
            preference: AppPreferences.ReaderBar.preference,
            defaults: defaults,
            row: { Row(title: $0.label, image: UIImage(systemName: $0.systemImage, withConfiguration: UIImage.SymbolConfiguration(textStyle: .body))) }
        )
    }
}
