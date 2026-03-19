import SwiftUI

/// Tappable breadcrumb shown at the top of a child session's ChatView.
///
/// Displays the parent session name with a back arrow, allowing navigation
/// back to the parent session. Only shown when the session has a `parentSessionId`.
struct ParentBreadcrumb: View {
    let parentSession: Session
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.caption2.weight(.semibold))

                Text(parentSession.displayTitle)
                    .font(.caption)
                    .lineLimit(1)

                Text("(parent)")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }
            .foregroundStyle(.themeBlue)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.themeBg)
        }
        .buttonStyle(.plain)
    }
}
