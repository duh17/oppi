import Foundation
import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("ToolTimelineRowContentView Mode Dispatch")
struct ToolTimelineRowModeDispatchTests {
    private static let testPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="

    private struct ExpectedVisibility {
        let expanded: Bool
        let command: Bool
        let output: Bool
    }

    private struct DispatchCase {
        let name: String
        let toolNamePrefix: String
        let content: ToolPresentationBuilder.ToolExpandedContent
        let expected: ExpectedVisibility
    }

    @Test func expandedModesRouteToExpectedContainers() throws {
        let cases: [DispatchCase] = [
            DispatchCase(
                name: "bash",
                toolNamePrefix: "$",
                content: .bash(command: "echo hi", output: "hi", unwrapped: true),
                expected: .init(expanded: false, command: true, output: true)
            ),
            DispatchCase(
                name: "diff",
                toolNamePrefix: "edit",
                content: .diff(lines: [
                    DiffLine(kind: .removed, text: "let x = 1"),
                    DiffLine(kind: .added, text: "let x = 2"),
                ], path: "src/main.swift"),
                expected: .init(expanded: true, command: false, output: false)
            ),
            DispatchCase(
                name: "code",
                toolNamePrefix: "read",
                content: .code(text: "struct App {}", language: .swift, startLine: 1, filePath: "App.swift"),
                expected: .init(expanded: true, command: false, output: false)
            ),
            DispatchCase(
                name: "markdown",
                toolNamePrefix: "read",
                content: .markdown(text: "# Header\n\nBody"),
                expected: .init(expanded: true, command: false, output: false)
            ),
            DispatchCase(
                name: "todoCard",
                toolNamePrefix: "todo",
                content: .todoCard(output: "{\"id\":\"TODO-1\",\"title\":\"Test\"}"),
                expected: .init(expanded: true, command: false, output: false)
            ),
            DispatchCase(
                name: "plot",
                toolNamePrefix: "plot",
                content: .plot(
                    spec: PlotChartSpec(
                        title: "Pace",
                        rows: [
                            .init(id: 0, values: ["x": .number(0), "pace": .number(295)]),
                            .init(id: 1, values: ["x": .number(1), "pace": .number(292)]),
                        ],
                        marks: [
                            .init(
                                id: "pace-line",
                                type: .line,
                                x: "x",
                                y: "pace"
                            ),
                        ],
                        xAxis: .init(label: "Distance", invert: false),
                        yAxis: .init(label: "Pace", invert: true),
                        interaction: .init(xSelection: true, xRangeSelection: false, scrollableX: false),
                        preferredHeight: 200
                    ),
                    fallbackText: "pace chart"
                ),
                expected: .init(expanded: true, command: false, output: false)
            ),
            DispatchCase(
                name: "readMedia",
                toolNamePrefix: "read",
                content: .readMedia(
                    output: "Read image file [image/png]\n\ndata:image/png;base64,\(Self.testPNGBase64)",
                    filePath: "fixtures/image.png",
                    startLine: 1
                ),
                expected: .init(expanded: true, command: false, output: false)
            ),
            DispatchCase(
                name: "text",
                toolNamePrefix: "remember",
                content: .text(text: "remembered notes", language: nil),
                expected: .init(expanded: true, command: false, output: false)
            ),
        ]

        for testCase in cases {
            let view = ToolTimelineRowContentView(configuration: makeToolConfiguration(
                toolNamePrefix: testCase.toolNamePrefix,
                expandedContent: testCase.content,
                isExpanded: true
            ))

            _ = fittedSize(for: view, width: 360)

            let expandedContainer = try #require(privateView(named: "expandedContainer", in: view))
            let commandContainer = try #require(privateView(named: "commandContainer", in: view))
            let outputContainer = try #require(privateView(named: "outputContainer", in: view))

            #expect(
                expandedContainer.isHidden == !testCase.expected.expanded,
                "Mode \(testCase.name): expanded container visibility mismatch"
            )
            #expect(
                commandContainer.isHidden == !testCase.expected.command,
                "Mode \(testCase.name): command container visibility mismatch"
            )
            #expect(
                outputContainer.isHidden == !testCase.expected.output,
                "Mode \(testCase.name): output container visibility mismatch"
            )
        }
    }

    @Test func expandedTodoItemBodyUsesMarkdownWhileKeepingMetadataRows() throws {
        let output = """
        {
          "id": "TODO-md-1",
          "title": "Render todo body as markdown",
          "status": "open",
          "created_at": "2026-02-24T09:00:00.000Z",
          "tags": ["ios", "live-activity"],
          "body": "## Summary\\n- Render markdown body\\n- Keep tags visible"
        }
        """

        let view = ToolTimelineRowContentView(configuration: makeToolConfiguration(
            toolNamePrefix: "todo",
            expandedContent: .todoCard(output: output),
            isExpanded: true
        ))

        _ = fittedSize(for: view, width: 360)

        let hosted = try #require(privateHostedExpandedView(in: view))
        let markdownView = firstView(ofType: AssistantMarkdownContentView.self, in: hosted)
        #expect(markdownView != nil)

        let labels = allLabels(in: hosted).map(renderedText(of:))
        #expect(labels.contains(where: { $0.contains("TODO-md-1") }))
        #expect(labels.contains(where: { $0.contains("tags: ios, live-activity") }))
    }

    @Test func reproducesFatalAccessConflictWhenResettingOutputScrollOnReconfigure() throws {
        let longOutput = Array(repeating: "line", count: 300).joined(separator: "\n")
        let initial = makeToolConfiguration(
            toolNamePrefix: "$",
            expandedContent: .bash(command: "tail -f log", output: longOutput, unwrapped: true),
            isExpanded: true
        )
        let cleared = makeToolConfiguration(
            toolNamePrefix: "$",
            expandedContent: .bash(command: nil, output: nil, unwrapped: true),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: initial)
        _ = fittedSize(for: view, width: 360)

        let outputScrollView = try #require(privateScrollView(named: "outputScrollView", in: view))
        outputScrollView.setContentOffset(CGPoint(x: 0, y: 120), animated: false)

        // Reconfiguring to empty output triggers resetOutputState(), which
        // programmatically resets contentOffset and synchronously calls
        // scrollViewDidScroll(). Current code passes outputShouldAutoFollow
        // as inout into resetOutputState, which can trigger a Swift exclusivity trap.
        view.configuration = cleared

        _ = fittedSize(for: view, width: 360)
    }

    @Test func expandedDiffInitialSizingBeforeLayoutPassStaysCompact() {
        let config = makeToolConfiguration(
            toolNamePrefix: "edit",
            expandedContent: .diff(lines: [
                DiffLine(kind: .removed, text: "let oldValue = false"),
                DiffLine(kind: .added, text: "let oldValue = true"),
            ], path: "Timeline/ChatTimelineCollectionView.swift"),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        let firstPassSize = fittedSizeWithoutPrelayout(for: view, width: 300)

        #expect(firstPassSize.height.isFinite)
        #expect(firstPassSize.height > 0)
        #expect(firstPassSize.height < 300, "Initial diff sizing should stay compact; got \(firstPassSize.height)")
    }

    @Test func expandedCodeInitialSizingBeforeLayoutPassStaysCompact() {
        let config = makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .code(
                text: "let title = \"tool expansion\"",
                language: .swift,
                startLine: 824,
                filePath: "Timeline/ChatTimelineCollectionView.swift"
            ),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        let firstPassSize = fittedSizeWithoutPrelayout(for: view, width: 300)

        #expect(firstPassSize.height.isFinite)
        #expect(firstPassSize.height > 0)
        #expect(firstPassSize.height < 300, "Initial code sizing should stay compact; got \(firstPassSize.height)")
    }

    @Test func expandedCodeApplySetsUnwrappedWidthImmediately() throws {
        let longCodeLine = String(repeating: "0123456789abcdef", count: 32)
        let config = makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .code(
                text: longCodeLine,
                language: .swift,
                startLine: 824,
                filePath: "Timeline/ChatTimelineCollectionView.swift"
            ),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        let widthConstraint = try #require(privateConstraint(named: "expandedLabelWidthConstraint", in: view))

        #expect(widthConstraint.priority == .required)
        #expect(
            widthConstraint.constant > 1,
            "Expanded code should set a positive unwrapped width delta during apply; got \(widthConstraint.constant)"
        )
    }

    @Test func expandedDiffApplySetsUnwrappedWidthImmediately() throws {
        let longDiffLine = String(repeating: "abcdefghijklmnopqrstuvwxyz", count: 20)
        let config = makeToolConfiguration(
            toolNamePrefix: "edit",
            expandedContent: .diff(lines: [
                DiffLine(kind: .removed, text: longDiffLine),
                DiffLine(kind: .added, text: longDiffLine + "-updated"),
            ], path: "Timeline/ChatTimelineCollectionView.swift"),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        let widthConstraint = try #require(privateConstraint(named: "expandedLabelWidthConstraint", in: view))

        #expect(widthConstraint.priority == .required)
        #expect(
            widthConstraint.constant > 1,
            "Expanded diff should set a positive unwrapped width delta during apply; got \(widthConstraint.constant)"
        )
    }
}

private func makeToolConfiguration(
    title: String = "tool title",
    toolNamePrefix: String = "read",
    expandedContent: ToolPresentationBuilder.ToolExpandedContent? = nil,
    isExpanded: Bool = false
) -> ToolTimelineRowConfiguration {
    ToolTimelineRowConfiguration(
        title: title,
        preview: nil,
        expandedContent: expandedContent,
        copyCommandText: "echo hi",
        copyOutputText: "hi",
        languageBadge: nil,
        trailing: nil,
        titleLineBreakMode: .byTruncatingTail,
        toolNamePrefix: toolNamePrefix,
        toolNameColor: .systemBlue,
        editAdded: nil,
        editRemoved: nil,
        collapsedImageBase64: nil,
        collapsedImageMimeType: nil,
        isExpanded: isExpanded,
        isDone: true,
        isError: false,
        segmentAttributedTitle: nil,
        segmentAttributedTrailing: nil
    )
}

@MainActor
private func privateView(named name: String, in view: ToolTimelineRowContentView) -> UIView? {
    Mirror(reflecting: view).children.first { $0.label == name }?.value as? UIView
}

@MainActor
private func privateScrollView(named name: String, in view: ToolTimelineRowContentView) -> UIScrollView? {
    Mirror(reflecting: view).children.first { $0.label == name }?.value as? UIScrollView
}

@MainActor
private func privateConstraint(named name: String, in view: ToolTimelineRowContentView) -> NSLayoutConstraint? {
    Mirror(reflecting: view).children.first { $0.label == name }?.value as? NSLayoutConstraint
}

@MainActor
private func privateHostedExpandedView(in view: ToolTimelineRowContentView) -> UIView? {
    Mirror(reflecting: view).children.first { $0.label == "expandedReadMediaContentView" }?.value as? UIView
}

@MainActor
private func firstView<T: UIView>(ofType type: T.Type, in root: UIView) -> T? {
    if let match = root as? T {
        return match
    }

    for child in root.subviews {
        if let found = firstView(ofType: type, in: child) {
            return found
        }
    }

    return nil
}

@MainActor
private func allLabels(in root: UIView) -> [UILabel] {
    var result: [UILabel] = []

    if let label = root as? UILabel {
        result.append(label)
    }

    for child in root.subviews {
        result.append(contentsOf: allLabels(in: child))
    }

    return result
}

@MainActor
private func renderedText(of label: UILabel) -> String {
    label.attributedText?.string ?? label.text ?? ""
}

@MainActor
private func fittedSize(for view: UIView, width: CGFloat) -> CGSize {
    let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 2_000))
    container.backgroundColor = .black

    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)

    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        view.topAnchor.constraint(equalTo: container.topAnchor),
    ])

    container.setNeedsLayout()
    container.layoutIfNeeded()

    return view.systemLayoutSizeFitting(
        CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
        withHorizontalFittingPriority: .required,
        verticalFittingPriority: .fittingSizeLevel
    )
}

@MainActor
private func fittedSizeWithoutPrelayout(for view: UIView, width: CGFloat) -> CGSize {
    let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 2_000))
    container.backgroundColor = .black

    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)

    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        view.topAnchor.constraint(equalTo: container.topAnchor),
    ])

    return view.systemLayoutSizeFitting(
        CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
        withHorizontalFittingPriority: .required,
        verticalFittingPriority: .fittingSizeLevel
    )
}
