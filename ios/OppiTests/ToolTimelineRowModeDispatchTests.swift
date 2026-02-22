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

private func privateView(named name: String, in view: ToolTimelineRowContentView) -> UIView? {
    Mirror(reflecting: view).children.first { $0.label == name }?.value as? UIView
}

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
