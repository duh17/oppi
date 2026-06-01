import SwiftUI

// MARK: - Workspace Floating Composer

struct WorkspaceFloatingComposerLabel: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 21, weight: .semibold))
            .foregroundStyle(.themeBlue)
            .frame(width: 56, height: 56)
            .glassEffect(.regular, in: Circle())
            .contentShape(Circle())
    }
}

// MARK: - WorkspaceIcon

struct WorkspaceIcon: View {
    let icon: String?
    let size: CGFloat

    /// Whether the icon string looks like an SF Symbol name.
    private var isSFSymbol: Bool {
        guard let icon, !icon.isEmpty else { return false }
        return icon.allSatisfy { $0.isASCII }
    }

    var body: some View {
        if let icon, !icon.isEmpty {
            if isSFSymbol {
                Image(systemName: icon)
                    .font(.system(size: size))
                    .foregroundStyle(.themeBlue)
            } else {
                Text(icon)
                    .font(.system(size: size))
            }
        } else {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: size))
                .foregroundStyle(.themeBlue)
        }
    }
}

struct WorkspaceRuntimeIcon: View {
    let workspace: Workspace
    let size: CGFloat
    let frameSize: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            WorkspaceIcon(icon: workspace.icon, size: size)
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
    var badgeColor: ServerBadgeColor = .defaultValue

    private var resolvedSymbolName: String {
        if UIImage(systemName: icon.symbolName) != nil {
            return icon.symbolName
        }
        return "desktopcomputer"
    }

    private var tint: Color {
        badgeColor.themeColor
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
                .fill(tint.opacity(0.22))

            Circle()
                .stroke(tint.opacity(0.78), lineWidth: 1)

            Image(systemName: resolvedSymbolName)
                .font(.system(size: symbolSize, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
        }
        .frame(width: badgeSize, height: badgeSize)
        .accessibilityLabel("Local session environment")
    }
}

extension ServerBadgeColor {
    var themeColor: Color {
        switch self {
        case .orange: return .themeOrange
        case .blue: return .themeBlue
        case .cyan: return .themeCyan
        case .green: return .themeGreen
        case .purple: return .themePurple
        case .red: return .themeRed
        case .yellow: return .themeYellow
        case .neutral: return .themeComment
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
        guard freshnessState == .offline, isTransportConnected else {
            return Self(
                state: freshnessState,
                label: freshnessLabel,
                isUnreachable: freshnessState == .offline
            )
        }

        if hasCachedCatalog {
            return Self(state: .stale, label: "Connected", isUnreachable: false)
        }

        return Self(state: .syncing, label: "Connecting", isUnreachable: false)
    }
}

// MARK: - RuntimeStatusBadge

// periphery:ignore - future navigation bar badge; not yet integrated into ChatView
/// Environment icon with a small status dot overlay in the bottom-trailing corner.
/// Used in the ChatView navigation bar to show session + sync state.
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
    var badgeColor: ServerBadgeColor = .defaultValue

    private var dotFillColor: Color {
        syncState == .offline ? .themeComment : statusColor
    }

    private var dotRingColor: Color {
        switch syncState {
        case .live: return .themeBg
        case .syncing: return .themeBlue
        case .offline: return .themeRed
        case .stale: return .themeOrange
        }
    }

    var body: some View {
        RuntimeBadge(compact: true, icon: icon, badgeColor: badgeColor)
            .frame(width: 24, height: 24, alignment: .center)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(dotFillColor)
                    .frame(width: 7, height: 7)
                    .overlay(
                        Circle()
                            .stroke(dotRingColor, lineWidth: 1.5)
                    )
                    .offset(x: 2, y: 2)
            }
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
