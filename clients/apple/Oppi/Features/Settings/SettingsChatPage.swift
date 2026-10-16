import SwiftUI

struct SettingsChatPage: View {
    @State private var spinnerStyle = AppPreferences.Appearance.spinnerStyle
    @State private var chatStyle = AppPreferences.ChatDisplay.style
    @State private var workStripStyle = AppPreferences.ChatDisplay.workStripStyle
    @Environment(\.screenNavigator) private var navigator

    var body: some View {
        List {
            Section {
                Picker("Busy Animation", selection: $spinnerStyle) {
                    ForEach(SpinnerStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .onChange(of: spinnerStyle) { _, newValue in
                    AppPreferences.Appearance.setSpinnerStyle(newValue)
                }
                .accessibilityIdentifier("settings.spinnerStyle")

                LabeledContent("Preview") {
                    WorkingSpinnerView(tintColor: .themeFg, style: spinnerStyle, side: 20)
                        .frame(width: 20, height: 20)
                        .id(spinnerStyle)
                }
            }

            Section {
                Picker("Style", selection: $chatStyle) {
                    ForEach(AppPreferences.ChatDisplay.Style.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: chatStyle) { _, newValue in
                    AppPreferences.ChatDisplay.setStyle(newValue)
                }
                .accessibilityIdentifier("settings.chatStyle")

                switch chatStyle {
                case .full:
                    EmptyView()
                case .compact:
                    Picker("Work Strip", selection: $workStripStyle) {
                        ForEach(AppPreferences.ChatDisplay.WorkStripStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: workStripStyle) { _, newValue in
                        AppPreferences.ChatDisplay.setWorkStripStyle(newValue)
                    }
                    .accessibilityIdentifier("settings.workStripStyle")

                    WorkStripPreviewCard(style: workStripStyle)
                case .chat:
                    ConversationWorkPillPreviewCard()
                }
            } header: {
                Text("Style")
            } footer: {
                Text(chatStyle.footer)
            }

            Section {
                SettingsIndexActionRow {
                    navigator.push { QuickCommentsSettingsView() }
                } label: {
                    Text("Quick Comments")
                }
                .accessibilityLabel("Quick Comments")
            } footer: {
                Text("Edit the quick comments shown after selecting text and choosing Comment.")
            }
        }
        .settingsPage("Chat")
        .onReceive(NotificationCenter.default.publisher(for: AppPreferences.ChatDisplay.didChangeNotification)) { _ in
            chatStyle = AppPreferences.ChatDisplay.style
            workStripStyle = AppPreferences.ChatDisplay.workStripStyle
        }
    }
}

private extension AppPreferences.ChatDisplay.Style {
    var footer: String {
        switch self {
        case .full:
            "Every tool call and thinking block stays in the transcript."
        case .compact:
            "Each turn's tool calls and thinking fold into one strip you tap to expand. Messages, asks, system events, cache misses, and audio stay visible."
        case .chat:
            "Your messages are bubbles and replies are cards. Each turn's tool calls and thinking fold into a pill you tap to expand."
        }
    }
}

/// The real conversation work row, so the preview cannot drift from the
/// timeline's pill geometry.
struct ConversationWorkPillPreviewCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Preview", systemImage: "bubble.left.and.text.bubble.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.themeFgDim)
            ConversationWorkPillRow()
                .frame(height: 44)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Worked 9s, 2 steps")
        }
        .padding(.vertical, 4)
    }
}

private struct ConversationWorkPillRow: UIViewRepresentable {
    static let sampleWorkLine = QuietTimelineWorkLine(
        id: "settings-conversation-pill-preview",
        turnID: "settings-conversation-pill-preview",
        sourceItemIDs: [],
        buckets: [.init(kind: .read, count: 1), .init(kind: .tooling, count: 1)],
        displayStyle: .icons,
        isExpanded: false,
        isLive: false,
        liveStartedAt: Date(timeIntervalSince1970: 0),
        intervalEndedAt: Date(timeIntervalSince1970: 9)
    )

    func makeUIView(context: Context) -> QuietWorkLineTimelineRowContentView {
        QuietWorkLineTimelineRowContentView(configuration: Self.configuration)
    }

    func updateUIView(_ uiView: QuietWorkLineTimelineRowContentView, context: Context) {
        uiView.configuration = Self.configuration
    }

    private static var configuration: QuietWorkLineTimelineRowConfiguration {
        QuietWorkLineTimelineRowConfiguration(workLine: sampleWorkLine, chromeStyle: .conversation)
    }
}

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
