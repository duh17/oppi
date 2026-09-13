#if DEBUG
import SwiftUI

// MARK: - Extension Surface Preview

struct ExtensionSurfacePreview: View {
    private static let autoresearchLines = [
        "━━ 🔬 autoresearch: Streaming markdown rendering latency experiment",
        "Runs: 21   9 kept   (conf: 17.1×)   12 discarded",
        "Baseline: ★ streaming_p95_us: 10,376.10µs #1",
        "Progress: ★ streaming_p95_us: 3,486.90µs #19   streaming_max_us: 8,256.20µs  −51.3%   streaming_avg_us: 2,415.90µs  −63.6%",
        "zero_change_max_us: 34.80µs  +5.8%   long_streaming_p95_us: 3,026.20µs   tail_segment_reparse_us: 712.40µs",
        "Checks: OppiTests/StreamingInlineReparseTests  ✓   OppiTests/StreamFinishFormattingTests  ✓   OppiTests/AssistantMarkdownLayoutTests  ✓",
        "Next: Add device validation loop after install/use before claiming CPU improvement.",
        "… (14 more lines)",
    ]

    private static let surface = ExtensionSurfaceState(
        widgets: [
            "autoresearch": ExtensionWidgetState(
                key: "autoresearch",
                lines: autoresearchLines,
                placement: "aboveEditor"
            ),
        ],
        nativeSurfaces: [
            "tasks": ExtensionNativeSurfaceState(
                key: "tasks",
                surface: ExtensionUINativeSurface(
                    version: 1,
                    id: "widget:tasks",
                    source: "widget",
                    presentation: ExtensionUINativePresentation(
                        style: "surfacePanel",
                        title: "1 of 5 tasks completed",
                        subtitle: nil
                    ),
                    blocks: [
                        .progress(
                            base: ExtensionUIBlockBase(id: "goal-progress", accessibility: nil),
                            label: nil,
                            value: 0.2,
                            indeterminate: nil
                        ),
                        .activityList(
                            base: ExtensionUIBlockBase(id: "goal-tasks", accessibility: nil),
                            rows: [
                                ExtensionUIActivityRow(
                                    id: "task-1",
                                    title: "Check Apple AVKit/AVFoundation playback requirements",
                                    subtitle: nil,
                                    detail: nil,
                                    state: "success",
                                    progress: nil,
                                    link: nil,
                                    children: nil
                                ),
                                ExtensionUIActivityRow(
                                    id: "task-2",
                                    title: "Read HTTP Range semantics from RFC",
                                    subtitle: nil,
                                    detail: nil,
                                    state: "running",
                                    progress: nil,
                                    link: nil,
                                    children: nil
                                ),
                                ExtensionUIActivityRow(
                                    id: "task-3",
                                    title: "Check Node.js stream/fs implementation details",
                                    subtitle: nil,
                                    detail: nil,
                                    state: "running",
                                    progress: nil,
                                    link: nil,
                                    children: nil
                                ),
                                ExtensionUIActivityRow(
                                    id: "task-4",
                                    title: "Compare current Oppi route against requirements",
                                    subtitle: nil,
                                    detail: nil,
                                    state: "inactive",
                                    progress: nil,
                                    link: nil,
                                    children: nil
                                ),
                                ExtensionUIActivityRow(
                                    id: "task-5",
                                    title: "Propose robust implementation and tests",
                                    subtitle: nil,
                                    detail: nil,
                                    state: "inactive",
                                    progress: nil,
                                    link: nil,
                                    children: nil
                                ),
                            ]
                        ),
                    ],
                    fallback: ExtensionUINativeFallback(
                        text: nil,
                        lines: ["1 of 5 tasks completed"]
                    )
                ),
                placement: "aboveEditor"
            ),
        ]
    )

    var body: some View {
        ZStack {
            Color.themeBg
                .ignoresSafeArea()

            VStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Extension surface")
                        .font(.headline)
                        .foregroundStyle(.themeFg)
                    Text("Native and terminal-compatible extension widgets use the same trailing disclosure control.")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ExtensionSurfacePanel(surface: Self.surface, placement: .aboveEditor)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
        }
        .accessibilityIdentifier("screenshot.ready")
    }
}
#endif
