import SwiftUI

// MARK: - Unified Spinner

/// SwiftUI view that shows the active spinner style (braille dots or Game of Life).
/// Used in the jump-to-bottom button to indicate agent activity while detached.
struct WorkingSpinnerView: View {
    let tintColor: Color

    var body: some View {
        switch SpinnerStyle.current {
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
