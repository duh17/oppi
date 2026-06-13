#if DEBUG
import SwiftUI
import os

/// Deterministic expanded-viewport streaming markdown harness.
///
/// This intentionally avoids model output. It feeds known markdown chunks through
/// the same `AssistantMarkdownContentView` pipeline used by assistant prose while
/// the preview is already in a full-screen/expanded viewport. UI tests record the
/// simulator and sample frames + renderer debug metrics so performance experiments
/// cannot optimize CPU by introducing clipping, overlap, or visible blanking.
struct StreamingFlickerPreviewView: View {
    private static let signpostLog = OSLog(subsystem: "dev.chenda.Oppi", category: "StreamingFlicker")

    @State private var tick = 0
    @State private var renderedText = ""
    @State private var isRunning = false
    @State private var timer: Timer?
    @State private var signpostID: OSSignpostID?
    @State private var metrics = StreamingMarkdownProbeMetrics.empty

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.themeBg.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Expanded streaming markdown")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.themeFg)
                            .padding(.top, 88)

                        StreamingMarkdownProbeView(
                            content: renderedText,
                            isStreaming: isRunning,
                            metrics: $metrics
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Color.clear
                            .frame(height: 1)
                            .id("stream-bottom")
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 32)
                }
                .onChange(of: tick) { _, _ in
                    // The real user repro expands/opens the output and watches
                    // the live tail. Keep the deterministic harness pinned to
                    // the writer's live edge instead of sampling stale prefix rows.
                    withAnimation(.linear(duration: 0.055)) {
                        proxy.scrollTo("stream-bottom", anchor: .bottom)
                    }
                }
            }

            overlay
        }
        .accessibilityIdentifier("screenshot.ready")
        .onAppear { restart() }
        .onDisappear { stop(endSignpost: true) }
    }

    private var overlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Streaming flicker probe")
                .font(.caption.weight(.semibold))
            Text("tick=\(tick) running=\(isRunning ? 1 : 0) chars=\(renderedText.count)")
                .font(.caption2.monospacedDigit())
                .accessibilityIdentifier("streaming-flicker.tick")
            Text(metrics.debugLine)
                .font(.caption2.monospacedDigit())
                .accessibilityIdentifier("streaming-flicker.metrics")
            Button("Restart stream") {
                restart()
            }
            .font(.caption2.weight(.semibold))
            .accessibilityIdentifier("streaming-flicker.restart")
        }
        .padding(10)
        .foregroundStyle(.themeFg)
        .background(Color.themeBg.opacity(0.88), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.themeComment.opacity(0.24), lineWidth: 1)
        }
        .padding(8)
    }

    private func restart() {
        stop(endSignpost: true)
        tick = 0
        renderedText = ""
        metrics = .empty
        isRunning = true

        let id = OSSignpostID(log: Self.signpostLog)
        signpostID = id
        os_signpost(.animationBegin, log: Self.signpostLog, name: "StreamingMarkdown", signpostID: id)

        timer = Timer.scheduledTimer(withTimeInterval: 0.075, repeats: true) { _ in
            Task { @MainActor in
                advanceStream()
            }
        }
    }

    private func advanceStream() {
        guard isRunning else { return }
        guard tick < Self.storyChunks.count else {
            isRunning = false
            stop(endSignpost: true)
            return
        }

        renderedText += Self.storyChunks[tick]
        tick += 1
    }

    private func stop(endSignpost: Bool) {
        timer?.invalidate()
        timer = nil

        if endSignpost, let signpostID {
            os_signpost(.end, log: Self.signpostLog, name: "StreamingMarkdown", signpostID: signpostID)
            self.signpostID = nil
        }
    }

    private static let storyChunks: [String] = {
        var chunks: [String] = []
        chunks.append("# The Lantern Cartographer\n\n")
        chunks.append("_A small markdown novel streamed one deterministic breath at a time._\n\n")
        chunks.append("| Name | Trade | Problem |\n| --- | --- | --- |\n| Mira Vale | cartographer | maps streets that move |\n| Nox | lantern apprentice | hears the city through glass |\n| Orlo | ferry pilot | owns a boat that remembers storms |\n\n")

        for chapter in 1...64 {
            chunks.append("## Chapter \(chapter): The Street That Forgot Its Name\n\n")
            chunks.append("Mira drew the road as a line, but Bellwether corrected her with a patient blue shimmer. A road, the city seemed to say, is not a line. A road is an argument with weather, memory, and whoever last promised to come home before dawn.\n\n")
            chunks.append("Nox lifted the lantern. The flame bent toward an alley full of wet cobblestones, **bold shadows**, _italic rain_, and a sign that read `PLEASE MIND THE UNFINISHED METAPHOR`.\n\n")
            chunks.append("- The bridge apologized.\n- The bakery sold tomorrow's bread.\n- The map tried to bite the margin.\n- Captain Orlo pretended this was normal.\n\n")
            chunks.append("> The city does not vanish, Mira wrote. It revises itself while the eye is busy elsewhere.\n\n")
            if chapter.isMultiple(of: 4) {
                chunks.append("```swift\nstruct LanternReading {\n    let chapter: Int\n    let streetName: String\n    let renderedOverflow: Double\n}\n```\n\n")
            }
            if chapter.isMultiple(of: 6) {
                chunks.append("| Bell | Direction | Mood |\n| ---: | --- | --- |\n| \(chapter) | east by northeast | suspicious |\n| \(chapter + 1) | riverward | apologetic |\n\n")
            }
        }

        chunks.append("## Epilogue\n\nAt sunrise the lantern cooled, the map folded itself into the brass watchcase, and Bellwether kept one honest route home. Mira marked it with a star and a warning: _if the words flicker, the street is still moving._\n")
        return chunks
    }()
}

private struct StreamingMarkdownProbeMetrics: Equatable {
    var height: CGFloat
    var overflow: CGFloat
    var overlap: CGFloat

    static let empty = Self(height: 0, overflow: 0, overlap: 0)

    var debugLine: String {
        String(
            format: "height=%.1f overflow=%.1f overlap=%.1f",
            Double(height),
            Double(overflow),
            Double(overlap)
        )
    }
}

private struct StreamingMarkdownProbeView: UIViewRepresentable {
    let content: String
    let isStreaming: Bool
    @Binding var metrics: StreamingMarkdownProbeMetrics

    func makeUIView(context: Context) -> AssistantMarkdownContentView {
        let view = AssistantMarkdownContentView()
        view.backgroundColor = .clear
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ uiView: AssistantMarkdownContentView, context: Context) {
        uiView.apply(configuration: .make(
            content: content,
            isStreaming: isStreaming,
            themeID: ThemeRuntimeState.currentThemeID(),
            perfSurface: .inlineAssistant
        ))
        publishMetrics(for: uiView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: AssistantMarkdownContentView,
        context: Context
    ) -> CGSize? {
        let fallbackWidth = uiView.window?.windowScene?.screen.bounds.width ?? uiView.bounds.width
        let width = proposal.width ?? fallbackWidth
        guard width > 0 else { return nil }

        let fitting = uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: width, height: max(1, fitting.height))
    }

    private func publishMetrics(for uiView: AssistantMarkdownContentView) {
        DispatchQueue.main.async {
            uiView.layoutIfNeeded()
            let next = StreamingMarkdownProbeMetrics(
                height: uiView.bounds.height,
                overflow: uiView.debugRenderedContentOverflowPoints,
                overlap: uiView.debugMaxRenderedSegmentOverlapPoints
            )
            if next != metrics {
                metrics = next
            }
        }
    }
}
#endif
