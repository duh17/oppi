import AppKit

enum OppiMacTheme {
    private static let themeDefaultsKey = "dev.chenda.PiRemote.theme.id"

    enum ID: String {
        case tokyoNight = "tokyo-night"
        case tokyoNightDay = "tokyo-night-day"
        case appleDark = "apple-dark"
    }

    struct Palette {
        let background: NSColor
        let backgroundSecondary: NSColor
        let foreground: NSColor
        let foregroundDim: NSColor
        let comment: NSColor

        let blue: NSColor
        let cyan: NSColor
        let green: NSColor
        let orange: NSColor
        let purple: NSColor
        let red: NSColor

        let selection: NSColor
    }

    static var current: Palette {
        switch currentID {
        case .tokyoNight:
            return Palette(
                background: .srgb(26, 27, 38),
                backgroundSecondary: .srgb(22, 22, 30),
                foreground: .srgb(192, 202, 245),
                foregroundDim: .srgb(169, 177, 214),
                comment: .srgb(86, 95, 137),
                blue: .srgb(122, 162, 247),
                cyan: .srgb(125, 207, 255),
                green: .srgb(158, 206, 106),
                orange: .srgb(255, 158, 100),
                purple: .srgb(187, 154, 247),
                red: .srgb(247, 118, 142),
                selection: .srgb(122, 162, 247, alpha: 0.20)
            )

        case .tokyoNightDay:
            return Palette(
                background: .srgb(225, 226, 231),
                backgroundSecondary: .srgb(208, 213, 227),
                foreground: .srgb(55, 96, 191),
                foregroundDim: .srgb(97, 114, 176),
                comment: .srgb(132, 140, 181),
                blue: .srgb(46, 125, 233),
                cyan: .srgb(0, 113, 151),
                green: .srgb(88, 117, 57),
                orange: .srgb(177, 92, 0),
                purple: .srgb(120, 71, 189),
                red: .srgb(198, 67, 67),
                selection: .srgb(46, 125, 233, alpha: 0.18)
            )

        case .appleDark:
            return Palette(
                background: .windowBackgroundColor,
                backgroundSecondary: .controlBackgroundColor,
                foreground: .labelColor,
                foregroundDim: .secondaryLabelColor,
                comment: .tertiaryLabelColor,
                blue: .systemBlue,
                cyan: .systemTeal,
                green: .systemGreen,
                orange: .systemOrange,
                purple: .systemPurple,
                red: .systemRed,
                selection: NSColor.systemBlue.withAlphaComponent(0.18)
            )
        }
    }

    static var currentID: ID {
        guard let rawValue = UserDefaults.standard.string(forKey: themeDefaultsKey),
              let id = ID(rawValue: rawValue)
        else {
            return .appleDark
        }
        return id
    }

    static func iconColor(for kind: ReviewTimelineKind) -> NSColor {
        let palette = current

        switch kind {
        case .user:
            return palette.blue
        case .assistant:
            return palette.purple
        case .thinking:
            return palette.purple
        case .toolCall:
            return palette.cyan
        case .toolResult:
            return palette.green
        case .system:
            return palette.comment
        case .compaction:
            return palette.orange
        }
    }

    static func titleColor(for kind: ReviewTimelineKind) -> NSColor {
        let palette = current

        switch kind {
        case .system:
            return palette.foregroundDim
        default:
            return palette.foreground
        }
    }

    static func subtitleColor(for kind: ReviewTimelineKind) -> NSColor {
        let palette = current

        switch kind {
        case .assistant:
            return palette.foregroundDim
        case .thinking, .system:
            return palette.comment
        default:
            return palette.foregroundDim
        }
    }
}

private extension NSColor {
    static func srgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1.0) -> NSColor {
        NSColor(
            red: red / 255.0,
            green: green / 255.0,
            blue: blue / 255.0,
            alpha: alpha
        )
    }
}
