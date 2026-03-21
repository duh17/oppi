import Testing
@testable import Oppi

@MainActor
@Suite("Tool expanded surface host")
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
