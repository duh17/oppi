import SwiftUI

// The previous/next file motion and controls for file pages still in SwiftUI
// (`SessionTouchedFileContentView`). UIKit viewers slide with
// `FileBrowserPushTransitionPolicy` and `AdjacentFileNavigatorButtons`.

// MARK: - File Navigation Transition

/// The SwiftUI side of `FileBrowserPushTransitionPolicy`, for the views still
/// in SwiftUI (`SessionTouchedFileContentView`).
extension FileBrowserPushTransitionPolicy {
    static func animation(reduceMotion: Bool) -> Animation? {
        ThemeMotion.easeInOut(duration: duration, reduceMotion: reduceMotion)
    }

    static func transition(
        for direction: FileBrowserNavigationDirection,
        reduceMotion: Bool
    ) -> AnyTransition {
        guard let spec = directionalSpec(for: direction, reduceMotion: reduceMotion) else {
            return .opacity
        }
        return .asymmetric(
            insertion: ThemeMotion.move(edge: spec.insertion.edge, reduceMotion: false),
            removal: ThemeMotion.move(edge: spec.removal.edge, reduceMotion: false)
        )
    }
}

private struct FilePushTransitionModifier<ID: Hashable>: ViewModifier {
    let id: ID
    let direction: FileBrowserNavigationDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ZStack {
            content
                .id(id)
                .transition(
                    FileBrowserPushTransitionPolicy.transition(
                        for: direction,
                        reduceMotion: reduceMotion
                    )
                )
        }
        .clipped()
        .animation(FileBrowserPushTransitionPolicy.animation(reduceMotion: reduceMotion), value: id)
    }
}

extension View {
    func filePushTransition<ID: Hashable>(
        id: ID,
        direction: FileBrowserNavigationDirection
    ) -> some View {
        modifier(FilePushTransitionModifier(id: id, direction: direction))
    }
}

// MARK: - File Navigation Controls

/// Explicit file-to-file controls keep horizontal swipes reserved for back.
struct AdjacentFileNavigatorControls: ViewModifier {
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomLeading) {
                slotButton(corner: .leading, action: onPrevious)
            }
            .overlay(alignment: .bottomTrailing) {
                slotButton(corner: .trailing, action: onNext)
            }
    }

    @ViewBuilder
    private func slotButton(
        corner: AdjacentFileNavigatorLayout.Corner,
        action: @escaping () -> Void
    ) -> some View {
        if let slot = AdjacentFileNavigatorLayout.slots(
            canGoPrevious: canGoPrevious,
            canGoNext: canGoNext
        ).first(where: { $0.corner == corner }) {
            Button(action: action) {
                Image(systemName: slot.systemImage)
                    .font(.system(size: FullScreenFloatingControlChrome.symbolPointSize, weight: .semibold))
                    .foregroundStyle(.themeFg)
                    .frame(
                        width: FullScreenFloatingControlChrome.controlSize,
                        height: FullScreenFloatingControlChrome.controlSize
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .fullScreenFloatingControlGlass(in: Capsule())
            .accessibilityLabel(slot.accessibilityLabel)
            .padding(.leading, corner == .leading ? FullScreenFloatingControlChrome.leadingPadding : 0)
            .padding(.trailing, corner == .trailing ? FullScreenFloatingControlChrome.trailingPadding : 0)
            .padding(.bottom, FullScreenFloatingControlChrome.bottomPadding)
        }
    }
}

extension FileBrowserPushTransitionEdge {
    var edge: Edge {
        switch self {
        case .leading: .leading
        case .trailing: .trailing
        }
    }
}
