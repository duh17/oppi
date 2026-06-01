import SwiftUI

// MARK: - Icon Grid

/// A grid of SF Symbol icons for picking a server badge icon.
/// No labels — just tappable symbol buttons in a flowing grid.
struct BadgeIconGrid: View {
    @Binding var selection: ServerBadgeIcon
    var tint: Color

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(ServerBadgeIcon.allCases) { icon in
                let isSelected = icon == selection
                Button {
                    selection = icon
                } label: {
                    Image(systemName: icon.symbolName)
                        .font(.system(size: 18))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isSelected ? tint : .themeComment)
                        .frame(width: 40, height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSelected ? tint.opacity(0.18) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isSelected ? tint.opacity(0.6) : Color.clear, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(icon.symbolName)
            }
        }
        .padding(.vertical, 4)
    }
}
