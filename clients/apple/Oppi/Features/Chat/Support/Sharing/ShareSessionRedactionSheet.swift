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
final class ShareSessionRedactionViewController: UIViewController, UICollectionViewDataSource {
    private enum Section: Int, CaseIterable { case settings, preview }

    private enum PreviewRow {
        case analyzing
        case error(String)
        case summary(Int)
        case noFindings
        case finding(ShareSessionRedactionFinding)
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
    private let list: UICollectionView
    private lazy var switches: [UISwitch] = Self.toggles.map { toggle in
        let control = UISwitch()
        control.accessibilityLabel = toggle.title
        control.addAction(UIAction { [weak self, weak control] _ in
            guard let self, let control else { return }
            self.setPolicy(toggle.keyPath, control.isOn)
        }, for: .valueChanged)
        return control
    }
    private var previewRows: [PreviewRow] = []
    private var refreshEnabled = true
    private lazy var rowRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, IndexPath> { [weak self] cell, indexPath, _ in
        self?.configure(cell, at: indexPath)
    }
    private lazy var headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
        elementKind: UICollectionView.elementKindSectionHeader
    ) { view, _, indexPath in
        var content = UIListContentConfiguration.groupedHeader()
        content.text = Section(rawValue: indexPath.section) == .settings ? "Redaction Settings" : "Redaction Preview"
        view.contentConfiguration = content
    }
    private lazy var footerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
        elementKind: UICollectionView.elementKindSectionFooter
    ) { view, _, indexPath in
        var content = UIListContentConfiguration.groupedFooter()
        content.text = Section(rawValue: indexPath.section) == .settings
            ? "These settings are remembered for future shares."
            : nil
        view.contentConfiguration = content
    }
    private var palette = ThemeRuntimeState.currentPalette()
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
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        configuration.footerMode = .supplementary
        // The theme's page shows behind the system cards, as on the settings pages.
        configuration.backgroundColor = .clear
        list = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration)
        )
        super.init(nibName: nil, bundle: nil)
        title = "Share Session"
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Registrations exist before the list asks for a cell.
        _ = (rowRegistration, headerRegistration, footerRegistration)
        list.dataSource = self
        list.delegate = self
        SSHTerminalSettingsList.pin(list, in: view)
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.onCancel()
        })
        review.reset()
        onRefresh()
    }

    /// Observation re-runs this when the review, sharing, or the theme change.
    override func updateProperties() {
        super.updateProperties()
        let themeID = HostFactory.root(near: self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        palette = themeID.palette
        let blue = UIColor(palette.blue)
        view.backgroundColor = UIColor(palette.bg)
        list.backgroundColor = UIColor(palette.bg)
        // The theme's accent, as the app root's SwiftUI tint gave the sheet.
        view.tintColor = blue
        navigationItem.leftBarButtonItem?.tintColor = blue
        shareItem.tintColor = blue
        let policy = review.policy
        for (index, toggle) in Self.toggles.enumerated() {
            switches[index].onTintColor = blue
            if switches[index].isOn != policy[keyPath: toggle.keyPath] {
                switches[index].setOn(policy[keyPath: toggle.keyPath], animated: true)
            }
        }
        let sharing = isSharing()
        let analyzing = review.isAnalyzing
        shareItem.isEnabled = !analyzing
        navigationItem.rightBarButtonItem = sharing ? sharingItem : shareItem

        var rows: [PreviewRow] = []
        if analyzing { rows.append(.analyzing) }
        if let error = review.errorMessage, !error.isEmpty { rows.append(.error(error)) }
        if let preflight = review.preflight {
            let findings = preflight.redaction?.findings ?? []
            rows.append(.summary(preflight.redaction?.totalReplacements ?? 0))
            if findings.isEmpty {
                rows.append(.noFindings)
            } else {
                rows.append(contentsOf: findings.prefix(6).map(PreviewRow.finding))
                if findings.count > 6 { rows.append(.more(findings.count - 6)) }
            }
            if preflight.blocked { rows.append(.blocked) }
        }
        rows.append(.refresh)
        previewRows = rows
        refreshEnabled = !analyzing && !sharing
        list.reloadData()
    }

    private func setPolicy(_ keyPath: WritableKeyPath<ShareSessionRedactionPolicy, Bool>, _ isOn: Bool) {
        var policy = review.policy
        policy[keyPath: keyPath] = isOn
        let normalized = policy.normalized
        review.policy = normalized
        AppPreferences.Share.setRedactionPolicy(normalized)
        onRefresh()
    }

    // MARK: List

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        Section.allCases.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        Section(rawValue: section) == .settings ? Self.toggles.count + 1 : previewRows.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        collectionView.dequeueConfiguredReusableSupplementary(
            using: kind == UICollectionView.elementKindSectionHeader ? headerRegistration : footerRegistration,
            for: indexPath
        )
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(using: rowRegistration, for: indexPath, item: indexPath)
    }

    private func configure(_ cell: UICollectionViewListCell, at indexPath: IndexPath) {
        cell.accessories = []
        cell.accessibilityTraits = []
        cell.accessibilityIdentifier = nil
        if Section(rawValue: indexPath.section) == .settings {
            if indexPath.item == 0 {
                var content = UIListContentConfiguration.valueCell()
                content.text = "Secrets"
                content.image = UIImage(systemName: "lock.fill")
                content.imageProperties.tintColor = UIColor(palette.blue)
                content.secondaryText = "Always On"
                content.secondaryTextProperties.color = UIColor(palette.green)
                cell.contentConfiguration = content
            } else {
                var content = UIListContentConfiguration.cell()
                content.text = Self.toggles[indexPath.item - 1].title
                cell.contentConfiguration = content
                cell.accessories = [.customView(configuration: .init(
                    customView: switches[indexPath.item - 1],
                    placement: .trailing()
                ))]
            }
            return
        }
        let mono = { (style: UIFont.TextStyle) in UIFont.scaledMonospaced(style, .regular) }
        var content = UIListContentConfiguration.cell()
        switch previewRows[indexPath.item] {
        case .analyzing:
            content.text = "Scanning session export…"
            content.textProperties.color = UIColor(palette.comment)
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .leading()))]
        case .error(let message):
            content.text = message
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.color = UIColor(palette.red)
        case .summary(let count):
            content.text = "Detected \(count) replacements"
            content.textProperties.font = UIFont.scaled(.subheadline, .semibold)
            cell.accessibilityIdentifier = "share-redaction-summary"
        case .noFindings:
            content.text = "No configured PII findings detected in this preview."
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.color = UIColor(palette.comment)
        case .finding(let finding):
            content = UIListContentConfiguration.subtitleCell()
            content.text = "\(finding.kind) ×\(finding.count)"
            content.textProperties.font = mono(.subheadline)
            content.textToSecondaryTextVerticalPadding = 4
            if let sample = finding.samples.first, !sample.isEmpty {
                content.secondaryText = sample
                content.secondaryTextProperties.font = mono(.caption1)
                content.secondaryTextProperties.color = UIColor(palette.comment)
            }
        case .more(let count):
            content.text = "+\(count) more categories"
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.color = UIColor(palette.comment)
        case .blocked:
            content.text = "Sharing is currently blocked because residual secrets were detected."
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.color = UIColor(palette.orange)
        case .refresh:
            // A button row, as a SwiftUI list draws one: the theme accent,
            // dimmed while a scan or a share runs.
            content.text = "Refresh Preview"
            content.textProperties.color = refreshEnabled ? UIColor(palette.blue) : .tertiaryLabel
            cell.accessibilityTraits = refreshEnabled ? .button : [.button, .notEnabled]
        }
        cell.contentConfiguration = content
    }
}

extension ShareSessionRedactionViewController: UICollectionViewDelegate {
    private func isRefreshRow(_ indexPath: IndexPath) -> Bool {
        guard Section(rawValue: indexPath.section) == .preview, previewRows.indices.contains(indexPath.item),
              case .refresh = previewRows[indexPath.item] else { return false }
        return true
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        isRefreshRow(indexPath) && refreshEnabled
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        onRefresh()
    }
}
