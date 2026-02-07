import SwiftUI

/// Tokyo Night palette (Night variant) used by host terminal theme.
extension Color {
    static let tokyoBg = Color(red: 26.0 / 255.0, green: 27.0 / 255.0, blue: 38.0 / 255.0)
    static let tokyoBgDark = Color(red: 22.0 / 255.0, green: 22.0 / 255.0, blue: 30.0 / 255.0)
    static let tokyoBgHighlight = Color(red: 41.0 / 255.0, green: 46.0 / 255.0, blue: 66.0 / 255.0)

    static let tokyoFg = Color(red: 192.0 / 255.0, green: 202.0 / 255.0, blue: 245.0 / 255.0)
    static let tokyoFgDim = Color(red: 169.0 / 255.0, green: 177.0 / 255.0, blue: 214.0 / 255.0)
    static let tokyoComment = Color(red: 86.0 / 255.0, green: 95.0 / 255.0, blue: 137.0 / 255.0)

    static let tokyoBlue = Color(red: 122.0 / 255.0, green: 162.0 / 255.0, blue: 247.0 / 255.0)
    static let tokyoCyan = Color(red: 125.0 / 255.0, green: 207.0 / 255.0, blue: 255.0 / 255.0)
    static let tokyoGreen = Color(red: 158.0 / 255.0, green: 206.0 / 255.0, blue: 106.0 / 255.0)
    static let tokyoOrange = Color(red: 255.0 / 255.0, green: 158.0 / 255.0, blue: 100.0 / 255.0)
    static let tokyoPurple = Color(red: 187.0 / 255.0, green: 154.0 / 255.0, blue: 247.0 / 255.0)
    static let tokyoRed = Color(red: 247.0 / 255.0, green: 118.0 / 255.0, blue: 142.0 / 255.0)
    static let tokyoYellow = Color(red: 224.0 / 255.0, green: 175.0 / 255.0, blue: 104.0 / 255.0)
}

extension ShapeStyle where Self == Color {
    static var tokyoBg: Color { Color.tokyoBg }
    static var tokyoBgDark: Color { Color.tokyoBgDark }
    static var tokyoBgHighlight: Color { Color.tokyoBgHighlight }
    static var tokyoFg: Color { Color.tokyoFg }
    static var tokyoFgDim: Color { Color.tokyoFgDim }
    static var tokyoComment: Color { Color.tokyoComment }
    static var tokyoBlue: Color { Color.tokyoBlue }
    static var tokyoCyan: Color { Color.tokyoCyan }
    static var tokyoGreen: Color { Color.tokyoGreen }
    static var tokyoOrange: Color { Color.tokyoOrange }
    static var tokyoPurple: Color { Color.tokyoPurple }
    static var tokyoRed: Color { Color.tokyoRed }
    static var tokyoYellow: Color { Color.tokyoYellow }
}
