import SwiftUI

/// Row for a local pi TUI session, visually matching SessionRow.
///
/// Uses the same layout as SessionRow (content + trailing time)
/// with a small "Terminal" badge in the subtitle.
struct LocalSessionRow: View {
    @Environment(\.themeID) private var themeID

    let session: LocalSession

    private var modelSummary: SessionModelSummary? {
        SessionModelSummaryBuilder.summaries(primaryModel: session.model).first
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            SessionIdentityIconView(sessionId: session.piSessionId)
                .frame(width: 20, height: 20)
                .frame(width: 24, height: 24)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.displayTitle)
                        .font(.body)
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)
                        .layoutPriority(1)

                    Spacer(minLength: 4)

                    Text(session.lastModified.relativeString())
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                        .fixedSize()
                }

                HStack(spacing: 6) {
                    Text("Terminal")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.themeComment)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.themeComment.opacity(0.15))
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
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .id(themeID)
        .padding(.vertical, 2)
    }
}
