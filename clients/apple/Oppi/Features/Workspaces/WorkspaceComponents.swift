import SwiftUI
import UIKit

// MARK: - WorkspaceIcon

struct WorkspaceIcon: View {
    let icon: IconChoice?
    let size: CGFloat
    var assetCache: IconAssetCache? = nil

    var body: some View {
        IconChoiceView(
            value: icon,
            purpose: .workspace,
            size: size,
            frameSize: size,
            assetCache: assetCache
        )
    }
}

private enum WorkspaceIconPickerError: LocalizedError {
    case serverOffline

    var errorDescription: String? { "Server is offline" }
}

/// Workspace adapter for the shared icon/avatar picker interaction.
struct WorkspaceIconPickerView: View {
    @Binding var icon: IconChoice
    @Environment(\.apiClient) private var apiClient

    var uploadOperation: ((Data, String) async throws -> IconChoice)?

    var body: some View {
        UnifiedIconPickerView(
            purpose: .workspace,
            savedValue: icon,
            defaultValue: .defaultValue,
            makeEmoji: IconChoice.emoji,
            makeSymbol: IconChoice.symbol,
            symbolName: Self.symbolName,
            customChoice: Self.customChoice,
            preview: { value, size in
                AnyView(WorkspaceIcon(icon: value, size: size))
            },
            genmojiPreview: { data, _, size in
                AnyView(IconPickerGenmojiDraftPreview(data: data, size: size))
            },
            prepareGenmoji: { data, contentDescription in
                if let uploadOperation {
                    return try await uploadOperation(data, contentDescription)
                }
                guard let apiClient else { throw WorkspaceIconPickerError.serverOffline }
                let asset = try await apiClient.uploadIconAsset(
                    data: data,
                    contentType: NSAdaptiveImageGlyph.contentType.preferredMIMEType ?? "image/heic"
                )
                return .genmoji(
                    assetId: asset.assetId,
                    contentDescription: contentDescription
                )
            },
            commit: { selected in
                icon = selected
            },
            accessibilityPrefix: "workspace.iconPicker"
        )
    }

    private static func symbolName(_ value: IconChoice) -> String? {
        guard case .symbol(let name) = value else { return nil }
        return name
    }

    private static func customChoice(_ value: IconChoice) -> IconPickerCustomChoice? {
        switch value {
        case .emoji(let emoji): return .emoji(emoji)
        case .genmoji(_, let contentDescription): return .genmoji(contentDescription)
        case .defaultValue, .symbol: return nil
        }
    }

    static func description(_ value: IconChoice) -> String {
        switch AgentIconContent.resolve(value) {
        case .text(let emoji): return "Emoji \(emoji)"
        case .symbol(let name): return IconSymbolCatalog.label(for: name) ?? "SF Symbol"
        case .genmoji(_, let contentDescription): return contentDescription
        case .fallback: return "Default workspace icon"
        }
    }
}

struct WorkspaceRuntimeIcon: View {
    let workspace: Workspace
    let size: CGFloat
    let frameSize: CGFloat
    var assetCache: IconAssetCache? = nil

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            WorkspaceIcon(icon: workspace.icon, size: size, assetCache: assetCache)
                .frame(width: frameSize, height: frameSize)

            if workspace.runtime == .sandbox {
                WorkspaceSandboxMark(size: max(11, frameSize * 0.34))
                    .offset(x: frameSize * 0.05, y: frameSize * 0.05)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(workspace.runtime == .sandbox ? "Sandbox workspace" : "Workspace")
    }
}

struct WorkspaceSandboxMark: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: size * 0.52, weight: .bold))
            .foregroundStyle(.themeBg)
            .frame(width: size, height: size)
            .background(Circle().fill(.themeOrange))
            .overlay(Circle().stroke(.themeBg, lineWidth: 1))
            .accessibilityLabel("Sandbox")
    }
}

// MARK: - RuntimeBadge

struct RuntimeBadge: View {
    var compact: Bool = false
    var icon: ServerBadgeIcon = .defaultValue
    var tint: ThemeShapeStyle = .themeComment

    private var resolvedSymbolName: String {
        if UIImage(systemName: icon.symbolName) != nil {
            return icon.symbolName
        }
        return "desktopcomputer"
    }

    private var badgeSize: CGFloat {
        compact ? 20 : 24
    }

    private var symbolSize: CGFloat {
        compact ? 10 : 12
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.16))

            Circle()
                .stroke(tint.opacity(0.5), lineWidth: 1)

            Image(systemName: resolvedSymbolName)
                .font(.system(size: symbolSize, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
        }
        .frame(width: badgeSize, height: badgeSize)
        .accessibilityLabel("Server badge")
    }
}

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

    var tintColor: ThemeShapeStyle {
        switch self {
        case .connected: return .themeGreen
        case .connecting: return .themeBlue
        case .recovering: return .themeOrange
        case .disconnected, .syncFailed: return .themeRed
        }
    }
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
        if connection.isTransportDemoting {
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
        return connection.configuredSOCKSGeneration != 0 ? "in-app Tailscale" : "Tailscale"
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
    /// A 26 pt workspace mark drawn at 78 % of its 26 pt box (`IconChoiceView`),
    /// centered in 32 pt with the sandbox lock (`WorkspaceRuntimeIcon`).
    private let icon = IconChoiceUIView(size: 26 * 0.78, frameSize: 32)
    private let nameLabel = UILabel()
    private let lockLabel = UILabel()
    private let statusLabel = UILabel()
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
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        let nameRow = UIStackView(arrangedSubviews: [nameLabel, lockLabel, SessionRowSpacer(minWidth: 0), statusLabel])
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
            colors: colors,
            assetCache: configuration.iconAssetCache
        )
        nameLabel.text = workspace.name
        nameLabel.textColor = colors.fg
        SessionRowText.setLockBadge(configuration.lockBadge, on: lockLabel, color: colors.comment)

        let status = configuration.status
        statusLabel.isHidden = !status.isVisible || hidesDetails
        statusLabel.attributedText = Self.statusText(status, colors: colors)

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

    /// Attention, working, and done counts, each a small glyph and its count.
    static func statusText(_ status: WorkspaceSidebarSessionStatus, colors: ComposerThemeColors) -> NSAttributedString {
        var metrics: [(String, Int, UIColor)] = []
        if status.attentionCount > 0 {
            metrics.append(("exclamationmark.triangle.fill", status.attentionCount, status.errorCount > 0 ? colors.red : colors.orange))
        }
        if status.workingCount > 0 { metrics.append(("bolt.fill", status.workingCount, colors.blue)) }
        if status.showsDone { metrics.append(("checkmark", status.doneCount, colors.green)) }
        return metricLine(
            metrics.map { (symbol: $0.0, text: SessionFormatting.compactCount($0.1), color: $0.2, small: true) },
            weight: .semibold,
            itemSpacing: 7,
            glyphSpacing: 2
        )
    }

    /// Changes, ahead, and behind.
    private static func gitText(_ summary: WorkspaceSidebarGitSummary, colors: ComposerThemeColors) -> NSAttributedString {
        var metrics: [(symbol: String, text: String, color: UIColor, small: Bool)] = []
        if summary.changedCount > 0 {
            metrics.append(("circle.fill", "\(SessionFormatting.compactCount(summary.changedCount)) changes", colors.orange, true))
        }
        if summary.aheadCount > 0 {
            metrics.append(("arrow.up", SessionFormatting.compactCount(summary.aheadCount), colors.blue, false))
        }
        if summary.behindCount > 0 {
            metrics.append(("arrow.down", SessionFormatting.compactCount(summary.behindCount), colors.orange, false))
        }
        return metricLine(metrics, weight: .medium, itemSpacing: 9, glyphSpacing: 3)
    }

    /// Each metric a small glyph and its text (`SessionRowText.symbolAndText`),
    /// `itemSpacing` apart.
    private static func metricLine(
        _ metrics: [(symbol: String, text: String, color: UIColor, small: Bool)],
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
