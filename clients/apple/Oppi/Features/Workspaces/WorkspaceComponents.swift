import UIKit

enum ServerBadgeConnectionState: Sendable, Equatable {
    case connected
    case connecting
    case recovering
    case disconnected
    case syncFailed

    init(_ transportStatus: WebSocketClient.Status?) {
        switch transportStatus {
        case .connected:
            self = .connected
        case .connecting, .reconnecting:
            self = .connecting
        case .disconnected, nil:
            self = .disconnected
        }
    }

    init(
        _ presentation: WorkspaceServerStatusPresentation,
        hasSyncFailure: Bool = false,
        isPreparing: Bool = false,
        isFocusedStreamRecovering: Bool = false,
        hasConnectionEvidence: Bool = false
    ) {
        if isPreparing {
            self = hasSyncFailure ? .recovering : (hasConnectionEvidence ? .connected : .connecting)
            return
        }
        if hasSyncFailure {
            self = .syncFailed
            return
        }

        switch presentation.state {
        case .live, .stale:
            self = isFocusedStreamRecovering ? .recovering : .connected
        case .syncing:
            self = hasConnectionEvidence ? .connected : .connecting
        case .offline:
            self = .disconnected
        }
    }

    var title: String {
        switch self {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .recovering: return "Recovering"
        case .disconnected: return "Offline"
        case .syncFailed: return "Update Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .connected: return "checkmark.circle.fill"
        case .connecting: return "ellipsis.circle.fill"
        case .recovering: return "arrow.triangle.2.circlepath.circle.fill"
        case .disconnected: return "wifi.slash"
        case .syncFailed: return "exclamationmark.triangle.fill"
        }
    }

    /// The palette slot the state paints with; `uiColor(_:)` (SessionListCollection)
    /// resolves it against the screen's palette.
    var tintRole: ServerBadgeTintRole {
        switch self {
        case .connected: return .green
        case .connecting: return .blue
        case .recovering: return .orange
        case .disconnected, .syncFailed: return .red
        }
    }
}

/// The accent slots a connection badge can paint with.
enum ServerBadgeTintRole {
    case green
    case blue
    case orange
    case red
}

enum FocusedSessionStreamRecoveryPresentation {
    static let message = "Recovering session stream"
}

@MainActor
enum ServerConnectionLanePresentation {
    static func title(
        server: PairedServer,
        connection: ServerConnection?,
        state: ServerBadgeConnectionState,
        isPreparing: Bool
    ) -> String {
        if isPreparing, state != .connected {
            return ServerTLSTrustPolicy.isTailscaleHostname(server.host)
                ? "Connecting over Tailscale"
                : "Connecting over HTTPS/WSS"
        }

        guard let connection, connection.credentials != nil else {
            return ServerTLSTrustPolicy.isTailscaleHostname(server.host)
                ? "Tailscale unavailable"
                : "HTTPS/WSS server unavailable"
        }

        // Mid Wi‑Fi→cell demotion keeps a stale transportPath (.lan) while
        // composition is nil. Don't claim "via local network" in that hole.
        if connection.route.isTransportDemoting {
            return state == .connected ? "Connected" : "Recovering connection"
        }

        if connection.isFocusedSessionStreamRecovering {
            switch state {
            case .disconnected, .syncFailed:
                break
            default:
                return FocusedSessionStreamRecoveryPresentation.message
            }
        }

        let lane = laneDescription(server: server, connection: connection)
        return switch state {
        case .connected: "Connected via \(lane)"
        case .connecting: "Connecting via \(lane)"
        case .recovering: "Recovering via \(lane)"
        case .disconnected: "\(lane) unavailable"
        case .syncFailed: "Update failed via \(lane)"
        }
    }

    /// User-facing path. `in-app Tailscale` only when the embedded SOCKS proxy is
    /// published; MagicDNS without it is still Tailscale (system VPN or resolver).
    private static func laneDescription(server: PairedServer, connection: ServerConnection) -> String {
        if connection.transportPath == .lan {
            return "local network"
        }
        let host = connection.credentials?.host ?? server.host
        guard ServerTLSTrustPolicy.isTailscaleHostname(host) else {
            return "paired HTTPS"
        }
        return connection.route.configuredSOCKSGeneration != 0 ? "in-app Tailscale" : "Tailscale"
    }
}

// MARK: - Workspace Server Status Presentation

struct WorkspaceServerStatusPresentation: Equatable, Sendable {
    let state: FreshnessState
    let label: String
    let isUnreachable: Bool

    static func derive(
        freshnessState: FreshnessState,
        freshnessLabel: String,
        isTransportConnected: Bool,
        hasCachedCatalog: Bool
    ) -> Self {
        derive(health: ServerHealth.derive(
            freshnessState: freshnessState,
            freshnessLabel: freshnessLabel,
            transportStates: [isTransportConnected ? .connected : .disconnected],
            hasCachedCatalog: hasCachedCatalog
        ))
    }

    static func derive(health: ServerHealth) -> Self {
        if health.freshnessState == .offline {
            switch health.transportState {
            case .connected:
                if health.hasCachedCatalog {
                    return Self(state: .stale, label: "Connected", isUnreachable: false)
                }
                return Self(state: .syncing, label: "Connecting", isUnreachable: false)

            case .connecting:
                return Self(state: .syncing, label: "Connecting", isUnreachable: false)

            case .disconnected:
                return Self(
                    state: .offline,
                    label: health.freshnessLabel,
                    isUnreachable: true
                )
            }
        }

        return Self(
            state: health.freshnessState,
            label: health.freshnessLabel,
            isUnreachable: false
        )
    }
}

// MARK: - Workspace sidebar row

/// A workspace in the sidebar: its icon, name and lock, session status
/// counts, description, and git summary. A locked workspace shows its name
/// only. The sidebar cell's button (`SidebarRowElement`) takes the tap and
/// speaks for the row.
struct WorkspaceSidebarRowConfiguration: UIContentConfiguration {
    let workspace: Workspace
    let status: WorkspaceSidebarSessionStatus
    let gitSummary: WorkspaceSidebarGitSummary?
    let isSelected: Bool
    let lockBadge: ScopedLockState
    let themeID: ThemeID
    let iconAssetCache: IconAssetCache?

    func makeContentView() -> any UIView & UIContentView {
        WorkspaceSidebarRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class WorkspaceSidebarRowContentView: UIView, UIContentView {
    private let selection = UIView()
    /// A 26 pt workspace mark drawn at 78 % of its 26 pt box,
    /// centered in 32 pt with the sandbox lock.
    private let icon = IconChoiceUIView(size: 26 * 0.78, frameSize: 32)
    private let nameLabel = UILabel()
    private let lockLabel = UILabel()
    private let statusView = WorkspaceSidebarStatusView()
    private let descriptionLabel = UILabel()
    private let gitLabel = UILabel()
    private var applied: WorkspaceSidebarRowConfiguration

    var configuration: UIContentConfiguration {
        get { applied }
        set {
            guard let configuration = newValue as? WorkspaceSidebarRowConfiguration else { return }
            apply(configuration)
        }
    }

    init(configuration: WorkspaceSidebarRowConfiguration) {
        applied = configuration
        super.init(frame: .zero)
        isAccessibilityElement = false
        accessibilityElementsHidden = true

        selection.layer.cornerRadius = 12
        selection.layer.cornerCurve = .continuous
        selection.translatesAutoresizingMaskIntoConstraints = false
        addSubview(selection)

        nameLabel.font = UIFont.scaled(.body, .semibold)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lockLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        lockLabel.setContentHuggingPriority(.required, for: .horizontal)
        let nameRow = UIStackView(arrangedSubviews: [nameLabel, lockLabel, SessionRowSpacer(minWidth: 0), statusView])
        nameRow.alignment = .firstBaseline
        nameRow.spacing = 5
        nameRow.setCustomSpacing(8, after: lockLabel)
        descriptionLabel.font = UIFont.scaled(.caption1)
        descriptionLabel.adjustsFontForContentSizeCategory = true
        gitLabel.adjustsFontSizeToFitWidth = true
        gitLabel.minimumScaleFactor = 0.75
        let column = UIStackView(arrangedSubviews: [nameRow, descriptionLabel, gitLabel])
        column.axis = .vertical
        column.spacing = 3

        // The content is centered in at least 44 pt, inside 5 pt of vertical padding.
        let content = UIView()
        for view in [content, icon, column] { view.translatesAutoresizingMaskIntoConstraints = false }
        content.addSubview(icon)
        content.addSubview(column)
        addSubview(content)
        let hug = content.heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .defaultLow
        // The row is as short as its content allows, never shorter than 54 pt.
        let rowHug = heightAnchor.constraint(equalToConstant: 54)
        rowHug.priority = .defaultLow
        NSLayoutConstraint.activate([
            selection.topAnchor.constraint(equalTo: topAnchor),
            selection.bottomAnchor.constraint(equalTo: bottomAnchor),
            selection.leadingAnchor.constraint(equalTo: leadingAnchor),
            selection.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 5),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 54),
            hug,
            rowHug,
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 1),
            content.bottomAnchor.constraint(greaterThanOrEqualTo: icon.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor),
            content.bottomAnchor.constraint(greaterThanOrEqualTo: column.bottomAnchor),
        ])
        apply(configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func apply(_ configuration: WorkspaceSidebarRowConfiguration) {
        applied = configuration
        let workspace = configuration.workspace
        let colors = SessionRowStyle.for(configuration.themeID).colors
        // A locked workspace shows its name only.
        let hidesDetails = configuration.lockBadge == .locked

        selection.isHidden = !configuration.isSelected
        selection.backgroundColor = colors.fg.withAlphaComponent(0.08)
        icon.apply(
            .choice(workspace.icon, purpose: .workspace, sandbox: workspace.runtime == .sandbox),
            assetCache: configuration.iconAssetCache
        )
        nameLabel.text = workspace.name
        nameLabel.textColor = colors.fg
        SessionRowText.setLockBadge(configuration.lockBadge, on: lockLabel, color: colors.comment, key: workspace.id)

        let status = configuration.status
        statusView.isHidden = !status.isVisible || hidesDetails
        statusView.apply(status, colors: colors, palette: configuration.themeID.palette)

        let description = workspace.description ?? ""
        descriptionLabel.isHidden = hidesDetails || description.isEmpty
        descriptionLabel.text = description
        descriptionLabel.textColor = colors.comment

        if !hidesDetails, let git = configuration.gitSummary, git.isVisible {
            gitLabel.isHidden = false
            gitLabel.attributedText = Self.gitText(git, colors: colors)
        } else {
            gitLabel.isHidden = true
        }
    }

    /// One glyph and its text in a `metricLine`.
    struct Metric {
        let symbol: String
        let text: String
        let color: UIColor
        let small: Bool
    }

    /// Changes, ahead, and behind.
    private static func gitText(_ summary: WorkspaceSidebarGitSummary, colors: ComposerThemeColors) -> NSAttributedString {
        var metrics: [Metric] = []
        if summary.changedCount > 0 {
            metrics.append(Metric(symbol: "circle.fill", text: "\(SessionFormatting.compactCount(summary.changedCount)) changes", color: colors.orange, small: true))
        }
        if summary.aheadCount > 0 {
            metrics.append(Metric(symbol: "arrow.up", text: SessionFormatting.compactCount(summary.aheadCount), color: colors.blue, small: false))
        }
        if summary.behindCount > 0 {
            metrics.append(Metric(symbol: "arrow.down", text: SessionFormatting.compactCount(summary.behindCount), color: colors.orange, small: false))
        }
        return metricLine(metrics, weight: .medium, itemSpacing: 9, glyphSpacing: 3)
    }

    /// Each metric a small glyph and its text (`SessionRowText.symbolAndText`),
    /// `itemSpacing` apart.
    static func metricLine(
        _ metrics: [Metric],
        weight: UIFont.Weight,
        itemSpacing: CGFloat,
        glyphSpacing: CGFloat
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for metric in metrics {
            if result.length > 0 { result.append(SessionRowText.gap(itemSpacing, font: .scaled(.caption2, weight))) }
            result.append(SessionRowText.symbolAndText(
                metric.symbol, metric.text, style: .caption2, symbolWeight: weight, textWeight: weight,
                symbolScale: metric.small ? .small : .medium, monospacedDigits: true, spacing: glyphSpacing, color: metric.color
            ))
        }
        return result
    }
}

/// A sidebar workspace's session counts: attention, then the working mark with
/// its count, then done. Working draws the app's static working icon
/// (`WorkingMarkView`); the others are a small glyph and a count. The row's name sits on the
/// counts' baseline, so the first count shown is the baseline.
final class WorkspaceSidebarStatusView: UIStackView {
    private let attention = UILabel()
    private let mark = WorkingMarkView(textStyle: .caption2)
    private let workingCount = UILabel()
    private lazy var working = UIStackView(arrangedSubviews: [mark, workingCount])
    private let done = UILabel()

    init() {
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .center
        spacing = 7
        working.alignment = .center
        working.spacing = 2
        workingCount.font = UIFont.scaled(.caption2, .semibold, monospacedDigits: true)
        for label in [attention, workingCount, done] {
            label.adjustsFontForContentSizeCategory = true
        }
        [attention, working, done].forEach(addArrangedSubview)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Not supported") }

    func apply(_ status: WorkspaceSidebarSessionStatus, colors: ComposerThemeColors, palette: ThemePalette) {
        attention.isHidden = status.attentionCount == 0
        if status.attentionCount > 0 {
            attention.attributedText = WorkspaceSidebarRowContentView.metricLine(
                [WorkspaceSidebarRowContentView.Metric(
                    symbol: "exclamationmark.triangle.fill", text: SessionFormatting.compactCount(status.attentionCount),
                    color: status.errorCount > 0 ? colors.red : colors.orange, small: true
                )],
                weight: .semibold, itemSpacing: 0, glyphSpacing: 2
            )
        }
        working.isHidden = status.workingCount == 0
        if status.workingCount > 0 {
            mark.apply(palette: palette)
            workingCount.text = SessionFormatting.compactCount(status.workingCount)
            workingCount.textColor = colors.blue
        }
        done.isHidden = !status.showsDone
        if status.showsDone {
            done.attributedText = WorkspaceSidebarRowContentView.metricLine(
                [WorkspaceSidebarRowContentView.Metric(symbol: "checkmark", text: SessionFormatting.compactCount(status.doneCount), color: colors.green, small: true)],
                weight: .semibold, itemSpacing: 0, glyphSpacing: 2
            )
        }
    }

    override var forFirstBaselineLayout: UIView {
        [attention, workingCount, done].first { !$0.isHidden && $0.superview?.isHidden == false } ?? attention
    }

    override var forLastBaselineLayout: UIView { forFirstBaselineLayout }
}
