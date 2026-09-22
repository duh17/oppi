import SwiftUI

// MARK: - Unified Spinner

/// SwiftUI view that shows a spinner style (Metal orbs, braille dots, or Game of Life).
/// Defaults to the persisted preference. Pass an explicit `style` to override
/// (e.g. for previews where the binding hasn't written to prefs yet).
struct WorkingSpinnerView: View {
    let tintColor: Color
    var style: SpinnerStyle = .current
    var side: CGFloat = 20

    var body: some View {
        switch style {
        case .working, .searching, .solving:
            if let orbStyle = style.orbStyle {
                OrbView(
                    style: orbStyle,
                    sizeClass: .working(side: Double(side)),
                    tint: tintColor
                )
            }
        case .brailleDots:
            BrailleSpinnerRepresentable(tintColor: tintColor)
        case .gameOfLife:
            GameOfLifeSpinnerRepresentable(tintColor: tintColor)
        }
    }
}

// MARK: - UIViewRepresentable Wrappers

private struct GameOfLifeSpinnerRepresentable: UIViewRepresentable {
    let tintColor: Color

    func makeUIView(context: Context) -> GameOfLifeUIView {
        let view = GameOfLifeUIView(gridSize: 6)
        view.tintUIColor = UIColor(tintColor)
        return view
    }

    func updateUIView(_ uiView: GameOfLifeUIView, context: Context) {
        uiView.tintUIColor = UIColor(tintColor)
    }
}

private struct BrailleSpinnerRepresentable: UIViewRepresentable {
    let tintColor: Color

    func makeUIView(context: Context) -> BrailleSpinnerUIView {
        let view = BrailleSpinnerUIView()
        view.tintUIColor = UIColor(tintColor)
        return view
    }

    func updateUIView(_ uiView: BrailleSpinnerUIView, context: Context) {
        uiView.tintUIColor = UIColor(tintColor)
    }
}
