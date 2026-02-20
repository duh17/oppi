import SwiftUI

/// Row for a local pi TUI session, visually matching SessionRow.
///
/// Uses the same layout as SessionRow (dot + content + trailing time)
/// but with a gray dot and a small "Terminal" badge in the subtitle.
struct LocalSessionRow: View {
    let session: LocalSession

    var body: some View {
        HStack(spacing: 12) {
            // Gray dot — matches SessionRow's status dot position
            Circle()
                .fill(Color.themeComment.opacity(0.5))
                .frame(width: 10, height: 10)

            // Content — same VStack structure as SessionRow
            VStack(alignment: .leading, spacing: 3) {
                // Row 1: name
                Text(session.displayTitle)
                    .font(.body)
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)

                // Row 2: model + message count + terminal badge
                HStack(spacing: 6) {
                    Text("Terminal")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.themeComment)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.themeComment.opacity(0.15))
                        )

                    if let model = session.modelShort {
                        Text(model)
                    }

                    if session.messageCount > 0 {
                        Text("\(session.messageCount) msgs")
                    }
                }
                .font(.caption)
                .foregroundStyle(.themeFgDim)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Trailing: relative time — same position as SessionRow
            Text(session.lastModified.relativeString())
                .font(.caption2)
                .foregroundStyle(.themeComment)
        }
        .padding(.vertical, 2)
    }
}
