import Testing
import UIKit
@testable import Oppi

@Suite("Tool expanded surface host")
@MainActor
struct ToolExpandedSurfaceHostTests {
    @Test func expandedSurfaceHostActivatesExpectedSurfaceForEachMode() {
        let markdownView = ToolTimelineRowContentView(configuration: makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "# Header\n\nBody"),
            isExpanded: true
        ))
        _ = fittedTimelineSize(for: markdownView, width: 360)
        #expect(markdownView.activeExpandedSurfaceKindForTesting == .markdown)

        let diffView = ToolTimelineRowContentView(configuration: makeTimelineToolConfiguration(
            expandedContent: .diff(lines: [
                DiffLine(kind: .removed, text: "old"),
                DiffLine(kind: .added, text: "new"),
            ], path: "File.swift"),
            isExpanded: true
        ))
        _ = fittedTimelineSize(for: diffView, width: 360)
        #expect(diffView.activeExpandedSurfaceKindForTesting == .label)

    }

    @Test func surfaceHostSizesToActiveVoiceViewWithoutPriorLayout() {
        let host = ToolExpandedSurfaceHostView()
        let voiceView = NativeVoiceMessageView()
        voiceView.apply(
            id: "voice-host-size",
            message: "This final voice transcript should determine the host height immediately when the audio card replaces streaming text, without clipping the lower lines or waiting for a later collection view sizing pass to recover.",
            attachmentId: "att-1",
            mimeType: "audio/wav",
            delivery: .directSpeak,
            audioPlayer: nil,
            attachmentFetcher: nil,
            palette: ThemeRuntimeState.currentPalette()
        )
        host.activateSurfaceView(voiceView)

        let fitted = host.systemLayoutSizeFitting(
            CGSize(width: 342, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )

        #expect(fitted.height >= 130)
    }

    @Test func expandedSurfaceHostSwitchesActiveSurfaceOnReuse() {
        let view = ToolTimelineRowContentView(configuration: makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "# Header\n\nBody"),
            isExpanded: true
        ))
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(view.activeExpandedSurfaceKindForTesting == .markdown)

        view.configuration = makeTimelineToolConfiguration(
            expandedContent: .code(text: "struct App {}", language: .swift, startLine: 1, filePath: "App.swift"),
            isExpanded: true
        )
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(view.activeExpandedSurfaceKindForTesting == .label)

        view.configuration = makeTimelineToolConfiguration(
            expandedContent: .readMedia(
                output: "data:image/png;base64,abc",
                filePath: "icon.png",
                startLine: 1
            ),
            isExpanded: true
        )
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(view.activeExpandedSurfaceKindForTesting == .hosted)

        view.configuration = makeTimelineToolConfiguration(isExpanded: false)
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(view.activeExpandedSurfaceKindForTesting == .none)
    }
}
