import SwiftUI

enum IPadReadableContentWidth {
    static let form: CGFloat = 760
    static let detail: CGFloat = 900
}

extension View {
    /// Caps long form/list content at regular width (iPad, the iPhone Duo inner
    /// display) while leaving compact-width layouts unchanged.
    func iPadReadableContent(maxWidth: CGFloat = IPadReadableContentWidth.detail) -> some View {
        modifier(IPadReadableContentModifier(maxWidth: maxWidth))
    }
}

private struct IPadReadableContentModifier: ViewModifier {
    let maxWidth: CGFloat
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @ViewBuilder
    func body(content: Content) -> some View {
        if horizontalSizeClass == .regular {
            content
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity, alignment: .top)
        } else {
            content
        }
    }
}
