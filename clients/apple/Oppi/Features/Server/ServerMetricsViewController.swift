import UIKit

/// Where the Server Metrics page loads from. The SwiftUI host passes a new one
/// when the pill switches hosts.
struct ServerMetricsSource {
    let serverId: String
    let client: @MainActor () async -> APIClient?
}

/// Server Metrics: the active host's CPU, memory, and disk and the Oppi server
/// process over a chosen range, read from the server's resource sampler.
/// Activity Monitor for a phone: a current value per card and its history.
@MainActor
final class ServerMetricsViewController: UIViewController {
    private var source: ServerMetricsSource
    private var themeID: ThemeID
    private var range: ServerMetricsRange = .day
    private var snapshot: ServerMetricsSnapshot?
    private var errorMessage: String?
    private var isTogglingSampling = false
    private var loadTask: Task<Void, Never>?
    private var refreshTimer: Timer?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let rangeControl = UISegmentedControl(items: ServerMetricsRange.allCases.map(\.label))
    private let statusView = ServerMetricsStatusView()
    private let hostHeader = ServerMetricsViewController.sectionHeader("Host")
    private let processHeader = ServerMetricsViewController.sectionHeader("Oppi Server")
    private let footerLabel = UILabel()

    private let hostCPUCard = ServerMetricCardView(identifier: "hostCpu", title: "CPU")
    private let hostMemoryCard = ServerMetricCardView(identifier: "hostMemory", title: "Memory")
    private let hostDiskCard = ServerMetricCardView(identifier: "hostDisk", title: "Disk")
    private let processCPUCard = ServerMetricCardView(identifier: "processCpu", title: "CPU")
    private let processMemoryCard = ServerMetricCardView(identifier: "processMemory", title: "Memory")
    private let eventLoopCard = ServerMetricCardView(identifier: "eventLoop", title: "Event Loop")
    private let activityCard = ServerMetricCardView(identifier: "activity", title: "Sessions")

    private var hostViews: [UIView] { [hostHeader, hostCPUCard, hostMemoryCard, hostDiskCard] }
    private var processViews: [UIView] {
        [processHeader, processCPUCard, processMemoryCard, eventLoopCard, activityCard, footerLabel]
    }

    init(source: ServerMetricsSource, themeID: ThemeID) {
        self.source = source
        self.themeID = themeID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        applyTheme()
        render()
        reload()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startAutoRefresh()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func setSource(_ newSource: ServerMetricsSource) {
        let switchedHost = newSource.serverId != source.serverId
        source = newSource
        guard switchedHost else { return }
        snapshot = nil
        errorMessage = nil
        // A Turn On still in flight belongs to the previous host.
        isTogglingSampling = false
        render()
        reload()
    }

    func applyThemeIfNeeded(_ newThemeID: ThemeID) {
        guard newThemeID != themeID else { return }
        themeID = newThemeID
        applyTheme()
        render()
    }

    // MARK: - Layout

    private static func sectionHeader(_ title: String) -> UILabel {
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.accessibilityTraits = .header
        return label
    }

    private func buildLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.reload(endingRefresh: true) }, for: .valueChanged)
        scrollView.refreshControl = refresh
        view.addSubview(scrollView)

        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        rangeControl.selectedSegmentIndex = ServerMetricsRange.allCases.firstIndex(of: range) ?? 0
        rangeControl.accessibilityIdentifier = "server.metrics.range"
        rangeControl.addAction(UIAction { [weak self] _ in self?.rangeChanged() }, for: .valueChanged)

        statusView.onTurnOn = { [weak self] in self?.setSampling(true) }
        statusView.onRetry = { [weak self] in self?.reload() }

        footerLabel.font = .preferredFont(forTextStyle: .caption2)
        footerLabel.adjustsFontForContentSizeCategory = true
        footerLabel.numberOfLines = 0
        footerLabel.textAlignment = .center

        for view in [rangeControl, statusView] + hostViews + processViews {
            stack.addArrangedSubview(view)
        }
        stack.setCustomSpacing(20, after: rangeControl)
        stack.setCustomSpacing(20, after: hostDiskCard)
        stack.setCustomSpacing(16, after: activityCard)

        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        let fullWidth = stack.widthAnchor.constraint(equalTo: frame.widthAnchor, constant: -32)
        fullWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: frame.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            fullWidth,
        ])
    }

    private func applyTheme() {
        let palette = themeID.palette
        view.backgroundColor = UIColor(palette.bg)
        for header in [hostHeader, processHeader] {
            header.textColor = UIColor(palette.fg)
        }
        footerLabel.textColor = UIColor(palette.comment)
        statusView.apply(palette)
        for card in [hostCPUCard, hostMemoryCard, hostDiskCard, processCPUCard, processMemoryCard, eventLoopCard, activityCard] {
            card.apply(palette)
        }
    }

    // MARK: - Loading

    private func rangeChanged() {
        let index = rangeControl.selectedSegmentIndex
        guard ServerMetricsRange.allCases.indices.contains(index) else { return }
        range = ServerMetricsRange.allCases[index]
        // The old range's series must not sit under the new range's axis, and a
        // failed load for the new range must show its error.
        snapshot = nil
        errorMessage = nil
        render()
        reload()
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        // The sampler writes every ~30s; refreshing faster shows nothing new.
        // 7d and 30d re-read up to a month of samples, so they refresh on pull.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.range.refreshesLive else { return }
                self.reload()
            }
        }
    }

    private func reload(endingRefresh: Bool = false) {
        loadTask?.cancel()
        let source = source
        let range = range
        loadTask = Task { [weak self] in
            defer {
                if endingRefresh { self?.scrollView.refreshControl?.endRefreshing() }
            }
            guard let client = await source.client() else {
                self?.finishLoad(serverId: source.serverId, range: range, result: .failure(ServerMetricsLoadError.notConnected))
                return
            }
            do {
                let result = try await client.fetchServerMetrics(range: range)
                self?.finishLoad(serverId: source.serverId, range: range, result: .success(result))
            } catch is CancellationError {
                return
            } catch {
                self?.finishLoad(serverId: source.serverId, range: range, result: .failure(error))
            }
        }
    }

    private func finishLoad(serverId: String, range: ServerMetricsRange, result: Result<ServerMetricsSnapshot, Error>) {
        // A slow answer for a host or range the page has left is stale.
        guard serverId == source.serverId, range == self.range, !Task.isCancelled else { return }
        switch result {
        case .success(let value):
            snapshot = value
            errorMessage = nil
        case .failure(let error):
            if (error as? URLError)?.code == .cancelled { return }
            errorMessage = error.localizedDescription
        }
        render()
    }

    private func setSampling(_ enabled: Bool) {
        guard !isTogglingSampling else { return }
        isTogglingSampling = true
        render()
        let source = source
        Task { [weak self] in
            var failure: Error?
            do {
                guard let client = await source.client() else { throw ServerMetricsLoadError.notConnected }
                try await client.setServerMetricsEnabled(enabled)
            } catch {
                failure = error
            }
            // The pill moved to another host meanwhile; this answer is not its.
            guard let self, self.source.serverId == source.serverId else { return }
            self.isTogglingSampling = false
            if let failure {
                self.errorMessage = failure.localizedDescription
                self.render()
            } else {
                self.reload()
            }
        }
    }

    // MARK: - Rendering

    private func render() {
        guard isViewLoaded else { return }
        let palette = themeID.palette
        let status: ServerMetricsStatusView.State?
        if let snapshot, !snapshot.enabled {
            status = .off(isTurningOn: isTogglingSampling, error: errorMessage)
        } else if snapshot == nil, let errorMessage {
            status = .failed(errorMessage)
        } else if snapshot == nil {
            status = .loading
        } else {
            status = nil
        }
        statusView.isHidden = status == nil
        if let status { statusView.show(status) }

        guard let snapshot, snapshot.enabled else {
            (hostViews + processViews).forEach { $0.isHidden = true }
            return
        }
        let model = ServerMetricsPageModel(snapshot: snapshot, range: range, now: Date())
        hostViews.forEach { $0.isHidden = !model.hasHostData }
        processViews.forEach { $0.isHidden = false }
        hostHeader.text = model.hostTitle

        hostCPUCard.configure(model.hostCPU(palette: palette))
        hostMemoryCard.configure(model.hostMemory(palette: palette))
        hostDiskCard.configure(model.hostDisk(palette: palette))
        processCPUCard.configure(model.processCPU(palette: palette))
        processMemoryCard.configure(model.processMemory(palette: palette))
        eventLoopCard.configure(model.eventLoop(palette: palette))
        activityCard.configure(model.activity(palette: palette))
        footerLabel.text = model.footer
    }
}

private enum ServerMetricsLoadError: LocalizedError {
    case notConnected

    var errorDescription: String? { "Not connected to this server" }
}

// MARK: - Page model

/// Card contents from one snapshot. Pure, so the arithmetic is testable.
struct ServerMetricsPageModel {
    let snapshot: ServerMetricsSnapshot
    let range: ServerMetricsRange
    let now: Date

    private var latest: ServerResourceSample? { snapshot.latest }
    private var history: ServerMetricsHistory? { snapshot.history }

    var hasHostData: Bool {
        if latest?.host != nil { return true }
        return history?.series(.hostCpu)?.avg.contains { $0 != nil } == true
    }

    private var isContainer: Bool { latest?.host?.scope == .container }

    /// A container's CPU and memory are its own cgroup's, against its limits.
    var hostTitle: String { isContainer ? "Container" : "Host" }

    private func avg(_ key: ServerMetricSeries) -> [Double?] {
        history?.series(key)?.avg ?? []
    }

    private func max(_ key: ServerMetricSeries) -> [Double?] {
        history?.series(key)?.max ?? []
    }

    /// Highest single sample in the range, for the "peak" readout.
    private func peak(_ key: ServerMetricSeries) -> Double? {
        max(key).compactMap { $0 }.max()
    }

    /// Highest plotted bucket average. Charts scale to this, not to `peak`:
    /// one 11-second event-loop stall would otherwise flatten the whole line.
    private func plottedTop(_ key: ServerMetricSeries) -> Double? {
        avg(key).compactMap { $0 }.max()
    }

    private func chart(
        _ lines: [ServerMetricChartView.Line],
        yMax: Double,
        yLabel: String,
        format: @escaping (Double) -> String
    ) -> ServerMetricChartView.Content {
        ServerMetricChartView.Content(
            lines: lines,
            yMax: Swift.max(yMax, 0.0001),
            yLabel: yLabel,
            startLabel: range.startLabel,
            timestamps: history?.ts ?? [],
            range: range,
            format: format
        )
    }

    func hostCPU(palette: ThemePalette) -> ServerMetricCardView.Content {
        let host = latest?.host
        var detail: [String] = []
        if let cores = host?.cpuCores {
            let count = ServerMetricsFormat.cores(cores)
            detail.append(host?.cpuLimited == true ? "\(count) limit" : count)
        }
        if let load = host?.load1 { detail.append("load \(ServerMetricsFormat.decimal(load))") }
        if let peak = peak(.hostCpu) { detail.append("peak \(ServerMetricsFormat.percent(peak))") }
        return ServerMetricCardView.Content(
            value: host?.cpu.map(ServerMetricsFormat.percent) ?? "—",
            detail: detail.joined(separator: " · "),
            chart: chart(
                [.init(values: avg(.hostCpu), color: UIColor(palette.blue), filled: true)],
                yMax: 100,
                yLabel: "100%",
                format: ServerMetricsFormat.percent
            )
        )
    }

    func hostMemory(palette: ThemePalette) -> ServerMetricCardView.Content {
        let host = latest?.host
        let total = host?.memTotal
        var value = "—"
        var detail = "Collecting…"
        if let used = host?.memUsed, let total, total > 0 {
            value = "\(ServerMetricsFormat.megabytes(used)) of \(ServerMetricsFormat.megabytes(total))"
            detail = "\(ServerMetricsFormat.percent(used / total * 100)) used"
                + (host?.memLimited == true ? " of the container limit" : "")
                + (isContainer ? " · excluding file cache" : "")
        }
        return ServerMetricCardView.Content(
            value: value,
            detail: detail,
            chart: chart(
                [.init(values: avg(.memUsed), color: UIColor(palette.purple), filled: true)],
                yMax: total ?? plottedTop(.memUsed) ?? 1,
                yLabel: total.map(ServerMetricsFormat.megabytes) ?? "",
                format: ServerMetricsFormat.megabytes
            )
        )
    }

    func hostDisk(palette: ThemePalette) -> ServerMetricCardView.Content {
        let host = latest?.host
        let total = host?.diskTotal
        var value = "—"
        var detail = "Volume holding the Oppi data directory"
        if let used = host?.diskUsed, let total, total > 0 {
            value = "\(ServerMetricsFormat.megabytes(used)) of \(ServerMetricsFormat.megabytes(total))"
            detail = "\(ServerMetricsFormat.megabytes(total - used)) free · data directory volume"
        }
        return ServerMetricCardView.Content(
            value: value,
            detail: detail,
            chart: chart(
                [.init(values: avg(.diskUsed), color: UIColor(palette.orange), filled: true)],
                yMax: total ?? plottedTop(.diskUsed) ?? 1,
                yLabel: total.map(ServerMetricsFormat.megabytes) ?? "",
                format: ServerMetricsFormat.megabytes
            )
        )
    }

    func processCPU(palette: ThemePalette) -> ServerMetricCardView.Content {
        // One busy core is 100%; a multi-threaded spike can pass it.
        let yMax = Swift.max(100, plottedTop(.cpu) ?? 0)
        var detail = "Share of one core"
        if let peak = peak(.cpu) { detail += " · peak \(ServerMetricsFormat.percent(peak))" }
        return ServerMetricCardView.Content(
            value: latest.map { ServerMetricsFormat.percent($0.cpu.total) } ?? "—",
            detail: detail,
            chart: chart(
                [.init(values: avg(.cpu), color: UIColor(palette.green), filled: true)],
                yMax: yMax,
                yLabel: ServerMetricsFormat.percent(yMax),
                format: ServerMetricsFormat.percent
            )
        )
    }

    func processMemory(palette: ThemePalette) -> ServerMetricCardView.Content {
        let yMax = (plottedTop(.rss) ?? latest?.memory.rss ?? 1) * 1.15
        var detail = "Collecting…"
        if let memory = latest?.memory {
            detail = "Heap \(ServerMetricsFormat.megabytes(memory.heapUsed)) of \(ServerMetricsFormat.megabytes(memory.heapTotal))"
        }
        return ServerMetricCardView.Content(
            value: latest.map { "\(ServerMetricsFormat.megabytes($0.memory.rss)) RSS" } ?? "—",
            detail: detail,
            chart: chart(
                [
                    .init(values: avg(.rss), color: UIColor(palette.cyan), filled: true),
                    .init(
                        values: avg(.heapUsed),
                        color: UIColor(palette.comment),
                        filled: false,
                        readout: { "\(ServerMetricsFormat.megabytes($0)) heap" }
                    ),
                ],
                yMax: yMax,
                yLabel: ServerMetricsFormat.megabytes(yMax),
                format: ServerMetricsFormat.megabytes
            )
        )
    }

    func eventLoop(palette: ThemePalette) -> ServerMetricCardView.Content {
        let yMax = Swift.max(50, (plottedTop(.eventLoopP99) ?? 0) * 1.15)
        var detail = "p99 delay"
        if let loop = latest?.eventLoop { detail += " · max \(ServerMetricsFormat.milliseconds(loop.max)) last sample" }
        return ServerMetricCardView.Content(
            value: latest.map { ServerMetricsFormat.milliseconds($0.eventLoop.p99) } ?? "—",
            detail: detail,
            chart: chart(
                [.init(values: avg(.eventLoopP99), color: UIColor(palette.yellow), filled: true)],
                yMax: yMax,
                yLabel: ServerMetricsFormat.milliseconds(yMax),
                format: ServerMetricsFormat.milliseconds
            )
        )
    }

    func activity(palette: ThemePalette) -> ServerMetricCardView.Content {
        // Both lines share the axis, so it fits whichever peaks higher.
        let yMax = Swift.max(4, (peak(.sessions) ?? 0) + 1, (peak(.wsConnections) ?? 0) + 1)
        var value = "—"
        if let sessions = latest?.sessions {
            value = "\(sessions.total) active · \(sessions.busy) busy"
        }
        let uptime = ServerMetricsFormat.duration(now.timeIntervalSince1970 - snapshot.serverStartedAt / 1000)
        var detail = ["up \(uptime)", ServerMetricsFormat.platform(snapshot.platform, arch: snapshot.arch)]
        if let ws = latest?.wsConnections { detail.insert("\(ws) connections", at: 0) }
        return ServerMetricCardView.Content(
            value: value,
            detail: detail.joined(separator: " · "),
            chart: chart(
                [
                    .init(values: max(.sessions), color: UIColor(palette.red), filled: true),
                    .init(
                        values: max(.wsConnections),
                        color: UIColor(palette.comment),
                        filled: false,
                        readout: { "\(Int($0.rounded())) connections" }
                    ),
                ],
                yMax: yMax,
                yLabel: "\(Int(yMax))",
                format: { "\(Int($0.rounded())) sessions" }
            )
        )
    }

    var footer: String {
        let interval = Int((snapshot.intervalMs / 1000).rounded())
        return "Sampled every \(interval)s and kept 30 days on the server. Turn sampling off in Server Settings."
    }
}

enum ServerMetricsFormat {
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    static func cores(_ value: Double) -> String {
        let whole = value.rounded() == value
        let number = whole ? "\(Int(value))" : String(format: "%.1f", value)
        return value == 1 ? "1 core" : "\(number) cores"
    }

    static func decimal(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func milliseconds(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f ms", value) : "\(Int(value.rounded())) ms"
    }

    /// Server values are MB (1024²). Shown as MB, GB, or TB.
    static func megabytes(_ value: Double) -> String {
        if value >= 1024 * 1024 { return String(format: "%.1f TB", value / 1024 / 1024) }
        if value >= 1024 {
            let gb = value / 1024
            return gb >= 100 ? "\(Int(gb.rounded())) GB" : String(format: "%.1f GB", gb)
        }
        return "\(Int(value.rounded())) MB"
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int(Swift.max(0, seconds) / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    static func platform(_ platform: String, arch: String) -> String {
        let name = switch platform {
        case "darwin": "macOS"
        case "linux": "Linux"
        case "win32": "Windows"
        default: platform
        }
        return "\(name) \(arch)"
    }

    /// A bucket's time for the scrub readout, as precise as its range.
    static func bucketTime(_ ms: Double, range: ServerMetricsRange) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        switch range {
        case .hour, .day:
            return date.formatted(date: .omitted, time: .shortened)
        case .week, .month:
            return date.formatted(.dateTime.month(.abbreviated).day().hour())
        }
    }
}

// MARK: - Status card

/// Loading, failure, and sampling-off states above the cards.
final class ServerMetricsStatusView: UIView {
    enum State: Equatable {
        case loading
        case failed(String)
        case off(isTurningOn: Bool, error: String?)
    }

    var onTurnOn: (() -> Void)?
    var onRetry: (() -> Void)?

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let button = UIButton(configuration: .borderedProminent())
    private var state: State = .loading

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        button.addAction(UIAction { [weak self] _ in self?.buttonTapped() }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [spinner, titleLabel, messageLabel, button])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    func apply(_ palette: ThemePalette) {
        backgroundColor = UIColor(palette.bgHighlight)
        titleLabel.textColor = UIColor(palette.fg)
        messageLabel.textColor = UIColor(palette.comment)
        spinner.color = UIColor(palette.comment)
    }

    func show(_ newState: State) {
        state = newState
        switch newState {
        case .loading:
            spinner.startAnimating()
            spinner.isHidden = false
            titleLabel.isHidden = true
            messageLabel.isHidden = true
            button.isHidden = true
        case .failed(let message):
            spinner.stopAnimating()
            spinner.isHidden = true
            titleLabel.isHidden = false
            titleLabel.text = "Unable to load server metrics"
            messageLabel.isHidden = false
            messageLabel.text = message
            button.isHidden = false
            button.configuration?.title = "Try Again"
            button.configuration?.showsActivityIndicator = false
            button.isEnabled = true
            button.accessibilityIdentifier = "server.metrics.retry"
        case .off(let isTurningOn, let error):
            spinner.stopAnimating()
            spinner.isHidden = true
            titleLabel.isHidden = false
            titleLabel.text = "Server metrics are off"
            messageLabel.isHidden = false
            messageLabel.text = error
                ?? "Turn on to sample this server's CPU, memory, and disk every 30 seconds. Samples stay on the server."
            button.isHidden = false
            button.configuration?.title = "Turn On"
            button.configuration?.showsActivityIndicator = isTurningOn
            button.isEnabled = !isTurningOn
            button.accessibilityIdentifier = "server.metrics.turnOn"
        }
    }

    private func buttonTapped() {
        switch state {
        case .loading: break
        case .failed: onRetry?()
        case .off: onTurnOn?()
        }
    }
}

// MARK: - Metric card

/// One metric: title, current value, detail line, and its history chart.
/// Press and drag on the chart to read a past value.
final class ServerMetricCardView: UIView {
    struct Content {
        let value: String
        let detail: String
        let chart: ServerMetricChartView.Content
    }

    private let titleText: String
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let detailLabel = UILabel()
    private let chartView = ServerMetricChartView()
    private let startLabel = UILabel()
    private let endLabel = UILabel()
    private var content: Content?

    init(identifier: String, title: String) {
        titleText = title
        super.init(frame: .zero)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityIdentifier = "server.metrics.card.\(identifier)"

        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .caption1)
        valueLabel.font = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .title3).pointSize,
            weight: .semibold
        )
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.7
        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.numberOfLines = 0
        for label in [startLabel, endLabel] {
            label.font = .preferredFont(forTextStyle: .caption2)
        }
        endLabel.text = "now"
        endLabel.textAlignment = .right

        chartView.onScrub = { [weak self] index in self?.scrubbed(to: index) }

        let axis = UIStackView(arrangedSubviews: [startLabel, endLabel])
        axis.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [titleLabel, valueLabel, detailLabel, chartView, axis])
        stack.axis = .vertical
        stack.spacing = 4
        stack.setCustomSpacing(10, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            chartView.heightAnchor.constraint(equalToConstant: 88),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    func apply(_ palette: ThemePalette) {
        backgroundColor = UIColor(palette.bgHighlight)
        titleLabel.textColor = UIColor(palette.comment)
        valueLabel.textColor = UIColor(palette.fg)
        detailLabel.textColor = UIColor(palette.comment)
        startLabel.textColor = UIColor(palette.comment)
        endLabel.textColor = UIColor(palette.comment)
        chartView.apply(palette)
    }

    func configure(_ newContent: Content) {
        content = newContent
        valueLabel.text = newContent.value
        detailLabel.text = newContent.detail
        startLabel.text = newContent.chart.startLabel
        chartView.content = newContent.chart
        accessibilityValue = "\(newContent.value), \(newContent.detail)"
    }

    private func scrubbed(to index: Int?) {
        guard let content else { return }
        guard let index, let readout = content.chart.readout(at: index) else {
            valueLabel.text = content.value
            detailLabel.text = content.detail
            return
        }
        valueLabel.text = readout.value
        detailLabel.text = readout.time
    }
}

// MARK: - Chart

/// Line/area chart over evenly spaced buckets. Nil values are gaps (server
/// down or sampling off), drawn as breaks rather than interpolated.
final class ServerMetricChartView: UIView {
    struct Line {
        let values: [Double?]
        let color: UIColor
        let filled: Bool
        /// A second line's scrub readout, named so it is not read as the first.
        var readout: ((Double) -> String)?
    }

    struct Content {
        let lines: [Line]
        let yMax: Double
        let yLabel: String
        let startLabel: String
        let timestamps: [Double]
        let range: ServerMetricsRange
        let format: (Double) -> String

        /// The first line's value at a bucket, then any named second line's.
        func readout(at index: Int) -> (value: String, time: String)? {
            guard timestamps.indices.contains(index) else { return nil }
            let time = ServerMetricsFormat.bucketTime(timestamps[index], range: range)
            guard let first = lines.first, first.values.indices.contains(index),
                  let value = first.values[index] else {
                return ("—", "\(time) · no samples")
            }
            let others = lines.dropFirst().compactMap { line -> String? in
                guard let readout = line.readout, line.values.indices.contains(index),
                      let other = line.values[index] else { return nil }
                return readout(other)
            }
            return (([format(value)] + others).joined(separator: ", "), time)
        }
    }

    var content: Content? {
        didSet { setNeedsDisplay() }
    }

    var onScrub: ((Int?) -> Void)?

    private var gridColor = UIColor.separator
    private var labelColor = UIColor.secondaryLabel
    private var scrubIndex: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0.15
        addGestureRecognizer(press)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    func apply(_ palette: ThemePalette) {
        gridColor = UIColor(palette.comment).withAlphaComponent(0.25)
        labelColor = UIColor(palette.comment)
        setNeedsDisplay()
    }

    private var bucketCount: Int {
        content?.lines.map(\.values.count).max() ?? 0
    }

    private func x(for index: Int, count: Int, in rect: CGRect) -> CGFloat {
        guard count > 1 else { return rect.midX }
        return rect.minX + rect.width * CGFloat(index) / CGFloat(count - 1)
    }

    @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
        let count = bucketCount
        switch gesture.state {
        case .began, .changed:
            guard count > 0 else { return }
            let fraction = Swift.min(Swift.max(gesture.location(in: self).x / Swift.max(bounds.width, 1), 0), 1)
            let index = Int((fraction * CGFloat(count - 1)).rounded())
            guard index != scrubIndex else { return }
            if scrubIndex == nil { UISelectionFeedbackGenerator().selectionChanged() }
            scrubIndex = index
            onScrub?(index)
            setNeedsDisplay()
        default:
            scrubIndex = nil
            onScrub?(nil)
            setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let content, let context = UIGraphicsGetCurrentContext() else { return }
        // The scale label sits above the plot so a line near the top never runs under it.
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .caption2),
            .foregroundColor: labelColor,
        ]
        let labelText = content.yLabel as NSString
        let labelSize = content.yLabel.isEmpty ? .zero : labelText.size(withAttributes: labelAttributes)
        let labelHeight = ceil(labelSize.height)
        let plot = CGRect(
            x: bounds.minX,
            y: bounds.minY + labelHeight + 2,
            width: bounds.width,
            height: Swift.max(bounds.height - labelHeight - 3, 1)
        )

        context.setLineWidth(1 / Swift.max(traitCollection.displayScale, 1))
        gridColor.setStroke()
        for fraction in [0.0, 0.5, 1.0] {
            let y = plot.maxY - plot.height * fraction
            context.move(to: CGPoint(x: plot.minX, y: y))
            context.addLine(to: CGPoint(x: plot.maxX, y: y))
        }
        context.strokePath()

        if !content.yLabel.isEmpty {
            labelText.draw(at: CGPoint(x: plot.maxX - labelSize.width, y: bounds.minY), withAttributes: labelAttributes)
        }

        for line in content.lines.reversed() {
            draw(line, yMax: content.yMax, in: plot)
        }

        if let scrubIndex {
            let x = x(for: scrubIndex, count: bucketCount, in: plot)
            labelColor.setStroke()
            let path = UIBezierPath()
            path.move(to: CGPoint(x: x, y: plot.minY))
            path.addLine(to: CGPoint(x: x, y: plot.maxY))
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func draw(_ line: Line, yMax: Double, in plot: CGRect) {
        let count = line.values.count
        guard count > 0 else { return }
        func point(_ index: Int, _ value: Double) -> CGPoint {
            let fraction = Swift.min(Swift.max(value / yMax, 0), 1)
            return CGPoint(x: x(for: index, count: count, in: plot), y: plot.maxY - plot.height * fraction)
        }

        var segments: [[CGPoint]] = []
        var current: [CGPoint] = []
        for (index, value) in line.values.enumerated() {
            if let value {
                current.append(point(index, value))
            } else if !current.isEmpty {
                segments.append(current)
                current = []
            }
        }
        if !current.isEmpty { segments.append(current) }

        for segment in segments {
            guard let first = segment.first, let last = segment.last else { continue }
            if segment.count == 1 {
                line.color.setFill()
                UIBezierPath(ovalIn: CGRect(x: first.x - 1.5, y: first.y - 1.5, width: 3, height: 3)).fill()
                continue
            }
            let stroke = UIBezierPath()
            stroke.move(to: first)
            segment.dropFirst().forEach { stroke.addLine(to: $0) }
            if line.filled {
                let area = UIBezierPath(cgPath: stroke.cgPath)
                area.addLine(to: CGPoint(x: last.x, y: plot.maxY))
                area.addLine(to: CGPoint(x: first.x, y: plot.maxY))
                area.close()
                line.color.withAlphaComponent(0.18).setFill()
                area.fill()
            }
            line.color.setStroke()
            stroke.lineWidth = 1.5
            stroke.lineJoinStyle = .round
            stroke.stroke()
        }
    }
}
