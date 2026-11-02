import UIKit

// The UIKit pieces of Usage: the hero totals, the model and workspace lists, a day's
// detail, and the provider glyph. Every one is configured with a palette by
// `UsageViewController`; the charts between them are SwiftUI leaves (`UsageCharts.swift`).

/// The theme colors Usage's views draw with.
struct UsageColors {
    let bg: UIColor
    let highlight: UIColor
    let fg: UIColor
    let comment: UIColor
    let blue: UIColor
    let green: UIColor
    let orange: UIColor
    let palette: ThemePalette

    init(palette: ThemePalette) {
        self.palette = palette
        bg = palette.ui.bg
        highlight = palette.ui.bgHighlight
        fg = palette.ui.fg
        comment = palette.ui.comment
        blue = palette.ui.blue
        green = palette.ui.green
        orange = palette.ui.orange
    }
}

// MARK: - Section heading

enum UsageText {
    static func heading(_ text: String, colors: UsageColors) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textColor = colors.fg
        label.accessibilityTraits = .header
        return label
    }

    static func caption(_ text: String, colors: UsageColors, style: UIFont.TextStyle = .caption1) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textColor = colors.comment
        return label
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: 0)
    }
}

// MARK: - Hero

/// Sessions, Cost, and Tokens totals for the range, each with its trend. A box is a
/// button that makes its metric the one the chart and the model list show.
final class UsageHeroView: UIView {
    private let stack = UIStackView()
    private var boxes: [StatsMetric: UsageMetricBox] = [:]
    private var usesAccessibilityLayout: Bool?
    var onSelect: ((StatsMetric) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for metric in StatsMetric.allCases {
            let box = UsageMetricBox(metric: metric)
            box.addAction(UIAction { [weak self] _ in self?.onSelect?(metric) }, for: .touchUpInside)
            boxes[metric] = box
        }
        // Sessions, Cost, Tokens, in the order the totals read.
        for metric in [StatsMetric.sessions, .cost, .tokens] {
            if let box = boxes[metric] { stack.addArrangedSubview(box) }
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: Self, _) in
            view.updateAxis()
        }
        updateAxis()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Side by side at normal sizes, stacked at accessibility sizes where three totals
    /// would not fit on a line.
    private func updateAxis() {
        let accessibility = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        guard accessibility != usesAccessibilityLayout else { return }
        usesAccessibilityLayout = accessibility
        stack.axis = accessibility ? .vertical : .horizontal
        invalidateIntrinsicContentSize()
    }

    func configure(totals: StatsTotals, daily: [StatsDailyEntry], selected: StatsMetric, colors: UsageColors) {
        backgroundColor = colors.highlight
        boxes[.sessions]?.configure(
            value: "\(totals.sessions)",
            trend: UsageTrend.make(values: daily.map { Double($0.sessions) }),
            isCost: false, isSelected: selected == .sessions, colors: colors
        )
        boxes[.cost]?.configure(
            value: SessionFormatting.costString(totals.cost),
            trend: UsageTrend.make(values: daily.map(\.cost)),
            isCost: true, isSelected: selected == .cost, colors: colors
        )
        boxes[.tokens]?.configure(
            value: totals.tokens.formattedTokenCount(),
            trend: UsageTrend.make(values: daily.map { Double($0.tokens) }),
            isCost: false, isSelected: selected == .tokens, colors: colors
        )
    }
}

private final class UsageMetricBox: UIControl {
    let metric: StatsMetric
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let trendLabel = UILabel()
    private let marker = UIView()

    init(metric: StatsMetric) {
        self.metric = metric
        super.init(frame: .zero)
        let stack = UIStackView(arrangedSubviews: [titleLabel, valueLabel, trendLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 4
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        marker.layer.cornerRadius = 1
        marker.translatesAutoresizingMaskIntoConstraints = false
        marker.isUserInteractionEnabled = false
        addSubview(marker)
        titleLabel.font = .preferredFont(forTextStyle: .caption1)
        valueLabel.font = UIFont.scaled(.title3, .semibold, monospacedDigits: true)
        trendLabel.font = .preferredFont(forTextStyle: .caption2)
        for label in [titleLabel, valueLabel, trendLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.textAlignment = .center
            label.numberOfLines = 0
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.bottomAnchor.constraint(equalTo: marker.topAnchor, constant: -6),
            marker.widthAnchor.constraint(equalToConstant: 32),
            marker.heightAnchor.constraint(equalToConstant: 2),
            marker.centerXAnchor.constraint(equalTo: centerXAnchor),
            marker.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        accessibilityIdentifier = "server.usage.metric.\(metric.rawValue)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(value: String, trend: UsageTrend?, isCost: Bool, isSelected: Bool, colors: UsageColors) {
        titleLabel.text = metric.title
        titleLabel.textColor = colors.comment
        valueLabel.text = value
        valueLabel.textColor = colors.fg
        marker.backgroundColor = colors.blue
        marker.isHidden = !isSelected
        var trendWords: String?
        if let trend {
            let tint = isCost ? (trend.isRising ? colors.orange : colors.green) : colors.comment
            let text = NSMutableAttributedString(attachment: NSTextAttachment(
                image: UIImage(systemName: trend.isRising ? "arrow.up.right" : "arrow.down.right")?
                    .withTintColor(tint, renderingMode: .alwaysOriginal) ?? UIImage()
            ))
            text.append(NSAttributedString(string: " " + trend.label))
            text.addAttributes([.foregroundColor: tint], range: NSRange(location: 0, length: text.length))
            trendLabel.attributedText = text
            trendLabel.isHidden = false
            trendWords = trend.isRising
                ? String(localized: "up \(trend.label)")
                : String(localized: "down \(trend.label)")
        } else {
            trendLabel.attributedText = nil
            trendLabel.isHidden = true
        }
        isAccessibilityElement = true
        accessibilityLabel = metric.title
        accessibilityValue = [value, trendWords].compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = isSelected ? [.button, .selected] : .button
    }
}

// MARK: - Provider glyph

/// A provider's mark in its brand color: the logo, or its monogram when it has
/// none. `EntityIcon` draws it, the same mark the model pills and rows show.
final class UsageProviderGlyphView: UIView {
    private let imageView = UIImageView()
    private let side: CGFloat

    init(side: CGFloat) {
        self.side = side
        super.init(frame: .zero)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
        ])
        isAccessibilityElement = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(provider: String?) {
        guard let provider = provider.flatMap({ $0.isEmpty ? nil : $0 }) else {
            imageView.image = nil
            return
        }
        imageView.image = EntityIcon.image(.provider(provider), size: side)
    }
}

// MARK: - Model rows

/// A bar showing a share of a whole: a track with the filled part over it.
final class UsageShareBar: UIView {
    private let fill = UIView()
    private var share: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(fill)
        layer.cornerRadius = 2.5
        fill.layer.cornerRadius = 2.5
        heightAnchor.constraint(equalToConstant: 5).isActive = true
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(share: Double, color: UIColor, track: UIColor) {
        self.share = CGFloat(max(0, min(1, share)))
        backgroundColor = track
        fill.backgroundColor = color
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fill.frame = CGRect(x: 0, y: 0, width: max(2, bounds.width * share), height: bounds.height)
    }
}

/// One model in the breakdown: its name and provider, its value and share, a bar, and
/// its prompt-cache line. One accessibility element that reads all of it.
final class UsageModelRowView: UIView {
    private let glyph = UsageProviderGlyphView(side: 14)
    private let nameLabel = UILabel()
    private let providerLabel = UILabel()
    private let valueLabel = UILabel()
    private let shareLabel = UILabel()
    private let bar = UsageShareBar()
    private let cacheLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let names = UIStackView(arrangedSubviews: [nameLabel, providerLabel])
        names.axis = .vertical
        names.spacing = 1
        let top = UIStackView(arrangedSubviews: [glyph, names, valueLabel, shareLabel])
        top.axis = .horizontal
        top.alignment = .firstBaseline
        top.spacing = 8
        let stack = UIStackView(arrangedSubviews: [top, bar, cacheLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        nameLabel.font = .preferredFont(forTextStyle: .caption1)
        providerLabel.font = .preferredFont(forTextStyle: .caption2)
        valueLabel.font = UIFont.scaled(.caption1, monospacedDigits: true)
        shareLabel.font = .preferredFont(forTextStyle: .caption1)
        cacheLabel.font = .preferredFont(forTextStyle: .caption2)
        for label in [nameLabel, providerLabel, valueLabel, shareLabel, cacheLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [valueLabel, shareLabel] {
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.textAlignment = .right
        }
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(item: AggregatedStatsModel, metric: StatsMetric, total: Double, colors: UsageColors) {
        let accent = modelColor(item.representativeModel)
        let share = total > 0 ? max(0, item.value(for: metric) / total) : 0
        let value = metric.formatted(item.value(for: metric))
        let percent = "\(Int((share * 100).rounded()))%"
        glyph.configure(provider: item.provider)
        nameLabel.text = item.displayName
        nameLabel.textColor = accent
        providerLabel.text = item.providerDisplayName
        providerLabel.textColor = colors.comment
        providerLabel.isHidden = item.providerDisplayName == nil
        valueLabel.text = value
        valueLabel.textColor = colors.comment
        shareLabel.text = percent
        shareLabel.textColor = colors.comment
        bar.configure(share: share, color: accent.withAlphaComponent(0.55), track: colors.comment.withAlphaComponent(0.12))

        var cacheWords: String?
        if item.cacheRead > 0 || (item.cacheWrite ?? 0) > 0 {
            let line = NSMutableAttributedString()
            func append(_ text: String, _ color: UIColor) {
                if line.length > 0 { line.append(NSAttributedString(string: "  ")) }
                line.append(NSAttributedString(string: text, attributes: [.foregroundColor: color]))
            }
            if let rate = item.cacheRate { append("cache \(Int((rate * 100).rounded()))%", colors.green) }
            append("R: \(item.cacheRead.formattedTokenCount())", colors.comment)
            append(formatModelCacheWriteLabel(item.cacheWrite), colors.comment)
            cacheLabel.attributedText = line
            cacheLabel.isHidden = false
            cacheWords = line.string
        } else {
            cacheLabel.attributedText = nil
            cacheLabel.isHidden = true
        }
        accessibilityIdentifier = "server.usage.model.\(item.aggregationKey)"
        accessibilityLabel = [item.displayName, item.providerDisplayName].compactMap { $0 }.joined(separator: ", ")
        accessibilityValue = [value, percent, cacheWords].compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: - Workspace rows

/// One workspace in the breakdown: its name, its sessions, and its cost.
final class UsageWorkspaceRowView: UIView {
    private let icon = UIImageView(image: UIImage(systemName: "folder.fill"))
    private let nameLabel = UILabel()
    private let sessionsLabel = UILabel()
    private let costLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [icon, nameLabel, sessionsLabel, costLabel])
        stack.axis = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        nameLabel.font = .preferredFont(forTextStyle: .caption1)
        sessionsLabel.font = UIFont.scaled(.caption1, monospacedDigits: true)
        costLabel.font = UIFont.scaled(.caption1, monospacedDigits: true)
        for label in [nameLabel, sessionsLabel, costLabel] {
            label.adjustsFontForContentSizeCategory = true
        }
        nameLabel.numberOfLines = 0
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [sessionsLabel, costLabel] {
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.textAlignment = .right
        }
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ workspace: StatsWorkspaceBreakdown, colors: UsageColors) {
        icon.tintColor = colors.comment
        nameLabel.text = workspace.name ?? workspace.id
        nameLabel.textColor = colors.fg
        sessionsLabel.text = "\(workspace.sessions)"
        sessionsLabel.textColor = colors.comment
        let cost = SessionFormatting.costString(workspace.cost)
        costLabel.text = cost
        costLabel.textColor = colors.comment
        accessibilityIdentifier = "server.usage.workspace.\(workspace.id)"
        accessibilityLabel = workspace.name ?? workspace.id
        accessibilityValue = String(localized: "\(workspace.sessions) sessions, \(cost)")
    }
}

// MARK: - Daily detail

/// One session in a day's detail: provider glyph, name, model, workspace, cost, and time.
final class UsageSessionRowView: UIView {
    private let glyph = UsageProviderGlyphView(side: 12)
    private let nameLabel = UILabel()
    private let modelLabel = UILabel()
    private let detailLabel = UILabel()
    private let costLabel = UILabel()
    private let timeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let texts = UIStackView(arrangedSubviews: [nameLabel, modelLabel, detailLabel])
        texts.axis = .vertical
        texts.spacing = 2
        let amounts = UIStackView(arrangedSubviews: [costLabel, timeLabel])
        amounts.axis = .vertical
        amounts.alignment = .trailing
        amounts.spacing = 1
        amounts.setContentHuggingPriority(.required, for: .horizontal)
        amounts.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [glyph, texts, amounts])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        nameLabel.font = .preferredFont(forTextStyle: .caption1)
        modelLabel.font = .preferredFont(forTextStyle: .caption2)
        detailLabel.font = .preferredFont(forTextStyle: .caption2)
        costLabel.font = UIFont.scaled(.caption1, monospacedDigits: true)
        timeLabel.font = .preferredFont(forTextStyle: .caption2)
        for label in [nameLabel, modelLabel, detailLabel, costLabel, timeLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ session: StatsDailySession, colors: UsageColors) {
        let model = session.model ?? "unknown"
        let name = session.name ?? "Session \(String(session.id.prefix(8)))"
        glyph.configure(provider: modelProviderKey(model))
        nameLabel.text = name
        nameLabel.textColor = colors.fg
        modelLabel.text = displayModelName(model)
        modelLabel.textColor = modelColor(model)
        let detail = [modelProviderLabel(model), session.workspaceName].compactMap { $0 }.joined(separator: " · ")
        detailLabel.text = detail
        detailLabel.textColor = colors.comment
        detailLabel.isHidden = detail.isEmpty
        let cost = SessionFormatting.costString(session.cost)
        let time = statsTimeLabel(epochMilliseconds: session.createdAt)
        costLabel.text = cost
        costLabel.textColor = colors.fg
        timeLabel.text = time
        timeLabel.textColor = colors.comment
        accessibilityIdentifier = "server.usage.detail.session.\(session.id)"
        accessibilityLabel = name
        accessibilityValue = [displayModelName(model), detail.isEmpty ? nil : detail, cost, time]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

/// A day's drill-down under the chart: its title and totals, a close button, an hourly
/// chart slot, and the day's sessions. The chart (`UsageHourlyChartLeaf`) is installed by
/// the screen into `chartSlot`.
final class UsageDailyDetailView: UIView {
    let chartSlot = UIView()
    var onClose: (() -> Void)?

    private let titleLabel = UILabel()
    private let totalsLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let sessionsHeading = UILabel()
    private let sessionList = UIStackView()
    private let moreLabel = UILabel()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous

        var close = UIButton.Configuration.plain()
        close.image = UIImage(systemName: "xmark.circle.fill")
        close.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .title3)
        closeButton.configuration = close
        closeButton.accessibilityLabel = String(localized: "Close day")
        closeButton.accessibilityIdentifier = "server.usage.detail.close"
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        // Pinned both sides, so the labels measure at the width the close button leaves them.
        let header = UIView()
        for view in [titleLabel, totalsLabel, closeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            totalsLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            totalsLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            totalsLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            totalsLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            closeButton.topAnchor.constraint(equalTo: header.topAnchor),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            closeButton.bottomAnchor.constraint(lessThanOrEqualTo: header.bottomAnchor),
        ])

        sessionList.axis = .vertical
        sessionsHeading.text = String(localized: "Sessions")
        sessionsHeading.font = .preferredFont(forTextStyle: .caption1).withWeight(.semibold)
        sessionsHeading.accessibilityTraits = .header
        moreLabel.font = .preferredFont(forTextStyle: .caption1)
        for label in [titleLabel, totalsLabel, sessionsHeading, moreLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        titleLabel.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        totalsLabel.font = .preferredFont(forTextStyle: .caption1)

        stack.axis = .vertical
        stack.spacing = 12
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        [header, chartSlot, sessionsHeading, sessionList, moreLabel].forEach(stack.addArrangedSubview)
        stack.setCustomSpacing(6, after: sessionsHeading)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        accessibilityIdentifier = "server.usage.detail"
        chartSlot.markAsChartSlot(UsageChartIdentifier.hourly)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The title and totals are pinned between the margin and the close button, so their width
    /// is fixed by constraints; handing it back as the wrap width keeps their measured height
    /// (and the audit's reading of it) in step with it.
    override func layoutSubviews() {
        super.layoutSubviews()
        for label in [titleLabel, totalsLabel] where label.bounds.width > 0 && label.preferredMaxLayoutWidth != label.bounds.width {
            label.preferredMaxLayoutWidth = label.bounds.width
        }
    }

    func configure(_ detail: DailyDetail, hasHourlyChart: Bool, colors: UsageColors) {
        backgroundColor = colors.comment.withAlphaComponent(0.06)
        titleLabel.text = detail.displayDayTitle
        titleLabel.textColor = colors.fg
        totalsLabel.text = String(localized: "\(detail.totals.sessions) sessions — \(SessionFormatting.costString(detail.totals.cost))")
        totalsLabel.textColor = colors.comment
        closeButton.tintColor = colors.comment
        chartSlot.isHidden = !hasHourlyChart
        sessionsHeading.textColor = colors.comment
        moreLabel.textColor = colors.comment
        let shown = detail.sessions.prefix(UsageModel.detailSessionCount)
        sessionsHeading.isHidden = shown.isEmpty
        sessionList.isHidden = shown.isEmpty
        sessionList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for session in shown {
            let row = UsageSessionRowView()
            row.configure(session, colors: colors)
            sessionList.addArrangedSubview(row)
        }
        let extra = detail.sessions.count - shown.count
        moreLabel.isHidden = extra <= 0
        moreLabel.text = extra > 0 ? "+\(extra) more" : nil
    }
}

// MARK: - Messages

/// Loading and failure in the page body, centered: a load state, with Retry
/// on a failure.
final class UsageMessageView: UIView {
    private let content = UIContentUnavailableView(loadState: .loading(nil))

    override init(frame: CGRect) {
        super.init(frame: frame)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func showLoading(colors: UsageColors) {
        content.configuration = UIContentUnavailableConfiguration.loadState(.loading(String(localized: "Loading usage")), palette: colors.palette)
        accessibilityIdentifier = "server.usage.loading"
    }

    func showFailure(_ message: String, colors: UsageColors, retry: @escaping @MainActor () -> Void) {
        content.configuration = UIContentUnavailableConfiguration.loadState(
            .failed(title: String(localized: "Unable to load usage"), message: message, retry: RetryAction(run: retry)),
            palette: colors.palette
        )
        accessibilityIdentifier = "server.usage.error"
    }
}
