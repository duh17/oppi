import SwiftUI

/// Row for a local pi TUI session, visually matching SessionRow.
///
/// Uses the same layout as SessionRow (content + trailing time)
/// with a small "Terminal" badge in the subtitle.
struct LocalSessionRow: View {
    let session: LocalSession

    private var modelSummary: SessionModelSummary? {
        SessionModelSummaryBuilder.summaries(primaryModel: session.model).first
    }

    var body: some View {
        HStack(spacing: 0) {
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

                    if let modelSummary {
                        if !modelSummary.provider.isEmpty {
                            ProviderIcon(provider: modelSummary.provider, size: 11)
                        }
                        Text(modelSummary.label)
                            .truncationMode(.middle)
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
