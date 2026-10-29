import UIKit

/// Token and cost usage for one server: the range, the totals, the daily chart and a
/// day's drill-down, the models' share, and the workspaces.
///
/// The page is pinned to the server it was made for: its `UsageModel`, its requests,
/// and its bar switcher use that server and never follow a switch. `UsageRouteViewController`
/// shows the visible server's page and replaces it when that changes. The screen is a
/// scroll view over a stack, pinned to the safe area like Server Metrics; the three Swift
/// Charts (`UsageCharts.swift`) are SwiftUI leaves hosted in it with value-only inputs.
/// Server process and host resources live on Server Metrics, not here.
@MainActor
final class UsageViewController: UIViewController {
    let server: PairedServer
    let model: UsageModel
    private let root: AppRootEnvironment

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let switcher = PinnedServerSwitcher()
    private var appliedThemeKey: String?
    private var renderedChart: AnyHashable?
    private var renderedDonut: AnyHashable?
    private var renderedHourly: AnyHashable?

    private let providerCard = ProviderSetupPromptView()
    private let rangeControl = UISegmentedControl(items: UsageRange.allCases.map(\.label))
    private let message = UsageMessageView()
    private let hero = UsageHeroView()
    private let chartSlot = UIView()
    private let detailSpinner = UIActivityIndicatorView(style: .medium)
    private let detailView = UsageDailyDetailView()
    private let modelsSection = UIStackView()
    private let modelsHeading = UILabel()
    private let donutSlot = UIView()
    /// The total in the ring's middle, or under it at large text sizes (`donutTotalBelow`).
    private let donutTotalCenter = UILabel()
    private let donutTotalBelow = UILabel()
    private let modelList = UIStackView()
    private let modelsToggle = UIButton(type: .system)
    private let workspacesSection = UIStackView()
    private let workspacesHeading = UILabel()
    private let workspaceList = UIStackView()
    private let noWorkspaces = UILabel()

    private let chartHost = UsageChartHost()
    private let donutHost = UsageChartHost()
    private let hourlyHost = UsageChartHost()

    /// `model` is for the screenshot harness and tests: the app makes the server's own.
    init(server: PairedServer, root: AppRootEnvironment, model: UsageModel? = nil) {
        self.server = server
        self.root = root
        self.model = model ?? UsageModel(serverId: server.id, coordinator: root.coordinator)
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        title = HostSwitcherDestination.usage.title
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        model.stop()
    }

    private var coordinator: ConnectionCoordinator { root.coordinator }

    /// The pinned server as the pairing list has it now (a new name or badge).
    private var current: PairedServer { coordinator.serverStore.server(for: server.id) ?? server }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        model.start()
        setNeedsUpdateProperties()
    }

    override func updateProperties() {
        super.updateProperties()
        overrideUserInterfaceStyle = root.themeStore.userInterfaceStyle
        pinnedBar()
        render()
    }

    private func pinnedBar() {
        switcher.update(
            server: current,
            destination: .usage,
            root: root,
            traits: traitCollection,
            item: pinnedRouteNavigationItem
        )
    }

    // MARK: - Layout

    private func buildLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.accessibilityIdentifier = "server.usage.scroll"
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            Task {
                await self?.model.refresh()
                refresh?.endRefreshing()
            }
        }, for: .valueChanged)
        scrollView.refreshControl = refresh
        view.addSubview(scrollView)

        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        rangeControl.accessibilityIdentifier = "server.usage.range"
        rangeControl.accessibilityLabel = String(localized: "Range")
        rangeControl.addAction(UIAction { [weak self] _ in self?.rangeChanged() }, for: .valueChanged)

        providerCard.setContentHuggingPriority(.required, for: .vertical)
        hero.onSelect = { [weak self] metric in self?.model.selectMetric(metric) }
        detailView.onClose = { [weak self] in self?.model.closeDetail() }
        detailSpinner.hidesWhenStopped = true
        modelsToggle.addAction(UIAction { [weak self] _ in self?.model.toggleShowAllModels() }, for: .touchUpInside)
        modelsToggle.accessibilityIdentifier = "server.usage.models.toggle"
        modelsToggle.contentHorizontalAlignment = .leading

        modelList.axis = .vertical
        modelList.spacing = 6
        modelsSection.axis = .vertical
        modelsSection.spacing = 12
        modelsSection.alignment = .fill
        for label in [donutTotalCenter, donutTotalBelow] {
            label.numberOfLines = 0
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        donutSlot.addSubview(donutTotalCenter)
        // One element speaks the whole donut; its labels and the ring's own nodes are not separate.
        donutSlot.isAccessibilityElement = true
        donutSlot.accessibilityTraits = .staticText
        donutSlot.accessibilityIdentifier = "server.usage.donut"
        donutTotalCenter.isAccessibilityElement = false
        donutTotalBelow.isAccessibilityElement = false
        chartSlot.markAsChartSlot(UsageChartIdentifier.daily)
        NSLayoutConstraint.activate([
            donutTotalCenter.centerXAnchor.constraint(equalTo: donutSlot.centerXAnchor),
            donutTotalCenter.centerYAnchor.constraint(equalTo: donutSlot.centerYAnchor),
            donutTotalCenter.widthAnchor.constraint(lessThanOrEqualToConstant: 84),
        ])
        [modelsHeading, donutSlot, donutTotalBelow, modelList, modelsToggle].forEach(modelsSection.addArrangedSubview)
        modelsHeading.font = .preferredFont(forTextStyle: .subheadline).bold()
        modelsHeading.adjustsFontForContentSizeCategory = true
        modelsHeading.accessibilityTraits = .header
        modelsHeading.text = String(localized: "Models")

        workspaceList.axis = .vertical
        workspacesSection.axis = .vertical
        workspacesSection.spacing = 8
        workspacesHeading.font = .preferredFont(forTextStyle: .subheadline).bold()
        workspacesHeading.adjustsFontForContentSizeCategory = true
        workspacesHeading.accessibilityTraits = .header
        workspacesHeading.text = String(localized: "Workspaces")
        noWorkspaces.text = String(localized: "No workspace data")
        noWorkspaces.font = .preferredFont(forTextStyle: .caption1)
        noWorkspaces.adjustsFontForContentSizeCategory = true
        noWorkspaces.numberOfLines = 0
        [workspacesHeading, workspaceList, noWorkspaces].forEach(workspacesSection.addArrangedSubview)

        [providerCard, rangeControl, message, hero, chartSlot, detailSpinner, detailView, modelsSection, workspacesSection]
            .forEach(stack.addArrangedSubview)

        let content = scrollView.contentLayoutGuide
        // The safe area, not the scroll view's frame: in the split view the sidebar
        // floats over the detail column and shows in the safe area's leading inset.
        let safe = view.safeAreaLayoutGuide
        let fullWidth = stack.widthAnchor.constraint(equalTo: safe.widthAnchor, constant: -32)
        // Above every label's compression resistance, so a large type size wraps text
        // instead of widening the page past the screen.
        fullWidth.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            fullWidth,
        ])
    }

    private func rangeChanged() {
        let index = rangeControl.selectedSegmentIndex
        guard UsageRange.allCases.indices.contains(index) else { return }
        model.selectRange(UsageRange.allCases[index])
    }

    // MARK: - Rendering

    private func render() {
        guard isViewLoaded else { return }
        let themeID = root.themeStore.activeThemeID
        let colors = UsageColors(palette: themeID.palette)
        let themeKey = "\(themeID)"
        view.backgroundColor = root.themeStore.backgroundColor
        if appliedThemeKey != themeKey {
            appliedThemeKey = themeKey
            renderedChart = nil
            renderedDonut = nil
            renderedHourly = nil
        }
        let chartColors = UsageChartColors(palette: colors.palette, themeKey: themeKey)

        providerCard.isHidden = !model.showsProviderSetup
        if model.showsProviderSetup {
            providerCard.apply(
                message: String(localized: "Connect a model provider so new sessions can run on this server."),
                identifier: "server.providerSetup.open",
                themeID: themeID
            ) { [weak self] in
                guard let self else { return }
                root.navigation.openModelProviders(ModelProvidersNavTarget(serverId: server.id))
            }
        }

        let rangeIndex = UsageRange.allCases.firstIndex(of: model.range) ?? 0
        if rangeControl.selectedSegmentIndex != rangeIndex { rangeControl.selectedSegmentIndex = rangeIndex }

        let stats = model.stats
        message.isHidden = stats != nil
        if stats == nil {
            if model.isLoading {
                message.showLoading(colors: colors)
            } else {
                message.showFailure(model.error ?? String(localized: "Not connected to a server"), colors: colors)
            }
        }
        guard let stats else {
            [hero, chartSlot, detailSpinner, detailView, modelsSection, workspacesSection].forEach { $0.isHidden = true }
            return
        }

        hero.isHidden = false
        hero.configure(totals: stats.totals, daily: stats.daily, selected: model.metric, colors: colors)

        chartSlot.isHidden = false
        let chartKey = AnyHashable([
            AnyHashable(model.metric), AnyHashable(stats.daily.count), AnyHashable(stats.daily.first?.date ?? ""),
            AnyHashable(stats.daily.last?.date ?? ""), AnyHashable(stats.totals.tokens), AnyHashable(stats.totals.sessions),
            AnyHashable(stats.totals.cost), AnyHashable(themeKey),
        ])
        if renderedChart != chartKey {
            renderedChart = chartKey
            chartHost.show(
                UsageDailyChartLeaf(
                    daily: stats.daily,
                    metric: model.metric,
                    colors: chartColors,
                    onDaySelected: { [weak self] date in self?.model.selectDay(date) }
                ),
                in: chartSlot, parent: self, root: root
            )
        }

        if model.isLoadingDetail { detailSpinner.startAnimating() } else { detailSpinner.stopAnimating() }
        renderDetail(colors: colors, chartColors: chartColors)
        renderModels(colors: colors, chartColors: chartColors, themeKey: themeKey)
        renderWorkspaces(stats.workspaceBreakdown, colors: colors)
    }

    private func renderDetail(colors: UsageColors, chartColors: UsageChartColors) {
        guard let detail = model.detail else {
            detailView.isHidden = true
            // The next day opened draws its chart again, even on the same date.
            renderedHourly = nil
            return
        }
        detailView.isHidden = false
        let hourly = detail.hourlyCostValues
        detailView.configure(detail, hasHourlyChart: !hourly.isEmpty, colors: colors)
        guard !hourly.isEmpty else { return }
        let key = Self.hourlyChartKey(detail, hourly: hourly, themeKey: chartColors.themeKey)
        if renderedHourly != key {
            renderedHourly = key
            hourlyHost.show(UsageHourlyChartLeaf(entries: hourly, colors: chartColors), in: detailView.chartSlot, parent: self, root: root)
        }
    }

    /// What the hourly chart is drawn from: the day, each bar (hour, model, cost), the day's
    /// totals, and the theme, so a reload that changes spend in an hour already shown redraws it.
    static func hourlyChartKey(_ detail: DailyDetail, hourly: [StatsHourlyCost], themeKey: String) -> AnyHashable {
        let bars = hourly.map { "\($0.hour)|\($0.model)|\($0.cost)" }
        return AnyHashable([
            AnyHashable(detail.date), AnyHashable(bars), AnyHashable(detail.totals.cost),
            AnyHashable(detail.totals.sessions), AnyHashable(themeKey),
        ])
    }

    private func renderModels(colors: UsageColors, chartColors: UsageChartColors, themeKey: String) {
        let models = model.aggregatedModels
        modelsSection.isHidden = models.isEmpty
        guard !models.isEmpty else { return }
        modelsHeading.textColor = colors.fg
        let total = model.totalMetricValue
        donutSlot.isHidden = total <= 0
        if total > 0 {
            let key = AnyHashable([
                AnyHashable(model.metric), AnyHashable(models.map(\.aggregationKey)),
                AnyHashable(total), AnyHashable(themeKey),
            ])
            if renderedDonut != key {
                renderedDonut = key
                donutHost.show(
                    UsageModelDonutLeaf(models: models, metric: model.metric, colors: chartColors),
                    in: donutSlot, parent: self, root: root
                )
            }
        }
        renderDonutTotal(model.metric.formatted(total), visible: total > 0, colors: colors)
        donutSlot.accessibilityLabel = model.donutSummaryTitle
        donutSlot.accessibilityValue = model.donutSummary
        modelList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in model.visibleModels {
            let row = UsageModelRowView()
            row.configure(item: item, metric: model.metric, total: total, colors: colors)
            modelList.addArrangedSubview(row)
        }
        let hidden = model.hiddenModelCount
        modelsToggle.isHidden = hidden == 0
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
        configuration.baseForegroundColor = colors.blue
        configuration.title = model.showsAllModels ? String(localized: "Show less") : String(localized: "Show \(hidden) more")
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: .caption1)
            return outgoing
        }
        modelsToggle.configuration = configuration
    }

    /// The total sits in the ring at ordinary text sizes and under it from XXL up, where it
    /// would not fit the ring's 84 pt middle.
    private func renderDonutTotal(_ total: String, visible: Bool, colors: UsageColors) {
        let below = traitCollection.preferredContentSizeCategory >= .extraExtraLarge
        let text = NSMutableAttributedString(
            string: total,
            attributes: [.font: UIFont.scaled(.caption1, .semibold, monospacedDigits: true), .foregroundColor: colors.fg]
        )
        text.append(NSAttributedString(
            string: "\n" + String(localized: "total"),
            attributes: [.font: UIFont.preferredFont(forTextStyle: .caption2), .foregroundColor: colors.comment]
        ))
        for label in [donutTotalCenter, donutTotalBelow] {
            label.attributedText = text
            label.adjustsFontForContentSizeCategory = true
        }
        donutTotalCenter.isHidden = !visible || below
        donutTotalBelow.isHidden = !visible || !below
    }

    private func renderWorkspaces(_ workspaces: [StatsWorkspaceBreakdown], colors: UsageColors) {
        workspacesSection.isHidden = false
        workspacesHeading.textColor = colors.fg
        noWorkspaces.textColor = colors.comment
        noWorkspaces.isHidden = !workspaces.isEmpty
        workspaceList.isHidden = workspaces.isEmpty
        workspaceList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for workspace in workspaces {
            let row = UsageWorkspaceRowView()
            row.configure(workspace, colors: colors)
            workspaceList.addArrangedSubview(row)
        }
    }
}

private extension UIFont {
    func bold() -> UIFont {
        UIFont(descriptor: fontDescriptor.withSymbolicTraits(.traitBold) ?? fontDescriptor, size: 0)
    }
}
