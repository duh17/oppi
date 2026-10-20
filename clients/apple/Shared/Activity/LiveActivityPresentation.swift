import SwiftUI

/// What the counts-only card says and how it looks. Shared by the widget extension and the
/// app's screenshot previews.
enum LiveActivityPresentation {
    /// "3 running · 1 needs you", "2 running", "1 needs you", or "All done".
    static func summary(_ state: OppiActivityAttributes.ContentState) -> String {
        var parts: [String] = []
        if state.running > 0 {
            parts.append(String(localized: "\(state.running) running"))
        }
        if state.needsYou > 0 {
            parts.append(
                state.needsYou == 1
                    ? String(localized: "1 needs you")
                    : String(localized: "\(state.needsYou) need you")
            )
        }
        return parts.isEmpty ? String(localized: "All done") : parts.joined(separator: " · ")
    }

    /// Waiting on the person leads: orange while anything needs you.
    static func color(_ state: OppiActivityAttributes.ContentState) -> Color {
        if state.needsYou > 0 { return needsYouColor }
        if state.running > 0 { return runningColor }
        return doneColor
    }

    static let runningColor = Color(red: 0.48, green: 0.64, blue: 0.97)
    static let needsYouColor = Color(red: 0.98, green: 0.52, blue: 0.18)
    static let doneColor = Color(red: 0.35, green: 0.86, blue: 0.62)
}

/// The app icon's pixel pi as a logo mark, drawn without a container (HIG: logo marks in a
/// Live Activity go without a container, never the whole icon). The mark takes the state
/// color; the icon's two orange spark cells stay lit only while agents run. Drawn from
/// shapes, not an image, so the Live Activity asset-size limit never applies.
struct LiveActivityPiMark: View {
    let state: OppiActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        let showsSparks = state.needsYou == 0 && state.running > 0
        ZStack {
            PixelCells(cells: showsSparks ? Self.body : Self.body + Self.sparks, columns: 6, rows: 6)
                .fill(LiveActivityPresentation.color(state))
            if showsSparks {
                PixelCells(cells: [Self.sparks[0]], columns: 6, rows: 6).fill(Self.sparkAmber)
                PixelCells(cells: [Self.sparks[1]], columns: 6, rows: 6).fill(Self.sparkRed)
            }
        }
        .frame(width: size, height: size)
    }

    // 6x6 grid (column, row) from AppIcon.icon: Assets/5-sparks.svg holds the spark cells;
    // 3-pi-mono.svg and 4-warm-detail.svg hold the rest of the pi.
    private static let sparks: [(Int, Int)] = [(0, 0), (1, 0)]
    private static let body: [(Int, Int)] = [
        (2, 0), (3, 0), (4, 0), (5, 0),
        (1, 1), (1, 2), (1, 3), (1, 4), (1, 5),
        (4, 1), (4, 2), (4, 3), (4, 4), (4, 5), (5, 5),
    ]
    private static let sparkAmber = Color(red: 0.96, green: 0.63, blue: 0.17)
    private static let sparkRed = Color(red: 0.94, green: 0.35, blue: 0.18)
}

/// A count in the pi's pixel cells: 3x5 digits one empty column apart. The default 2.4 pt
/// pitch makes a 12 pt tall digit, a little under the 18 pt pi so the mark leads. A new
/// value fades in rather than morphing cell paths.
struct LiveActivityPixelNumber: View {
    let value: Int
    let color: Color
    var cellPitch: CGFloat = 2.4

    var body: some View {
        let digits = String(max(value, 0)).compactMap(\.wholeNumberValue)
        let columns = digits.count * 4 - 1
        let cells = digits.enumerated().flatMap { index, digit in
            Self.font[digit].map { (index * 4 + $0.0, $0.1) }
        }
        PixelCells(cells: cells, columns: columns, rows: 5)
            .fill(color)
            .frame(width: CGFloat(columns) * cellPitch, height: 5 * cellPitch)
            .id(value)
            .transition(.opacity)
    }

    /// Lit (column, row) cells of each digit on a 3x5 grid.
    private static let font: [[(Int, Int)]] = [
        "111 101 101 101 111", "010 110 010 010 111", "111 001 111 100 111",
        "111 001 111 001 111", "101 101 111 001 001", "111 100 111 001 111",
        "111 100 111 101 111", "111 001 001 010 010", "111 101 111 101 111",
        "111 101 111 001 111",
    ].map { pattern in
        pattern.split(separator: " ").enumerated().flatMap { row, bits in
            bits.enumerated().compactMap { column, bit in bit == "1" ? (column, row) : nil }
        }
    }
}

/// Rounded square cells on a grid, matching the app icon's cell size and corner ratio.
private struct PixelCells: Shape {
    let cells: [(Int, Int)]
    let columns: Int
    let rows: Int

    func path(in rect: CGRect) -> Path {
        let pitch = min(rect.width / CGFloat(columns), rect.height / CGFloat(rows))
        let side = pitch * 0.88
        let inset = (pitch - side) / 2
        var path = Path()
        for (column, row) in cells {
            path.addRoundedRect(
                in: CGRect(
                    x: rect.minX + CGFloat(column) * pitch + inset,
                    y: rect.minY + CGFloat(row) * pitch + inset,
                    width: side,
                    height: side
                ),
                cornerSize: CGSize(width: side * 0.27, height: side * 0.27),
                style: .continuous
            )
        }
        return path
    }
}
