import SwiftUI

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

private extension ServerBadgeColor {
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

// MARK: - RuntimeStatusBadge

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
        ZStack(alignment: .bottomTrailing) {
            RuntimeBadge(compact: true, icon: icon, badgeColor: badgeColor)

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
