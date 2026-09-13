#if DEBUG
import SwiftUI
import UIKit

// MARK: - Global Audio Banner Preview

struct GlobalAudioBannerPreview: View {
    var body: some View {
        TabView {
            NavigationStack {
                List {
                    Section("Recent") {
                        Label("Albert TTS plan", systemImage: "waveform")
                        Label("Branch + fork UX", systemImage: "arrow.triangle.branch")
                        Label("Release checklist", systemImage: "checklist")
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.themeBg)
                .navigationTitle("Workspaces")
            }
            .tabItem {
                Label("Workspaces", systemImage: "square.grid.2x2")
            }

            NavigationStack {
                Color.themeBg
                    .navigationTitle("Settings")
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
        }
        .toolbarBackground(Color.themeBg, for: .tabBar)
        .background(Color.themeBg.ignoresSafeArea())
        .accessibilityIdentifier("screenshot.ready")
    }
}


// MARK: - Voice Message Preview

struct VoiceMessageExpandedPreview: View {
    private static let previewConfiguration = ToolTimelineRowConfiguration(
        itemID: "voice-preview-1",
        title: "Voice message",
        preview: nil,
        expandedContent: .audioMessage(
            text: "Got it. I’m reinstalling the iPhone app now, and I’ll launch it as part of the install so it comes back up cleanly.",
            attachmentId: "att-voice-preview-1",
            mimeType: "audio/wav",
            durationSeconds: 4.2,
            playbackBehavior: nil
        ),
        copyCommandText: nil,
        copyOutputText: nil,
        languageBadge: nil,
        trailing: nil,
        titleLineBreakMode: .byTruncatingTail,
        toolNamePrefix: "voice_speak",
        toolNameColor: .systemPurple,
        editAdded: nil,
        editRemoved: nil,
        collapsedImageBase64: nil,
        collapsedImageMimeType: nil,
        isExpanded: true,
        isDone: true,
        isError: false,
        startedAt: nil,
        elapsedSeconds: nil,
        segmentAttributedTitle: nil,
        segmentAttributedTrailing: nil
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Expanded voice message")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.themeFg)

                Text("Regression preview for the compact expanded voice-message card.")
                    .font(.caption)
                    .foregroundStyle(.themeComment)

                VoiceMessageToolRowRepresentable(configuration: Self.previewConfiguration, width: 370)
                    .frame(width: 370)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .background(Color.themeBg.ignoresSafeArea())
        .accessibilityIdentifier("screenshot.ready")
    }
}


private struct VoiceMessageToolRowRepresentable: UIViewRepresentable {
    let configuration: ToolTimelineRowConfiguration
    let width: CGFloat

    func makeUIView(context: Context) -> VoiceMessageToolRowHostView {
        VoiceMessageToolRowHostView(configuration: configuration, width: width)
    }

    func updateUIView(_ uiView: VoiceMessageToolRowHostView, context: Context) {
        uiView.update(configuration: configuration, width: width)
    }
}


private final class VoiceMessageToolRowHostView: UIView {
    private let contentView: ToolTimelineRowContentView
    private var widthConstraint: NSLayoutConstraint?
    private var targetWidth: CGFloat

    init(configuration: ToolTimelineRowConfiguration, width: CGFloat) {
        self.contentView = ToolTimelineRowContentView(configuration: configuration)
        self.targetWidth = width
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        let widthConstraint = contentView.widthAnchor.constraint(equalToConstant: width)
        self.widthConstraint = widthConstraint
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(configuration: ToolTimelineRowConfiguration, width: CGFloat) {
        targetWidth = width
        widthConstraint?.constant = width
        contentView.configuration = configuration
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        layoutIfNeeded()
        return contentView.systemLayoutSizeFitting(
            CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
    }
}
#endif
