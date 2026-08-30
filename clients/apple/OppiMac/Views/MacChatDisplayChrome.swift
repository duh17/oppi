import SwiftUI

/// SwiftUI paint for the device-local assistant avatar preference.
struct MacAssistantAvatarView: View {
    let avatar: AssistantAvatarPreference
    var sessionId: String = "assistant-avatar-preview"
    var size: CGFloat = 22
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            switch avatar {
            case .officialPi:
                MacOfficialPiMark(color: theme.text.primary)
            case .piText:
                Text("π")
                    .font(.system(size: size * 0.55, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.accent.purple)
            case .golGrid:
                MacAssistantGridIcon(
                    sessionId: sessionId,
                    foreground: theme.text.primary,
                    spark: theme.accent.orange
                )
            case .emoji(let char):
                Text(char)
                    .font(.system(size: size * 0.7))
            }
        }
        .frame(width: size, height: size)
        .background(
            theme.text.tertiary.opacity(0.10),
            in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
        )
        .accessibilityLabel(avatar.accessibilityDescription)
    }
}

/// Reloads the persisted avatar when Settings writes a new value.
struct MacCurrentAssistantAvatarView: View {
    var sessionId: String
    var size: CGFloat = 18

    @State private var avatar = AssistantAvatarPreference.current

    var body: some View {
        MacAssistantAvatarView(avatar: avatar, sessionId: sessionId, size: size)
            .onReceive(
                NotificationCenter.default.publisher(for: AssistantAvatarPreference.didChangeNotification)
            ) { _ in
                avatar = AssistantAvatarPreference.current
            }
    }
}

/// Pi / GoL working spinner. Defaults to the persisted preference.
struct MacWorkingSpinnerView: View {
    var tint: Color
    var style: SpinnerStyle = .current

    var body: some View {
        switch style {
        case .brailleDots:
            MacBrailleSpinner(tint: tint)
        case .gameOfLife:
            MacGameOfLifeSpinner(tint: tint)
        }
    }
}

struct MacWorkingIndicatorRow: View {
    @Environment(\.theme) private var theme
    @State private var spinnerStyle = SpinnerStyle.current

    static let rowID = "mac.timeline.working"

    var body: some View {
        HStack(spacing: 6) {
            MacWorkingSpinnerView(tint: theme.text.secondary, style: spinnerStyle)
                .frame(width: 16, height: 16)
            Text("Working…")
                .font(.callout)
                .foregroundStyle(theme.text.secondary.opacity(0.6))
        }
        .padding(.leading, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working…")
        .accessibilityIdentifier("mac.timeline.workingRow")
        .onReceive(
            NotificationCenter.default.publisher(
                for: AppPreferenceStore.Appearance.spinnerDidChangeNotification
            )
        ) { _ in
            spinnerStyle = SpinnerStyle.current
        }
    }
}

private struct MacOfficialPiMark: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let scale = size.width / 800
            var canvas = context
            canvas.concatenate(CGAffineTransform(scaleX: scale, y: scale))

            var mark = Path()
            mark.move(to: CGPoint(x: 165.29, y: 165.29))
            mark.addLine(to: CGPoint(x: 517.36, y: 165.29))
            mark.addLine(to: CGPoint(x: 517.36, y: 400))
            mark.addLine(to: CGPoint(x: 400, y: 400))
            mark.addLine(to: CGPoint(x: 400, y: 517.36))
            mark.addLine(to: CGPoint(x: 282.65, y: 517.36))
            mark.addLine(to: CGPoint(x: 282.65, y: 634.72))
            mark.addLine(to: CGPoint(x: 165.29, y: 634.72))
            mark.closeSubpath()
            mark.move(to: CGPoint(x: 282.65, y: 282.65))
            mark.addLine(to: CGPoint(x: 282.65, y: 400))
            mark.addLine(to: CGPoint(x: 400, y: 400))
            mark.addLine(to: CGPoint(x: 400, y: 282.65))
            mark.closeSubpath()

            canvas.fill(mark, with: .color(color), style: FillStyle(eoFill: true))
            canvas.fill(
                Path(CGRect(x: 517.36, y: 400, width: 117.36, height: 234.72)),
                with: .color(color)
            )
        }
        .accessibilityHidden(true)
    }
}

private struct MacAssistantGridIcon: View {
    let sessionId: String
    let foreground: Color
    let spark: Color

    var body: some View {
        let cells = SessionGridRenderer.generateCells(sessionId: sessionId)
        Canvas { context, size in
            let grid = SessionGridRenderer.gridSize
            let cellTotal = size.width / CGFloat(grid)
            let gap = cellTotal * 0.10
            let cellSize = cellTotal - gap
            let cornerRadius = cellSize * 0.24

            for cell in cells {
                let x = CGFloat(cell.col) * cellTotal + gap / 2
                let y = CGFloat(cell.row) * cellTotal + gap / 2
                let rect = CGRect(x: x, y: y, width: cellSize, height: cellSize)
                let path = Path(roundedRect: rect, cornerRadius: cornerRadius)
                let color: Color = switch cell.role {
                case .spark:
                    spark.opacity(0.90)
                case .almostSpark:
                    spark.opacity(0.30)
                default:
                    foreground.opacity(Double(cell.opacity))
                }
                context.fill(path, with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct MacBrailleSpinner: View {
    var tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 3_600 : 0.16)) { context in
            let index = reduceMotion
                ? 0
                : Int(context.date.timeIntervalSinceReferenceDate / 0.16)
                    % Self.frames.count
            Text(Self.frames[index])
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(tint)
        }
        .accessibilityHidden(true)
    }
}

private struct MacGameOfLifeSpinner: View {
    var tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bits: UInt64 = 0
    @State private var history: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    @State private var ticksSinceReseed = 0

    private let gridSize = 6

    var body: some View {
        Canvas { context, size in
            let cellW = size.width / CGFloat(gridSize)
            let cellH = size.height / CGFloat(gridSize)
            let inset = min(cellW, cellH) * 0.12
            for row in 0..<gridSize {
                for col in 0..<gridSize {
                    let index = row * gridSize + col
                    guard (bits >> index) & 1 == 1 else { continue }
                    let rect = CGRect(
                        x: CGFloat(col) * cellW + inset,
                        y: CGFloat(row) * cellH + inset,
                        width: cellW - inset * 2,
                        height: cellH - inset * 2
                    )
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: inset),
                        with: .color(tint)
                    )
                }
            }
        }
        .task(id: reduceMotion) {
            seed()
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                tick()
            }
        }
        .accessibilityHidden(true)
    }

    private func seed() {
        var next: UInt64 = 0
        let count = gridSize * gridSize
        for i in 0..<count where Double.random(in: 0..<1) < 0.33 {
            next |= 1 << i
        }
        if next == 0 {
            next = 1 << (count / 2)
        }
        bits = next
        history = (next, next, next, next)
        ticksSinceReseed = 0
    }

    private func tick() {
        let size = gridSize
        let count = size * size
        let sizeMinus1 = size - 1
        var newBits: UInt64 = 0
        let currentBits = bits
        var row = 0
        var col = 0
        var rowOffset = 0
        var rowUpOffset = sizeMinus1 * size
        var rowDownOffset = size
        for i in 0..<count {
            let cLeft = col == 0 ? sizeMinus1 : col - 1
            let cRight = col == sizeMinus1 ? 0 : col + 1
            var neighbors = 0
            if (currentBits >> (rowUpOffset + cLeft)) & 1 == 1 { neighbors += 1 }
            if (currentBits >> (rowUpOffset + col)) & 1 == 1 { neighbors += 1 }
            if (currentBits >> (rowUpOffset + cRight)) & 1 == 1 { neighbors += 1 }
            if (currentBits >> (rowOffset + cLeft)) & 1 == 1 { neighbors += 1 }
            if (currentBits >> (rowOffset + cRight)) & 1 == 1 { neighbors += 1 }
            if (currentBits >> (rowDownOffset + cLeft)) & 1 == 1 { neighbors += 1 }
            if (currentBits >> (rowDownOffset + col)) & 1 == 1 { neighbors += 1 }
            if (currentBits >> (rowDownOffset + cRight)) & 1 == 1 { neighbors += 1 }

            let alive = (currentBits >> i) & 1 == 1
            if alive {
                if neighbors == 2 || neighbors == 3 {
                    newBits |= 1 << i
                }
            } else if neighbors == 3 {
                newBits |= 1 << i
            }

            col += 1
            if col == size {
                col = 0
                row += 1
                rowUpOffset = rowOffset
                rowOffset = rowDownOffset
                rowDownOffset = row == sizeMinus1 ? 0 : rowDownOffset + size
            }
        }

        let aliveCount = newBits.nonzeroBitCount
        if aliveCount < 2 {
            seed()
            return
        }
        ticksSinceReseed += 1
        if ticksSinceReseed >= 8 {
            let stale = newBits == history.0
                || newBits == history.1
                || newBits == history.2
                || newBits == history.3
            if stale {
                seed()
                return
            }
        }
        history = (history.1, history.2, history.3, newBits)
        bits = newBits
    }
}
