import SwiftUI

enum StatusPillTone {
    case neutral
    case accent
    case success
    case working
    case warning
    case danger
    case info
    case custom(Color)

    var style: AnyShapeStyle {
        switch self {
        case .neutral:
            AnyShapeStyle(ThemeShapeStyle(role: .comment))
        case .accent, .working:
            AnyShapeStyle(ThemeShapeStyle(role: .blue))
        case .success:
            AnyShapeStyle(ThemeShapeStyle(role: .green))
        case .warning:
            AnyShapeStyle(ThemeShapeStyle(role: .orange))
        case .danger:
            AnyShapeStyle(ThemeShapeStyle(role: .red))
        case .info:
            AnyShapeStyle(ThemeShapeStyle(role: .cyan))
        case .custom(let color):
            AnyShapeStyle(color)
        }
    }
}

enum StatusPillEmphasis {
    case quiet
    case tinted
    case glass
}

enum StatusPillSize {
    case mini
    case small
    case regular

    var font: Font {
        switch self {
        case .mini:
            return .caption2.weight(.medium)
        case .small:
            return .caption2.weight(.semibold)
        case .regular:
            return .caption.weight(.semibold)
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .mini:
            return 6
        case .small:
            return 7
        case .regular:
            return 8
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .mini:
            return 2
        case .small:
            return 3
        case .regular:
            return 4
        }
    }

    var spacing: CGFloat {
        switch self {
        case .mini:
            return 3
        case .small, .regular:
            return 4
        }
    }
}

struct StatusPill: View {
    @Environment(\.themeID) private var themeID

    let text: String
    var systemImage: String? = nil
    var tone: StatusPillTone = .neutral
    var emphasis: StatusPillEmphasis = .quiet
    var size: StatusPillSize = .small
    var monospacedDigit = false
    var accessibilityLabel: String? = nil

    var body: some View {
        let _ = themeID
        switch emphasis {
        case .glass:
            content
                .padding(.horizontal, size.horizontalPadding)
                .padding(.vertical, size.verticalPadding)
                .glassEffect(.regular, in: Capsule())
                .accessibilityLabel(accessibilityLabel ?? text)
        case .quiet, .tinted:
            content
                .padding(.horizontal, size.horizontalPadding)
                .padding(.vertical, size.verticalPadding)
                .background(backgroundStyle, in: Capsule())
                .accessibilityLabel(accessibilityLabel ?? text)
        }
    }

    private var content: some View {
        HStack(spacing: size.spacing) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(size.font)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tone.style)
            }

            labelText
                .font(size.font)
                .foregroundStyle(labelStyle)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var labelText: some View {
        if monospacedDigit {
            Text(text).monospacedDigit()
        } else {
            Text(text)
        }
    }

    private var labelStyle: AnyShapeStyle {
        switch emphasis {
        case .quiet:
            systemImage == nil ? tone.style : AnyShapeStyle(ThemeShapeStyle(role: .comment))
        case .tinted, .glass:
            tone.style
        }
    }

    private var backgroundStyle: AnyShapeStyle {
        switch emphasis {
        case .quiet:
            AnyShapeStyle(ThemeShapeStyle(role: .foreground).opacity(0.08))
        case .tinted:
            AnyShapeStyle(tone.style.opacity(0.14))
        case .glass:
            AnyShapeStyle(Color.clear)
        }
    }
}
