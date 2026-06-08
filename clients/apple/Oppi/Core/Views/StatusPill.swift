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

    var color: Color {
        switch self {
        case .neutral:
            return .themeComment
        case .accent, .working:
            return .themeBlue
        case .success:
            return .themeGreen
        case .warning:
            return .themeOrange
        case .danger:
            return .themeRed
        case .info:
            return .themeCyan
        case .custom(let color):
            return color
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
    let text: String
    var systemImage: String? = nil
    var tone: StatusPillTone = .neutral
    var emphasis: StatusPillEmphasis = .quiet
    var size: StatusPillSize = .small
    var monospacedDigit = false
    var accessibilityLabel: String? = nil

    var body: some View {
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
                .background(backgroundColor, in: Capsule())
                .accessibilityLabel(accessibilityLabel ?? text)
        }
    }

    private var content: some View {
        HStack(spacing: size.spacing) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(size.font)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(iconColor)
            }

            labelText
                .font(size.font)
                .foregroundStyle(labelColor)
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

    private var iconColor: Color {
        tone.color
    }

    private var labelColor: Color {
        switch emphasis {
        case .quiet:
            return systemImage == nil ? tone.color : .themeComment
        case .tinted, .glass:
            return tone.color
        }
    }

    private var backgroundColor: Color {
        switch emphasis {
        case .quiet:
            return .themeFg.opacity(0.08)
        case .tinted:
            let color = tone.color
            return color.opacity(0.14)
        case .glass:
            return .clear
        }
    }
}
