import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum IPadReadableContentWidth {
    static let form: CGFloat = 760
    static let detail: CGFloat = 900
}

extension View {
    /// Caps long form/list content on regular-width iPad while leaving compact
    /// iPhone navigation unchanged.
    func iPadReadableContent(maxWidth: CGFloat = IPadReadableContentWidth.detail) -> some View {
        modifier(IPadReadableContentModifier(maxWidth: maxWidth))
    }
}

private struct IPadReadableContentModifier: ViewModifier {
    let maxWidth: CGFloat
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var shouldConstrain: Bool {
        guard horizontalSizeClass == .regular else { return false }
#if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad
#else
        return false
#endif
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if shouldConstrain {
            content
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity, alignment: .top)
        } else {
            content
        }
    }
}
