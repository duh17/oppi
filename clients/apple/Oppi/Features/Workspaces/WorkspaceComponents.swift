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

struct WorkspaceSidebarRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.themeID) private var themeID

    let workspace: Workspace
    let status: WorkspaceSidebarSessionStatus
    let gitSummary: WorkspaceSidebarGitSummary?
    let isSelected: Bool
    let lockBadge: ScopedLockState

    init(
        workspace: Workspace,
        status: WorkspaceSidebarSessionStatus,
        gitSummary: WorkspaceSidebarGitSummary? = nil,
        isSelected: Bool,
        lockBadge: ScopedLockState = .none
    ) {
        self.workspace = workspace
        self.status = status
        self.gitSummary = gitSummary
        self.isSelected = isSelected
        self.lockBadge = lockBadge
    }

    /// A locked workspace shows its name only.
    private var hidesDetails: Bool { lockBadge == .locked }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            WorkspaceRuntimeIcon(workspace: workspace, size: 26, frameSize: 32)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(workspace.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.themeFg)
                            .lineLimit(1)
                        LockBadge(state: lockBadge)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if status.isVisible, !hidesDetails {
                        WorkspaceSidebarSessionStatusIndicator(status: status)
                    }
                }

                if !hidesDetails, let description = workspace.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !hidesDetails, let gitSummary, gitSummary.isVisible {
                    WorkspaceSidebarGitStatusLine(summary: gitSummary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .frame(minHeight: 44)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.text.primary.opacity(0.08))
            }
        }
        .contentShape(Rectangle())
        .id(themeID)
    }
}

struct WorkspaceSidebarGitStatusLine: View {
    let summary: WorkspaceSidebarGitSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            if summary.changedCount > 0 {
                metric(
                    text: "\(SessionFormatting.compactCount(summary.changedCount)) changes",
                    symbol: "circle.fill",
                    tint: .themeOrange,
                    symbolScale: .small
                )
            }

            if summary.aheadCount > 0 {
                metric(
                    text: "\(SessionFormatting.compactCount(summary.aheadCount))",
                    symbol: "arrow.up",
                    tint: .themeBlue
                )
            }

            if summary.behindCount > 0 {
                metric(
                    text: "\(SessionFormatting.compactCount(summary.behindCount))",
                    symbol: "arrow.down",
                    tint: .themeOrange
                )
            }
        }
        .font(.caption2.weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.accessibilityValue)
    }

    private func metric(
        text: String,
        symbol: String,
        tint: ThemeShapeStyle,
        symbolScale: Image.Scale = .medium
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: symbol)
                .imageScale(symbolScale)
            Text(text)
                .monospacedDigit()
        }
        .foregroundStyle(tint)
    }
}

struct WorkspaceSidebarSessionStatusIndicator: View {
    let status: WorkspaceSidebarSessionStatus

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            if status.attentionCount > 0 {
                metric(
                    symbol: "exclamationmark.triangle.fill",
                    count: status.attentionCount,
                    tint: status.errorCount > 0 ? .themeRed : .themeOrange
                )
            }

            if status.workingCount > 0 {
                metric(symbol: "bolt.fill", count: status.workingCount, tint: .themeBlue)
            }

            if status.showsDone {
                metric(symbol: "checkmark", count: status.doneCount, tint: .themeGreen)
            }
        }
        .font(.caption2.weight(.semibold))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityHidden(true)
    }

    private func metric(symbol: String, count: Int, tint: ThemeShapeStyle) -> some View {
        HStack(alignment: .center, spacing: 2) {
            Image(systemName: symbol)
                .imageScale(.small)

            Text(SessionFormatting.compactCount(count))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .lineLimit(1)
    }
}

extension WorkspaceSidebarRow {
    /// The row as cell content for the UIKit sidebar (`WorkspaceSidebarViewController`).
    @MainActor
    static func contentConfiguration(
        root: AppRootEnvironment,
        workspace: Workspace,
        status: WorkspaceSidebarSessionStatus,
        gitSummary: WorkspaceSidebarGitSummary?,
        isSelected: Bool,
        lockBadge: ScopedLockState
    ) -> UIContentConfiguration {
        UIHostingConfiguration {
            WorkspaceSidebarRow(
                workspace: workspace,
                status: status,
                gitSummary: gitSummary,
                isSelected: isSelected,
                lockBadge: lockBadge
            )
            .appRootEnvironment(root)
        }
        .margins(.all, 0)
    }
}
