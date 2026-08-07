import SwiftUI
import UIKit

typealias WorkspaceIconOption = IconSymbolOption

enum WorkspaceIconCatalog {
    static let options = IconSymbolCatalog.options

    static func filtered(by query: String) -> [WorkspaceIconOption] {
        IconSymbolCatalog.availableOptions(matching: query)
    }

    static func label(for symbolName: String) -> String? {
        IconSymbolCatalog.label(for: symbolName)
    }
}

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
            genmojiPreview: { data, contentDescription, size in
                AnyView(AssistantAvatarPreview(
                    avatar: .genmoji(data: data, contentDescription: contentDescription),
                    sessionId: "workspace-icon-picker-genmoji",
                    size: size
                ))
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
            .overlay(Circle().stroke(Color.themeBg, lineWidth: 1))
            .accessibilityLabel("Sandbox")
    }
}

// MARK: - WorkspaceSelectionButton

struct WorkspaceSelectionButton: View {
    let isSelected: Bool
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? .themeBlue : .themeComment)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

// MARK: - RuntimeBadge

struct RuntimeBadge: View {
    var compact: Bool = false
    var icon: ServerBadgeIcon = .defaultValue
    var tint: Color = .themeComment

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
        isPreparing: Bool = false
    ) {
        if isPreparing {
            self = hasSyncFailure ? .recovering : .connecting
            return
        }
        if hasSyncFailure {
            self = .syncFailed
            return
        }

        switch presentation.state {
        case .live, .stale:
            self = .connected
        case .syncing:
            self = .connecting
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

    var tintColor: Color {
        switch self {
        case .connected: return .themeGreen
        case .connecting: return .themeBlue
        case .recovering: return .themeOrange
        case .disconnected, .syncFailed: return .themeRed
        }
    }
}

@MainActor
enum ServerConnectionLanePresentation {
    static func title(
        server: PairedServer,
        connection: ServerConnection?,
        state: ServerBadgeConnectionState,
        isPreparing: Bool
    ) -> String {
        if isPreparing {
            return switch server.credentials.transports.preference {
            case .irohOnly: "Trying Iroh"
            case .irohPreferred: "Connecting"
            case .httpOnly: "Connecting to paired server"
            }
        }

        guard let connection, let credentials = connection.credentials else {
            return switch server.credentials.transports.preference {
            case .irohOnly: "Iroh unavailable"
            case .irohPreferred: "Connection unavailable"
            case .httpOnly: "Paired server unavailable"
            }
        }

        // Mid Wi‑Fi→cell demotion keeps a stale transportPath (.lan) while
        // composition is nil. Don't claim "via local network" in that hole.
        if connection.isTransportDemoting {
            return "Recovering connection"
        }

        let lane = switch connection.transportPath {
        case .iroh: "Iroh"
        case .lan: "local network"
        case .paired: credentials.resolvedScheme == .http ? "paired HTTP" : "paired HTTPS"
        }
        return switch state {
        case .connected: "Connected via \(lane)"
        case .connecting: "Connecting via \(lane)"
        case .recovering: "Recovering via \(lane)"
        case .disconnected: "\(lane) unavailable"
        case .syncFailed: "Update failed via \(lane)"
        }
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

// MARK: - RuntimeStatusBadge

// periphery:ignore - future navigation bar badge; not yet integrated into ChatView
/// Environment icon whose tint reflects session + sync state.
struct RuntimeStatusBadge: View {
    enum SyncState {
        case live
        case syncing
        case offline
        case stale

        var accessibilityText: String {
            switch self {
            case .live: return "Live"
            case .syncing: return "Syncing"
            case .offline: return "Offline"
            case .stale: return "Stale"
            }
        }
    }

    let statusColor: Color
    var syncState: SyncState = .live
    var icon: ServerBadgeIcon = .defaultValue

    private var badgeTint: Color {
        switch syncState {
        case .live: return statusColor
        case .syncing: return .themeBlue
        case .offline: return .themeRed
        case .stale: return .themeOrange
        }
    }

    var body: some View {
        RuntimeBadge(compact: true, icon: icon, tint: badgeTint)
            .frame(width: 24, height: 24)
            .accessibilityLabel("\(syncState.accessibilityText) session status")
    }
}

// periphery:ignore - extension on RuntimeStatusBadge.SyncState; suppressed with parent type
extension RuntimeStatusBadge.SyncState {
    init(_ freshness: FreshnessState) {
        switch freshness {
        case .live:
            self = .live
        case .syncing:
            self = .syncing
        case .offline:
            self = .offline
        case .stale:
            self = .stale
        }
    }
}
