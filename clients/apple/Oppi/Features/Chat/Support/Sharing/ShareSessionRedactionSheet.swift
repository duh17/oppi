import Observation
import UIKit

/// Share redaction state that chat and its share sheet both edit. The sheet
/// is a router modal with its own graph, so it reads this model rather than
/// chat's `@State`.
@MainActor @Observable
final class ShareSessionRedactionReview {
    var policy = AppPreferences.Share.redactionPolicy
    private(set) var preflight: ShareSessionPrepareResult?
    private(set) var errorMessage: String?
    private(set) var isAnalyzing = false
    @ObservationIgnored private var preflightTask: Task<Void, Never>?

    /// Starts from the remembered policy with no preview.
    func reset() {
        policy = AppPreferences.Share.redactionPolicy
        preflight = nil
        errorMessage = nil
    }

    /// Debounced preview of the export with the current policy. A newer
    /// request or `cancelPreflight()` drops an older one.
    func schedulePreflight(
        prepare: @escaping @MainActor (ShareSessionRedactionPolicy) async throws -> ShareSessionPrepareResult?
    ) {
        preflightTask?.cancel()
        isAnalyzing = true
        errorMessage = nil
        let policy = policy.normalized
        preflightTask = Task { @MainActor [weak self] in
            defer { self?.isAnalyzing = false }
            do {
                try await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                let prepared = try await prepare(policy)
                guard !Task.isCancelled else { return }
                self?.preflight = prepared
                self?.errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.preflight = nil
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelPreflight() {
        preflightTask?.cancel()
        preflightTask = nil
        isAnalyzing = false
    }
}

/// Share with redaction review, at the root of a router navigation controller
/// (`.inNavigation()`): the redaction switches, remembered for future
/// shares, and a preview of what the export redacts. It reads `review` live,
/// so the preview updates while the sheet is up.
final class ShareSessionRedactionViewController: ListScreenController<ShareSessionRedactionViewController.Section, ShareSessionRedactionViewController.Item> {
    enum Section: Hashable, Sendable { case settings, preview }

    enum Item: Hashable, Sendable {
        case secrets
        /// One redaction switch, by its index in `toggles` (a key path is not `Hashable`).
        case toggle(Int)
        case analyzing
        case error(String)
        case summary(Int)
        case noFindings
        case finding(kind: String, count: Int, sample: String?)
        case more(Int)
        case blocked
        case refresh
    }

    private static let toggles: [(title: String, keyPath: WritableKeyPath<ShareSessionRedactionPolicy, Bool>)] = [
        ("Email Addresses", \.emails),
        ("Phone Numbers", \.phones),
        ("User Paths", \.userPaths),
        ("IP Addresses", \.ipAddresses),
        ("JWT Tokens", \.jwtAndBearer),
        ("Names (Heuristic)", \.namesHeuristic),
        ("Skills", \.skills),
    ]

    private let review: ShareSessionRedactionReview
    private let isSharing: () -> Bool
    private let onRefresh: () -> Void
    private let onShare: () -> Void
    private let onCancel: () -> Void
    /// The seven switches, kept across redraws: each row owns one for the sheet's life.
    private lazy var switches: [UISwitch] = Self.toggles.map { toggle in
        let control = UISwitch()
        control.accessibilityLabel = toggle.title
        control.addAction(UIAction { [weak self, weak control] _ in
            guard let self, let control else { return }
            self.setPolicy(toggle.keyPath, control.isOn)
        }, for: .valueChanged)
        return control
    }
    private lazy var shareItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            title: "Share",
            image: UIImage(systemName: "square.and.arrow.up"),
            primaryAction: UIAction { [weak self] _ in self?.onShare() }
        )
        item.style = .prominent
        return item
    }()
    private lazy var sharingItem: UIBarButtonItem = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        spinner.accessibilityLabel = "Sharing"
        return UIBarButtonItem(customView: spinner)
    }()

    init(
        review: ShareSessionRedactionReview,
        isSharing: @escaping () -> Bool,
        onRefresh: @escaping () -> Void,
        onShare: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.review = review
        self.isSharing = isSharing
        self.onRefresh = onRefresh
        self.onShare = onShare
        self.onCancel = onCancel
        super.init(
            title: "Share Session",
            listIdentifier: "share.redaction.list",
            headers: true,
            footers: true
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.onCancel()
        })
        review.reset()
        onRefresh()
    }

    /// Observation re-runs this when the review, sharing, or the theme change.
    override func updateProperties() {
        super.updateProperties()
        // The theme's accent, as the app root's SwiftUI tint gave the sheet.
        let style = SettingsStyle.current
        let accent = style.accent
        view.tintColor = accent
        navigationItem.leftBarButtonItem?.tintColor = accent
        shareItem.tintColor = accent
        let policy = review.policy
        for (index, toggle) in Self.toggles.enumerated() {
            switches[index].onTintColor = accent
            if switches[index].isOn != policy[keyPath: toggle.keyPath] {
                switches[index].setOn(policy[keyPath: toggle.keyPath], animated: true)
            }
        }
        shareItem.isEnabled = !review.isAnalyzing
        navigationItem.rightBarButtonItem = isSharing() ? sharingItem : shareItem
    }

    private func setPolicy(_ keyPath: WritableKeyPath<ShareSessionRedactionPolicy, Bool>, _ isOn: Bool) {
        var policy = review.policy
        policy[keyPath: keyPath] = isOn
        let normalized = policy.normalized
        review.policy = normalized
        AppPreferences.Share.setRedactionPolicy(normalized)
        onRefresh()
    }

    // MARK: - Rows

    override func sections() -> [ListSection<Section, Item>] {
        var preview: [Item] = []
        if review.isAnalyzing { preview.append(.analyzing) }
        if let error = review.errorMessage, !error.isEmpty { preview.append(.error(error)) }
        if let preflight = review.preflight {
            let findings = preflight.redaction?.findings ?? []
            preview.append(.summary(preflight.redaction?.totalReplacements ?? 0))
            if findings.isEmpty {
                preview.append(.noFindings)
            } else {
                preview.append(contentsOf: findings.prefix(6).map {
                    Item.finding(kind: $0.kind, count: $0.count, sample: $0.samples.first)
                })
                if findings.count > 6 { preview.append(.more(findings.count - 6)) }
            }
            if preflight.blocked { preview.append(.blocked) }
        }
        preview.append(.refresh)
        return [
            ListSection(
                .settings,
                header: "Redaction Settings",
                footer: "These settings are remembered for future shares.",
                items: [.secrets] + Self.toggles.indices.map { Item.toggle($0) }
            ),
            ListSection(.preview, header: "Redaction Preview", items: preview),
        ]
    }

    /// A switch shows the policy's value, and the Refresh row the one thing that
    /// changes about it while the sheet is up. The rest draw what they carry.
    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .toggle(let index): AnyHashable(review.policy[keyPath: Self.toggles[index].keyPath])
        case .secrets, .analyzing, .noFindings, .blocked: AnyHashable(0)
        case .refresh: AnyHashable(isSelectable(item))
        case .error, .summary, .finding, .more: AnyHashable(item)
        }
    }

    override func isSelectable(_ item: Item) -> Bool {
        guard item == .refresh else { return false }
        return !review.isAnalyzing && !isSharing()
    }

    override func select(_ item: Item) {
        guard item == .refresh else { return }
        onRefresh()
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        let palette = ThemeRuntimeState.currentPalette()
        let mono = { (style: UIFont.TextStyle) in UIFont.scaledMonospaced(style, .regular) }
        switch item {
        case .secrets:
            var content = content(.info)
            content.text = "Secrets"
            content.image = UIImage(systemName: "lock.fill")
            content.imageProperties.tintColor = palette.ui.blue
            content.secondaryText = "Always On"
            content.secondaryTextProperties.color = palette.ui.green
            cell.contentConfiguration = content
        case .toggle(let index):
            var content = content(.plain)
            content.text = Self.toggles[index].title
            cell.contentConfiguration = content
            cell.accessories = [.customView(configuration: .init(
                customView: switches[index],
                placement: .trailing()
            ))]
        case .analyzing:
            var content = content(.plain)
            content.text = "Scanning session export…"
            content.textProperties.color = palette.ui.comment
            cell.contentConfiguration = content
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .leading()))]
        case .error(let message):
            var content = content(.plain)
            content.text = message
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.color = palette.ui.red
            cell.contentConfiguration = content
        case .summary(let count):
            var content = content(.plain)
            content.text = "Detected \(count) replacements"
            content.textProperties.font = UIFont.scaled(.subheadline, .semibold)
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "share-redaction-summary"
        case .noFindings:
            var content = content(.plain)
            content.text = "No configured PII findings detected in this preview."
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.color = palette.ui.comment
            cell.contentConfiguration = content
        case .finding(let kind, let count, let sample):
            var content = content(.subtitle)
            content.text = "\(kind) ×\(count)"
            content.textProperties.font = mono(.subheadline)
            content.textToSecondaryTextVerticalPadding = 4
            if let sample, !sample.isEmpty {
                content.secondaryText = sample
                content.secondaryTextProperties.font = mono(.caption1)
                content.secondaryTextProperties.color = palette.ui.comment
            }
            cell.contentConfiguration = content
        case .more(let count):
            var content = content(.plain)
            content.text = "+\(count) more categories"
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.color = palette.ui.comment
            cell.contentConfiguration = content
        case .blocked:
            var content = content(.plain)
            content.text = "Sharing is currently blocked because residual secrets were detected."
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.color = palette.ui.orange
            cell.contentConfiguration = content
        case .refresh:
            // A button row, as a SwiftUI list draws one: the theme accent,
            // dimmed while a scan or a share runs.
            let enabled = isSelectable(item)
            var content = content(.plain)
            content.text = "Refresh Preview"
            content.textProperties.color = enabled ? palette.ui.blue : .tertiaryLabel
            cell.contentConfiguration = content
            cell.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
        }
    }
}
