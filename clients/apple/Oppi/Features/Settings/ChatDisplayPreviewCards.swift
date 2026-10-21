import SwiftUI

// The chat style's work strip preview, kept as a SwiftUI card for the
// screenshot harness (`QuietWorkStripPreview`). Settings → Chat draws the same
// preview in UIKit from the real timeline view (`SettingsWorkPreviewCell`), and
// both use the sample counts here so they cannot drift.

struct WorkStripPreviewCard: View {
    let style: AppPreferences.ChatDisplay.WorkStripStyle

    static let sampleWorkLine = QuietTimelineWorkLine(
        id: "settings-work-strip-preview",
        turnID: "settings-work-strip-preview",
        sourceItemIDs: [],
        buckets: [
            .init(kind: .read, count: 4),
            .init(kind: .tooling, count: 7),
            .init(kind: .write, count: 1),
            .init(kind: .edit, count: 1, editStats: .init(added: 12, removed: 3)),
        ],
        displayStyle: .icons,
        isExpanded: false,
        isLive: true,
        liveStartedAt: Date(timeIntervalSince1970: 0)
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Live Preview", systemImage: "rectangle.compress.vertical")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.themeFgDim)

            Group {
                switch style {
                case .icons:
                    HStack(spacing: 12) {
                        ForEach(Array(Self.sampleWorkLine.buckets.enumerated()), id: \.offset) { _, bucket in
                            HStack(spacing: 4) {
                                Image(systemName: bucket.kind.symbolName)
                                if bucket.kind == .edit, let stats = bucket.editStats {
                                    Text("+\(stats.added)")
                                        .foregroundStyle(.themeGreen)
                                    Text("−\(stats.removed)")
                                        .foregroundStyle(.themeRed)
                                } else {
                                    Text("\(bucket.count)")
                                }
                            }
                        }
                        Spacer(minLength: 0)
                        Text("· 7s")
                    }
                case .words:
                    wordsPreview
                }
            }
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .foregroundStyle(.themeBlue)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(.themeBlue.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.themeBlue.opacity(0.45), lineWidth: 0.5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.sampleWorkLine.wordsSummary(now: Date(timeIntervalSince1970: 7)))
        }
        .padding(.vertical, 4)
    }

    private var wordsPreview: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.sampleWorkLine.buckets.enumerated()), id: \.offset) { index, bucket in
                if index > 0 {
                    Text("  ")
                }
                if bucket.kind == .edit, let stats = bucket.editStats {
                    Text("edit ")
                    Text("+\(stats.added)")
                        .foregroundStyle(.themeGreen)
                    Text(" −\(stats.removed)")
                        .foregroundStyle(.themeRed)
                } else {
                    Text(bucket.words)
                }
            }
        }
    }
}
