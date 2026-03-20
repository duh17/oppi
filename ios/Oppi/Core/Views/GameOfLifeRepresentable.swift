import SwiftUI

/// SwiftUI bridge for the Game of Life UIKit view.
///
/// Usage:
/// ```swift
/// GameOfLifeRepresentable(gridSize: 6, color: .purple)
///     .frame(width: 20, height: 20)
/// ```
struct GameOfLifeRepresentable: UIViewRepresentable {

    let gridSize: Int
    let color: UIColor

    init(gridSize: Int = 6, color: UIColor = .label) {
        self.gridSize = gridSize
        self.color = color
    }

    func makeUIView(context: Context) -> GameOfLifeUIView {
        let view = GameOfLifeUIView(gridSize: gridSize)
        view.tintUIColor = color
        return view
    }

    func updateUIView(_ uiView: GameOfLifeUIView, context: Context) {
        uiView.tintUIColor = color
    }
}
